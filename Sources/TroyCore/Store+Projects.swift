import Foundation

extension Store {
    func fetchProject(_ db: Database, id: Int64) throws -> Project {
        guard let base = try db.first(
            "SELECT \(Columns.project) FROM projects WHERE id = ?", [.int(id)], { readProjectRow($0) }
        ) else { throw TroyError.notFound("No project #\(id).") }
        return withPaths(base, try projectPaths(db, projectID: id))
    }

    private func readProjectRow(_ row: Row) -> Project {
        Project(
            id: row.int(), name: row.text(), summary: row.text(), paths: [],
            status: ProjectStatus(rawValue: row.text()) ?? .active,
            createdAt: Clock.date(row.int()), updatedAt: Clock.date(row.int())
        )
    }

    private func withPaths(_ project: Project, _ paths: [String]) -> Project {
        var copy = project
        copy.paths = paths
        return copy
    }

    func projectPaths(_ db: Database, projectID: Int64) throws -> [String] {
        try db.query("SELECT path FROM project_paths WHERE project_id = ? ORDER BY path", [.int(projectID)]) { $0.text() }
    }

    func projectStats(_ db: Database, projectID: Int64) throws -> ProjectStats {
        try db.first(
            """
            SELECT count(*), coalesce(sum(kind = 'task' AND status = 'open'), 0), coalesce(sum(status = 'doing'), 0), max(updated_at)
            FROM records WHERE project_id = ?
            """,
            [.int(projectID)]
        ) { row in
            ProjectStats(
                records: Int(row.int()), openTasks: Int(row.int()), doing: Int(row.int()), lastActivity: row.optInt().map(Clock.date)
            )
        } ?? ProjectStats()
    }

    func projectList(_ db: Database, includeArchived: Bool) throws -> [ProjectSummary] {
        var pathsByProject: [Int64: [String]] = [:]
        for (id, path) in try db.query("SELECT project_id, path FROM project_paths ORDER BY path", [], { ($0.int(), $0.text()) }) {
            pathsByProject[id, default: []].append(path)
        }
        let rows = try db.query(
            """
            SELECT p.id, p.name, p.summary, p.status, p.created_at, p.updated_at,
              (SELECT count(*) FROM records WHERE project_id = p.id),
              (SELECT count(*) FROM records WHERE project_id = p.id AND kind = 'task' AND status = 'open'),
              (SELECT count(*) FROM records WHERE project_id = p.id AND status = 'doing'),
              (SELECT max(updated_at) FROM records WHERE project_id = p.id)
            FROM projects p
            WHERE (? OR p.status = 'active')
            ORDER BY coalesce((SELECT max(updated_at) FROM records WHERE project_id = p.id), p.updated_at) DESC, p.id DESC
            """,
            [.int(includeArchived ? 1 : 0)]
        ) { row -> ProjectSummary in
            let project = readProjectRow(row)
            let stats = ProjectStats(
                records: Int(row.int()), openTasks: Int(row.int()), doing: Int(row.int()), lastActivity: row.optInt().map(Clock.date)
            )
            return ProjectSummary(project: project, stats: stats)
        }
        return rows.map { ProjectSummary(project: withPaths($0.project, pathsByProject[$0.project.id] ?? []), stats: $0.stats) }
    }

