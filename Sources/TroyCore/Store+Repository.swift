import Foundation

/// What a folder maps to, for the first-save rule.
public enum FolderMatch: Hashable, Sendable {
    /// An active project is linked to one of the folders or to an ancestor of one.
    case active(Project)
    /// No active project matches, and an archived project is linked to the repository root,
    /// an ancestor of it or a folder inside it. A second project must not be made beside it.
    case archived(Project)
    case none
}

/// The outcome of a save that may have created its project.
public struct RepositorySave: Hashable, Sendable {
    public var result: SaveResult
    public var project: Project
    /// True only when this call created the project.
    public var createdProject: Bool
}

extension Store {
    /// The active project linked to the first of `folders`, then of `repositoryRoots`, that has one
    /// (closest linked ancestor wins within each), else `.archived` when a root collides with an
    /// archived project. Every path, asked and stored, is compared in canonical form
    /// (`PathRules.canonical`), so a link made under another spelling of the folder still matches.
    ///
    /// `repositoryRoots` holds the root of the repository the folders are in, and `enclosing` the
    /// roots of the repositories that one is nested in (a submodule's superproject). For a folder
    /// in a repository a link counts only when it lies at or below the repository's root or is
    /// itself one of the enclosing roots. Any other link above a repository says where the
    /// repository happens to sit: a project linked to a plain folder never takes the repositories
    /// below it, whether they were there when it was linked or came later.
    ///
    /// `worktree` holds the linked git worktree the folders are in, when the repository's main
    /// folder is elsewhere. A link found for `folders` then counts only when it
    /// lies inside that worktree: a link above it says where the worktree happens to sit, and the
    /// worktree belongs to its main repository.
    public func project(
        forFolders folders: [String], repositoryRoots: [String], worktree: [String] = [], enclosing: [String] = []
    ) throws -> FolderMatch {
        try read { db in
            try matchFolders(db, folders: folders, repositoryRoots: repositoryRoots, worktree: worktree, enclosing: enclosing)
        }
    }

    /// Saves `draft` into the project of `folders`, creating a project when there is none: linked
    /// to the first of `repositoryRoots`, or to `plainFolder` for a working folder that is in no
    /// repository. `draft.projectID` is ignored.
    ///
    /// The lookup, the creation and the insert run in one `BEGIN IMMEDIATE` transaction, so two
    /// sessions saving their first record at the same moment end up in one project: the second
    /// waits for the first to commit and then finds its project.
    /// - Throws `.conflict` when the root collides with an archived project; nothing is written.
    public func saveCreatingProject(
        _ draft: RecordDraft, folders: [String], repositoryRoots: [String], worktree: [String] = [], enclosing: [String] = [],
        plainFolder: String? = nil
    ) throws -> RepositorySave {
        var checked = try CheckedDraft(draft)
        guard let first = repositoryRoots.first ?? plainFolder else { throw TroyError.invalid("No folder to link the project to.") }
        let root = try PathRules.projectPath(PathRules.canonical(first))
        return try lock.withLock {
            let outcome = try write { db -> (value: (InsertOutcome, Project, Bool), wrote: Bool) in
                let project: Project
                var created = false
                switch try matchFolders(db, folders: folders, repositoryRoots: repositoryRoots, worktree: worktree, enclosing: enclosing) {
                case .active(let found):
                    project = found
                case .archived(let old):
                    throw TroyError.conflict(Store.archivedMessage(old, root: root))
                case .none:
                    project = try insertProject(db, name: try freeProjectName(db, root: root), summary: "", paths: [root])
                    created = true
                }
                checked.projectID = project.id
                let inserted = try insertRecord(db, checked, agent: agent)
                return ((inserted.value, project, created), inserted.wrote || created)
            }
            let (inserted, project, created) = outcome
            return RepositorySave(result: try saveResult(inserted), project: project, createdProject: created)
        }
    }

