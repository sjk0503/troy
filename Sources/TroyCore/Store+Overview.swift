import Foundation

extension Store {
    func buildOverview(_ db: Database, projectID: Int64) throws -> ProjectOverview {
        let project = try fetchProject(db, id: projectID)
        let stats = try projectStats(db, projectID: projectID)
        var kindCounts: [RecordKind: Int] = [:]
        for (kind, count) in try db.query(
            "SELECT kind, count(*) FROM records WHERE project_id = ? GROUP BY kind", [.int(projectID)], { ($0.text(), Int($0.int())) }
        ) {
            if let kind = RecordKind(rawValue: kind) { kindCounts[kind] = count }
        }

        let allDoing = try db.query(
            "SELECT \(Columns.summary()) FROM records r WHERE r.project_id = ? AND r.status = 'doing' ORDER BY coalesce(r.claimed_at, r.updated_at), r.id",
            [.int(projectID)], readSummary
        )
        let doing = Array(allDoing.prefix(Limits.overviewDoing))

        let waits = """
        EXISTS (SELECT 1 FROM links l JOIN records t ON t.id = l.target_id
                WHERE l.source_id = r.id AND l.relation = 'depends_on' AND t.status NOT IN ('done', 'dropped'))
        """
        // A task another record has replaced is not something to pick up.
        let replaced = "EXISTS (SELECT 1 FROM links WHERE target_id = r.id AND relation = 'supersedes')"
        let ready = try db.query(
            "SELECT \(Columns.summary()) FROM records r WHERE r.project_id = ? AND r.kind = 'task' AND r.status = 'open' AND NOT \(waits) AND NOT \(replaced) ORDER BY r.id LIMIT ?",
            [.int(projectID), .int(Int64(Limits.overviewReady))], readSummary
        )

        let blockedRecords = try db.query(
            "SELECT \(Columns.summary()) FROM records r WHERE r.project_id = ? AND r.kind = 'task' AND r.status IN ('open', 'doing') AND \(waits) ORDER BY r.id LIMIT ?",
            [.int(projectID), .int(Int64(Limits.overviewBlocked))], readSummary
        )
        var waitingOn: [Int64: [RecordSummary]] = [:]
        if !blockedRecords.isEmpty {
            let rows = try db.query(
                """
                SELECT l.source_id, \(Columns.summary("t")) FROM links l JOIN records t ON t.id = l.target_id
                WHERE l.relation = 'depends_on' AND t.status NOT IN ('done', 'dropped') AND l.source_id IN (\(placeholders(blockedRecords.count)))
                ORDER BY l.id
                """,
                blockedRecords.map { .int($0.id) }
            ) { row -> (Int64, RecordSummary) in
                let source = row.int()
                return (source, readSummary(row))
            }
            for (source, target) in rows { waitingOn[source, default: []].append(target) }
        }
        let blocked = blockedRecords.map { BlockedRecord(record: $0, waitingOn: waitingOn[$0.id] ?? []) }

        var collisions: [Collision] = try db.query(
            """
            SELECT l.note, \(Columns.summary("a")), \(Columns.summary("b"))
            FROM links l JOIN records a ON a.id = l.source_id JOIN records b ON b.id = l.target_id
            WHERE l.relation = 'conflicts_with' AND a.project_id = ?1 AND b.project_id = ?1
              AND a.status NOT IN ('done', 'dropped') AND b.status NOT IN ('done', 'dropped')
            ORDER BY l.id DESC LIMIT ?2
            """,
            [.int(projectID), .int(Int64(Limits.overviewCollisions))]
        ) { row -> Collision in
            let note = row.text()
            let first = readSummary(row)
            return Collision(first: first, second: readSummary(row), kind: .conflict, detail: note)
        }
        outer: for i in allDoing.indices {
            for j in allDoing.indices where j > i {
                if collisions.count >= Limits.overviewCollisions { break outer }
                let a = allDoing[i], b = allDoing[j]
                guard (a.assignee ?? "") != (b.assignee ?? "") else { continue }
                let shared = PathRules.sharedPaths(a.paths, b.paths)
                if !shared.isEmpty {
                    collisions.append(Collision(first: a, second: b, kind: .pathOverlap, detail: shared.joined(separator: ", ")))
                }
            }
        }

        let decisions = try db.query(
            """
            SELECT \(Columns.summary()) FROM records r
            WHERE r.project_id = ? AND r.kind = 'decision' AND r.status <> 'dropped'
              AND NOT EXISTS (SELECT 1 FROM links WHERE target_id = r.id AND relation = 'supersedes')
            ORDER BY r.updated_at DESC, r.id DESC LIMIT ?
            """,
            [.int(projectID), .int(Int64(Limits.overviewDecisions))], readSummary
        )

        var listed = Set<Int64>()
        for record in doing + ready + blocked.map(\.record) + decisions { listed.insert(record.id) }
        for collision in collisions {
            listed.insert(collision.first.id)
            listed.insert(collision.second.id)
        }
        let candidates = try db.query(
            "SELECT \(Columns.summary()) FROM records r WHERE r.project_id = ? ORDER BY r.updated_at DESC, r.id DESC LIMIT ?",
            [.int(projectID), .int(Int64(Limits.overviewRecent + listed.count))], readSummary
        )
        let recent = Array(candidates.filter { !listed.contains($0.id) }.prefix(Limits.overviewRecent))

        var shown = listed
        for record in recent { shown.insert(record.id) }
        var parents: [Int64: [Int64]] = [:]
        if !shown.isEmpty {
            let ids = shown.sorted()
            for (source, target) in try db.query(
                "SELECT source_id, target_id FROM links WHERE relation = 'part_of' AND source_id IN (\(placeholders(ids.count))) ORDER BY id",
                ids.map { .int($0) }, { ($0.int(), $0.int()) }
            ) {
                parents[source, default: []].append(target)
            }
        }
        return ProjectOverview(
            project: project, stats: stats, kindCounts: kindCounts, doing: doing, ready: ready, blocked: blocked,
            collisions: collisions, decisions: decisions, recent: recent, parents: parents
        )
    }

