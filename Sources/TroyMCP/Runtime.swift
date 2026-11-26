import Foundation
import TroyCore

/// The server's working context: one store, the environment and the folder it runs in.
/// The MCP tools and the `troy` command line both call these methods, so they print the same text.
public struct ToolRuntime {
    public let store: Store
    public let environment: [String: String]
    public let workingDirectory: String
    /// The person's home folder. Which folders may become a project on their own is measured from it.
    public let home: String
    /// What the running call reports about itself for the usage log. The server passes a fresh
    /// note per tool call; on the command line it is filled and dropped.
    public let usage: UsageNote

    public init(
        store: Store, environment: [String: String] = ProcessInfo.processInfo.environment, workingDirectory: String? = nil,
        home: String? = nil, usage: UsageNote = UsageNote()
    ) {
        self.store = store
        self.environment = environment
        self.workingDirectory = workingDirectory ?? ToolRuntime.currentDirectory()
        self.home = home ?? NSHomeDirectory()
        self.usage = usage
    }

    /// The folder the process runs in. Prefers `$PWD` when it names the same folder, so a
    /// symlinked path the person typed keeps matching the folder linked to a project.
    public static func currentDirectory() -> String {
        let physical = FileManager.default.currentDirectoryPath
        if let logical = ProcessInfo.processInfo.environment["PWD"], logical.hasPrefix("/"),
           (logical as NSString).resolvingSymlinksInPath == (physical as NSString).resolvingSymlinksInPath {
            return logical
        }
        return physical
    }

    /// Record numbers typed on a command line: `42`, `#42`, `42,43`.
    public static func recordIDs(from words: [String]) throws -> [Int64] {
        try Arguments.recordIDs(.string(words.joined(separator: " ")), key: "id", max: 20)
    }

    // MARK: Project resolution

    /// An explicit reference, else `$TROY_PROJECT`, else (when `useDirectory`) the project linked to the working folder.
    func project(_ reference: String?, useDirectory: Bool = true) throws -> Project {
        // Without the folder fallback the caller is about to write: only an id or an exact name will do.
        let exact = !useDirectory
        if let named = named(reference) {
            return try project(named: named, exactName: exact)
        }
        guard useDirectory else {
            let active = try store.projects().map { "#\($0.project.id) \($0.project.name)" }
            let listing = active.isEmpty
                ? "There are no projects yet; create one with troy_new_project."
                : "Projects: \(active.joined(separator: ", "))."
            throw ToolError("\"project\" is required: an id or a name. \(listing) Call troy_context first to see which project this folder belongs to.")
        }
        let state = try folderState(workingDirectory)
        if case .project(let found) = state { return found }
        throw unlinkedFolder(try notFound(state, folder: workingDirectory), state)
    }

