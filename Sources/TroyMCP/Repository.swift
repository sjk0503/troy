import Foundation
import TroyCore

/// The git repository a folder belongs to, for the rule that a repository's first save creates its project.
enum Repository: Equatable {
    /// The repository's main folder.
    case root(String)
    /// The nearest `.git` above the folder is a file (a linked worktree, a submodule or a separate
    /// git dir) and git could not name the main folder. Holds the folder with that file.
    case undetermined(String)
    case none

    /// How long git may take in all for one folder. Tests that run many git processes at once raise it.
    nonisolated(unsafe) static var gitTimeLimit: TimeInterval = 2

    /// The repository of `directory`. A `.git` folder needs no subprocess: that is the common
    /// case, and the session-start hook runs it before every session. Only a `.git` file asks git.
    /// - Parameter excludeHome: the home folder and `/` are never a root for the first-save rule.
    static func find(above directory: String, excludeHome: Bool = true, home: String = NSHomeDirectory()) -> Repository {
        guard let top = nearestGit(above: directory) else { return .none }
        let found: Repository
        if top.isDirectory {
            found = .root(top.folder)
        } else if let main = rememberedMainWorktree(of: top.folder) {
            found = .root(main)
        } else {
            found = .undetermined(top.folder)
        }
        guard excludeHome, case .root(let root) = found else { return found }
        return isHomeOrTop(root, home: home) ? .none : found
    }

