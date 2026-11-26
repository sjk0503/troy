import Foundation
import TroyCore

/// One MCP tool: its listing and the function that runs it.
struct ToolSpec: Sendable {
    var name: String
    var title: String
    var description: String
    var schema: JSON
    var readOnly: Bool
    var idempotent: Bool
    var alwaysLoad: Bool
    var run: @Sendable (ToolRuntime, Arguments) throws -> String

    var listing: JSON {
        var tool: [String: JSON] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": schema,
            "annotations": [
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": false,
                "idempotentHint": .bool(idempotent),
                "openWorldHint": false,
            ],
        ]
        if alwaysLoad { tool["_meta"] = ["anthropic/alwaysLoad": true] }
        return .object(tool)
    }
}

/// The eight tools, in a fixed order.
enum Tools {
    static let all: [ToolSpec] = [context, save, update, link, search, read, projects, newProject]

    static func find(_ name: String) -> ToolSpec? { all.first { $0.name == name } }

    static var listJSON: JSON { .array(all.map(\.listing)) }

    // MARK: Schema helpers

    private static func schema(_ properties: [String: JSON], required: [String] = []) -> JSON {
        var object: [String: JSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    private static func whole(_ description: String, min: Int? = nil, max: Int? = nil) -> JSON {
        var object: [String: JSON] = ["type": "integer", "description": .string(description)]
        if let min { object["minimum"] = .int(Int64(min)) }
        if let max { object["maximum"] = .int(Int64(max)) }
        return .object(object)
    }

    private static func flag(_ description: String) -> JSON { ["type": "boolean", "description": .string(description)] }

    private static func choice(_ values: [String], _ description: String = "") -> JSON {
        var object: [String: JSON] = ["type": "string", "enum": .array(values.map { .string($0) })]
        if !description.isEmpty { object["description"] = .string(description) }
        return .object(object)
    }

    private static func strings(_ description: String, maxItems: Int) -> JSON {
        var object: [String: JSON] = ["type": "array", "items": ["type": "string"], "maxItems": .int(Int64(maxItems))]
        if !description.isEmpty { object["description"] = .string(description) }
        return .object(object)
    }

    private static let projectRef: JSON = ["type": ["integer", "string"], "description": "Project id, name or folder."]
    private static let recordNumber: JSON = ["type": "integer"]
    private static let kinds = RecordKind.allCases.map(\.rawValue)
    private static let statuses = RecordStatus.allCases.map(\.rawValue)
    private static let relations = Relation.allCases.map(\.rawValue)

    // MARK: Definitions

    static let context = ToolSpec(
        name: "troy_context", title: "Project state",
        description: "Project state: in progress and by whom, ready, blocked, collisions, decisions in effect. Call once when starting work in a project. Returns titles with #ids; bodies via troy_read.",
        schema: schema([
            "project": ["type": ["integer", "string"], "description": "Default: the project of the working folder."],
            "max_chars": whole("Default 6000.", min: 1_000),
        ]),
        readOnly: true, idempotent: true, alwaysLoad: true
    ) { runtime, args in
        try args.allow(["project", "max_chars"])
        return try runtime.context(project: try args.project(), maxChars: try args.int("max_chars", in: 1_000...100_000, clamp: true))
    }

    static let save = ToolSpec(
        name: "troy_save", title: "Save a record",
        description: "Save a task, decision, note, result or prompt to project memory, linked to related records. Use it as each decision (with its reason), finding or finished piece of work happens: one record per item. Returns the #id, similar records and collisions.",
        schema: schema([
            "project": ["type": ["integer", "string"], "description": "Id or exact name, or the folder troy_context printed: the first save there creates the project."],
            "kind": choice(kinds),
            "title": ["type": "string", "maxLength": .int(Int64(Limits.title))],
            "body": ["type": "string", "description": "Markdown. For a decision, give the reason."],
            "tags": strings("", maxItems: Limits.tagCount),
            "paths": strings("Relative to the project root.", maxItems: Limits.recordPaths),
            "status": choice(statuses, "Default open."),
            "parent": recordNumber,
            "links": [
                "type": "array", "maxItems": .int(Int64(Limits.draftLinks)),
                "items": [
                    "type": "object", "required": ["to", "relation"],
                    "properties": ["to": recordNumber, "relation": choice(relations), "note": ["type": "string", "maxLength": .int(Int64(Limits.linkNote))]],
                ],
            ],
        ], required: ["project", "kind", "title"]),
        readOnly: false, idempotent: false, alwaysLoad: true
    ) { runtime, args in try runtime.save(args) }

    static let update = ToolSpec(
        name: "troy_update", title: "Update a record",
        description: "Change a record: status (doing claims it, done finishes it), append to or rewrite the body, rename, retag. Claim work before starting; append the outcome when finishing. Refuses a claim another session holds.",
        schema: schema([
            "id": recordNumber,
            "title": ["type": "string", "maxLength": .int(Int64(Limits.title))],
            "body": ["type": "string", "description": "Replaces the whole body."],
            "append": ["type": "string", "description": "Added to the end of the body."],
            "status": choice(statuses),
            "kind": choice(kinds),
            "tags": strings("Replaces the tags.", maxItems: Limits.tagCount),
            "paths": strings("Replaces the paths.", maxItems: Limits.recordPaths),
            "takeover": flag("Claim from a session that is gone."),
        ], required: ["id"]),
        readOnly: false, idempotent: false, alwaysLoad: true
    ) { runtime, args in try runtime.update(args) }

    static let link = ToolSpec(
        name: "troy_link", title: "Link records",
        description: "Link two records, or remove a link. Reads \"from <relation> to\". Use when work depends on, replaces or contradicts other records.",
        schema: schema([
            "from": recordNumber,
            "to": ["type": ["integer", "array"], "items": ["type": "integer"], "description": "One record number or a list."],
            "relation": choice(relations),
            "note": ["type": "string", "maxLength": .int(Int64(Limits.linkNote))],
            "remove": flag("Remove the link instead."),
        ], required: ["from", "to", "relation"]),
        readOnly: false, idempotent: true, alwaysLoad: false
    ) { runtime, args in try runtime.link(args) }

    static let search = ToolSpec(
        name: "troy_search", title: "Search records",
        description: "Search records by words in titles, tags and bodies (every word must match). Use before saving and to find earlier decisions. Current project unless all_projects. Returns #ids with snippets.",
        schema: schema([
            "query": ["type": "string", "maxLength": .int(Int64(Limits.searchQuery))],
            "project": projectRef,
            "all_projects": flag("Search every project."),
            "kind": choice(kinds),
            "status": choice(statuses),
            "tag": ["type": "string"],
            "limit": whole("Default 10.", min: 1, max: 50),
        ], required: ["query"]),
        readOnly: true, idempotent: true, alwaysLoad: false
    ) { runtime, args in try runtime.search(args) }

    static let read = ToolSpec(
        name: "troy_read", title: "Read records",
        description: "Read records in full: body, links, warnings. Use when troy_context, troy_search or troy_save names a record you need. 1 to 20 ids.",
        schema: schema([
            "ids": ["type": "array", "items": ["type": "integer"], "minItems": 1, "maxItems": 20],
            "max_chars": whole("Per body. Default 8000.", min: 200),
        ], required: ["ids"]),
        readOnly: true, idempotent: true, alwaysLoad: false
    ) { runtime, args in try runtime.read(args) }

    static let projects = ToolSpec(
        name: "troy_projects", title: "List projects",
        description: "List projects with record counts and folders. Use when troy_context cannot tell which project this folder belongs to.",
        schema: schema(["include_archived": flag("Include archived projects.")]),
        readOnly: true, idempotent: true, alwaysLoad: false
    ) { runtime, args in
        try args.allow(["include_archived"])
        return try runtime.projects(includeArchived: try args.bool("include_archived") ?? false)
    }

    static let newProject = ToolSpec(
        name: "troy_new_project", title: "Create a project",
        description: "Create a project linked to a folder, so troy_context finds it there. Needed only for a custom name, or where troy_context says Troy creates no project on its own: elsewhere the first troy_save creates it. path defaults to the git root, else the working folder.",
        schema: schema([
            "name": ["type": "string", "maxLength": .int(Int64(Limits.projectName))],
            "summary": ["type": "string", "maxLength": .int(Int64(Limits.projectSummary))],
            "path": ["type": "string", "description": "Absolute folder to link."],
        ], required: ["name"]),
        readOnly: false, idempotent: false, alwaysLoad: false
    ) { runtime, args in
        try args.allow(["name", "summary", "path"])
        return try runtime.newProject(
            name: try args.requiredString("name", example: "\"troy\""), summary: try args.string("summary"), path: try args.string("path")
        )
    }
}

// MARK: - Tool bodies

extension ToolRuntime {
    private func status(_ args: Arguments) throws -> RecordStatus? {
        guard let text = try args.string("status") else { return nil }
        if text.lowercased().contains("supersed") {
            throw ToolError("\"superseded\" is not a status. Save or link the newer record with relation \"supersedes\" instead; the older one then counts as superseded.")
        }
        return try Arguments.choice(text, key: "status", as: RecordStatus.self)
    }

    func save(_ args: Arguments) throws -> String {
        try args.allow(["project", "kind", "title", "body", "tags", "paths", "status", "parent", "links"])
        let target = try saveTarget(try args.project())
        if case .project(let project) = target { usage.projectID = project.id }
        guard let kindText = try args.string("kind") else {
            throw ToolError("\"kind\" is required: task, decision, note, result or prompt.")
        }
        let kind = try Arguments.choice(kindText, key: "kind", as: RecordKind.self)
        let title = try args.requiredString("title", example: "\"Add the export command\"")
        var draft = RecordDraft(
            projectID: 0, kind: kind, title: title, body: try args.string("body") ?? "",
            tags: try args.tags() ?? [], paths: try args.paths() ?? [], status: try status(args) ?? .open,
            parent: try args.recordID("parent"), links: try linkDrafts(args)
        )
        let result: SaveResult
        let project: Project
        var createdProject = false
        switch target {
        case .project(let existing):
            draft.projectID = existing.id
            result = try store.create(draft)
            project = existing
        case .create(let pending):
            let saved: RepositorySave
            do {
                // The lookup is repeated inside the write with the same inputs as `folderState`.
                saved = try store.saveCreatingProject(
                    draft, folders: pending.folders, repositoryRoots: pending.repositoryRoots, worktree: pending.worktree,
                    enclosing: pending.enclosing, plainFolder: pending.isRepository ? nil : pending.root)
            } catch let error as TroyError {
                // Another session archived the project between the lookup and the write.
                if case .conflict(let message) = error, message.contains("is archived") { throw ToolError(message) }
                throw error
            }
            result = saved.result
            project = saved.project
            createdProject = saved.createdProject
        }
        usage.projectID = project.id
        usage.set("id", .int(result.record.id))
        usage.set("kind", .string(result.record.kind.rawValue))
        usage.set("links", .int(Int64(result.links.count)))
        usage.set("similar", .int(Int64(result.similar.count)))
        usage.set("advisories", .array(result.advisories.map { .string($0.kind.rawValue) }))
        usage.set("deduplicated", .bool(result.deduplicated))
        usage.set("created_project", .bool(createdProject))
        // A save with status "doing" claims the task just as troy_update does.
        if result.record.status == .doing, !result.deduplicated { usage.set("claim", "claimed") }
        let text = TroyText.saved(result, project: project)
        guard createdProject else { return text }
        return "Created project #\(project.id) \"\(project.name)\", linked to \(project.paths.first ?? root(of: target)).\n" + text
    }

    private func root(of target: SaveTarget) -> String {
        if case .create(let pending) = target { return pending.root }
        return ""
    }

    private enum SaveTarget {
        case project(Project)
        /// No project yet: the save creates one linked to the folder's root, unless another session just did.
        case create(PendingFolder)
    }

    /// Writes name their project: an id, an exact name, or a folder. Only a folder may lead to a
    /// new project: a repository, or a working folder in no repository that Troy takes for a
    /// project, and only when nothing else claims it.
    private func saveTarget(_ reference: String?) throws -> SaveTarget {
        let named = reference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? environment["TROY_PROJECT"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let named, let folder = ToolRuntime.folder(named) else {
            return .project(try project(reference, useDirectory: false))
        }
        switch try folderState(folder) {
        case .project(let project):
            return .project(project)
        case .pending(let pending):
            return .create(pending)
        case .archived(let project, let root):
            throw ToolError(Store.archivedMessage(project, root: root))
        case .undetermined(let worktree):
            throw ToolError(ToolRuntime.undeterminedMessage(worktree))
        case .outside(let refusal):
            throw ToolError(PlainFolder.saveRefusal(folder, refusal))
        }
    }

    private func linkDrafts(_ args: Arguments) throws -> [LinkDraft] {
        guard let value = args.values["links"], !value.isNull else { return [] }
        let example = "links: [{\"to\": 12, \"relation\": \"depends_on\"}]"
        var entries: [JSON]
        switch value {
        case .array(let array): entries = array
        case .object: entries = [value]
        default: throw ToolError("\"links\" must be a list such as \(example).")
        }
        var drafts: [LinkDraft] = []
        for entry in entries {
            guard let object = entry.object else { throw ToolError("Each item of \"links\" must be an object such as {\"to\": 12, \"relation\": \"depends_on\"}.") }
            if object["to"] == nil {
                // {"depends_on": [3, 4]} — relation names as keys.
                for (key, targets) in object.sorted(by: { $0.key < $1.key }) {
                    let relation = try Arguments.choice(key, key: "links", as: Relation.self, hint: "Write links as \(example).")
                    for id in try Arguments.recordIDs(targets, key: "links", max: Limits.draftLinks) {
                        drafts.append(LinkDraft(to: id, relation: relation))
                    }
                }
                continue
            }
            guard let relationText = object["relation"]?.string else {
                throw ToolError("Each item of \"links\" needs a \"relation\": \(Relation.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let relation = try Arguments.choice(relationText, key: "relation", as: Relation.self)
            let note = object["note"]?.string ?? ""
            for id in try Arguments.recordIDs(object["to"] ?? .null, key: "to", max: Limits.draftLinks) {
                drafts.append(LinkDraft(to: id, relation: relation, note: note))
            }
        }
        guard drafts.count <= Limits.draftLinks else {
            throw ToolError("\"links\" can create at most \(Limits.draftLinks) links in one call; got \(drafts.count).")
        }
        return drafts
    }

    func update(_ args: Arguments) throws -> String {
        let fields = ["title", "body", "append", "status", "kind", "tags", "paths", "takeover"]
        try args.allow(["id"] + fields)
        let id = try args.requiredRecordID("id")
        var patch = RecordPatch(
            title: try args.string("title"), body: try args.string("body"), append: try args.string("append"),
            kind: try args.choice("kind", as: RecordKind.self), status: try status(args),
            tags: try args.tags(), paths: try args.paths(), takeover: try args.bool("takeover") ?? false
        )
        if let append = patch.append, append.isEmpty { patch.append = nil }
        guard fields.dropLast().contains(where: { args.has($0) }) else {
            throw ToolError("Nothing to change on #\(id). Pass at least one of: \(fields.dropLast().joined(separator: ", ")). Example: {\"id\": \(id), \"status\": \"doing\"}.")
        }
        usage.set("id", .int(id))
        let old = try store.record(id: id)
        usage.projectID = old.projectID
        let result: UpdateResult
        do {
            result = try store.update(id: id, patch)
        } catch let error as TroyError {
            if case .conflict(let message) = error, message.contains("take it over if that session is gone") {
                usage.set("claim", "refused")
                throw ToolError(message.replacingOccurrences(
                    of: "take it over if that session is gone.", with: "pass \"takeover\": true if that session is gone."))
            }
            throw error
        }
        let record = result.record
        let tookOver = old.status == .doing && record.status == .doing && old.summary.assignee != nil
            && old.summary.assignee != record.summary.assignee
        if record.status != old.status { usage.set("status", .string(record.status.rawValue)) }
        if tookOver {
            usage.set("claim", "takeover")
        } else if record.status == .doing, old.status != .doing || old.summary.assignee != record.summary.assignee {
            usage.set("claim", "claimed")
        }
        usage.set("advisories", .array(result.advisories.map { .string($0.kind.rawValue) }))
        let head = "#\(record.id) \(TroyText.tagline(record.summary)) \(TroyText.quoted(record.title))"
        guard result.changed else { return "No change to \(head): it already looked like that." }
        var lines = ["Updated \(head): \(TroyText.changes(from: old, to: record, patch: patch))."]
        if old.status == .doing, record.status == .doing, let before = old.summary.assignee, before != record.summary.assignee {
            lines[0].removeLast()
            lines[0] += " (took over from \(before))."
        }
        let claimed = record.status == .doing && (old.status != .doing || old.summary.assignee != record.summary.assignee)
        if claimed, !result.advisories.isEmpty { lines.append(TroyText.advisories(result.advisories)) }
        let addsText = patch.append != nil || patch.body != nil
        if record.kind == .task, record.status == .done, old.status != .done, !addsText {
            lines.append("Add a one-line outcome so the next session knows what happened: troy_update {\"id\":\(record.id),\"append\":\"Outcome: …\"}.")
        }
        return lines.joined(separator: "\n")
    }

    func link(_ args: Arguments) throws -> String {
        try args.allow(["from", "to", "relation", "note", "remove"])
        let from = try args.requiredRecordID("from")
        guard let toValue = args.values["to"], !toValue.isNull else {
            throw ToolError("\"to\" is required: a record number or a list, for example to: [12, 13].")
        }
        let targets = try Arguments.recordIDs(toValue, key: "to", max: Limits.draftLinks)
        guard let relationText = try args.string("relation") else {
            throw ToolError("\"relation\" is required: \(Relation.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let relation = try Arguments.choice(relationText, key: "relation", as: Relation.self)
        let note = try args.string("note") ?? ""
        let remove = try args.bool("remove") ?? false
        usage.projectID = (try? store.record(id: from))?.projectID
        var added = 0
        var removed = 0
        defer {
            usage.set("added", .int(Int64(added)))
            usage.set("removed", .int(Int64(removed)))
        }

        var lines: [String] = []
        var failures: [String] = []
        for target in targets {
            do {
                let other = (try? store.record(id: target))?.summary
                let label = other.map { "#\(target) \(TroyText.tagline($0)) \($0.title)" } ?? "#\(target)"
                if remove {
                    if try store.unlink(from: from, to: target, relation: relation) {
                        removed += 1
                        lines.append("Removed: #\(from) \(relation.forwardPhrase) \(label).")
                    } else {
                        lines.append("There is no \(relation.rawValue) link between #\(from) and #\(target); nothing to remove.")
                    }
                } else {
                    _ = try store.link(from: from, to: target, relation: relation, note: note)
                    added += 1
                    var line = "Linked #\(from) \(relation.forwardPhrase) \(label)."
                    if relation == .supersedes { line += " #\(target) now counts as superseded." }
                    lines.append(line)
                }
            } catch let error as TroyError {
                failures.append("#\(from) \(relation.forwardPhrase) #\(target): \(error.message)")
            }
        }
        if lines.isEmpty { throw ToolError(failures.joined(separator: "\n")) }
        return (lines + failures).joined(separator: "\n")
    }

    func search(_ args: Arguments) throws -> String {
        try args.allow(["query", "project", "all_projects", "kind", "status", "tag", "limit"])
        let query = try args.requiredString("query", example: "\"export markdown\"")
        func set<T: RawRepresentable & CaseIterable & Hashable>(_ key: String, _ type: T.Type) throws -> Set<T> where T.RawValue == String {
            guard let items = try args.list(key, example: "[\"task\"]") else { return [] }
            return Set(try items.filter { !$0.isEmpty }.map { try Arguments.choice($0, key: key, as: type) })
        }
        return try search(
            query: query, project: try args.project(), allProjects: try args.bool("all_projects") ?? false,
            kinds: try set("kind", RecordKind.self), statuses: try set("status", RecordStatus.self),
            tag: try args.string("tag")?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            limit: try args.int("limit", in: 1...50, clamp: true) ?? 10
        )
    }

    func read(_ args: Arguments) throws -> String {
        try args.allow(["ids", "id", "max_chars"])
        let key = args.has("ids") ? "ids" : "id"
        guard let ids = try args.recordIDs(key, max: 20) else {
            throw ToolError("\"ids\" is required: record numbers such as [42, 43].")
        }
        return try read(ids: ids, maxChars: try args.int("max_chars", in: 200...100_000, clamp: true))
    }
}
