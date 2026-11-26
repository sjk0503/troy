import Foundation

/// A draft whose fields passed validation and normalization.
struct CheckedDraft {
    var projectID: Int64
    var kind: RecordKind
    var title: String
    var body: String
    var tags: [String]
    var paths: [String]
    var status: RecordStatus
    var parent: Int64?
    var links: [LinkDraft]

    init(_ draft: RecordDraft) throws {
        projectID = draft.projectID
        kind = draft.kind
        title = try TextRules.required(draft.title, field: "Title", max: Limits.title)
        body = try TextRules.verbatim(draft.body, field: "Body", max: Limits.body)
        tags = try TagRules.normalize(draft.tags)
        paths = try PathRules.recordPaths(draft.paths)
        status = draft.status
        parent = draft.parent
        guard draft.links.count <= Limits.draftLinks else {
            throw TroyError.invalid("A record can be saved with at most \(Limits.draftLinks) links; got \(draft.links.count).")
        }
        links = try draft.links.map {
            LinkDraft(to: $0.to, relation: $0.relation, note: try TextRules.optional($0.note, field: "Link note", max: Limits.linkNote))
        }
    }
}

/// A patch whose fields passed validation and normalization.
struct CheckedPatch {
    var title: String?
    var body: String?
    var append: String?
    var kind: RecordKind?
    var status: RecordStatus?
    var tags: [String]?
    var paths: [String]?
    var projectID: Int64?
    var takeover: Bool
    var expectedRev: Int?

    init(_ patch: RecordPatch) throws {
        if patch.body != nil && patch.append != nil {
            throw TroyError.invalid("Pass either body (replace the text) or append (add to it), not both.")
        }
        title = try patch.title.map { try TextRules.required($0, field: "Title", max: Limits.title) }
        body = try patch.body.map { try TextRules.verbatim($0, field: "Body", max: Limits.body) }
        append = try patch.append.map { try TextRules.verbatim($0, field: "Appended text", max: Limits.body) }
        kind = patch.kind
        status = patch.status
        tags = try patch.tags.map { try TagRules.normalize($0) }
        paths = try patch.paths.map { try PathRules.recordPaths($0) }
        projectID = patch.projectID
        takeover = patch.takeover
        expectedRev = patch.expectedRev
    }
}

struct InsertOutcome {
    var id: Int64
    var links: [RecordLink]
    var deduplicated: Bool
}

extension Store {
    func fetchRecord(_ db: Database, id: Int64) throws -> Record {
        guard let record = try db.first(
            "SELECT \(Columns.summary()), r.body, r.rev FROM records r WHERE r.id = ?", [.int(id)],
            { row in
                let summary = readSummary(row)
                return Record(summary: summary, body: row.text(), rev: Int(row.int()))
            }
        ) else { throw TroyError.notFound("No record #\(id).") }
        return record
    }

    func requireRecord(_ db: Database, id: Int64) throws {
        guard try db.exists("SELECT 1 FROM records WHERE id = ?", [.int(id)]) else {
            throw TroyError.notFound("No record #\(id).")
        }
    }

    func listRecords(_ db: Database, _ query: RecordQuery) throws -> [RecordSummary] {
        var clauses: [String] = []
        var args: [SQLValue] = []
        appendFilters(&clauses, &args, projectID: query.projectID, kinds: query.kinds, statuses: query.statuses, tag: query.tag)
        if !query.includeSuperseded {
            clauses.append("NOT EXISTS (SELECT 1 FROM links WHERE target_id = r.id AND relation = 'supersedes')")
        }
        let order = query.sort == .createdDescending ? "r.created_at DESC, r.id DESC" : "r.updated_at DESC, r.id DESC"
        let limit = min(max(query.limit, 0), Limits.listLimit)
        let offset = max(query.offset, 0)
        args.append(.int(Int64(limit)))
        args.append(.int(Int64(offset)))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try db.query(
            "SELECT \(Columns.summary()) FROM records r \(whereSQL) ORDER BY \(order) LIMIT ? OFFSET ?", args, readSummary
        )
    }