    /// The argument when given, else `$TROY_PROJECT`, trimmed. Nil when neither is set.
    private func named(_ reference: String?) -> String? {
        reference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? environment["TROY_PROJECT"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// A value starting with `/` or `~` is a folder; anything else is an id or a name.
    private func project(named reference: String, exactName: Bool) throws -> Project {
        if let folder = ToolRuntime.folder(reference) { return try linkedProject(folder) }
        return try store.resolveProject(reference: reference, directory: nil, exactName: exactName)
    }

    /// The not-found error for the working folder, with what to do about it. A folder that holds
    /// projects is not to be linked: a project there would take every plain folder below it.
    private func unlinkedFolder(_ error: TroyError, _ state: FolderState) -> Error {
        guard case .notFound = error else { return error }
        if case .outside(.holdsProjects) = state {
            return ToolError("\(error.message) Pass \"project\": an id or a name.")
        }
        return ToolError("\(error.message) Pass \"project\", or link this folder with troy_new_project.")
    }

    /// Explicit reference or `$TROY_PROJECT` only. Nil when neither is set.
    func explicitProject(_ reference: String?) throws -> Project? {
        guard let named = named(reference) else { return nil }
        return try project(named: named, exactName: false)
    }

    /// The project linked to the working folder: the folder or its closest linked ancestor, also
    /// with symlinks resolved, else the folder's repository root.
    func projectForWorkingDirectory() throws -> Project {
        try linkedProject(workingDirectory)
    }

    private func linkedProject(_ folder: String) throws -> Project {
        let state = try folderState(folder)
        if case .project(let found) = state { return found }
        throw try notFound(state, folder: folder)
    }

    /// The error for a folder without a project, built from its state. Nothing re-resolves the
    /// folder by a plain ancestor lookup: that would ignore the worktree rule and could name the
    /// project of a folder the repository merely sits in.
    private func notFound(_ state: FolderState, folder: String) throws -> TroyError {
        let active = try store.projects().map(\.project)
        let listing = active.isEmpty
            ? "There are no active projects yet."
            : "Active projects: " + active.map { "#\($0.id) \($0.name)" }.joined(separator: ", ") + "."
        let shown = ToolRuntime.normalized(folder)
        switch state {
        case .archived(let project, _):
            return .notFound("No active project for \(shown): it belongs to project #\(project.id) \"\(project.name)\", which is archived. Unarchive it in the Troy app, or pass another project. \(listing)")
        case .undetermined(let worktree):
            return .notFound("No project is linked to \(shown). \(listing) \(ToolRuntime.undeterminedMessage(worktree))")
        case .outside(.holdsProjects):
            return .notFound("No project is linked to \(shown), and Troy does not create one here: \(PlainFolder.holdsProjectsReason). \(listing)")
        case .project, .pending, .outside:
            return .notFound("No project is linked to \(shown). \(listing)")
        }
    }

    /// A folder whose first save creates its project, with what the lookup was made with, so that
    /// the write repeats exactly the same lookup.
    struct PendingFolder {
        /// The folder the project will be linked to, in its canonical spelling: the repository
        /// root, or the folder itself when it is in no repository.
        let root: String
        let isRepository: Bool
        let folders: [String]
        let repositoryRoots: [String]
        let worktree: [String]
        let enclosing: [String]
    }

    /// What a folder maps to.
    enum FolderState {
        case project(Project)
        /// No project yet, and the first save creates it.
        case pending(PendingFolder)
        /// The folder belongs to an archived project.
        case archived(Project, root: String)
        /// A linked worktree whose main repository git could not name.
        case undetermined(worktree: String)
        /// In no repository, and not a folder Troy makes a project for on its own.
        case outside(PlainFolder.Refusal)
    }

    /// The one place a folder is resolved. Whether the folder is in a linked worktree is read from
    /// its `.git` file, never from git, so git's answer can only add the main repository, never
    /// change which link claims the folder.
    func folderState(_ folder: String) throws -> FolderState {
        let repository = Repository.find(above: folder, home: home)
        let worktree = Repository.linkedWorktree(above: folder).map { [$0] } ?? []
        var roots: [String] = []
        var enclosing: [String] = []
        switch repository {
        case .root(let path):
            roots = [Store.canonicalFolder(path)]
            enclosing = Repository.enclosing(path, home: home).map(Store.canonicalFolder)
        case .undetermined(let top) where worktree.isEmpty:
            // A `.git` file git did not answer for that is no linked worktree (a submodule, a
            // separate git dir): still a repository, so its folder is the boundary for the links
            // above it. Nothing is created for it while git cannot name its root.
            roots = [Store.canonicalFolder(top)]
            enclosing = Repository.enclosing(top, home: home).map(Store.canonicalFolder)
        case .undetermined, .none:
            break
        }
        switch try store.project(forFolders: [folder], repositoryRoots: roots, worktree: worktree, enclosing: enclosing) {
        case .active(let project): return .project(project)
        case .archived(let project): return .archived(project, root: roots.first ?? folder)
        case .none:
            switch repository {
            case .root:
                return .pending(PendingFolder(
                    root: roots[0], isRepository: true, folders: [folder], repositoryRoots: roots, worktree: worktree,
                    enclosing: enclosing))
            case .undetermined(let top): return .undetermined(worktree: top)
            case .none:
                // A linked worktree whose main folder is the home folder or `/`, or whose `.git`
                // file git cannot read: links above it still do not count.
                if let top = worktree.first { return .undetermined(worktree: top) }
                // In no repository: the folder itself is the project, where Troy takes it for one.
                if let refusal = PlainFolder.refusal(for: folder, home: home) { return .outside(refusal) }
                return .pending(PendingFolder(
                    root: Store.canonicalFolder(folder), isRepository: false, folders: [folder], repositoryRoots: [],
                    worktree: [], enclosing: []))
            }
        }
    }

    static func undeterminedMessage(_ worktree: String) -> String {
        "\(worktree) is a git worktree whose main repository Troy could not determine, so Troy does not create a project for it on its own. Link one with troy_new_project and its \"path\"."
    }

    /// The path with every symlink resolved, `/private` included (`NSString.resolvingSymlinksInPath`
    /// strips it again). The path itself when it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A project reference that names a folder, made absolute and clean. Nil for ids and names.
    static func folder(_ reference: String) -> String? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        return resolved((text as NSString).expandingTildeInPath)
    }

    /// An absolute path as the file system reads it: `realpath` on the path as typed when it
    /// exists, because `..` right after a symlink leaves the symlink's target, not the folder the
    /// link sits in. Only a path that does not exist is cleaned up as text.
    static func resolved(_ absolute: String) -> String {
        if FileManager.default.fileExists(atPath: absolute) {
            let real = realPath(absolute)
            if real.hasPrefix("/") { return normalized(real) }
        }
        return normalized(absolute)
    }

    /// `.` and `..` resolved, repeated and trailing `/` removed. Plain string work, like the store's
    /// own rule, so the result matches the paths projects are linked to.
    static func normalized(_ path: String) -> String {
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(component)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    // MARK: Reading

    public func context(project reference: String?, maxChars: Int?) throws -> String {
        let project: Project
        // Nothing named means the working folder. A named folder is treated the same way: an agent
        // told to start with troy_context often passes the folder it is in, and an error there
        // (seen in a real Codex session) reads as "Troy is not set up" when the truth is "nothing
        // saved yet". A name or an id that matches nothing stays an error.
        let name = named(reference)
        if let folder = name == nil ? workingDirectory : name.flatMap(ToolRuntime.folder) {
            let state = try folderState(folder)
            switch state {
            case .project(let found):
                project = found
            case .pending(let pending):
                usage.set("state", "pending")
                return TroyText.pending(
                    root: pending.root, isRepository: pending.isRepository, projects: try store.projects().map(\.project))
            case .archived, .undetermined, .outside:
                let error = try notFound(state, folder: folder)
                throw name == nil ? unlinkedFolder(error, state) : error
            }
        } else {
            project = try self.project(reference)
        }
        let overview = try store.overview(projectID: project.id)
        usage.projectID = project.id
        usage.set("state", "project")
        usage.set("records", .int(Int64(overview.stats.records)))
        usage.set("doing", .int(Int64(overview.stats.doing)))
        usage.set("advisories", .int(Int64(overview.collisions.count)))
        return TroyText.context(overview, maxChars: maxChars ?? TroyText.contextDefaultChars)
    }

    public func search(
        query: String, project reference: String?, allProjects: Bool, kinds: Set<RecordKind> = [],
        statuses: Set<RecordStatus> = [], tag: String? = nil, limit: Int = 10
    ) throws -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ToolError("\"query\" must not be empty, for example query: \"export markdown\".")
        }
        let limit = min(max(limit, 1), 50)
        var projectID: Int64?
        var scope = "all projects"
        if !allProjects {
            // A folder's project does not exist before its first save, so a search that names
            // the folder has nothing to look in. That is an answer, not an error: agents search
            // before they save, and an error there reads as "Troy is not set up".
            if let folder = named(reference).flatMap(ToolRuntime.folder), case .pending(let pending) = try folderState(folder) {
                usage.set("state", "pending")
                usage.set("hits", .int(0))
                usage.set("all", .bool(false))
                usage.set("more", .bool(false))
                return TroyText.searchPending(query: text, root: pending.root, isRepository: pending.isRepository)
            }
            if let explicit = try explicitProject(reference) {
                projectID = explicit.id
                scope = "project #\(explicit.id) \(explicit.name)"
            } else if let linked = try? projectForWorkingDirectory() {
                projectID = linked.id
                scope = "project #\(linked.id) \(linked.name)"
            }
        }
        let query = SearchQuery(text: text, projectID: projectID, kinds: kinds, statuses: statuses, tag: tag, limit: limit + 1)
        var hits = try store.search(query)
        let more = hits.count > limit
        if more { hits = Array(hits.prefix(limit)) }
        usage.projectID = projectID
        usage.set("hits", .int(Int64(hits.count)))
        usage.set("all", .bool(projectID == nil))
        usage.set("more", .bool(more))
        return TroyText.search(hits: hits, query: text, scope: scope, more: more, limit: limit)
    }

