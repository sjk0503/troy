import Foundation
import Testing
import TroyCore
@testable import TroyMCP

/// A folder tree for repository tests, with symlinks resolved up front so the paths git
/// reports (/private/var/…) match the ones the test uses.
final class RepoDir: @unchecked Sendable {
    let path: String

    init() throws {
        // The whole test run starts many processes at once; the hook's two seconds are for one session.
        Repository.gitTimeLimit = 30
        let base = ToolRuntime.realPath(NSTemporaryDirectory())
        path = ToolRuntime.normalized(base + "/troy-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func folder(_ relative: String, git: Bool = false) throws -> String {
        let full = path + "/" + relative
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        if git {
            // A git dir always has a HEAD; an empty `.git` folder does not count as a repository.
            try FileManager.default.createDirectory(atPath: full + "/.git", withIntermediateDirectories: true)
            try "ref: refs/heads/main\n".write(toFile: full + "/.git/HEAD", atomically: true, encoding: .utf8)
        }
        return full
    }

    /// Runs git with no user or system configuration, so hooks and signing settings stay out.
    func git(_ arguments: [String], in folder: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Repository.gitExecutable() ?? "/usr/bin/git")
        process.arguments = ["-c", "user.name=Troy Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                             "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder ?? path)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("git \(arguments.joined(separator: " ")) failed") }
    }

    /// A repository with one commit at `relative`.
    @discardableResult
    func repository(_ relative: String) throws -> String {
        let folder = try self.folder(relative)
        try git(["init", "-q"], in: folder)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: folder)
        return folder
    }
}

let gitAvailable = Repository.gitExecutable() != nil

@Suite struct RepositoryTests {
    // MARK: Repository identity

    @Test func aGitFolderIsTheRootWithoutAskingGit() throws {
        let dir = try RepoDir()
        let root = try dir.folder("app", git: true)
        let nested = try dir.folder("app/Sources/Deep")
        #expect(Repository.find(above: nested) == .root(root))
        #expect(ToolRuntime.firstSaveRoot(for: nested)?.root == root)
        #expect(ToolRuntime.firstSaveRoot(for: nested)?.isRepository == true)
        #expect(Repository.find(above: try dir.folder("plain")) == .none)
        // The home folder is never a repository root for the first-save rule.
        #expect(Repository.find(above: nested, home: root) == .none)
        #expect(Repository.find(above: nested, excludeHome: false, home: root) == .root(root))
    }

    @Test func aGitFileGitCannotReadIsUndetermined() throws {
        let dir = try RepoDir()
        let worktree = try dir.folder("wt")
        try "gitdir: \(dir.path)/missing/.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        #expect(Repository.find(above: try dir.folder("wt/src")) == .undetermined(worktree))
        // Not even as a plain folder: a worktree belongs to a repository, wherever that is.
        #expect(ToolRuntime.firstSaveRoot(for: worktree) == nil)
        #expect(ToolRuntime.firstSaveRoot(for: worktree, home: dir.path) == nil)

        let h = try Harness(workingDirectory: worktree)
        let save = h.call("troy_save", ["project": .string(worktree), "kind": "note", "title": "x"])
        #expect(save.isError)
        #expect(save.text.contains("git worktree whose main repository Troy could not determine"), "\(save.text)")
        #expect(save.text.contains("troy_new_project"))
        let context = h.call("troy_context")
        #expect(context.isError)
        #expect(context.text.contains("No project is linked to"))
        #expect(context.text.contains("could not determine"))
        #expect(try h.store.projects().isEmpty)
        // An explicit link on the worktree folder still works.
        h.newProject("Linked", path: worktree)
        #expect(h.ok("troy_context").hasPrefix("Project #1 \"Linked\""))
    }

    @Test(.enabled(if: gitAvailable)) func aLinkedWorktreeBelongsToItsMainRepository() throws {
        let dir = try RepoDir()
        let main = try dir.repository("main/app")
        let worktree = dir.path + "/elsewhere/app-feature"
        try dir.git(["worktree", "add", "-q", "-b", "feature", worktree], in: main)
        #expect(Repository.find(above: worktree + "/") == .root(main))

        let store = try Store(path: ":memory:")
        let inWorktree = try Harness(store: store, workingDirectory: worktree)
        let pending = inWorktree.ok("troy_context")
        #expect(pending.hasPrefix("No project yet for this repository: \(main)\n"), "\(pending)")
        #expect(try store.projects().isEmpty)

        let saved = inWorktree.ok("troy_save", ["project": .string(worktree), "kind": "note", "title": "From the worktree"])
        #expect(saved.hasPrefix("Created project #1 \"app\", linked to \(main).\nSaved #1 "), "\(saved)")
        let fromMain = try Harness(store: store, workingDirectory: main)
        let again = fromMain.ok("troy_save", ["project": .string(main), "kind": "note", "title": "From the main folder"])
        #expect(again.hasPrefix("Saved #2 [note/open] \"From the main folder\" in project #1 app."), "\(again)")
        #expect(try store.projects().count == 1)
        #expect(inWorktree.ok("troy_context").hasPrefix("Project #1 \"app\""))
        // The main folder spelled through a symlink (/var for /private/var) finds the same project.
        let logical = ToolRuntime.normalized(NSTemporaryDirectory())
        let real = ToolRuntime.realPath(logical)
        if logical != real {
            let spelled = logical + main.dropFirst(real.count)
            let viaLink = try Harness(store: store, workingDirectory: spelled)
            #expect(viaLink.ok("troy_save", ["project": .string(spelled), "kind": "note", "title": "Via the link"]).contains("in project #1 app."))
            #expect(try store.projects().count == 1)
        }
        #expect(inWorktree.ok("troy_projects").contains("← this folder"))
        #expect(inWorktree.ok("troy_search", ["query": "worktree"]).contains("in project #1 app:"))
        // troy_new_project from a worktree links the main folder too.
        #expect(try Harness(workingDirectory: worktree).ok("troy_new_project", ["name": "Other"]).contains("linked to \(main)."))
    }

