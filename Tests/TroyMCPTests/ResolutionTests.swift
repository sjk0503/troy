import Foundation
import Testing
import TroyCore
@testable import TroyMCP

/// One resolution path for a folder, whatever git answers. These build linked worktrees by hand
/// and tell `Repository` what git "said", so no git is needed and the failure case is exact.
@Suite struct ResolutionTests {
    /// A main repository at `main/app` and a linked worktree of it at `clients/app-feature`, inside
    /// a folder linked to the project "Clients".
    private struct Layout {
        let dir: RepoDir
        let main: String
        let enclosing: String
        let worktree: String
        let store: Store

        init() throws {
            dir = try RepoDir()
            main = try dir.folder("main/app", git: true)
            let meta = try dir.folder("main/app/.git/worktrees/app-feature")
            try "../..\n".write(toFile: meta + "/commondir", atomically: true, encoding: .utf8)
            enclosing = try dir.folder("clients")
            worktree = try dir.folder("clients/app-feature")
            try "gitdir: \(meta)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
            store = try Store(path: ":memory:")
            _ = try store.createProject(name: "Clients", paths: [enclosing])
        }

        func gitAnswers() { Repository.remember(worktree, main: main) }
        func gitFails() { Repository.remember(worktree, main: nil) }
        func harness() throws -> Harness { try Harness(store: store, workingDirectory: worktree) }
    }

    @Test func theWorktreeBoundaryComesFromTheGitFileNotFromGit() throws {
        let layout = try Layout()
        #expect(Repository.linkedWorktree(above: layout.worktree + "/src") == layout.worktree)
        #expect(Repository.linkedWorktree(above: layout.main) == nil)
        // A target that is missing counts as a boundary too.
        let lost = try layout.dir.folder("clients/lost")
        try "gitdir: /no/such/git/dir\n".write(toFile: lost + "/.git", atomically: true, encoding: .utf8)
        #expect(Repository.linkedWorktree(above: lost) == lost)
        // No commondir: a submodule or the main folder of a separate git dir. No boundary.
        let module = try layout.dir.folder("main/app/.git/modules/lib")
        let sub = try layout.dir.folder("clients/sub")
        try "gitdir: \(module)\n".write(toFile: sub + "/.git", atomically: true, encoding: .utf8)
        #expect(Repository.linkedWorktree(above: sub) == nil)
    }

    @Test func aGitFailureNeverSendsTheWorktreeToTheEnclosingProject() throws {
        let layout = try Layout()
        layout.gitAnswers()
        let h = try layout.harness()
        let created = h.ok("troy_save", ["project": .string(layout.worktree), "kind": "note", "title": "First"])
        #expect(created.hasPrefix("Created project #2 \"app\""), "\(created)")

        layout.gitFails()
        let context = h.call("troy_context")
        #expect(context.isError)
        #expect(!context.text.contains("Project #1") && context.text.contains("could not determine"), "\(context.text)")
        let save = h.call("troy_save", ["project": .string(layout.worktree), "kind": "note", "title": "While git fails"])
        #expect(save.isError && save.text.contains("could not determine"), "\(save.text)")
        #expect(h.ok("troy_search", ["query": "first"]).contains("in all projects"))
        #expect(!h.ok("troy_projects").contains("← this folder"))
        #expect(try layout.store.list(RecordQuery(projectID: 1)).isEmpty)

        layout.gitAnswers()
        #expect(h.ok("troy_context").hasPrefix("Project #2 \"app\""))
    }

    @Test func anArchivedRepositoryProjectIsNotReplacedByTheEnclosingOne() throws {
        let layout = try Layout()
        layout.gitAnswers()
        let archived = try layout.store.createProject(name: "app", paths: [layout.main])
        _ = try layout.store.updateProject(id: archived.id, status: .archived)
        for folder in [layout.worktree, layout.main] {
            let h = try Harness(store: layout.store, workingDirectory: folder)
            let context = h.call("troy_context")
            #expect(context.isError && context.text.contains("#\(archived.id) \"app\"") && context.text.contains("archived"), "\(context.text)")
            #expect(!context.text.hasPrefix("Project #1"))
            let save = h.call("troy_save", ["project": .string(folder), "kind": "note", "title": "x"])
            #expect(save.isError && save.text.contains("is archived"), "\(save.text)")
            #expect(h.ok("troy_search", ["query": "x"]).contains("in all projects"))
            #expect(!h.ok("troy_projects").contains("← this folder"))
        }
        // The main folder sits under no link here, so put one above it as well.
        let outer = try layout.dir.folder("main")
        _ = try layout.store.createProject(name: "Outer", paths: [outer])
        let fromMain = try Harness(store: layout.store, workingDirectory: layout.main)
        #expect(fromMain.call("troy_context").isError)
        #expect(try layout.store.list(RecordQuery()).isEmpty)
    }

    @Test func aSaveWithStatusDoingReportsTheClaim() throws {
        let store = try Store(path: ":memory:", agent: "me/1")
        let project = try store.createProject(name: "Claims")
        let note = UsageNote()
        let runtime = ToolRuntime(store: store, environment: [:], workingDirectory: "/nonexistent", usage: note)
        _ = try Tools.find("troy_save")!.run(runtime, Arguments(tool: "troy_save", [
            "project": .int(project.id), "kind": "task", "title": "Started at once", "status": "doing",
        ]))
        #expect(note.fields["claim"] == "claimed")
        let plain = UsageNote()
        _ = try Tools.find("troy_save")!.run(
            ToolRuntime(store: store, environment: [:], workingDirectory: "/nonexistent", usage: plain),
            Arguments(tool: "troy_save", ["project": .int(project.id), "kind": "task", "title": "Later"]))
        #expect(plain.fields["claim"] == nil)
    }

