import Foundation
import TroyCore
@testable import TroyMCP

extension JSON {
    func at(_ index: Int) -> JSON? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }
}

/// One server over a store, driven line by line.
final class Harness {
    let server: MCPServer
    let store: Store
    private var nextID: Int64 = 1

    /// - Parameter home: The home folder the server measures from. Test folders live in the
    ///   temporary folder, which is outside the real one, so a test of plain work folders names
    ///   the folder its tree hangs in.
    init(
        store: Store? = nil, environment: [String: String] = [:], workingDirectory: String = "/nonexistent/folder",
        home: String? = nil, tag: String = "abc"
    ) throws {
        self.store = try store ?? Store(path: ":memory:")
        self.server = MCPServer(
            store: self.store, environment: environment, workingDirectory: workingDirectory, home: home, tag: tag)
    }

    /// Sends one request and returns the parsed reply.
    @discardableResult
    func rpc(_ method: String, _ params: JSON? = nil) -> JSON {
        var message: [String: JSON] = ["jsonrpc": "2.0", "id": .int(nextID), "method": .string(method)]
        if let params { message["params"] = params }
        nextID += 1
        let line = server.handle(line: JSON.object(message).text)
        return JSON.parse(line ?? "null") ?? .null
    }

    func raw(_ line: String) -> JSON? {
        server.handle(line: line).flatMap { JSON.parse($0) }
    }

    /// Calls a tool and returns its text and whether it was an error.
    func call(_ tool: String, _ arguments: [String: JSON] = [:]) -> (text: String, isError: Bool) {
        let reply = rpc("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        let result = reply["result"]
        let text = result?["content"]?.at(0)?["text"]?.string ?? "<no text: \(reply.text)>"
        return (text, result?["isError"]?.bool ?? true)
    }

    /// Calls a tool that must succeed.
    @discardableResult
    func ok(_ tool: String, _ arguments: [String: JSON] = [:]) -> String {
        let (text, isError) = call(tool, arguments)
        if isError { return "UNEXPECTED ERROR: " + text }
        return text
    }

    /// Creates a project directly in the store, linked to `path` when given.
    @discardableResult
    func newProject(_ name: String, path: String? = nil) -> Int64 {
        (try? store.createProject(name: name, paths: path.map { [$0] } ?? []).id) ?? -1
    }

    /// Saves a record and returns its id.
    @discardableResult
    func save(_ project: Int64, _ kind: String, _ title: String, _ extra: [String: JSON] = [:]) -> Int64 {
        var arguments: [String: JSON] = ["project": .int(project), "kind": .string(kind), "title": .string(title)]
        for (key, value) in extra { arguments[key] = value }
        let text = ok("troy_save", arguments)
        guard let range = text.range(of: #"#\d+"#, options: .regularExpression) else { return -1 }
        return Int64(text[range].dropFirst()) ?? -1
    }
}