    public func read(ids: [Int64], maxChars: Int?) throws -> String {
        let budget = min(max(maxChars ?? 8_000, 200), 100_000)
        var names: [Int64: String] = [:]
        var blocks: [String] = []
        var found = 0
        var foreign = 0
        var projectIDs = Set<Int64>()
        usage.set("ids", .array(ids.map { .int($0) }))
        defer {
            usage.set("found", .int(Int64(found)))
            usage.set("foreign", .int(Int64(foreign)))
            if projectIDs.count == 1 { usage.projectID = projectIDs.first }
        }
        for id in ids {
            do {
                let detail = try store.detail(id: id)
                found += 1
                let projectID = detail.record.projectID
                projectIDs.insert(projectID)
                if names[projectID] == nil { names[projectID] = (try? store.project(id: projectID).name) ?? "" }
                let updatedBy = (try? store.versions(of: id, limit: 1))?.first?.actor
                let lastWriter = updatedBy?.nilIfEmpty ?? detail.record.summary.source
                if lastWriter != store.agent { foreign += 1 }
                blocks.append(TroyText.record(detail, projectName: names[projectID], updatedBy: updatedBy, maxChars: budget))
            } catch let error as TroyError {
                if case .notFound = error { blocks.append("#\(id) does not exist.") } else { throw error }
            }
        }
        if found == 0 { throw ToolError(blocks.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    public func projects(includeArchived: Bool) throws -> String {
        let list = try store.projects(includeArchived: includeArchived)
        let current = (try? projectForWorkingDirectory())?.id
        usage.set("count", .int(Int64(list.count)))
        return TroyText.projects(list, current: current)
    }

    // MARK: Projects

    /// The folder `troy_new_project` links by default: the repository root above the working
    /// folder (a linked worktree's main folder when git can name it), else the folder itself.
    public func defaultProjectFolder() -> String {
        // The home folder is not excluded here: `newProject` refuses it with a message of its own.
        switch Repository.find(above: workingDirectory, excludeHome: false) {
        case .root(let path): return path
        case .undetermined(let worktree): return worktree
        case .none: return workingDirectory
        }
    }

    public func newProject(name: String, summary: String?, path: String?) throws -> String {
        var folder: String? = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let given = folder {
            let absolute = given.hasPrefix("/") || given.hasPrefix("~")
                ? (given as NSString).expandingTildeInPath : workingDirectory + "/" + given
            folder = ToolRuntime.resolved(absolute)
        }
        var skippedHome = false
        var skippedHolder: String?
        let repository = Repository.find(above: workingDirectory, excludeHome: false, home: home)
        if folder == nil, case .undetermined(let worktree) = repository {
            // Linking the worktree itself would split the repository: its main folder may already
            // have a project, and a link inside a worktree wins over the main repository's.
            throw ToolError("\(worktree) is a git worktree whose main repository Troy could not determine, so troy_new_project does not link it on its own. Pass \"path\": the main repository's folder, or this worktree's folder if it should have a project of its own.")
        }
        if folder == nil {
            let candidate = defaultProjectFolder()
            // Compared as the file system spells them: the home folder reached through a symlink is still the home folder.
            let spelled = Store.canonicalFolder(candidate)
            if spelled == "/" || spelled == Store.canonicalFolder(home) {
                skippedHome = true
            } else if repository == .none, PlainFolder.refusal(for: candidate, home: home) == .holdsProjects {
                // Not linked without being asked to: a project here would take every plain folder below it.
                skippedHolder = candidate
            } else {
                folder = candidate
            }
        }
        let project = try store.createProject(name: name, summary: summary ?? "", paths: folder.map { [$0] } ?? [])
        usage.projectID = project.id
        usage.set("created_project", true)
        let linked = project.paths.first
        var text = "Created project #\(project.id) \"\(project.name)\""
        if let linked {
            text += ", linked to \(linked)."
        } else if skippedHome {
            text += ". It is not linked to a folder, because the working folder is your home folder; pass path to link one."
        } else if let skippedHolder {
            text += ". It is not linked to a folder, because \(skippedHolder) holds projects rather than being one; pass path to link a folder."
        } else {
            text += "."
        }
        return text + " Use \"project\": \(project.id) in troy_save."
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