    func resolve(_ db: Database, reference: String?, directory: String?, exactName: Bool = false) throws -> Project {
        let active = try projectList(db, includeArchived: false).map(\.project)
        if let raw = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let isNumber = raw.allSatisfy(\.isASCII) && raw.allSatisfy(\.isNumber)
            if isNumber, let id = Int64(raw), let found = try? fetchProject(db, id: id) {
                return found
            }
            if let id = try db.int("SELECT id FROM projects WHERE name = ? COLLATE NOCASE", [.text(raw)]) {
                return try fetchProject(db, id: id)
            }
            // A number is an id. When no project has it, a project whose name merely contains
            // those digits ("release-42" for 42) is not what was asked for.
            if isNumber { throw TroyError.notFound("No project #\(raw). \(listing(active))") }
            let matches = active.filter { $0.name.range(of: raw, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            if exactName {
                let closest = matches.isEmpty ? listing(active) : "Closest: \(describe(matches))."
                throw TroyError.notFound("No project is named \"\(raw)\". \(closest) Use the id or the exact name.")
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw TroyError.invalid(
                    "\"\(raw)\" matches more than one project: \(describe(matches)). Use the id or the exact name."
                )
            }
            throw TroyError.notFound("No project matches \"\(raw)\". \(listing(active))")
        }
        if let raw = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let normalized = try? PathRules.normalizeDirectory(raw) {
            if let best = closestLink(active, to: normalized) { return best.project }
            throw TroyError.notFound("No project is linked to \(normalized). \(listing(active))")
        }
        throw TroyError.notFound("No project given and no folder to match. \(listing(active))")
    }

    /// The project whose linked folder is `folder` or its closest ancestor, comparing canonical
    /// paths, with that link in canonical form. Only links `accepts` lets through take part.
    func closestLink(
        _ projects: [Project], to folder: String, where accepts: (String) -> Bool = { _ in true }
    ) -> (project: Project, link: String)? {
        let asked = PathRules.canonical(folder)
        var best: (project: Project, link: String)?
        for project in projects {
            for linked in project.paths {
                let link = PathRules.canonical(linked)
                guard PathRules.contains(ancestor: link, asked), accepts(link) else { continue }
                if best == nil || link.count > best!.link.count { best = (project, link) }
            }
        }
        return best
    }

    private func describe(_ projects: [Project]) -> String {
        projects.map { "#\($0.id) \($0.name)" }.joined(separator: ", ")
    }

    private func listing(_ projects: [Project]) -> String {
        projects.isEmpty ? "There are no active projects yet." : "Active projects: \(describe(projects))."
    }

    func insertProject(_ db: Database, name: String, summary: String, paths: [String]) throws -> Project {
        if let existing = try db.int("SELECT id FROM projects WHERE name = ? COLLATE NOCASE", [.text(name)]) {
            throw TroyError.conflict("A project named \"\(name)\" already exists (#\(existing)).")
        }
        try checkPathsFree(db, paths: paths, except: nil)
        let now = Clock.nowMillis()
        try db.run(
            "INSERT INTO projects (name, summary, status, created_at, updated_at) VALUES (?, ?, 'active', ?, ?)",
            [.text(name), .text(summary), .int(now), .int(now)]
        )
        let id = db.lastInsertRowID
        for path in paths {
            try db.run("INSERT INTO project_paths (path, project_id) VALUES (?, ?)", [.text(path), .int(id)])
        }
        return try fetchProject(db, id: id)
    }

    /// A folder belongs to at most one project, whatever its spelling (case, symlinks, firmlinks).
    private func checkPathsFree(_ db: Database, paths: [String], except projectID: Int64?) throws {
        let links = try db.query(
            "SELECT p.id, p.name, x.path FROM project_paths x JOIN projects p ON p.id = x.project_id", [],
            { ($0.int(), $0.text(), $0.text()) }
        )
        let taken = links.map { (id: $0.0, name: $0.1, path: PathRules.canonical($0.2)) }
        for path in paths {
            let wanted = PathRules.canonical(path)
            if let owner = taken.first(where: { $0.path == wanted }), owner.id != projectID {
                throw TroyError.conflict("The folder \(path) is already linked to project #\(owner.id) \(owner.name).")
            }
        }
    }

    func changeProject(
        _ db: Database, id: Int64, name: String?, summary: String?, status: ProjectStatus?, paths: [String]?
    ) throws -> (value: Project, wrote: Bool) {
        let old = try fetchProject(db, id: id)
        var sets: [String] = []
        var args: [SQLValue] = []
        if let name, name != old.name {
            if let other = try db.int("SELECT id FROM projects WHERE name = ? COLLATE NOCASE AND id <> ?", [.text(name), .int(id)]) {
                throw TroyError.conflict("A project named \"\(name)\" already exists (#\(other)).")
            }
            sets.append("name = ?")
            args.append(.text(name))
        }
        if let summary, summary != old.summary {
            sets.append("summary = ?")
            args.append(.text(summary))
        }
        if let status, status != old.status {
            sets.append("status = ?")
            args.append(.text(status.rawValue))
        }
        let pathsChanged = paths.map { Set($0) != Set(old.paths) } ?? false
        if pathsChanged, let paths { try checkPathsFree(db, paths: paths, except: id) }
        if sets.isEmpty && !pathsChanged { return (old, false) }
        if pathsChanged, let paths {
            try db.run("DELETE FROM project_paths WHERE project_id = ?", [.int(id)])
            for path in paths {
                try db.run("INSERT INTO project_paths (path, project_id) VALUES (?, ?)", [.text(path), .int(id)])
            }
        }
        let now = max(Clock.nowMillis(), Clock.millis(old.updatedAt) + 1)
        sets.append("updated_at = ?")
        args.append(.int(now))
        args.append(.int(id))
        try db.run("UPDATE projects SET \(sets.joined(separator: ", ")) WHERE id = ?", args)
        return (try fetchProject(db, id: id), true)
    }
}