    /// A worktree may sit inside a folder that is linked to another project (a parent folder of
    /// several checkouts, or another repository). It still belongs to its main repository.
    @Test(.enabled(if: gitAvailable)) func aLinkAboveALinkedWorktreeDoesNotClaimIt() throws {
        let dir = try RepoDir()
        let main = try dir.repository("main/app")
        let enclosing = try dir.folder("clients")
        let worktree = enclosing + "/app-feature"
        try dir.git(["worktree", "add", "-q", "-b", "feature", worktree], in: main)

        let store = try Store(path: ":memory:")
        let inMain = try Harness(store: store, workingDirectory: main)
        inMain.newProject("Clients", path: enclosing)
        let inWorktree = try Harness(store: store, workingDirectory: worktree)
        // Nothing is linked to the main repository yet: the worktree waits for it, it is not part of "Clients".
        let pending = inWorktree.ok("troy_context")
        #expect(pending.hasPrefix("No project yet for this repository: \(main)\n"), "\(pending)")
        let saved = inWorktree.ok("troy_save", ["project": .string(worktree), "kind": "note", "title": "From the worktree"])
        #expect(saved.hasPrefix("Created project #2 \"app\", linked to \(main).\n"), "\(saved)")
        #expect(inWorktree.ok("troy_context").hasPrefix("Project #2 \"app\""))
        // A link inside the worktree itself is deliberate and wins.
        let docs = try dir.folder("clients/app-feature/docs")
        inMain.newProject("Docs", path: docs)
        #expect(try Harness(store: store, workingDirectory: docs).ok("troy_context").hasPrefix("Project #3 \"Docs\""))
        // A plain folder next to the worktree still belongs to the enclosing project.
        let notes = try dir.folder("clients/notes")
        #expect(try Harness(store: store, workingDirectory: notes).ok("troy_context").hasPrefix("Project #1 \"Clients\""))
    }

    @Test(.enabled(if: gitAvailable)) func aSeparateGitDirIsNeverMistakenForItsMetadataFolder() throws {
        let dir = try RepoDir()
        let work = try dir.folder("work/app")
        try dir.folder("meta")
        try dir.git(["init", "-q", "--separate-git-dir", dir.path + "/meta/app.git", work])
        try dir.git(["commit", "-q", "--allow-empty", "-m", "init"], in: work)
        let worktree = dir.path + "/trees/app-two"
        try dir.git(["worktree", "add", "-q", "-b", "two", worktree], in: work)
        // The work folder itself: its .git is a file, and git names the folder as the top level.
        #expect(Repository.find(above: work + "/") == .root(work))
        let h = try Harness(workingDirectory: work)
        #expect(h.ok("troy_save", ["project": .string(work), "kind": "note", "title": "x"]).hasPrefix("Created project #1 \"app\", linked to \(work)."))
        // A linked worktree: git lists the metadata folder as the main worktree, because nothing
        // records where the work folder is. That is no repository root, so nothing is created.
        #expect(Repository.find(above: worktree) == .undetermined(worktree))
        let fromTree = try Harness(store: h.store, workingDirectory: worktree)
        let save = fromTree.call("troy_save", ["project": .string(worktree), "kind": "note", "title": "y"])
        #expect(save.isError && save.text.contains("could not determine"), "\(save.text)")
        #expect(try h.store.projects().count == 1)
    }