    /// Filters shared by `list` and `search`. The records table is aliased `r`.
    func appendFilters(
        _ clauses: inout [String], _ args: inout [SQLValue],
        projectID: Int64?, kinds: Set<RecordKind>, statuses: Set<RecordStatus>, tag: String?
    ) {
        if let projectID {
            clauses.append("r.project_id = ?")
            args.append(.int(projectID))
        }
        if !kinds.isEmpty {
            clauses.append("r.kind IN (\(placeholders(kinds.count)))")
            args.append(contentsOf: kinds.map(\.rawValue).sorted().map { SQLValue.text($0) })
        }
        if !statuses.isEmpty {
            clauses.append("r.status IN (\(placeholders(statuses.count)))")
            args.append(contentsOf: statuses.map(\.rawValue).sorted().map { SQLValue.text($0) })
        }
        if let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            clauses.append("EXISTS (SELECT 1 FROM json_each(r.tags) WHERE value = ? COLLATE NOCASE)")
            args.append(.text(tag))
        }
    }

    // MARK: Create

    func insertRecord(_ db: Database, _ draft: CheckedDraft, agent: String) throws -> (value: InsertOutcome, wrote: Bool) {
        guard try db.exists("SELECT 1 FROM projects WHERE id = ?", [.int(draft.projectID)]) else {
            throw TroyError.notFound("No project #\(draft.projectID).")
        }
        let now = Clock.nowMillis()
        let windowStart = now - Int64(Limits.dedupeWindowSeconds) * 1000
        if let existing = try db.int(
            """
            SELECT id FROM records
            WHERE project_id = ? AND kind = ? AND title = ? AND body = ? AND tags = ? AND paths = ? AND status = ?
              AND source = ? AND created_at >= ?
            ORDER BY id DESC LIMIT 1
            """,
            [
                .int(draft.projectID), .text(draft.kind.rawValue), .text(draft.title), .text(draft.body),
                .text(JSONText.encode(draft.tags)), .text(JSONText.encode(draft.paths)), .text(draft.status.rawValue),
                .text(agent), .int(windowStart),
            ]
        ) {
            // The record is already there, but this call may carry links the first one did not.
            var links: [RecordLink] = []
            var wrote = false
            var wanted = draft.links
            if let parent = draft.parent { wanted.insert(LinkDraft(to: parent, relation: .partOf), at: 0) }
            for draftLink in wanted {
                let added = try insertLink(db, from: existing, to: draftLink.to, relation: draftLink.relation, note: draftLink.note, agent: agent)
                if added.wrote { wrote = true }
                if !links.contains(where: { $0.id == added.link.id }) { links.append(added.link) }
            }
            return (InsertOutcome(id: existing, links: links, deduplicated: true), wrote)
        }
        let claim = draft.status == .doing
        try db.run(
            """
            INSERT INTO records (project_id, kind, status, title, body, tags, paths, source, assignee, claimed_at, rev, created_at, updated_at, updated_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """,
            [
                .int(draft.projectID), .text(draft.kind.rawValue), .text(draft.status.rawValue), .text(draft.title), .text(draft.body),
                .text(JSONText.encode(draft.tags)), .text(JSONText.encode(draft.paths)), .text(agent),
                claim ? .text(agent) : .null, claim ? .int(now) : .null, .int(now), .int(now), .text(agent),
            ]
        )
        let id = db.lastInsertRowID
        var created: [RecordLink] = []
        func add(_ link: RecordLink) { if !created.contains(where: { $0.id == link.id }) { created.append(link) } }
        if let parent = draft.parent {
            add(try insertLink(db, from: id, to: parent, relation: .partOf, note: "", agent: agent).link)
        }
        for draftLink in draft.links {
            add(try insertLink(db, from: id, to: draftLink.to, relation: draftLink.relation, note: draftLink.note, agent: agent).link)
        }
        return (InsertOutcome(id: id, links: created, deduplicated: false), true)
    }

    // MARK: Update

    private struct OldRow {
        var projectID: Int64
        var kind: RecordKind
        var status: RecordStatus
        var title: String
        var tags: [String]
        var paths: [String]
        var assignee: String?
        var claimedAt: Int64?
        var rev: Int
        var updatedAt: Int64
        var bodyLength: Int
    }

    /// Returns true when something was written.
    func applyPatch(_ db: Database, id: Int64, _ patch: CheckedPatch, agent: String) throws -> Bool {
        guard let old = try db.first(
            "SELECT project_id, kind, status, title, tags, paths, assignee, claimed_at, rev, updated_at, length(body) FROM records WHERE id = ?",
            [.int(id)],
            { row in
                OldRow(
                    projectID: row.int(), kind: RecordKind(rawValue: row.text()) ?? .note,
                    status: RecordStatus(rawValue: row.text()) ?? .open, title: row.text(),
                    tags: JSONText.decodeStrings(row.text()), paths: JSONText.decodeStrings(row.text()),
                    assignee: row.optText(), claimedAt: row.optInt(), rev: Int(row.int()), updatedAt: row.int(),
                    bodyLength: Int(row.int())
                )
            }
        ) else { throw TroyError.notFound("No record #\(id).") }

        if let expected = patch.expectedRev, expected != old.rev {
            throw TroyError.conflict(
                "#\(id) changed since you read it (it is at revision \(old.rev), you expected \(expected)). Read it again and redo the change."
            )
        }
        let now = Clock.nowMillis()
        var sets: [String] = []
        var args: [SQLValue] = []

        if let title = patch.title, title != old.title {
            sets.append("title = ?")
            args.append(.text(title))
        }
        if let body = patch.body {
            let current = try db.first("SELECT body FROM records WHERE id = ?", [.int(id)]) { $0.text() } ?? ""
            if body != current {
                sets.append("body = ?")
                args.append(.text(body))
            }
        }
        if let append = patch.append, !append.isEmpty {
            let added = old.bodyLength == 0 ? append.count : old.bodyLength + 2 + append.count
            guard added <= Limits.body else {
                throw TroyError.invalid(
                    "Appending \(append.count) characters would make #\(id) \(added) characters long; the limit is \(Limits.body)."
                )
            }
            sets.append("body = CASE WHEN body = '' THEN ? ELSE body || char(10) || char(10) || ? END")
            args.append(.text(append))
            args.append(.text(append))
        }
        if let kind = patch.kind, kind != old.kind {
            sets.append("kind = ?")
            args.append(.text(kind.rawValue))
        }
        if let tags = patch.tags, tags != old.tags {
            sets.append("tags = ?")
            args.append(.text(JSONText.encode(tags)))
        }
        if let paths = patch.paths, paths != old.paths {
            sets.append("paths = ?")
            args.append(.text(JSONText.encode(paths)))
        }
        if let projectID = patch.projectID, projectID != old.projectID {
            guard try db.exists("SELECT 1 FROM projects WHERE id = ?", [.int(projectID)]) else {
                throw TroyError.notFound("No project #\(projectID).")
            }
            sets.append("project_id = ?")
            args.append(.int(projectID))
        }

        if let status = patch.status {
            var claims = false
            var clears = false
            // While another agent holds the record, any status change needs an explicit takeover.
            // Checking only "doing" would leave a way round the claim: set it to open, then claim it.
            let heldByOther = old.status == .doing && old.assignee != nil && old.assignee != agent
            if heldByOther && !patch.takeover {
                let holder = old.assignee ?? ""
                let claimed = old.claimedAt.map { ", claimed " + Age.ago(since: Clock.date($0), now: Clock.date(now)) } ?? ""
                throw TroyError.conflict(
                    "#\(id) is in progress by \(holder)\(claimed). Pick other work, or take it over if that session is gone."
                )
            }
            if status == .doing {
                claims = old.status != .doing || heldByOther || old.assignee == nil
            } else if old.status == .doing {
                clears = true
            }
            if status != old.status {
                sets.append("status = ?")
                args.append(.text(status.rawValue))
            }
            if claims {
                sets.append("assignee = ?")
                args.append(.text(agent))
                sets.append("claimed_at = ?")
                args.append(.int(now))
            } else if clears {
                sets.append("assignee = NULL")
                sets.append("claimed_at = NULL")
            }
        }

        if sets.isEmpty { return false }
        sets.append("rev = rev + 1")
        sets.append("updated_at = ?")
        args.append(.int(max(now, old.updatedAt + 1)))
        sets.append("updated_by = ?")
        args.append(.text(agent))
        args.append(.int(id))
        try db.run("UPDATE records SET \(sets.joined(separator: ", ")) WHERE id = ?", args)
        return true
    }

    // MARK: History and tags

    func fetchVersions(_ db: Database, of id: Int64, limit: Int) throws -> [RecordVersion] {
        try requireRecord(db, id: id)
        let count = min(max(limit, 0), Limits.versionKeep)
        return try db.query(
            "SELECT id, record_id, rev, changed, actor, created_at FROM record_versions WHERE record_id = ? ORDER BY id DESC LIMIT ?",
            [.int(id), .int(Int64(count))]
        ) { row in
            let versionID = row.int()
            let recordID = row.int()
            let rev = Int(row.int())
            let changed = row.text()
            let actor = row.text()
            let at = Clock.date(row.int())
            let object = (try? JSONSerialization.jsonObject(with: Data(changed.utf8))) as? [String: Any] ?? [:]
            return RecordVersion(
                id: versionID, recordID: recordID, rev: rev, actor: actor, changedAt: at,
                title: object["title"] as? String, body: object["body"] as? String,
                kind: (object["kind"] as? String).flatMap(RecordKind.init(rawValue:)),
                status: (object["status"] as? String).flatMap(RecordStatus.init(rawValue:)),
                tags: object["tags"] as? [String], paths: object["paths"] as? [String],
                projectID: (object["projectID"] as? NSNumber)?.int64Value, assignee: object["assignee"] as? String
            )
        }
    }

    func tagCounts(_ db: Database, projectID: Int64?) throws -> [TagCount] {
        var sql = "SELECT min(j.value), count(*) FROM records r, json_each(r.tags) j"
        var args: [SQLValue] = []
        if let projectID {
            sql += " WHERE r.project_id = ?"
            args.append(.int(projectID))
        }
        sql += " GROUP BY lower(j.value) ORDER BY count(*) DESC, lower(j.value)"
        return try db.query(sql, args) { TagCount(tag: $0.text(), count: Int($0.int())) }
    }
}
