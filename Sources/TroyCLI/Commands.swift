import Foundation
import TroyCore
import TroyMCP

enum Commands {
    static func find(_ name: String) -> Command? { all.first { $0.name == name } }

    static func openStore(_ context: CLIContext, agent: String = "troy-cli") throws -> Store {
        try Store(path: context.db ?? Store.defaultPath(), agent: agent)
    }

    static func runtime(_ context: CLIContext) throws -> ToolRuntime {
        ToolRuntime(store: try openStore(context))
    }

    /// What the session-start hook prints, the project it showed and the state for the usage log
    /// ("project", "pending" or "none"). A hook must never break a session, and must not create a
    /// database as a side effect: without the file, a folder whose first save would create a
    /// project gets the hint and nothing is opened.
    static func hookText(
        path: String, project: String?, maxChars: Int?,
        environment: [String: String] = ProcessInfo.processInfo.environment, workingDirectory: String? = nil
    ) -> (text: String, projectID: Int64?, state: String) {
        let folder = workingDirectory ?? ToolRuntime.currentDirectory()
        let explicit = project?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || environment["TROY_PROJECT"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard FileManager.default.fileExists(atPath: path) else {
            guard !explicit, let first = ToolRuntime.firstSaveRoot(for: folder) else { return ("", nil, "none") }
            return (TroyText.pending(root: first.root, isRepository: first.isRepository, projects: []), nil, "pending")
        }
        guard let store = try? Store(path: path, agent: "troy-cli") else { return ("", nil, "none") }
        let usage = UsageNote()
        let runtime = ToolRuntime(store: store, environment: environment, workingDirectory: folder, usage: usage)
        guard let text = try? runtime.context(project: project, maxChars: maxChars) else { return ("", nil, "none") }
        let state = usage.fields["state"]?.string == "pending" ? "pending" : "project"
        return (text, usage.projectID, state)
    }

    static let all: [Command] = [
        Command(name: "mcp", synopsis: "", summary: "Run the MCP server on stdin and stdout (what AI clients start).") { _, _, context in
            MCPServer(dbPath: context.db).serve()
            return 0
        },
        Command(
            name: "context", synopsis: "[--project <id|name|folder>] [--max-chars N] [--quiet]",
            summary: "Print the project's state: in progress, ready, blocked, decisions. In a folder without a project whose first save creates one (a git repository, or a work folder at least two levels below the home folder), print how. --quiet prints nothing when neither applies and never fails (for session-start hooks).",
            flags: ["quiet"], options: ["project", "max-chars"]
        ) { parsed, console, context in
            let quiet = parsed.flags.contains("quiet")
            let maxChars = try parsed.int("max-chars")
            if quiet {
                let started = DispatchTime.now().uptimeNanoseconds
                let path = ((context.db ?? Store.defaultPath()) as NSString).expandingTildeInPath
                let (text, projectID, state) = hookText(path: path, project: parsed.options["project"], maxChars: maxChars)
                if !text.isEmpty { console.out(text) }
                let micros = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
                // `record` does not wait for a busy log; `close` does, briefly, so the row is not
                // lost when another process holds the log at that moment.
                let log = UsageLog.forDatabase(at: path, createFolder: false)
                log?.record(.hook(projectID: projectID, state: state, printed: text, micros: micros))
                log?.close()
                return 0
            }
            console.out(try runtime(context).context(project: parsed.options["project"], maxChars: maxChars))
            return 0
        },
        Command(
            name: "search", synopsis: "<words…> [--project <id|name>] [--all] [--limit N]",
            summary: "Find records whose title, tags or body contain every word.",
            flags: ["all"], options: ["project", "limit"]
        ) { parsed, console, context in
            guard !parsed.positionals.isEmpty else {
                throw UsageError(message: "search needs the words to look for.", usage: find("search")?.usage)
            }
            console.out(try runtime(context).search(
                query: parsed.positionals.joined(separator: " "), project: parsed.options["project"],
                allProjects: parsed.flags.contains("all"), limit: try parsed.int("limit") ?? 10))
            return 0
        },
        Command(
            name: "read", synopsis: "<id>… [--max-chars N]", summary: "Print records in full, with their links and warnings.",
            options: ["max-chars"]
        ) { parsed, console, context in
            guard !parsed.positionals.isEmpty else {
                throw UsageError(message: "read needs at least one record number.", usage: find("read")?.usage)
            }
            let ids = try ToolRuntime.recordIDs(from: parsed.positionals)
            console.out(try runtime(context).read(ids: ids, maxChars: try parsed.int("max-chars")))
            return 0
        },
        Command(name: "projects", synopsis: "[--archived]", summary: "List projects with record counts and linked folders.", flags: ["archived"]) { parsed, console, context in
            console.out(try runtime(context).projects(includeArchived: parsed.flags.contains("archived")))
            return 0
        },
        Command(
            name: "new-project", synopsis: "<name> [--summary <text>] [--path <folder>]",
            summary: "Create a project linked to a folder (default: the git root above this folder).",
            options: ["summary", "path"]
        ) { parsed, console, context in
            guard !parsed.positionals.isEmpty else {
                throw UsageError(message: "new-project needs a name.", usage: find("new-project")?.usage)
            }
            console.out(try runtime(context).newProject(
                name: parsed.positionals.joined(separator: " "), summary: parsed.options["summary"], path: parsed.options["path"]))
            return 0
        },
        Command(
            name: "export", synopsis: "[--project <id|name>] [--out <file>]",
            summary: "Write every record and link as Markdown (all projects unless --project is given).",
            options: ["project", "out"]
        ) { parsed, console, context in
            let runtime = try runtime(context)
            var projectID: Int64?
            if let reference = parsed.options["project"] { projectID = try runtime.store.resolveProject(reference: reference, directory: nil).id }
            let markdown = try runtime.store.exportMarkdown(projectID: projectID)
            if let out = parsed.options["out"] {
                let path = (out as NSString).expandingTildeInPath
                do {
                    try markdown.write(toFile: path, atomically: true, encoding: .utf8)
                } catch {
                    throw Failure(message: "cannot write \(path): \(error.localizedDescription)")
                }
                console.out("Wrote \(markdown.utf8.count) bytes to \(path).")
            } else {
                console.out(markdown)
            }
            return 0
        },
        Command(
            name: "backup", synopsis: "<file>",
            summary: "Write a complete copy of the database to a new file, safe while agents are working."
        ) { parsed, console, context in
            guard parsed.positionals.count == 1 else {
                throw UsageError(message: "backup needs the file to write.", usage: find("backup")?.usage)
            }
            // Opening a store creates the file, and an empty database is nothing to back up.
            let source = ((context.db ?? Store.defaultPath()) as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: source) else {
                throw Failure(message: "there is no database at \(source) yet.")
            }
            let target = (parsed.positionals[0] as NSString).expandingTildeInPath
            try openStore(context).backup(to: target)
            let size = (try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? Int ?? 0
            console.out("Wrote \(size) bytes to \(target).")
            return 0
        },
        StatsCommand.command,
        Command(
            name: "guide", synopsis: "[--hook]",
            summary: "Print the section to paste into AGENTS.md or CLAUDE.md. --hook prints the Claude Code session-start hook for this binary.",
            flags: ["hook"]
        ) { parsed, console, _ in
            console.out(parsed.flags.contains("hook")
                ? AgentGuide.sessionStartHook(binary: MCPClients.defaultBinary()) : AgentGuide.projectSnippet)
            return 0
        },
        Command(
            name: "connect", synopsis: "[<client>] [--remove]",
            summary: "List the AI clients Troy can register with, or connect (or with --remove, disconnect) one by id.",
            flags: ["remove"]
        ) { parsed, console, _ in
            let binary = MCPClients.defaultBinary()
            let guides = MCPClients.guides(binary: binary)
            guard let id = parsed.positionals.first else {
                if parsed.flags.contains("remove") {
                    throw UsageError(message: "--remove needs a client id.", usage: find("connect")?.usage)
                }
                for guide in guides {
                    let installed = MCPClients.isInstalled(guide) ? "installed" : "not installed"
                    let connected = MCPClients.isConnected(guide).map { $0 ? "connected" : "not connected" } ?? "unknown"
                    console.out("\(guide.id)  \(guide.name)  (\(installed), \(connected))")
                    console.out(guide.manual.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
                }
                console.out("\nConnect one with: troy connect <client>")
                return 0
            }
            guard parsed.positionals.count == 1 else {
                throw UsageError(message: "connect takes one client id.", usage: find("connect")?.usage)
            }
            guard let guide = guides.first(where: { $0.id == id }) else {
                throw UsageError(message: "unknown client '\(id)'. Clients: \(guides.map(\.id).joined(separator: ", ")).", usage: find("connect")?.usage)
            }
            if parsed.flags.contains("remove") {
                console.out(try MCPClients.disconnect(guide))
            } else {
                console.out(try MCPClients.connect(guide, binary: binary))
                if let followUp = guide.followUp { console.out("\n" + followUp) }
            }
            return 0
        },
        Command(name: "demo", synopsis: "[--korean]", summary: "Add the example project to the database.", flags: ["korean"]) { parsed, console, context in
            let store = try openStore(context)
            let language: DemoData.Language = parsed.flags.contains("korean") ? .korean : .english
            let project = try DemoData.seed(into: store, language: language)
            console.out("Demo project #\(project.id) \"\(project.name)\" is in the database. Try: troy context --project \(project.id)")
            return 0
        },
        Command(name: "doctor", synopsis: "", summary: "Check the database and print where everything is.") { _, console, context in
            let path = ((context.db ?? Store.defaultPath()) as NSString).expandingTildeInPath
            console.out("troy \(MCPServer.version)")
            console.out("binary:   \(MCPClients.defaultBinary())")
            console.out("database: \(path)")
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let size = attributes?[.size] as? Int else {
                console.out("          not created yet; Troy creates it the first time it is opened.")
                return 0
            }
            console.out("          \(size) bytes")
            let store: Store
            do {
                store = try Store(path: path, agent: "troy-cli")
            } catch {
                throw Failure(message: "the database cannot be opened: \((error as? TroyError)?.message ?? "\(error)")")
            }
            let projects = try store.projects(includeArchived: true)
            let records = projects.reduce(0) { $0 + $1.stats.records }
            console.out("schema:   version \(Schema.currentVersion)")
            console.out("search:   " + (store.ftsAvailable ? "full-text index (trigram)" : "LIKE only (this SQLite has no FTS5 trigram tokenizer)"))
            console.out("content:  \(projects.count) project\(projects.count == 1 ? "" : "s"), \(records) record\(records == 1 ? "" : "s")")
            return 0
        },
        Command(name: "version", synopsis: "", summary: "Print the version.") { _, console, _ in
            console.out("troy \(MCPServer.version)")
            return 0
        },
    ]
}
