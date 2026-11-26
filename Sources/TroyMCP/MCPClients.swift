import Foundation

/// How one AI client is told about the Troy MCP server.
public struct MCPClientGuide: Identifiable, Hashable, Sendable {
    public enum Method: Hashable, Sendable {
        /// The client's own command line tool registers the server. `argv[0]` is the tool's name.
        case command(argv: [String])
        /// The server is an entry in a JSON settings file: `file[key]["troy"]`.
        case jsonFile(path: String, key: String)
    }

    /// Stable identifier: "claude-code", "codex", "claude-desktop", "cursor", "vscode", "gemini".
    public var id: String
    public var name: String
    public var method: Method
    /// Command that removes the registration, when the client has one.
    public var removeArgv: [String]?
    /// The file that shows whether the server is registered. Tilde is not expanded.
    public var statusFile: String
    /// The JSON key holding the servers in `statusFile`; `nil` for Codex's TOML file.
    public var statusKey: String?
    /// The application bundle that shows the client is installed, when it is an app.
    public var appPath: String?
    /// What to run or paste when connecting by hand.
    public var manual: String
    /// What the person still has to do themselves after the server is registered, when the
    /// client needs it before agents can use Troy unasked. Troy never changes these settings.
    public var followUp: String?
}

/// Registering Troy with the AI clients installed on this Mac.
///
/// Nothing here runs on its own. The app calls `connect` when the person clicks Connect,
/// and `troy connect <client>` calls it from the command line.
public enum MCPClients {
    public static let serverName = "troy"

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Every client Troy knows how to connect, for a `troy` binary at `binary`.
    public static func guides(binary: String) -> [MCPClientGuide] {
        let entry = "{\"command\": \"\(escape(binary))\", \"args\": [\"mcp\"]}"
        let vscodeEntry = "{\"name\":\"troy\",\"type\":\"stdio\",\"command\":\"\(escape(binary))\",\"args\":[\"mcp\"]}"
        func snippet(_ key: String) -> String { "{\n  \"\(key)\": {\n    \"troy\": \(entry)\n  }\n}" }
        func shell(_ argv: [String]) -> String { argv.map(quote).joined(separator: " ") }

        let claudeCode = ["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", serverName, "--", binary, "mcp"]
        let codex = ["codex", "mcp", "add", serverName, "--", binary, "mcp"]
        let vscode = ["code", "--add-mcp", vscodeEntry]
        let gemini = ["gemini", "mcp", "add", "--scope", "user", serverName, binary, "mcp"]
        let claudeDesktopFile = "~/Library/Application Support/Claude/claude_desktop_config.json"
        let cursorFile = "~/.cursor/mcp.json"

        return [
            MCPClientGuide(
                id: "claude-code", name: "Claude Code", method: .command(argv: claudeCode),
                removeArgv: ["claude", "mcp", "remove", serverName, "--scope", "user"],
                statusFile: "~/.claude.json", statusKey: "mcpServers", appPath: nil, manual: shell(claudeCode),
                followUp: claudeCodeFollowUp),
            MCPClientGuide(
                id: "codex", name: "Codex", method: .command(argv: codex),
                removeArgv: ["codex", "mcp", "remove", serverName],
                statusFile: "~/.codex/config.toml", statusKey: nil, appPath: nil, manual: shell(codex)),
            MCPClientGuide(
                id: "claude-desktop", name: "Claude Desktop", method: .jsonFile(path: claudeDesktopFile, key: "mcpServers"),
                removeArgv: nil, statusFile: claudeDesktopFile, statusKey: "mcpServers",
                appPath: "/Applications/Claude.app", manual: snippet("mcpServers")),
            MCPClientGuide(
                id: "cursor", name: "Cursor", method: .jsonFile(path: cursorFile, key: "mcpServers"),
                removeArgv: nil, statusFile: cursorFile, statusKey: "mcpServers",
                appPath: "/Applications/Cursor.app", manual: snippet("mcpServers")),
            MCPClientGuide(
                id: "vscode", name: "VS Code", method: .command(argv: vscode), removeArgv: nil,
                statusFile: "~/Library/Application Support/Code/User/mcp.json", statusKey: "servers",
                appPath: "/Applications/Visual Studio Code.app", manual: shell(vscode)),
            MCPClientGuide(
                id: "gemini", name: "Gemini CLI", method: .command(argv: gemini),
                removeArgv: ["gemini", "mcp", "remove", "--scope", "user", serverName],
                statusFile: "~/.gemini/settings.json", statusKey: "mcpServers", appPath: nil, manual: shell(gemini)),
        ]
    }

