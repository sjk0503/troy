import Foundation
import TroyCore

/// How the server names the client in `assignee` and `source`: `claude-code/a3f`.
public enum AgentLabel {
    /// `clientName` lowercased, spaces turned into `-`, a trailing `-mcp-client` removed, then `/` and the tag.
    /// `override` (from `TROY_AGENT`) replaces everything. Without a client name the label is `agent/<tag>`.
    public static func make(clientName: String?, tag: String, override: String? = nil) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty { return override }
        var name = (clientName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.map { $0.isWhitespace ? "-" : $0 })
        name = String(name.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.".contains($0) ? $0 : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        if name.hasSuffix("-mcp-client") { name.removeLast("-mcp-client".count) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(name.isEmpty ? "agent" : name)/\(tag)"
    }

    /// Three random lowercase hex characters, chosen once per process.
    public static func randomTag() -> String { String(format: "%03x", Int.random(in: 0..<4096)) }
}

/// The MCP server as a pure function from one input line to zero or one output line.
/// The stdin/stdout loop (`serve`) is a thin shell around `handle(line:)`.
public final class MCPServer: @unchecked Sendable {
    public static let name = "troy"
    public static let version = "0.2.0"
    /// The stateless revision.
    public static let modernVersion = "2026-07-28"
    /// Handshake revisions, newest first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { [modernVersion] + legacyVersions }

    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let infoKey = "io.modelcontextprotocol/clientInfo"
    private static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    private let lock = NSLock()
    private var openedStore: Store?
    private let dbPath: String?
    private let environment: [String: String]
    private let workingDirectory: String
    private let home: String?
    private let tag: String
    private var clientName: String?
    /// Where this server notes what it was asked and what it cost; nil when off.
    private let usageLog: UsageLog?
    private let usageSession = UsageLog.newSessionID()
    private let usageHost: String

    /// The label this process writes with. Changes once when the client names itself.
    public private(set) var agentLabel: String

    /// - Parameters:
    ///   - store: An open store (tests). Otherwise one is opened on first use at `dbPath` or `Store.defaultPath()`.
    ///   - home: The home folder (tests). Otherwise the person's own.
    ///   - tag: The per-process suffix of the agent label; random when nil.
    ///   - usageLog: The usage log (tests). Otherwise the one next to the database, which is a file
    ///     of its own: the handshake writes to it without opening or creating the database.
    public init(
        store: Store? = nil, dbPath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String? = nil, home: String? = nil, tag: String? = nil, usageLog: UsageLog? = nil
    ) {
        self.openedStore = store
        self.dbPath = dbPath
        self.environment = environment
        self.workingDirectory = workingDirectory ?? ToolRuntime.currentDirectory()
        self.home = home
        self.tag = tag ?? AgentLabel.randomTag()
        self.agentLabel = AgentLabel.make(clientName: nil, tag: self.tag, override: environment["TROY_AGENT"])
        store?.agent = agentLabel
        self.usageLog = usageLog
            ?? UsageLog.forDatabase(at: store?.path ?? dbPath ?? Store.defaultPath(), environment: environment, createFolder: true)
        self.usageHost = self.usageLog == nil ? "" : UsageLog.hostProcess()
    }

    // MARK: Line in, line out

    /// Handles one line of input. Returns the line to write, or nil when nothing is to be written
    /// (blank lines, notifications, responses from the client).
    public func handle(line: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let message = JSON.parse(trimmed) else {
            return Self.failure(id: .null, code: -32700, message: "Parse error: the line is not valid JSON.").text
        }
        if case .array(let batch) = message {
            if batch.isEmpty { return Self.failure(id: .null, code: -32600, message: "Invalid request: empty batch.").text }
            let replies = batch.compactMap(process)
            return replies.isEmpty ? nil : JSON.array(replies).text
        }
        return process(message)?.text
    }

