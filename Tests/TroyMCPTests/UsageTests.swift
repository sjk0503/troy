import Foundation
import Testing
@testable import TroyCore
@testable import TroyMCP

/// A temporary folder that disappears with the value. Created on first use.
final class UsageFolder: @unchecked Sendable {
    let url: URL

    init(name: String = "troy-usage-tests") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    var database: String { path("troy.db") }
    var log: String { UsageLog.path(forDatabase: database) }
}

private func rows(_ path: String) throws -> [LoggedUsage] {
    try UsageLog.read(at: path, since: Date(timeIntervalSince1970: 0))
}

/// Sends `requests` to `server` and returns the reply lines.
private func drive(_ server: MCPServer, _ requests: [String]) -> [String?] {
    requests.map { server.handle(line: $0) }
}

private func request(_ id: Int, _ method: String, _ params: JSON? = nil) -> String {
    var message: [String: JSON] = ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method)]
    if let params { message["params"] = params }
    return JSON.object(message).text
}

private func call(_ id: Int, _ tool: String, _ arguments: [String: JSON]) -> String {
    request(id, "tools/call", ["name": .string(tool), "arguments": .object(arguments)])
}

/// Requests whose answers do not depend on anything but the store's content.
private let script: [String] = [
    request(1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "1"]]),
    request(2, "tools/list"),
    call(3, "troy_projects", [:]),
    call(4, "troy_search", ["query": "nothing", "all_projects": true]),
    call(5, "troy_read", ["ids": [1]]),
    call(6, "troy_projects", ["include_archived": true]),
]