    @Test(.enabled(if: gitAvailable)) func aSubmoduleIsItsOwnRoot() throws {
        let dir = try RepoDir()
        let library = try dir.repository("library")
        let main = try dir.repository("main")
        try dir.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "vendor/library"], in: main)
        #expect(Repository.find(above: main + "/vendor/library/x") == .root(main + "/vendor/library"))
    }

    @Test(.enabled(if: gitAvailable)) func aWorktreeOfABareRepositoryCreatesNothing() throws {
        let dir = try RepoDir()
        let source = try dir.repository("source")
        let bare = dir.path + "/bare.git"
        try dir.git(["clone", "-q", "--bare", source, bare])
        let worktree = dir.path + "/bare-tree"
        try dir.git(["worktree", "add", "-q", worktree, "main"], in: bare)
        #expect(Repository.find(above: worktree) == .undetermined(worktree))
        let h = try Harness(workingDirectory: worktree)
        let save = h.call("troy_save", ["project": .string(worktree), "kind": "note", "title": "x"])
        #expect(save.isError && save.text.contains("could not determine"), "\(save.text)")
        #expect(h.call("troy_context").isError)
        #expect(try h.store.projects().isEmpty)
    }

    @Test func aSlowProgramIsStoppedAtTheTimeLimit() throws {
        let started = Date()
        #expect(Repository.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(Repository.run("/bin/echo", ["hello"], timeout: 5) == "hello\n")
        #expect(Repository.run("/usr/bin/false", [], timeout: 5) == nil)
    }

    // MARK: First save and the pending reply

    @Test func contextInARepositoryWithoutAProjectSaysHowToStart() throws {
        let dir = try RepoDir()
        let root = try dir.folder("my app", git: true)
        let h = try Harness(workingDirectory: try dir.folder("my app/src"))
        #expect(h.ok("troy_context") == """
        No project yet for this repository: \(root)
        Record this session's work without being asked: troy_save each decision (with its reason), finding and finished piece of work as it happens. The first save with "project": "\(root)" creates the project, named after the folder and linked to it.
        There are no projects yet.
        """)
        // Searching the folder before its first save finds nothing, and says why, without failing.
        #expect(h.ok("troy_search", ["query": "importer", "project": .string(root)]) == """
        No results for "importer": this repository has no project yet, so nothing is saved for it. The first troy_save with "project": "\(root)" creates it. To search the other projects pass all_projects: true.
        """)
        h.newProject("A")
        h.newProject("B")
        #expect(h.ok("troy_context").hasSuffix("\nOther projects: #2 B, #1 A.") || h.ok("troy_context").hasSuffix("\nOther projects: #1 A, #2 B."))
        // Reading created nothing.
        #expect(try h.store.projects().count == 2)
        // A name that matches nothing is an error, also from TROY_PROJECT. The repository's own
        // folder named outright is the same question as naming nothing, and gets the same hint.
        let named = try Harness(store: h.store, environment: ["TROY_PROJECT": "nope"], workingDirectory: root)
        #expect(named.call("troy_context").isError)
        #expect(h.ok("troy_context", ["project": .string(root)]).hasPrefix("No project yet for this repository: \(root)\n"))
        #expect(h.ok("troy_context", ["project": .string(root + "/src")]).hasPrefix("No project yet for this repository: \(root)\n"))
        let byFolder = try Harness(store: h.store, environment: ["TROY_PROJECT": root], workingDirectory: "/")
        #expect(byFolder.ok("troy_context").hasPrefix("No project yet for this repository: \(root)\n"))
        // A folder outside any repository is still an error.
        #expect(h.call("troy_context", ["project": .string(dir.path)]).isError)
        #expect(try h.store.projects().count == 2)
    }

    @Test func firstSaveCreatesTheProjectNamedAfterTheFolder() throws {
        let dir = try RepoDir()
        let root = try dir.folder("dev/app", git: true)
        let h = try Harness(workingDirectory: root)
        h.newProject("app")
        let saved = h.ok("troy_save", ["project": .string(root + "/src/"), "kind": "task", "title": "First", "paths": ["src"]])
        let lines = saved.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "Created project #2 \"app (dev)\", linked to \(root).", "\(saved)")
        #expect(lines.dropFirst().first == "Saved #1 [task/open] \"First\" in project #2 app (dev).")
        #expect(h.ok("troy_context").hasPrefix("Project #2 \"app (dev)\""))
        let second = h.ok("troy_save", ["project": .string(root), "kind": "note", "title": "Second"])
        #expect(second.hasPrefix("Saved #2 "), "\(second)")
        // Without "project" a save is still refused, even in the linked folder.
        #expect(h.call("troy_save", ["kind": "note", "title": "x"]).text.contains("\"project\" is required"))
    }

    // MARK: Work folders in no repository

    /// A folder in no repository is a project too when it sits where work is kept: its first save
    /// creates the project, linked to the folder itself. (In real use a work folder that was no
    /// repository went a day of sessions without one record, because only repositories got a project.)
    @Test func aWorkFolderInNoRepositoryGetsItsProjectOnTheFirstSave() throws {
        let dir = try RepoDir()
        let work = try dir.folder("dev/cs")
        let h = try Harness(workingDirectory: work, home: dir.path)
        #expect(h.ok("troy_context") == """
        No project yet for this folder: \(work)
        Record this session's work without being asked: troy_save each decision (with its reason), finding and finished piece of work as it happens. The first save with "project": "\(work)" creates the project, named after the folder and linked to it.
        There are no projects yet.
        """)
        #expect(h.ok("troy_search", ["query": "importer", "project": .string(work)]) == """
        No results for "importer": this folder has no project yet, so nothing is saved for it. The first troy_save with "project": "\(work)" creates it. To search the other projects pass all_projects: true.
        """)
        #expect(try h.store.projects().isEmpty)
        let saved = h.ok("troy_save", ["project": .string(work), "kind": "note", "title": "First"])
        #expect(saved.hasPrefix("Created project #1 \"cs\", linked to \(work).\nSaved #1 "), "\(saved)")
        #expect(h.ok("troy_context").hasPrefix("Project #1 \"cs\""))
        #expect(h.ok("troy_save", ["project": .string(work), "kind": "note", "title": "Second"]).hasPrefix("Saved #2 "))
        // A folder below it has no boundary of its own and belongs to the same project.
        let below = try Harness(store: h.store, workingDirectory: try dir.folder("dev/cs/notes/2026"), home: dir.path)
        #expect(below.ok("troy_context").hasPrefix("Project #1 \"cs\""))
        #expect(try h.store.projects().count == 1)
        // The hook's answer before the database exists is the same folder.
        let sibling = try dir.folder("dev/other")
        #expect(ToolRuntime.firstSaveRoot(for: sibling, home: dir.path)?.root == sibling)
        #expect(ToolRuntime.firstSaveRoot(for: sibling, home: dir.path)?.isRepository == false)
    }

    /// The folder a session runs in is taken as it is: nothing walks up, and a project made for a
    /// folder below does not stop the one above from getting its own.
    @Test func aSubfolderSavedFirstDoesNotBlockTheFolderAboveIt() throws {
        let dir = try RepoDir()
        let notes = try dir.folder("dev/cs/notes")
        let cs = try dir.folder("dev/cs")
        let inNotes = try Harness(workingDirectory: notes, home: dir.path)
        #expect(inNotes.ok("troy_save", ["project": .string(notes), "kind": "note", "title": "n"]).hasPrefix("Created project #1 \"notes\""))
        let inCS = try Harness(store: inNotes.store, workingDirectory: cs, home: dir.path)
        #expect(inCS.ok("troy_context").hasPrefix("No project yet for this folder: \(cs)\n"))
        #expect(inCS.ok("troy_save", ["project": .string(cs), "kind": "note", "title": "c"]).hasPrefix("Created project #2 \"cs\""))
        // Each keeps its own from then on: the closest link decides.
        #expect(inNotes.ok("troy_context").hasPrefix("Project #1 \"notes\""))
        #expect(inCS.ok("troy_context").hasPrefix("Project #2 \"cs\""))
    }

    /// Where Troy makes no project on its own. The folders right in the home folder hold
    /// projects (a link there would take every plain folder below it); the rest are places
    /// nobody keeps work in.
    @Test func placesThatHoldProjectsOrNoWorkAreNotTakenForOne() throws {
        let dir = try RepoDir()
        let home = dir.path
        func refusal(_ relative: String) throws -> PlainFolder.Refusal? {
            PlainFolder.refusal(for: try dir.folder(relative), home: home)
        }
        #expect(PlainFolder.refusal(for: home, home: home) == .holdsProjects)
        #expect(PlainFolder.refusal(for: "/", home: home) == .holdsProjects)
        #expect(try refusal("dev") == .holdsProjects)
        #expect(try refusal("Documents") == .holdsProjects)
        #expect(try refusal("dev/app") == nil)
        #expect(try refusal("Desktop/기획/deep") == nil)
        // Hidden anywhere on the way, application data, and a client's project-less chats.
        #expect(try refusal(".config/tool") == .notForWork)
        #expect(try refusal("dev/.cache/x") == .notForWork)
        #expect(try refusal("Library/Application Support/Claude/scratch/one") == .notForWork)
        #expect(try refusal("Documents/Codex/2026-11-10/new-chat") == .notForWork)
        #expect(try refusal("Documents/Codex") == .notForWork)
        #expect(try refusal("Documents/Work/plan") == nil)
        // Cloud drives live under Library, and count from the drive, like the home folder.
        #expect(try refusal("Library/Mobile Documents/com~apple~CloudDocs") == .holdsProjects)
        #expect(try refusal("Library/Mobile Documents/com~apple~CloudDocs/Work") == .holdsProjects)
        #expect(try refusal("Library/Mobile Documents/com~apple~CloudDocs/Work/기획") == nil)
        #expect(try refusal("Library/CloudStorage/Dropbox/work/site") == nil)
        #expect(try refusal("Library/CloudStorage/Dropbox/work") == .holdsProjects)
        #expect(try refusal("Library/Mobile Documents") == .notForWork)
        // Outside the home folder (the real one here): only another volume, and not a missing folder.
        #expect(PlainFolder.refusal(for: try dir.folder("dev/app")) == .notForWork)
        #expect(PlainFolder.refusal(for: "/usr/local", home: home) == .notForWork)
        #expect(PlainFolder.refusal(for: home + "/dev/missing", home: home) == .notForWork)
        // A symlink is judged by where it leads.
        try FileManager.default.createSymbolicLink(atPath: home + "/dev/chat", withDestinationPath: home + "/Documents/Codex/2026-11-10/new-chat")
        try FileManager.default.createSymbolicLink(atPath: home + "/dev/linked", withDestinationPath: home + "/Documents/Work/plan")
        #expect(PlainFolder.refusal(for: home + "/dev/chat", home: home) == .notForWork)
        #expect(PlainFolder.refusal(for: home + "/dev/linked", home: home) == nil)
        // `~/Library` is a folder right in the home folder like any other, and a hidden drive is hidden.
        #expect(try refusal("Library") == .holdsProjects)
        #expect(try refusal("Library/CloudStorage/.provider/work/site") == .notForWork)

        // The chats folder under another spelling: stored in lower case, or a symlink itself.
        let lower = try RepoDir()
        #expect(PlainFolder.refusal(for: try lower.folder("Documents/codex/2026-11-10/chat"), home: lower.path) == .notForWork)
        let moved = try RepoDir()
        let chats = try moved.folder("dev/chats/2026-11-10/talk")
        try moved.folder("Documents")
        try FileManager.default.createSymbolicLink(atPath: moved.path + "/Documents/Codex", withDestinationPath: moved.path + "/dev/chats")
        #expect(PlainFolder.refusal(for: moved.path + "/Documents/Codex/2026-11-10/talk", home: moved.path) == .notForWork)
        #expect(PlainFolder.refusal(for: chats, home: moved.path) == nil)
    }

    @Test func aFolderTroyDoesNotTakeForAProjectSaysWhy() throws {
        let dir = try RepoDir()
        // Outside the home folder: the temporary folder the tests run in.
        let plain = try dir.folder("plain")
        let h = try Harness(workingDirectory: plain)
        let save = h.call("troy_save", ["project": .string(plain), "kind": "note", "title": "x"])
        #expect(save.isError)
        #expect(save.text == "Troy does not create a project for \(plain) on its own: it is not in a git repository, and outside one Troy only takes an existing, visible folder at least two levels below the home folder, an iCloud Drive or cloud-storage folder, or another volume. Pass an existing project's id or name, or create one with troy_new_project and \"path\".")
        let context = h.call("troy_context")
        #expect(context.isError && context.text.hasPrefix("No project is linked to \(plain). "))
        #expect(context.text.hasSuffix("Pass \"project\", or link this folder with troy_new_project."))
        #expect(try h.store.projects().isEmpty)

        // A folder right in the home folder holds projects: nothing is created for it, and nothing
        // says to link it, because a project there would take every plain folder below it.
        let dev = try dir.folder("dev")
        let top = try Harness(workingDirectory: dev, home: dir.path)
        let refused = top.call("troy_save", ["project": .string(dev), "kind": "note", "title": "x"])
        #expect(refused.isError)
        #expect(refused.text == "Troy does not create a project for \(dev) on its own: the home folder, a drive and the folders right in them hold projects, and Troy does not take them for one. Pass an existing project's id or name, or the folder of the project itself.")
        let lost = top.call("troy_context")
        #expect(lost.isError)
        #expect(lost.text == "No project is linked to \(dev), and Troy does not create one here: the home folder, a drive and the folders right in them hold projects, and Troy does not take them for one. There are no active projects yet. Pass \"project\": an id or a name.")
        // troy_new_project there makes the project without linking the folder, unless a path asks for it.
        let made = top.ok("troy_new_project", ["name": "Scratch"])
        #expect(made == "Created project #1 \"Scratch\". It is not linked to a folder, because \(dev) holds projects rather than being one; pass path to link a folder. Use \"project\": 1 in troy_save.")
        #expect(top.ok("troy_new_project", ["name": "Asked", "path": .string(dev)]).hasPrefix("Created project #2 \"Asked\", linked to \(dev)."))
        // The same for `~/Library`, which holds every application's folders.
        let library = try dir.folder("Library")
        let inLibrary = try Harness(store: top.store, workingDirectory: library, home: dir.path)
        #expect(inLibrary.ok("troy_new_project", ["name": "Stray"]).contains("It is not linked to a folder, because \(library) holds projects"))
    }

    /// When git does not answer for a `.git` file that is no linked worktree (a submodule, a
    /// separate git dir), the folder is still a repository: a plain folder's project above it
    /// does not take it, and nothing is created until git can name its root.
    @Test func aRepositoryGitCannotAnswerForIsStillABoundary() throws {
        let dir = try RepoDir()
        let work = try dir.folder("dev/work")
        let api = try dir.folder("dev/work/api")
        let meta = try dir.folder("meta/api.git")
        try "gitdir: \(meta)\n".write(toFile: api + "/.git", atomically: true, encoding: .utf8)
        Repository.remember(api, main: nil)
        #expect(Repository.find(above: api, home: dir.path) == .undetermined(api))
        #expect(Repository.linkedWorktree(above: api) == nil)
        let h = try Harness(workingDirectory: api, home: dir.path)
        let id = h.newProject("Work", path: work)
        let context = h.call("troy_context")
        #expect(context.isError && !context.text.hasPrefix("Project #"), "\(context.text)")
        #expect(h.call("troy_save", ["project": .string(api), "kind": "note", "title": "x"]).isError)
        #expect(try h.store.list(RecordQuery(projectID: id)).isEmpty)
        // A link on the folder itself still claims it.
        let own = h.newProject("API", path: api)
        #expect(h.ok("troy_context").hasPrefix("Project #\(own) \"API\""))
    }

    /// Above a linked worktree the enclosing repositories go on from the worktree's main
    /// repository, not from the repository the worktree happens to sit in, and a `.git` file
    /// that leads nowhere says nothing about its folder.
    @Test func enclosingRepositoriesFollowAWorktreeToItsMainRepository() throws {
        let dir = try RepoDir()
        // A worktree of `a` checked out inside the unrelated repository `b`, with a clone in it.
        let a = try dir.folder("dev/a", git: true)
        let b = try dir.folder("dev/b", git: true)
        let wt = try dir.folder("dev/b/wt")
        let admin = try dir.folder("dev/a/.git/worktrees/wt")
        try "../..\n".write(toFile: admin + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(admin)\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        let lib = try dir.folder("dev/b/wt/lib", git: true)
        Repository.remember(wt, main: a)
        #expect(Repository.enclosing(lib, home: dir.path) == [wt, a])
        let h = try Harness(workingDirectory: lib, home: dir.path)
        h.newProject("B", path: b)
        #expect(h.ok("troy_context").hasPrefix("No project yet for this repository: \(lib)\n"))
        // When git cannot name the main repository the walk ends at the worktree.
        Repository.remember(wt, main: nil)
        #expect(Repository.enclosing(lib, home: dir.path) == [wt])
        #expect(h.ok("troy_context").hasPrefix("No project yet for this repository: \(lib)\n"))
        // A link on the worktree itself reaches the repository nested in it.
        let own = h.newProject("WT", path: wt)
        #expect(h.ok("troy_context").hasPrefix("Project #\(own) \"WT\""))

        // The usual layout: the worktree sits inside its own main repository, whose link reaches in.
        let other = try RepoDir()
        let main = try other.folder("dev/app", git: true)
        let inside = try other.folder("dev/app/.claude/worktrees/fix")
        let entry = try other.folder("dev/app/.git/worktrees/fix")
        try "../..\n".write(toFile: entry + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(entry)\n".write(toFile: inside + "/.git", atomically: true, encoding: .utf8)
        let dep = try other.folder("dev/app/.claude/worktrees/fix/vendor/dep", git: true)
        Repository.remember(inside, main: main)
        let g = try Harness(workingDirectory: dep, home: other.path)
        let id = g.newProject("App", path: main)
        #expect(g.ok("troy_context").hasPrefix("Project #\(id) \"App\""))

        // A plain folder with a stale `.git` file does not own the repositories below it.
        let third = try RepoDir()
        let work = try third.folder("dev/work")
        try "gitdir: \(third.path)/gone/.git/worktrees/work\n".write(toFile: work + "/.git", atomically: true, encoding: .utf8)
        let api = try third.folder("dev/work/api", git: true)
        #expect(Repository.enclosing(api, home: third.path).isEmpty)
        let k = try Harness(workingDirectory: api, home: third.path)
        k.newProject("Work", path: work)
        #expect(k.ok("troy_context").hasPrefix("No project yet for this repository: \(api)\n"))
    }

    /// A project linked to a plain folder never takes the repositories below it: a repository is
    /// its own project, whether it was there when the folder was linked or came later.
    @Test func aPlainFoldersProjectDoesNotReachIntoARepositoryBelowIt() throws {
        let dir = try RepoDir()
        let work = try dir.folder("dev/work")
        let h = try Harness(workingDirectory: work, home: dir.path)
        #expect(h.ok("troy_save", ["project": .string(work), "kind": "note", "title": "w"]).hasPrefix("Created project #1 \"work\""))
        // `git init` below it, afterwards.
        let api = try dir.folder("dev/work/api", git: true)
        let inAPI = try Harness(store: h.store, workingDirectory: try dir.folder("dev/work/api/src"), home: dir.path)
        #expect(inAPI.ok("troy_context").hasPrefix("No project yet for this repository: \(api)\n"))
        #expect(inAPI.ok("troy_save", ["project": .string(api), "kind": "note", "title": "a"]).hasPrefix("Created project #2 \"api\", linked to \(api)."))
        #expect(inAPI.ok("troy_context").hasPrefix("Project #2 \"api\""))
        // A plain folder next to it still belongs to the folder's project.
        let notes = try Harness(store: h.store, workingDirectory: try dir.folder("dev/work/notes"), home: dir.path)
        #expect(notes.ok("troy_context").hasPrefix("Project #1 \"work\""))
        // An archived project on the plain folder does not block the repository either.
        _ = try h.store.updateProject(id: 1, status: .archived)
        let web = try dir.folder("dev/work/web", git: true)
        let inWeb = try Harness(store: h.store, workingDirectory: web, home: dir.path)
        #expect(inWeb.ok("troy_save", ["project": .string(web), "kind": "note", "title": "b"]).hasPrefix("Created project #3 \"web\""))
        #expect(notes.call("troy_context").text.contains("which is archived"))
    }

    /// A repository nested in a linked repository still belongs to that one (a vendored clone, a
    /// scratch checkout), and only a link on an enclosing repository's root reaches it.
    @Test func aRepositoryNestedInALinkedRepositoryStaysWithIt() throws {
        let dir = try RepoDir()
        let outer = try dir.folder("dev/app", git: true)
        let inner = try dir.folder("dev/app/vendor/lib", git: true)
        #expect(Repository.enclosing(inner, home: dir.path) == [outer])
        #expect(Repository.enclosing(outer, home: dir.path).isEmpty)
        // The home folder is never an enclosing repository.
        #expect(Repository.enclosing(inner, home: outer).isEmpty)
        let h = try Harness(workingDirectory: inner, home: dir.path)
        let id = h.newProject("App", path: outer)
        #expect(h.ok("troy_context").hasPrefix("Project #\(id) \"App\""))

        // A link on a plain folder inside the outer repository is above the inner one and is not
        // a repository root, so it does not reach in; the outer root's link does.
        let other = try RepoDir()
        let area = try other.folder("dev/mono/packages")
        let mono = try other.folder("dev/mono", git: true)
        let pkg = try other.folder("dev/mono/packages/pkg", git: true)
        let g = try Harness(workingDirectory: pkg, home: other.path)
        let areaID = g.newProject("Area", path: area)
        #expect(g.ok("troy_context").hasPrefix("No project yet for this repository: \(pkg)\n"))
        let monoID = g.newProject("Mono", path: mono)
        #expect(g.ok("troy_context").hasPrefix("Project #\(monoID) \"Mono\""))
        // Plain folders of the outer repository still go to the closest link.
        let inArea = try Harness(store: g.store, workingDirectory: try other.folder("dev/mono/packages/docs"), home: other.path)
        #expect(inArea.ok("troy_context").hasPrefix("Project #\(areaID) \"Area\""))
    }

    @Test func anArchivedRepositoryProjectIsNamedAndNotDuplicated() throws {
        let dir = try RepoDir()
        let root = try dir.folder("old", git: true)
        let h = try Harness(workingDirectory: root)
        let id = h.newProject("Old", path: root)
        _ = try h.store.updateProject(id: id, status: .archived)
        let save = h.call("troy_save", ["project": .string(root), "kind": "note", "title": "x"])
        #expect(save.isError)
        #expect(save.text.contains("#\(id) \"Old\" is archived"), "\(save.text)")
        #expect(save.text.contains("Unarchive it in the Troy app, or pass another project"))
        let context = h.call("troy_context")
        #expect(context.isError && !context.text.contains("No project yet"))
        #expect(try h.store.projects(includeArchived: true).count == 1)
    }

    // MARK: Folder references

    @Test func aFolderReferenceWorksInEveryToolThatTakesAProject() throws {
        let dir = try RepoDir()
        let linked = try dir.folder("linked")
        let h = try Harness(workingDirectory: try dir.folder("elsewhere"))
        let id = h.newProject("Linked", path: linked)
        h.newProject("Other")
        let sub = linked + "/deep/../deep"
        #expect(h.ok("troy_context", ["project": .string(sub)]).hasPrefix("Project #\(id) \"Linked\""))
        let saved = h.ok("troy_save", ["project": .string(sub), "kind": "note", "title": "Folder note"])
        #expect(saved.contains("in project #\(id) Linked."))
        #expect(h.ok("troy_search", ["query": "folder", "project": .string(linked)]).contains("in project #\(id) Linked:"))
        let missing = h.call("troy_search", ["query": "folder", "project": "/nowhere/at/all"])
        #expect(missing.isError && missing.text.contains("No project is linked to /nowhere/at/all"))
        #expect(h.call("troy_context", ["project": "/nowhere"]).isError)
        // TROY_PROJECT may name a folder too.
        let env = try Harness(store: h.store, environment: ["TROY_PROJECT": linked])
        #expect(env.ok("troy_context").hasPrefix("Project #\(id) \"Linked\""))
        #expect(ToolRuntime.folder("~/x/") == NSHomeDirectory() + "/x")
        #expect(ToolRuntime.folder("app") == nil)
    }

    // MARK: Usage note

    private func call(_ runtime: ToolRuntime, _ tool: String, _ arguments: [String: JSON]) throws -> String {
        try Tools.find(tool)!.run(runtime, Arguments(tool: tool, arguments))
    }

    @Test func toolsFillTheUsageNote() throws {
        let dir = try RepoDir()
        let root = try dir.folder("app", git: true)
        let store = try Store(path: ":memory:", agent: "me/1")
        func runtime() -> (ToolRuntime, UsageNote) {
            let note = UsageNote()
            return (ToolRuntime(store: store, environment: [:], workingDirectory: root, usage: note), note)
        }

        var (r, note) = runtime()
        _ = try r.context(project: nil, maxChars: nil)
        #expect(note.fields["state"] == "pending" && note.projectID == nil)

        (r, note) = runtime()
        _ = try call(r, "troy_save", ["project": .string(root), "kind": "task", "title": "Export the graph", "paths": ["src"]])
        #expect(note.projectID == 1)
        #expect(note.fields["id"] == 1 && note.fields["kind"] == "task" && note.fields["links"] == 0 && note.fields["similar"] == 0)
        #expect(note.fields["advisories"] == .array([]) && note.fields["deduplicated"] == false && note.fields["created_project"] == true)

        (r, note) = runtime()
        _ = try call(r, "troy_save", ["project": 1, "kind": "task", "title": "Export the graph twice", "parent": 1, "paths": ["src"]])
        #expect(note.fields["created_project"] == false && note.fields["links"] == 1 && note.fields["similar"] == 1)

        (r, note) = runtime()
        _ = try call(r, "troy_context", [:])
        #expect(note.fields["state"] == "project" && note.projectID == 1)
        #expect(note.fields["records"] == 2 && note.fields["doing"] == 0 && note.fields["advisories"] == 0)

        (r, note) = runtime()
        _ = try call(r, "troy_update", ["id": 1, "status": "doing"])
        #expect(note.fields["id"] == 1 && note.fields["status"] == "doing" && note.fields["claim"] == "claimed" && note.projectID == 1)

        // Another agent: refused, then takeover with a path-overlap advisory.
        let otherStore = store
        let refused = UsageNote()
        otherStore.agent = "you/2"
        let other = ToolRuntime(store: otherStore, environment: [:], workingDirectory: root, usage: refused)
        #expect(throws: (any Error).self) { try call(other, "troy_update", ["id": 1, "status": "done"]) }
        #expect(refused.fields["claim"] == "refused")
        let takeover = UsageNote()
        _ = try call(ToolRuntime(store: otherStore, environment: [:], workingDirectory: root, usage: takeover),
                     "troy_update", ["id": 1, "status": "doing", "takeover": true])
        #expect(takeover.fields["claim"] == "takeover")
        #expect(takeover.fields["status"] == nil)
        store.agent = "me/1"
        (r, note) = runtime()
        _ = try call(r, "troy_update", ["id": 2, "status": "doing"])
        #expect(note.fields["advisories"] == .array(["pathOverlap"]), "\(note.detail)")

        (r, note) = runtime()
        _ = try call(r, "troy_link", ["from": 2, "to": 1, "relation": "relates_to"])
        #expect(note.fields["added"] == 1 && note.fields["removed"] == 0 && note.projectID == 1)
        (r, note) = runtime()
        _ = try call(r, "troy_link", ["from": 2, "to": 1, "relation": "relates_to", "remove": true])
        #expect(note.fields["added"] == 0 && note.fields["removed"] == 1)

        (r, note) = runtime()
        _ = try call(r, "troy_search", ["query": "export", "limit": 1])
        #expect(note.fields["hits"] == 1 && note.fields["all"] == false && note.fields["more"] == true && note.projectID == 1)
        (r, note) = runtime()
        _ = try call(r, "troy_search", ["query": "export", "all_projects": true])
        #expect(note.fields["all"] == true && note.projectID == nil)

        (r, note) = runtime()
        _ = try call(r, "troy_read", ["ids": [1, 2, 99]])
        // #1 was last written by you/2 (the takeover); #2 by me/1.
        #expect(note.fields["ids"] == .array([1, 2, 99]) && note.fields["found"] == 2 && note.fields["foreign"] == 1, "\(note.detail)")

        (r, note) = runtime()
        _ = try call(r, "troy_projects", [:])
        #expect(note.fields["count"] == 1)
        (r, note) = runtime()
        _ = try call(r, "troy_new_project", ["name": "Second", "path": .string(dir.path + "/second")])
        #expect(note.fields["created_project"] == true && note.projectID == 2)

        // Nothing that names a title, a query or a folder.
        let text = note.detail + refused.detail + takeover.detail
        #expect(!text.contains("/") && !text.contains("export"))
    }
}