    /// Closes the store, if one was opened, and writes what the usage log still holds.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        openedStore?.close()
        openedStore = nil
        usageLog?.close()
    }

    /// Reads lines from stdin until it closes and writes the replies to stdout, one per line.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line: line) else { continue }
            do {
                try output.write(contentsOf: Data((reply + "\n").utf8))
            } catch {
                break
            }
        }
        close()
    }

    // MARK: Tracing

    /// With `TROY_TRACE=<file>`, appends one line per incoming message: the method, the tool name
    /// for a call, and the protocol version a stateless request carries. For finding out what a
    /// client actually sends; record contents are never written.
    private func trace(_ method: String, params: JSON?) {
        guard let path = environment["TROY_TRACE"], !path.isEmpty else { return }
        var line = ISO8601DateFormatter().string(from: Date()) + " " + method
        if method == "tools/call", let tool = params?.object?["name"]?.string { line += " " + tool }
        if let version = params?.object?["_meta"]?.object?[Self.versionKey]?.string { line += " [" + version + "]" }
        if method == "initialize", let version = params?.object?["protocolVersion"]?.string { line += " [" + version + "]" }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    // MARK: Messages

    private static func failure(id: JSON, code: Int64, message: String, data: JSON? = nil) -> JSON {
        var error: [String: JSON] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }

    private func process(_ message: JSON) -> JSON? {
        guard let object = message.object else {
            return Self.failure(id: .null, code: -32600, message: "Invalid request: a JSON-RPC message must be an object.")
        }
        guard let method = object["method"] else {
            // A response sent by the client: this server never sends requests, so there is nothing to match.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.failure(id: Self.validID(object["id"]) ?? .null, code: -32600, message: "Invalid request: no \"method\".")
        }
        let hasID = object["id"] != nil
        let id = Self.validID(object["id"])
        trace(method.string ?? "?", params: object["params"])
        guard let method = method.string else {
            return Self.failure(id: id ?? .null, code: -32600, message: "Invalid request: \"method\" must be a string.")
        }
        let params = object["params"]
        if !hasID {
            notify(method: method, params: params)
            return nil
        }
        guard let id else {
            return Self.failure(id: .null, code: -32600, message: "Invalid request: \"id\" must be a string or an integer.")
        }
        if let params, params.object == nil, !params.isNull {
            return Self.failure(id: id, code: -32602, message: "Invalid params: \"params\" must be an object.")
        }
        do {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try respond(method: method, params: params?.object ?? [:])
            if Self.handshakeMethods.contains(method) { logHandshake(method, result: result, started: started) }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return Self.failure(id: id, code: error.code, message: error.message, data: error.data)
        } catch {
            return Self.failure(id: id, code: -32603, message: "Internal error: \(error)")
        }
    }

    /// A request id is a string or an integer. `1.0` is accepted as `1`; a fraction, or a number too
    /// large to hold exactly, could not be echoed back unchanged and is refused.
    private static func validID(_ value: JSON?) -> JSON? {
        switch value {
        case .string?, .int?: return value
        case .double(let number)?: return Int64(exactly: number).map { .int($0) }
        default: return nil
        }
    }

    private struct RPCError: Error {
        var code: Int64
        var message: String
        var data: JSON?
    }

    private func notify(method: String, params: JSON?) {
        // notifications/initialized, notifications/cancelled and every other notification need no action:
        // requests run to completion before the next line is read.
        if method == "notifications/initialized" || method.hasPrefix("notifications/") { return }
    }

    // MARK: Requests

    private func respond(method: String, params: [String: JSON]) throws -> JSON {
        if method == "initialize" { return try initialize(params) }

        var modern = false
        let meta = params["_meta"]?.object
        if let requested = meta?[Self.versionKey] {
            guard let version = requested.string else {
                throw RPCError(code: -32602, message: "Invalid params: \"\(Self.versionKey)\" must be a string.")
            }
            if version == Self.modernVersion {
                modern = true
            } else if !Self.legacyVersions.contains(version) {
                throw RPCError(
                    code: -32022, message: "Unsupported protocol version",
                    data: ["supported": .array(Self.supportedVersions.map { .string($0) }), "requested": .string(version)])
            }
        }
        if modern, let name = meta?[Self.infoKey]?["name"]?.string { learn(clientName: name) }

        switch method {
        case "server/discover":
            return Self.finish([
                "supportedVersions": .array(Self.supportedVersions.map { .string($0) }),
                "capabilities": Self.capabilities,
                "instructions": .string(AgentGuide.instructions),
                "ttlMs": 3_600_000, "cacheScope": "public",
            ], modern: true)
        case "ping", "logging/setLevel":
            return Self.finish([:], modern: modern)
        case "tools/list":
            return Self.finish(["tools": Tools.listJSON].merging(Self.cacheable(modern)) { $1 }, modern: modern)
        case "tools/call":
            return Self.finish(try callTool(params), modern: modern)
        case "resources/list":
            return Self.finish(["resources": []].merging(Self.cacheable(modern)) { $1 }, modern: modern)
        case "resources/templates/list":
            return Self.finish(["resourceTemplates": []].merging(Self.cacheable(modern)) { $1 }, modern: modern)
        case "prompts/list":
            return Self.finish(["prompts": []].merging(Self.cacheable(modern)) { $1 }, modern: modern)
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private static let capabilities: JSON = ["tools": [:]]

    /// Freshness hints that the stateless revision requires on list results. The lists never change within a build.
    private static func cacheable(_ modern: Bool) -> [String: JSON] {
        modern ? ["ttlMs": 3_600_000, "cacheScope": "public"] : [:]
    }

    /// Adds `resultType` and the server identity to modern results. Handshake-era results stay as they were.
    private static func finish(_ result: [String: JSON], modern: Bool) -> JSON {
        guard modern else { return .object(result) }
        var result = result
        result["resultType"] = "complete"
        var meta = result["_meta"]?.object ?? [:]
        meta[serverInfoKey] = ["name": .string(name), "version": .string(version)]
        result["_meta"] = .object(meta)
        return .object(result)
    }

    private func initialize(_ params: [String: JSON]) throws -> JSON {
        guard let requested = params["protocolVersion"]?.string else {
            throw RPCError(code: -32602, message: "Invalid params: \"protocolVersion\" is required, for example \"2025-11-25\".")
        }
        if let name = params["clientInfo"]?["name"]?.string { learn(clientName: name) }
        let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": Self.capabilities,
            "serverInfo": ["name": .string(Self.name), "version": .string(Self.version)],
            "instructions": .string(AgentGuide.instructions),
        ]
    }

    private func learn(clientName name: String) {
        clientName = name
        agentLabel = AgentLabel.make(clientName: name, tag: tag, override: environment["TROY_AGENT"])
        openedStore?.agent = agentLabel
    }

    // MARK: Tools

    private func callTool(_ params: [String: JSON]) throws -> [String: JSON] {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let name = params["name"]?.string else {
            throw refused(RPCError(code: -32602, message: "Invalid params: \"name\" (the tool to call) is required."), started: started)
        }
        guard let tool = Tools.find(name) else {
            throw refused(
                RPCError(code: -32602, message: "Unknown tool \"\(name)\". Tools: \(Tools.all.map(\.name).joined(separator: ", "))."),
                started: started)
        }
        var arguments: [String: JSON] = [:]
        if let given = params["arguments"], !given.isNull {
            guard let object = given.object else {
                throw refused(RPCError(code: -32602, message: "Invalid params: \"arguments\" must be an object."), started: started)
            }
            arguments = object
        }
        let note = UsageNote()
        let text: String
        let isError: Bool
        do {
            let store = try openStore()
            let runtime = ToolRuntime(
                store: store, environment: environment, workingDirectory: workingDirectory, home: home, usage: note)
            text = try tool.run(runtime, Arguments(tool: name, arguments))
            isError = false
        } catch let error as ToolError {
            (text, isError) = (error.message, true)
            note.set("error", "tool")
        } catch let error as TroyError {
            (text, isError) = (error.message, true)
            note.set("error", .string(Self.usageName(error)))
        } catch {
            (text, isError) = ("\(name) failed: \(error)", true)
            note.set("error", "other")
        }
        let result = Self.toolResult(text, isError: isError)
        if let usageLog {
            let request = JSON.object(arguments).text
            usageLog.record(usageEvent(
                name, projectID: note.projectID, ok: !isError, request: request, response: text,
                started: started, detail: note.detail))
        }
        return result
    }

    // MARK: Usage log

    /// The methods every session pays for before its first tool call: the instructions and the tool definitions.
    private static let handshakeMethods: Set<String> = ["initialize", "server/discover", "tools/list"]

    private static func usageName(_ error: TroyError) -> String {
        switch error {
        case .notFound: "not_found"
        case .invalid: "invalid"
        case .conflict: "conflict"
        case .database: "database"
        }
    }

    /// Logs a `tools/call` that reached no tool and hands the error back to be thrown. The name the
    /// client sent is not logged: it is free text, and an unknown one is all this row is about.
    private func refused(_ error: RPCError, started: UInt64) -> RPCError {
        usageLog?.record(usageEvent(
            "tools/call", projectID: nil, ok: false, request: "", response: "", started: started, detail: #"{"error":"protocol"}"#))
        return error
    }

    private func logHandshake(_ method: String, result: JSON, started: UInt64) {
        guard let usageLog else { return }
        usageLog.record(usageEvent(method, projectID: nil, ok: true, request: "", response: result.text, started: started, detail: "{}"))
    }

    /// Sizes only: the texts themselves never reach the log.
    private func usageEvent(
        _ event: String, projectID: Int64?, ok: Bool, request: String, response: String, started: UInt64, detail: String
    ) -> UsageEvent {
        let micros = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000)
        return UsageEvent(
            session: usageSession, host: usageHost, agent: agentLabel, client: clientName ?? "", source: "mcp", event: event,
            projectID: projectID, ok: ok, requestChars: request.count, requestBytes: request.utf8.count,
            responseChars: response.count, responseBytes: response.utf8.count, micros: micros, detail: detail)
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: JSON] {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private func openStore() throws -> Store {
        if let openedStore {
            openedStore.agent = agentLabel
            return openedStore
        }
        let path = dbPath ?? Store.defaultPath()
        do {
            let store = try Store(path: path, agent: agentLabel)
            openedStore = store
            return store
        } catch {
            let reason = (error as? TroyError)?.message ?? "\(error)"
            FileHandle.standardError.write(Data("troy: cannot open \(path): \(reason)\n".utf8))
            throw ToolError("Troy cannot open its database (\(reason)). Check that the file is writable, or set TROY_DB to another file.")
        }
    }
}