@Suite struct UsageTests {
    @Test func oneRowPerToolCallWithItsSizes() throws {
        let folder = UsageFolder()
        let h = try Harness(store: Store(path: folder.database))
        let initialize = h.rpc("initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "1"]])
        let list = h.rpc("tools/list")
        let arguments: [String: JSON] = ["include_archived": true]
        let projects = h.call("troy_projects", arguments)
        let missing = h.call("troy_read", ["ids": [999]])
        let unknown = h.rpc("tools/call", ["name": "troy_nope", "arguments": [:]])
        #expect(unknown["error"] != nil)
        #expect(missing.isError)

        let logged = try rows(folder.log)
        // The unknown tool is a protocol error row, without its name.
        #expect(logged.map(\.event.event) == ["initialize", "tools/list", "troy_projects", "troy_read", "tools/call"])
        #expect(Set(logged.map(\.event.session)).count == 1)
        #expect(logged.filter { !($0.event.source == "mcp" && $0.event.client == "claude-code" && $0.event.agent == "claude-code/abc") }.isEmpty)

        let initText = try #require(initialize["result"]).text
        #expect(logged[0].event.responseChars == initText.count)
        #expect(logged[0].event.responseBytes == initText.utf8.count)
        #expect(logged[0].event.requestChars == 0)
        #expect(logged[1].event.responseChars == (try #require(list["result"])).text.count)

        let call = logged[2].event
        #expect(call.ok)
        #expect(call.requestChars == JSON.object(arguments).text.count)
        #expect(call.responseChars == projects.text.count)
        #expect(call.responseBytes == projects.text.utf8.count)
        #expect(call.micros > 0)

        let failed = logged[3].event
        #expect(!failed.ok)
        #expect(JSON.parse(failed.detail)?["error"]?.string == "tool")
        #expect(failed.responseChars == missing.text.count)
    }

    @Test func aCallThatReachesNoToolIsOneProtocolErrorRow() throws {
        let folder = UsageFolder()
        let h = try Harness(store: Store(path: folder.database))
        #expect(h.rpc("tools/call", ["name": "troy_nope_zq7", "arguments": [:]])["error"] != nil)
        #expect(h.rpc("tools/call", ["name": "troy_projects", "arguments": [1]])["error"] != nil)
        #expect(h.rpc("tools/call", ["arguments": [:]])["error"] != nil)
        let logged = try rows(folder.log)
        #expect(logged.map(\.event.event) == ["tools/call", "tools/call", "tools/call"])
        #expect(logged.filter { $0.event.ok || $0.event.detail != #"{"error":"protocol"}"# }.isEmpty)
        #expect(logged.filter { $0.event.requestChars != 0 || $0.event.responseChars != 0 }.isEmpty)
        for file in [folder.log, folder.log + "-wal"] where FileManager.default.fileExists(atPath: file) {
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)).range(of: Data("zq7".utf8)) == nil)
        }
    }

    @Test func statelessDiscoveryIsLoggedToo() throws {
        let folder = UsageFolder()
        let h = try Harness(store: Store(path: folder.database))
        let meta: JSON = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": ["name": "codex", "version": "1"],
        ]
        let discover = h.rpc("server/discover", ["_meta": meta])
        h.rpc("tools/list", ["_meta": meta])
        h.rpc("ping")
        let logged = try rows(folder.log)
        #expect(logged.map(\.event.event) == ["server/discover", "tools/list"])
        #expect(logged[0].event.client == "codex")
        #expect(logged[0].event.responseChars == (try #require(discover["result"])).text.count)
    }

    @Test func theHandshakeDoesNotCreateTheDatabase() throws {
        let folder = UsageFolder()
        let server = MCPServer(dbPath: folder.database, environment: [:], workingDirectory: "/nonexistent", tag: "abc")
        _ = drive(server, Array(script.prefix(2)))
        #expect(!FileManager.default.fileExists(atPath: folder.database))
        #expect(try rows(folder.log).map(\.event.event) == ["initialize", "tools/list"])
        _ = drive(server, [script[2]])
        #expect(FileManager.default.fileExists(atPath: folder.database))
        server.close()
        #expect(try rows(folder.log).count == 3)
    }

    @Test func offInTheEnvironmentWritesNothing() throws {
        let folder = UsageFolder()
        let server = MCPServer(dbPath: folder.database, environment: ["TROY_USAGE": "off"], workingDirectory: "/nonexistent", tag: "abc")
        _ = drive(server, script)
        server.close()
        #expect(!FileManager.default.fileExists(atPath: folder.log))
    }

    /// The same requests to a server without a log, for comparison.
    private func unloggedReplies() throws -> [String?] {
        let server = MCPServer(store: try Store(path: ":memory:"), environment: [:], workingDirectory: "/nonexistent", tag: "abc")
        return drive(server, script)
    }

    @Test func aBrokenLogChangesNoReplyAndCostsNoTime() throws {
        let folder = UsageFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("this is not a database, just some text that is long enough to be read".utf8).write(to: URL(fileURLWithPath: folder.log))
        let broken = UsageLog(path: folder.log, createFolder: true)
        let server = MCPServer(store: try Store(path: ":memory:"), environment: [:], workingDirectory: "/nonexistent", tag: "abc", usageLog: broken)
        var replies: [String?] = []
        let started = Date()
        replies = drive(server, script)
        let took = Date().timeIntervalSince(started)
        #expect(replies == (try unloggedReplies()))
        #expect(took < 0.3, "the calls took \(took) s")
        #expect(!broken.isOn)
        #expect(try String(contentsOfFile: folder.log, encoding: .utf8).hasPrefix("this is not a database"))
    }

    @Test func aLockedLogChangesNoReplyAndLosesNoRow() throws {
        let folder = UsageFolder()
        let log = UsageLog(path: folder.log, createFolder: true)
        log.record(UsageEvent(session: "x", host: "", agent: "", client: "", source: "mcp", event: "setup"))
        let holder = try Database(path: folder.log)
        try holder.execute("BEGIN IMMEDIATE")
        let server = MCPServer(store: try Store(path: ":memory:"), environment: [:], workingDirectory: "/nonexistent", tag: "abc", usageLog: log)
        let started = Date()
        let replies = drive(server, script)
        let took = Date().timeIntervalSince(started)
        #expect(replies == (try unloggedReplies()))
        #expect(took < 0.3, "the calls took \(took) s")
        #expect(log.isOn)
        try holder.execute("COMMIT")
        holder.close()
        server.close()
        #expect(try rows(folder.log).map(\.event.event) == ["setup", "initialize", "tools/list"] + ["troy_projects", "troy_search", "troy_read", "troy_projects"])
    }

    @Test func nothingTypedReachesTheLog() throws {
        let marker = "zq7Marker"
        let folder = UsageFolder(name: "troy-usage-\(marker)")
        let project = folder.path("repo-\(marker)")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        // A project-specific label that holds a folder path, and a client name that holds one too.
        let h = try Harness(store: Store(path: folder.database), environment: ["TROY_AGENT": project], workingDirectory: project)
        h.rpc("initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": .string("client \(project)"), "version": "1"]])
        // Records and claims keep the label as given; only the log is cleaned.
        #expect(h.server.agentLabel == project)
        #expect(!h.ok("troy_new_project", ["name": .string("name-\(marker)"), "summary": .string("summary \(marker)"), "path": .string(project)]).hasPrefix("UNEXPECTED"))
        let id = h.save(1, "task", "title \(marker)", [
            "body": .string("body \(marker)"), "tags": [.string("tag\(marker)")], "paths": [.string("src/\(marker).swift")],
        ])
        #expect(id > 0)
        h.ok("troy_update", ["id": .int(id), "append": .string("more \(marker)"), "status": "doing"])
        h.ok("troy_search", ["query": .string(marker)])
        h.ok("troy_read", ["ids": [.int(id)]])
        h.ok("troy_context", [:])
        _ = h.call("troy_link", ["from": .int(id), "to": .int(id), "relation": "relates_to", "note": .string("note \(marker)")])
        h.server.close()

        let logged = try rows(folder.log)
        #expect(logged.count >= 8)
        #expect(Set(logged.map(\.event.agent)) == ["other"])
        #expect(Set(logged.map(\.event.client)) == ["other"])
        for row in logged {
            let e = row.event
            for field in [e.session, e.host, e.agent, e.client, e.source, e.event, e.detail] {
                #expect(!field.contains(marker), "\(e.event) logged \(field)")
                #expect(!field.contains(folder.url.path), "\(e.event) logged \(field)")
            }
        }
        for file in [folder.log, folder.log + "-wal"] where FileManager.default.fileExists(atPath: file) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
            #expect(bytes.range(of: Data(marker.utf8)) == nil, "\(file) holds the marker")
        }
    }

    @Test func severalServerProcessesStartingOnANewLogAllWrite() throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/troy").path
        try #require(FileManager.default.isExecutableFile(atPath: binary), "build troy first: \(binary)")
        let folder = UsageFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TROY_") }
        environment["TROY_AGENT"] = "proc"
        let input = script.prefix(2).joined(separator: "\n") + "\n"
        let processes: [(Process, Pipe)] = try (0..<6).map { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--db", folder.database, "mcp"]
            process.environment = environment
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return (process, pipe)
        }
        for (_, pipe) in processes {
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        }
        for (process, _) in processes { process.waitUntilExit() }
        #expect(processes.map(\.0.terminationStatus) == Array(repeating: 0, count: 6))
        let logged = try rows(folder.log)
        #expect(logged.count == 12)
        #expect(Set(logged.map(\.event.session)).count == 6)
        let hosts = Set(logged.map(\.event.host))
        #expect(hosts.count == 1 && hosts.first?.isEmpty == false, "hosts: \(hosts)")
        #expect(!FileManager.default.fileExists(atPath: folder.database))
    }
}