    private static func isHomeOrTop(_ folder: String, home: String) -> Bool {
        folder == "/" || folder == home
            || (folder as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath
    }

    /// The roots of the repositories `root` is nested in, nearest first: a submodule's
    /// superproject, the repository a vendored clone or a scratch checkout sits in. A link on one
    /// of these still claims the nested repository; any other link above a repository does not.
    /// The home folder and `/` never count, as for `find`.
    ///
    /// A `.git` folder is taken as it is. A `.git` file is read first: one that leads nowhere
    /// readable ends the walk, because what its folder is cannot be told, and a plain folder with
    /// a stale `.git` file must not own the repositories below it. A linked worktree counts
    /// itself, and above it the walk goes on from its main repository (git is asked, as in
    /// `find`), not from the folder the worktree happens to sit in.
    static func enclosing(_ root: String, home: String = NSHomeDirectory()) -> [String] {
        var found: [String] = []
        var inner = root
        while true {
            let parent = (inner as NSString).deletingLastPathComponent
            guard parent != inner, !parent.isEmpty, let top = nearestGit(above: parent),
                  !isHomeOrTop(top.folder, home: home), top.folder != root, !found.contains(top.folder) else {
                return found
            }
            if top.isDirectory {
                found.append(top.folder)
                inner = top.folder
                continue
            }
            switch gitFile(in: top.folder) {
            case .unknown:
                return found
            case .standalone:
                found.append(top.folder)
                inner = top.folder
            case .worktree:
                found.append(top.folder)
                guard let main = rememberedMainWorktree(of: top.folder), !isHomeOrTop(main, home: home),
                      main != root, !found.contains(main) else {
                    return found
                }
                found.append(main)
                inner = main
            }
        }
    }

    /// What a `.git` file says its folder is, read from the file and its target alone.
    private enum GitFile {
        /// A linked worktree: the `gitdir:` target has a `commondir` file.
        case worktree
        /// A repository with its git dir elsewhere and no `commondir`: a submodule, or the main
        /// folder of a separate git dir.
        case standalone
        /// The file or its target is missing, empty or cannot be looked into.
        case unknown
    }

    private static func gitFile(in folder: String) -> GitFile {
        guard let text = try? String(contentsOfFile: folder + "/.git", encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return .unknown }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return .unknown }
        let gitDir = target.hasPrefix("/") ? target : folder + "/" + target
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: gitDir) else { return .unknown }
        return entries.contains("commondir") ? .worktree : .standalone
    }

    /// What git said about a folder with a `.git` file, kept for a short while. The session-start
    /// hook and a single tool call ask more than once, and a git that hangs must cost its time
    /// limit once, not on every call of a session.
    static let memoLifetime: TimeInterval = 30
    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [String: (main: String?, at: Date)] = [:]

    /// The memo key: the folder and what its `.git` file says, so a worktree replaced at the same
    /// path by one of another repository is asked about again.
    private static func memoKey(_ folder: String) -> String {
        let pointer = (try? String(contentsOfFile: folder + "/.git", encoding: .utf8)) ?? ""
        return folder + "\u{0}" + pointer
    }

    private static func rememberedMainWorktree(of folder: String) -> String? {
        let key = memoKey(folder)
        memoLock.lock()
        if let hit = memo[key], Date().timeIntervalSince(hit.at) < memoLifetime {
            memoLock.unlock()
            return hit.main
        }
        memoLock.unlock()
        let main = mainWorktree(of: folder)
        memoLock.withLock { memo[key] = (main, Date()) }
        return main
    }

    /// The linked worktree `directory` is in, decided from its `.git` file alone, without git: the
    /// `gitdir:` target has a `commondir` file. A target that is missing or cannot be looked into
    /// counts as a worktree too, so a git that fails or is slow can never change which project a folder gets.
    /// Nil for a `.git` folder, a submodule and the main folder of a separate git dir (no `commondir`).
    static func linkedWorktree(above directory: String) -> String? {
        guard let top = nearestGit(above: directory), !top.isDirectory else { return nil }
        // Only a git dir that can be listed and has no `commondir` means no boundary; one that is
        // missing, not a folder or cannot be looked into is "cannot tell", and that is a boundary.
        return gitFile(in: top.folder) == .standalone ? nil : top.folder
    }

    /// Stores an answer as if git had given it. For tests: `nil` stands for a git that failed or timed out.
    static func remember(_ folder: String, main: String?) {
        let key = memoKey(folder)
        memoLock.withLock { memo[key] = (main, Date()) }
    }

    /// The nearest folder at or above `directory` that holds `.git` (a file, or a folder with a
    /// `HEAD`), and whether that is a folder.
    static func nearestGit(above directory: String) -> (folder: String, isDirectory: Bool)? {
        // Plain string work: URL.standardizedFileURL would rewrite /private/var to /var and
        // the result would no longer match the folder the process runs in.
        var current = directory
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current + "/.git", isDirectory: &isDirectory) {
                // Every git dir has a HEAD. A leftover empty `.git` folder is not a repository, and
                // git itself looks past it to the enclosing one.
                if !isDirectory.boolValue || FileManager.default.fileExists(atPath: current + "/.git/HEAD") {
                    return (current, isDirectory.boolValue)
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty || current == "/" { return nil }
            current = parent
        }
    }

    /// The main work folder of the repository whose `.git` file is in `folder`, as git reports it.
    /// Nil when git is missing, fails, takes longer than `timeout` in all, the repository is bare,
    /// or git itself does not know the main work folder.
    ///
    /// Git is asked instead of reading `gitdir` and `commondir` by hand: with `--separate-git-dir`
    /// the common dir's parent is the metadata folder, not the work tree.
    /// - A folder that is not a linked worktree (a submodule, the main folder of a separate git
    ///   dir) has the same git dir and common dir; its root is the top level git reports.
    /// - A linked worktree's main folder is the first entry of `git worktree list`, accepted only
    ///   when it is a work tree itself. For a separate git dir, git lists the metadata folder
    ///   there, because nothing records where the main work tree is.
    static func mainWorktree(of folder: String, timeout: TimeInterval = gitTimeLimit) -> String? {
        guard let git = gitExecutable() else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        guard let paths = run(git, ["-C", folder, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel"],
                              timeout: deadline.timeIntervalSinceNow) else { return nil }
        let lines = paths.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        let (gitDir, commonDir, topLevel) = (ToolRuntime.normalized(lines[0]), ToolRuntime.normalized(lines[1]), lines[2])
        if gitDir == commonDir { return isFolder(topLevel) ? ToolRuntime.normalized(topLevel) : nil }
        guard let listing = run(git, ["-C", folder, "worktree", "list", "--porcelain"], timeout: deadline.timeIntervalSinceNow) else {
            return nil
        }
        let first = listing.components(separatedBy: "\n\n").first ?? ""
        let entry = first.split(separator: "\n").map(String.init)
        guard !entry.contains("bare"), let line = entry.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
        let main = String(line.dropFirst("worktree ".count))
        guard main.hasPrefix("/"), isFolder(main), FileManager.default.fileExists(atPath: main + "/.git") else { return nil }
        return ToolRuntime.normalized(main)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `/usr/bin/git`, else the first `git` on `PATH`. MCP servers started by GUI apps get a short
    /// `PATH`, so the system location comes first.
    static func gitExecutable() -> String? {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: "/usr/bin/git") { return "/usr/bin/git" }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = "\(folder)/git"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs a program with no stdin and returns its stdout when it exits 0 within `timeout`.
    /// A program that overruns is killed: the hook must never hold a session up.
    /// The environment git runs with: none of the caller's `GIT_*` variables. A server or hook
    /// started from a git hook, a rebase `exec` or a wrapper inherits `GIT_DIR` and `GIT_WORK_TREE`
    /// of another repository, and git would then answer for that one instead of the folder asked.
    static func gitEnvironment(from inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        // Reading must not take locks or rewrite the index under another git process.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval, environment: [String: String] = gitEnvironment()
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        // Read while it runs, so a long listing cannot fill the pipe and stall the process. A thread
        // of its own: under load the shared dispatch pool may not start a block (or a termination
        // handler) in time.
        let output = OutputBox()
        let done = DispatchSemaphore(value: 0)
        Thread {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Not `waitUntilExit`: it runs this thread's run loop, which has no sources and notices
            // the exit tens of milliseconds late, on every call. The pipe is closed, so the exit is
            // moments away: look for it directly.
            while process.isRunning { usleep(500) }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + max(timeout, 0)) == .success else {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.data, encoding: .utf8)
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }
}

extension ToolRuntime {
    /// The folder a first save in `directory` would link its project to, when nothing is linked
    /// yet: the repository root (never the home folder or `/`), or the folder itself when it is
    /// in no repository and Troy takes it for a project (`PlainFolder`). Nil when git could not
    /// name a linked worktree's main folder, and for a folder Troy makes no project for.
    ///
    /// For the session-start hook before the database exists; with a database, `folderState`
    /// answers the same question and also knows the links.
    public static func firstSaveRoot(for directory: String, home: String = NSHomeDirectory()) -> (root: String, isRepository: Bool)? {
        switch Repository.find(above: directory, home: home) {
        case .root(let path):
            return (Store.canonicalFolder(path), true)
        case .undetermined:
            return nil
        case .none:
            guard Repository.linkedWorktree(above: directory) == nil, PlainFolder.refusal(for: directory, home: home) == nil else {
                return nil
            }
            return (Store.canonicalFolder(directory), false)
        }
    }
}