    /// Claude Code asks before each call of a tool that no rule allows, and a session nobody
    /// watches (`claude -p`, a delegated worker) is refused instead: measured on 2026-11-24, when
    /// the one session that tried `troy_context` got "you haven't granted it yet". Permissions
    /// are the person's to give, so `connect` says how and changes nothing.
    public static let claudeCodeFollowUp = """
    One more step, yours to take: allow Troy's tools in ~/.claude/settings.json.
    Until then Claude Code asks before every call, and sessions nobody watches (claude -p, delegated workers) are refused.
        "permissions": { "allow": ["mcp__troy"] }
    Optional: `troy guide --hook` prints a session-start hook that shows the project's state before the first turn.
    """

    /// The `troy` binary other programs should start: the one inside the app bundle when this
    /// code runs in the app, otherwise the running executable itself.
    public static func defaultBinary() -> String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/troy").path
        if FileManager.default.isExecutableFile(atPath: helper) { return helper }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "troy").standardizedFileURL
        if executable.lastPathComponent == "troy", FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable.resolvingSymlinksInPath().path
        }
        return locate("troy") ?? "troy"
    }

    /// The absolute path of a command line tool. Looks in the usual install folders first,
    /// then asks the person's login shell, because apps started from Finder get a short PATH.
    public static func locate(_ tool: String) -> String? {
        guard !tool.isEmpty, !tool.contains("/") else {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        let home = NSHomeDirectory()
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin",
        ]
        for folder in folders {
            let candidate = "\(folder)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard let found = try? loginShell("command -v \(quote(tool))"), found.status == 0 else { return nil }
        let line = found.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: line) ? line : nil
    }

    /// Whether the client appears to be installed on this Mac.
    public static func isInstalled(_ guide: MCPClientGuide) -> Bool {
        let files = FileManager.default
        if let appPath = guide.appPath, files.fileExists(atPath: appPath) { return true }
        if case .command(let argv) = guide.method, let tool = argv.first, locate(tool) != nil { return true }
        let folder = (expand(guide.statusFile) as NSString).deletingLastPathComponent
        // A settings folder directly under the home folder (~/.codex, ~/.cursor) means the client ran here.
        return folder != NSHomeDirectory() && files.fileExists(atPath: folder)
    }

    /// Whether the client already has a server named "troy". `nil` when the file cannot be read as expected.
    public static func isConnected(_ guide: MCPClientGuide) -> Bool? {
        let path = expand(guide.statusFile)
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        guard let key = guide.statusKey else {
            let text = String(decoding: data, as: UTF8.self)
            return text.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.\(serverName)]"
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Settings files with comments are not strict JSON; do not guess.
            return nil
        }
        return (root[key] as? [String: Any])?[serverName] != nil
    }

    /// Registers the server and returns a one-line description of what was done.
    /// A JSON file is rewritten with the entry merged in; the previous file is kept next to it
    /// with the extension `troy-backup`.
    @discardableResult
    public static func connect(_ guide: MCPClientGuide, binary: String) throws -> String {
        switch guide.method {
        case .command(let argv):
            try run(argv)
            return "\(guide.name): registered the server \"\(serverName)\"."
        case .jsonFile(let path, let key):
            try edit(file: expand(path), shown: path, guide: guide) { root in
                var servers: [String: Any] = [:]
                if let existing = root[key] {
                    // A list, or anything else that is not a name-to-server table, is a format Troy does not know.
                    guard let table = existing as? [String: Any] else {
                        throw Failure("\"\(key)\" in \(path) is not a table of servers, so Troy will not rewrite it. Add this entry by hand:\n\(guide.manual)")
                    }
                    servers = table
                }
                // Keep whatever else the entry already carries (an env with TROY_DB, for example).
                var entry = servers[serverName] as? [String: Any] ?? [:]
                entry["command"] = binary
                entry["args"] = ["mcp"]
                servers[serverName] = entry
                root[key] = servers
            }
            return "\(guide.name): added \"\(serverName)\" to \(path). Restart \(guide.name) to load it."
        }
    }

    /// Removes the registration and returns a one-line description of what was done.
    @discardableResult
    public static func disconnect(_ guide: MCPClientGuide) throws -> String {
        if let argv = guide.removeArgv {
            try run(argv)
            return "\(guide.name): removed the server \"\(serverName)\"."
        }
        guard let key = guide.statusKey else {
            throw Failure("Remove the [mcp_servers.\(serverName)] section from \(guide.statusFile) by hand.")
        }
        let missing = Failure("\(guide.name) has no server named \"\(serverName)\" in \(guide.statusFile).")
        guard FileManager.default.fileExists(atPath: expand(guide.statusFile)) else { throw missing }
        try edit(file: expand(guide.statusFile), shown: guide.statusFile, guide: guide) { root in
            guard var servers = root[key] as? [String: Any], servers[serverName] != nil else { throw missing }
            servers[serverName] = nil
            root[key] = servers
        }
        return "\(guide.name): removed \"\(serverName)\" from \(guide.statusFile)."
    }

    /// Rewrites a client's JSON settings file with `change` applied, losing nothing else in it.
    /// - The file must be a JSON object; anything else (comments, a list) is refused, not repaired.
    /// - The file that was replaced is kept next to the new one as `<name>.troy-backup`.
    /// - If the client saved the file while Troy was editing it, the client's version stays,
    ///   nothing of Troy's is written and the caller is asked to try again.
    static func edit(
        file path: String, shown: String, guide: MCPClientGuide, _ change: (inout [String: Any]) throws -> Void
    ) throws {
        let files = FileManager.default
        // The file itself rather than a link to it, so settings kept in a dotfiles folder stay linked.
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let before = files.contents(atPath: file)
        if before == nil, files.fileExists(atPath: file) {
            throw Failure("\(shown) cannot be read, so Troy will not rewrite it. Add this entry by hand:\n\(guide.manual)")
        }
        var root: [String: Any] = [:]
        if let before, !before.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: before) as? [String: Any] else {
                throw Failure("\(shown) is not plain JSON, so Troy will not rewrite it. Add this entry by hand:\n\(guide.manual)")
            }
            root = parsed
        }
        try change(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try files.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try replace(file, with: data, expecting: before, shown: shown)
    }

    /// Puts `data` in place of `file`, which held `expected` when Troy read it (`nil`: no file).
    ///
    /// Comparing the file and then writing it would leave a moment in which a save by the client
    /// is overwritten. Instead the new file and the old one trade places in a single step of the
    /// file system, and what came out is compared afterwards. When it is not what was read, the
    /// client saved in between, and its version goes back the same way.
    ///
    /// A client cannot be locked out of its own file, so one gap is left: for the instant
    /// between the exchange and the exchange back, Troy's version is what a reader finds, and a
    /// client that reads it then may save on top of it, during the exchanges or after them.
    /// The rule that covers it: once the client has saved in between, a copy of every save of
    /// its that came out of an exchange is kept next to the file, and the error names them.
    ///
    /// `exchanged` is called after every exchange (tests use it to play the client).
    static func replace(
        _ file: String, with data: Data, expecting expected: Data?, shown: String, exchanged: () -> Void = {}
    ) throws {
        #if canImport(Darwin)
        let files = FileManager.default
        let changed = Failure("\(shown) changed while Troy was editing it. Nothing was written; try again.")
        func reason(_ code: Int32) -> String { String(cString: strerror(code)) }

        // The spare file is number 0 and the kept saves are 1, 2, …: names of one length, so a
        // folder that took the name of the spare file takes theirs too.
        let tag = UUID().uuidString.prefix(8)
        func side(_ number: Int) -> String { "\(file).troy-\(tag)-\(number)" }
        let spare = side(0)
        guard files.createFile(atPath: spare, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("\(shown) could not be written: its folder does not take a new file next to it.")
        }
        var spareIsDisposable = true
        defer { if spareIsDisposable { try? files.removeItem(atPath: spare) } }

        guard let expected else {
            // There was no file. Refuse to replace one that has appeared since.
            if renamex_np(spare, file, UInt32(RENAME_EXCL)) == 0 { return }
            let code = errno
            if code == EEXIST { throw changed }
            guard code == ENOTSUP else { throw Failure("\(shown) could not be written: \(reason(code)).") }
            return try replaceByRename(file, with: data, expecting: nil, shown: shown)
        }
        if let mode = (try? files.attributesOfItem(atPath: file))?[.posixPermissions] {
            try? files.setAttributes([.posixPermissions: mode], ofItemAtPath: spare)
        }

        var inPlace: Data? = expected  // what the file is believed to hold
        var arriving: Data? = data     // what the spare file holds; the next exchange puts it in place
        var unseen: [Data] = []        // saves by the client that came out of an exchange, oldest first

        /// What the spare file holds when Troy steps back.
        enum Spare { case troysVersion, savedElsewhere, onlyCopy }

        /// A failure that says where the client's saves in `versions` are kept. They are written
        /// only now, so that Troy's version is not in place for longer than the exchanges take.
        func steppedBack(_ text: String, keeping versions: [Data], spare holds: Spare) -> Failure {
            var names: [String] = []
            var missing = false
            for (index, version) in versions.enumerated() {
                let name = side(index + 1)
                if files.createFile(atPath: name, contents: version, attributes: [.posixPermissions: 0o600]) {
                    names.append(name)
                } else {
                    missing = true
                }
            }
            if holds == .onlyCopy || (holds == .savedElsewhere && missing) {
                spareIsDisposable = false
                names.append(spare)
            }
            var message = names.isEmpty ? text : "\(text) What the client saved meanwhile is kept as \(names.joined(separator: ", "))."
            if missing { message += " Not every copy could be written." }
            return Failure(message)
        }

        for round in 0..<6 {
            guard renamex_np(spare, file, UInt32(RENAME_SWAP)) == 0 else {
                let code = errno
                if round > 0 {
                    // The client's newest save is in the spare file and could not go back in place.
                    throw steppedBack(
                        "\(shown) changed while Troy was editing it and could not be restored (\(reason(code))).",
                        keeping: Array(unseen.dropLast()), spare: .onlyCopy)
                }
                if code == ENOENT { throw changed }
                guard code == ENOTSUP else { throw Failure("\(shown) could not be written: \(reason(code)).") }
                return try replaceByRename(file, with: data, expecting: expected, shown: shown)
            }
            exchanged()
            // The spare file now holds whatever the exchange displaced.
            let displaced = files.contents(atPath: spare)
            if displaced == inPlace {
                if round == 0 {
                    // The file Troy read made way for the new one. It becomes the backup; if it
                    // cannot take that name it stays under its spare name rather than being lost.
                    if rename(spare, file + ".troy-backup") != 0 { spareIsDisposable = false }
                    return
                }
                // What came out is what Troy had put there: its own version in round 1, an earlier
                // save of the client after that. The client's latest save is in place again. The
                // copies stay even so: the client may have read Troy's version in the meantime.
                if round == 1 {
                    throw steppedBack(changed.description, keeping: unseen, spare: .troysVersion)
                }
                throw steppedBack(
                    "\(shown) changed more than once while Troy was editing it, so Troy stepped back. The file may miss something from the client's earlier saves.",
                    keeping: unseen, spare: .savedElsewhere)
            }
            // A save Troy had not seen. It goes back in place with the next exchange.
            unseen.append(displaced ?? Data())
            inPlace = arriving
            arriving = displaced
        }
        throw steppedBack(
            "\(shown) kept changing while Troy was editing it, so Troy stepped back.",
            keeping: Array(unseen.dropLast()), spare: .onlyCopy)
        #else
        try replaceByRename(file, with: data, expecting: expected, shown: shown)
        #endif
    }

    /// For volumes without an atomic exchange: compare, then rename over the file. A save by the
    /// client in the instant between the two is still lost there.
    static func replaceByRename(_ file: String, with data: Data, expecting expected: Data?, shown: String) throws {
        let files = FileManager.default
        guard files.contents(atPath: file) == expected, expected != nil || !files.fileExists(atPath: file) else {
            throw Failure("\(shown) changed while Troy was editing it. Nothing was written; try again.")
        }
        if let expected {
            try expected.write(to: URL(fileURLWithPath: file + ".troy-backup"), options: .atomic)
        }
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    // MARK: Running commands

    private static func run(_ argv: [String]) throws {
        guard let tool = argv.first else { throw Failure("Nothing to run.") }
        guard locate(tool) != nil else {
            throw Failure("The command \"\(tool)\" was not found. Install it, or run this yourself:\n\(argv.map(quote).joined(separator: " "))")
        }
        // Through the login shell, so tools that need the person's PATH (node, for example) start.
        let result = try loginShell(argv.map(quote).joined(separator: " "))
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure("\"\(tool)\" exited with status \(result.status).\(detail.isEmpty ? "" : "\n" + String(detail.suffix(600)))")
        }
    }

    private static func loginShell(_ command: String, timeout: TimeInterval = 30) throws -> (status: Int32, output: String) {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchSemaphore(value: 0)
        let collected = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw Failure("The command did not finish within \(Int(timeout)) seconds.")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: collected.data, as: UTF8.self))
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }

    // MARK: Text helpers

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// Single-quotes a word for a POSIX shell.
    static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use inside a JSON string literal.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