    // MARK: Graph

    func buildGraph(_ db: Database, projectID: Int64?) throws -> GraphSnapshot {
        var args: [SQLValue] = []
        var scope = ""
        if let projectID {
            guard try db.exists("SELECT 1 FROM projects WHERE id = ?", [.int(projectID)]) else {
                throw TroyError.notFound("No project #\(projectID).")
            }
            scope = "WHERE r.project_id = ?"
            args.append(.int(projectID))
        }
        let total = try db.int("SELECT count(*) FROM records r \(scope)", args) ?? 0
        let records = try db.query(
            "SELECT \(Columns.summary()) FROM records r \(scope) ORDER BY r.updated_at DESC, r.id DESC LIMIT ?",
            args + [.int(Int64(Limits.graphRecords))], readSummary
        )
        let ids = Set(records.map(\.id))
        let candidates: [RecordLink]
        if let projectID {
            candidates = try db.query(
                """
                SELECT \(Columns.link) FROM links l
                WHERE l.source_id IN (SELECT id FROM records WHERE project_id = ?1)
                  AND l.target_id IN (SELECT id FROM records WHERE project_id = ?1)
                ORDER BY l.id
                """,
                [.int(projectID)], readLink
            )
        } else {
            candidates = try db.query("SELECT \(Columns.link) FROM links l ORDER BY l.id", [], readLink)
        }
        return GraphSnapshot(
            records: records, links: candidates.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) },
            truncated: Int(total) > Limits.graphRecords
        )
    }

    // MARK: Export

    func buildExport(_ db: Database, projectID: Int64?) throws -> String {
        let projects: [Project]
        if let projectID {
            projects = [try fetchProject(db, id: projectID)]
        } else {
            let all = try projectList(db, includeArchived: true).map(\.project)
            projects = all.sorted { $0.id < $1.id }
        }
        let stamp = ISO8601DateFormatter()
        func when(_ date: Date) -> String { stamp.string(from: date) }

        var out = "# Troy export\n\nExported \(when(Date())). \(projects.count) project\(projects.count == 1 ? "" : "s").\n"
        for project in projects {
            out += "\n## Project #\(project.id) \(project.name)\n\n"
            if project.status == .archived { out += "Archived.\n" }
            if !project.summary.isEmpty { out += project.summary + "\n\n" }
            if !project.paths.isEmpty { out += "Folders: " + project.paths.joined(separator: ", ") + "\n" }
            let rows = try db.query(
                "SELECT \(Columns.summary()), r.body, r.rev FROM records r WHERE r.project_id = ? ORDER BY r.id",
                [.int(project.id)]
            ) { row -> Record in
                let summary = readSummary(row)
                return Record(summary: summary, body: row.text(), rev: Int(row.int()))
            }
            out += "\n\(rows.count) record\(rows.count == 1 ? "" : "s").\n"
            for record in rows {
                var status = record.status.rawValue
                if let holder = record.summary.assignee, record.status == .doing { status += " by \(holder)" }
                if record.summary.isSuperseded { status += ", superseded" }
                out += "\n### #\(record.id) \(record.title)\n\n"
                out += "- kind: \(record.kind.rawValue)\n- status: \(status)\n"
                out += "- tags: \(record.tags.isEmpty ? "none" : record.tags.joined(separator: ", "))\n"
                if !record.paths.isEmpty { out += "- paths: \(record.paths.joined(separator: ", "))\n" }
                out += "- created \(when(record.summary.createdAt)) by \(record.summary.source.isEmpty ? "unknown" : record.summary.source); updated \(when(record.summary.updatedAt))\n"
                if !record.body.isEmpty { out += "\n" + record.body + "\n" }
            }
        }

        let select = """
        SELECT \(Columns.link) FROM links l
        """
        let links: [RecordLink]
        if let projectID {
            links = try db.query(
                """
                \(select) WHERE l.source_id IN (SELECT id FROM records WHERE project_id = ?1)
                   OR l.target_id IN (SELECT id FROM records WHERE project_id = ?1) ORDER BY l.id
                """,
                [.int(projectID)], readLink
            )
        } else {
            links = try db.query("\(select) ORDER BY l.id", [], readLink)
        }
        out += "\n## Links\n\n"
        if links.isEmpty {
            out += "None.\n"
        } else {
            for link in links {
                out += "- #\(link.sourceID) \(link.relation.rawValue) #\(link.targetID)"
                if !link.note.isEmpty { out += " — \(link.note)" }
                out += "\n"
            }
        }
        return out
    }
}