    @Test(.enabled(if: gitAvailable)) func aSeparateGitDirNamedDotGitIsAKnownLimitation() throws {
        // Pins the documented limitation: nothing records the real work folder, and the metadata
        // folder has a `.git` folder, so git's answer is taken.
        let dir = try RepoDir()
        let work = try dir.folder("work/app")
        try dir.folder("meta/app")
        try dir.git(["init", "-q", "--separate-git-dir", dir.path + "/meta/app/.git", work])
        try dir.git(["commit", "-q", "--allow-empty", "-m", "init"], in: work)
        let worktree = dir.path + "/trees/app-two"
        try dir.git(["worktree", "add", "-q", "-b", "two", worktree], in: work)
        #expect(Repository.find(above: work) == .root(work))
        #expect(Repository.find(above: worktree) == .root(dir.path + "/meta/app"))
    }
}

/// The last review round: inherited git variables, worktree defaults, `..` after a symlink,
/// empty `.git` folders, a replaced worktree and a git dir that cannot be looked into.
@Suite struct ResolutionEdgeTests {
    @Test(.enabled(if: gitAvailable)) func inheritedGitVariablesDoNotRedirectGit() throws {
        let dir = try RepoDir()
        let asked = try dir.repository("asked")
        let other = try dir.repository("other")
        let git = Repository.gitExecutable()!
        let inherited = ["GIT_DIR": other + "/.git", "GIT_WORK_TREE": other, "PATH": "/usr/bin:/bin"]
        let arguments = ["-C", asked, "rev-parse", "--show-toplevel"]
        // Unfiltered, git answers for the other repository: the case being guarded against.
        #expect(Repository.run(git, arguments, timeout: 30, environment: inherited) == other + "\n")
        let clean = Repository.gitEnvironment(from: inherited)
        #expect(clean["GIT_DIR"] == nil && clean["GIT_WORK_TREE"] == nil && clean["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(Repository.run(git, arguments, timeout: 30, environment: clean) == asked + "\n")
    }

    @Test func newProjectInAnUndeterminedWorktreeAsksForAPath() throws {
        let dir = try RepoDir()
        let worktree = try dir.folder("wt")
        try "gitdir: \(dir.path)/gone/.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        Repository.remember(worktree, main: nil)
        let h = try Harness(workingDirectory: worktree)
        let refused = h.call("troy_new_project", ["name": "Split"])
        #expect(refused.isError && refused.text.contains("Pass \"path\""), "\(refused.text)")
        #expect(try h.store.projects().isEmpty)
        #expect(h.ok("troy_new_project", ["name": "Own", "path": .string(worktree)]).contains("linked to \(worktree)."))
    }

    @Test func dotDotAfterASymlinkFollowsTheFileSystem() throws {
        let dir = try RepoDir()
        let deep = try dir.folder("arch/debug")
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/debug", withDestinationPath: deep)
        // `debug/..` is the folder the link points into, not the folder the link sits in.
        #expect(ToolRuntime.folder(dir.path + "/debug/..") == dir.path + "/arch")
        #expect(ToolRuntime.folder(dir.path + "/missing/../x") == dir.path + "/x")
        let store = try Store(path: ":memory:")
        let arch = try store.createProject(name: "Arch", paths: [dir.path + "/arch"])
        let h = try Harness(store: store, workingDirectory: "/nonexistent")
        #expect(h.ok("troy_context", ["project": .string(dir.path + "/debug/..")]).hasPrefix("Project #\(arch.id) \"Arch\""))
        let relative = try Harness(store: store, workingDirectory: dir.path)
        #expect(relative.ok("troy_new_project", ["name": "Deep", "path": "debug"]).contains("linked to \(deep)."))
    }

    @Test func anEmptyDotGitFolderIsNotARepository() throws {
        let dir = try RepoDir()
        let root = try dir.folder("app", git: true)
        let leftover = try dir.folder("app/vendor/old")
        try dir.folder("app/vendor/old/.git")
        #expect(Repository.find(above: leftover + "/src") == .root(root))
        #expect(Repository.find(above: try dir.folder("plain/.git") + "/..") == .none)
    }

    @Test func aReplacedWorktreeIsAskedAboutAgain() throws {
        let dir = try RepoDir()
        let first = try dir.folder("first", git: true)
        let worktree = try dir.folder("wt")
        try "gitdir: \(first)/.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        Repository.remember(worktree, main: first)
        #expect(Repository.find(above: worktree) == .root(first))
        // Same path, now a worktree of another (here: unreachable) repository.
        try "gitdir: \(dir.path)/second/.git/worktrees/wt\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        #expect(Repository.find(above: worktree) == .undetermined(worktree))
    }

    @Test func aGitDirThatCannotBeLookedIntoIsABoundary() throws {
        let dir = try RepoDir()
        let locked = try dir.folder("meta/locked")
        let worktree = try dir.folder("wt")
        try "gitdir: \(locked)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: locked)) == nil else { return }  // running as root
        #expect(Repository.linkedWorktree(above: worktree) == worktree)
        // A readable git dir without commondir is a submodule: no boundary.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        #expect(Repository.linkedWorktree(above: worktree) == nil)
    }
}