    /// The refusal for a repository whose project is archived.
    public static func archivedMessage(_ project: Project, root: String) -> String {
        let linked = project.paths.first.map { " and linked to \($0)" } ?? ""
        return "Project #\(project.id) \"\(project.name)\" is archived\(linked), so Troy does not create another project for \(root). Unarchive it in the Troy app, or pass another project."
    }

    func matchFolders(
        _ db: Database, folders: [String], repositoryRoots: [String], worktree: [String] = [], enclosing: [String] = []
    ) throws -> FolderMatch {
        // Archived projects take part, so that the closest link decides: an archived project linked
        // to the repository is not skipped in favour of an active one linked to a folder above it.
        let all = try projectList(db, includeArchived: true).map(\.project)
        func claim(_ found: (project: Project, link: String)) -> FolderMatch {
            found.project.status == .archived ? .archived(found.project) : .active(found.project)
        }
        let inside = worktree.map(PathRules.canonical)
        let roots = repositoryRoots.map(PathRules.canonical)
        let outer = Set(enclosing.map(PathRules.canonical))
        // The repository boundary: a link at or below the root, or the root of a repository
        // around it. Without a repository every link above the folder counts.
        func reaches(_ link: String) -> Bool {
            roots.isEmpty || outer.contains(link) || roots.contains { PathRules.contains(ancestor: $0, link) }
        }
        // In a linked worktree only a link inside it claims the folder: a link above it says
        // where the worktree happens to sit, and the worktree belongs to its main repository.
        func insideWorktree(_ link: String) -> Bool { inside.contains { PathRules.contains(ancestor: $0, link) } }
        for folder in folders {
            if let found = closestLink(all, to: folder, where: inside.isEmpty ? reaches : insideWorktree) { return claim(found) }
        }
        for root in roots {
            if let found = closestLink(all, to: root, where: reaches) { return claim(found) }
        }
        guard !roots.isEmpty else { return .none }
        let archived = try db.query(
            "SELECT x.project_id, x.path FROM project_paths x JOIN projects p ON p.id = x.project_id WHERE p.status = 'archived' ORDER BY x.path",
            [], { ($0.int(), PathRules.canonical($0.text())) }
        )
        // A folder inside the root would be split from its repository by a new project linked to
        // the root. (A link above the root that counts was found by the loops already.)
        if let hit = archived.first(where: { link in roots.contains { PathRules.contains(ancestor: $0, link.1) } }) {
            return .archived(try fetchProject(db, id: hit.0))
        }
        return .none
    }

    /// The canonical spelling of a folder (case, symlinks and firmlinks resolved), the one a
    /// repository's project is created under.
    public static func canonicalFolder(_ path: String) -> String { PathRules.canonical(path) }

    /// The folder's name; when taken, "name (parent)"; then "name (parent) 2", "3", …
    /// Names are unique ignoring case, as `insertProject` checks.
    func freeProjectName(_ db: Database, root: String) throws -> String {
        let folder = (root as NSString).lastPathComponent
        let parent = ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent
        func taken(_ name: String) throws -> Bool {
            try db.exists("SELECT 1 FROM projects WHERE name = ? COLLATE NOCASE", [.text(name)])
        }
        // Never longer than the limit, whatever the folder names: a long parent name is cut
        // inside the suffix rather than leaving no room (a negative prefix traps).
        func fit(_ base: String, suffix: String = "") -> String {
            let room = Limits.projectName - suffix.count
            if room >= 1 { return String(base.prefix(room)) + suffix }
            return String((base + suffix).prefix(Limits.projectName))
        }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty || trimmed == "/" ? "project" : trimmed
        var candidates = [fit(base)]
        let qualified = parent.isEmpty || parent == "/" ? fit(base) : fit(base, suffix: " (\(parent))")
        if qualified != candidates[0] { candidates.append(qualified) }
        for name in candidates where try !taken(name) { return name }
        var number = 2
        while true {
            let name = fit(qualified, suffix: " \(number)")
            if try !taken(name) { return name }
            number += 1
        }
    }
}
