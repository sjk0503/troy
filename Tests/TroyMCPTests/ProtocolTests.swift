import Foundation
import Testing
import TroyCore
@testable import TroyMCP

@Suite struct ProtocolTests {
    let modernMeta: JSON = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
        "io.modelcontextprotocol/clientInfo": ["name": "Example Client", "version": "1"],
    ]

    @Test func handshakeEraEndToEnd() throws {
        let h = try Harness()
        let initialize = h.rpc("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.1"],
        ])
        #expect(initialize["jsonrpc"]?.string == "2.0")
        #expect(initialize["id"] == .int(1))
        let result = try #require(initialize["result"])
        #expect(result["protocolVersion"]?.string == "2025-06-18")
        #expect(result["serverInfo"]?["name"]?.string == "troy")
        #expect(result["serverInfo"]?["version"]?.string == MCPServer.version)
        #expect(result["instructions"]?.string == AgentGuide.instructions)
        #expect(result["capabilities"]?.object?.keys.sorted() == ["tools"])
        #expect(result["resultType"] == nil)

        #expect(h.raw(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = h.rpc("tools/list")
        let tools = try #require(list["result"]?["tools"]?.array)
        #expect(tools.map { $0["name"]?.string } == [
            "troy_context", "troy_save", "troy_update", "troy_link", "troy_search", "troy_read", "troy_projects", "troy_new_project",
        ])
        #expect(list["result"]?["ttlMs"] == nil)

        let call = h.call("troy_projects")
        #expect(!call.isError)
        #expect(call.text.contains("No projects yet"))
    }

    @Test func initializeAnswersLatestForUnknownVersions() throws {
        let h = try Harness()
        let reply = h.rpc("initialize", ["protocolVersion": "1999-01-01", "clientInfo": ["name": "x"]])
        #expect(reply["result"]?["protocolVersion"]?.string == "2025-11-25")
        for version in ["2025-11-25", "2025-03-26", "2024-11-05"] {
            #expect(h.rpc("initialize", ["protocolVersion": .string(version)])["result"]?["protocolVersion"]?.string == version)
        }
        // The stateless revision has no handshake; initialize answers a handshake-era version.
        #expect(h.rpc("initialize", ["protocolVersion": "2026-07-28"])["result"]?["protocolVersion"]?.string == "2025-11-25")
        #expect(h.rpc("initialize", [:])["error"]?["code"] == .int(-32602))
    }

    @Test func statelessEraEndToEnd() throws {
        let h = try Harness()
        let discover = h.rpc("server/discover", ["_meta": modernMeta])
        let result = try #require(discover["result"])
        #expect(result["resultType"]?.string == "complete")
        #expect(result["supportedVersions"]?.array?.first?.string == "2026-07-28")
        #expect(result["supportedVersions"]?.array?.contains(.string("2025-11-25")) == true)
        #expect(result["capabilities"]?.object?.keys.sorted() == ["tools"])
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.string == "troy")
        #expect(result["instructions"]?.string == AgentGuide.instructions)
        #expect(result["ttlMs"] != nil)
        #expect(result["cacheScope"]?.string == "public")

        let list = h.rpc("tools/list", ["_meta": modernMeta])
        #expect(list["result"]?["resultType"]?.string == "complete")
        #expect(list["result"]?["tools"]?.array?.count == 8)
        #expect(list["result"]?["ttlMs"] != nil)
        #expect(list["result"]?["cacheScope"]?.string == "public")

        let reply = h.rpc("tools/call", ["name": "troy_projects", "arguments": [:], "_meta": modernMeta])
        #expect(reply["result"]?["resultType"]?.string == "complete")
        #expect(reply["result"]?["isError"]?.bool == false)
        #expect(reply["result"]?["content"]?.at(0)?["text"]?.string?.contains("No projects yet") == true)
        // The client named itself in _meta, so writes carry its label.
        #expect(h.server.agentLabel == "example-client/abc")
    }

    @Test func unsupportedVersionListsWhatIsSupported() throws {
        let h = try Harness()
        let reply = h.rpc("tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2030-01-01"]])
        let error = try #require(reply["error"])
        #expect(error["code"] == .int(-32022))
        #expect(error["data"]?["requested"]?.string == "2030-01-01")
        #expect(error["data"]?["supported"]?.array?.first?.string == "2026-07-28")
        #expect(error["data"]?["supported"]?.array?.contains(.string("2025-11-25")) == true)
        let discover = h.rpc("server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]])
        #expect(discover["error"]?["code"] == .int(-32022))
    }

    @Test func protocolErrors() throws {
        let h = try Harness()
        let parse = try #require(h.raw("{not json"))
        #expect(parse["error"]?["code"] == .int(-32700))
        #expect(parse["id"] == .null)
        for line in ["42", "\"text\"", "true", "null"] {
            #expect(try #require(h.raw(line))["error"]?["code"] == .int(-32600))
        }
        #expect(try #require(h.raw("[]"))["error"]?["code"] == .int(-32600))
        #expect(try #require(h.raw(#"{"jsonrpc":"2.0","id":7}"#))["error"]?["code"] == .int(-32600))
        #expect(try #require(h.raw(#"{"jsonrpc":"2.0","id":7,"method":5}"#))["error"]?["code"] == .int(-32600))
        #expect(try #require(h.raw(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))["error"]?["code"] == .int(-32600))
        let unknown = h.rpc("no/such/method")
        #expect(unknown["error"]?["code"] == .int(-32601))
        #expect(unknown["id"] == .int(1))
        #expect(h.rpc("tools/call", ["name": "troy_nothing"])["error"]?["code"] == .int(-32602))
        #expect(h.rpc("tools/call", [:])["error"]?["code"] == .int(-32602))
        #expect(h.rpc("tools/call", ["name": "troy_projects", "arguments": [1, 2]])["error"]?["code"] == .int(-32602))
        #expect(try #require(h.raw(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":[1]}"#))["error"]?["code"] == .int(-32602))
    }

    @Test func silentInputProducesNoOutput() throws {
        let h = try Harness()
        #expect(h.raw("") == nil)
        #expect(h.raw("   \r") == nil)
        #expect(h.raw(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(h.raw(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(h.raw(#"{"jsonrpc":"2.0","method":"tools/list"}"#) == nil)
        #expect(h.raw(#"{"jsonrpc":"2.0","method":"unknown/notification"}"#) == nil)
        #expect(h.raw(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
    }

    @Test func batchesAreAnsweredPerElement() throws {
        let h = try Harness()
        let line = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"nope"}]"#
        let reply = try #require(h.raw(line)?.array)
        #expect(reply.count == 2)
        #expect(reply[0]["id"] == .int(1))
        #expect(reply[0]["result"] == [:])
        #expect(reply[1]["id"] == .string("b"))
        #expect(reply[1]["error"]?["code"] == .int(-32601))
        #expect(h.raw(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    }

    @Test func toleratedMethodsAnswerSensibly() throws {
        let h = try Harness()
        #expect(h.rpc("ping")["result"] == [:])
        #expect(h.rpc("logging/setLevel", ["level": "info"])["result"] == [:])
        #expect(h.rpc("resources/list")["result"]?["resources"] == [])
        #expect(h.rpc("resources/templates/list")["result"]?["resourceTemplates"] == [])
        #expect(h.rpc("prompts/list")["result"]?["prompts"] == [])
        let modern = h.rpc("prompts/list", ["_meta": modernMeta])
        #expect(modern["result"]?["resultType"]?.string == "complete")
        #expect(modern["result"]?["ttlMs"] != nil)
    }

    @Test func idsKeepTheirTypeAndRepliesAreOneLine() throws {
        let h = try Harness()
        let project = h.newProject("Multi\nline")
        h.save(project, "note", "Line one\nline two\u{2028}x", ["body": "a\nb\r\nc\td \"quoted\""])
        for id in ["abc", "7"] {
            let reply = try #require(h.server.handle(line: #"{"jsonrpc":"2.0","id":"# + (id == "7" ? "7" : "\"abc\"") + #","method":"ping"}"#))
            #expect(!reply.contains("\n"))
            #expect(JSON.parse(reply)?["id"] == (id == "7" ? .int(7) : .string("abc")))
        }
        let context = try #require(h.server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"troy_context","arguments":{"project":1}}}"#))
        #expect(!context.contains("\n"))
        #expect(!context.contains("\u{2028}"))
        #expect(JSON.parse(context)?["result"]?["content"]?.at(0)?["text"]?.string?.contains("Project #1") == true)
    }

    @Test func listingIsCompactAndHonest() throws {
        let h = try Harness()
        let result = try #require(h.rpc("tools/list")["result"])
        let size = result.text.count
        #expect(size < 7_000, "tools/list is \(size) characters")
        let tools = try #require(result["tools"]?.array)
        for tool in tools {
            let name = try #require(tool["name"]?.string)
            #expect(tool["title"]?.string?.isEmpty == false)
            #expect(tool["description"]?.string?.isEmpty == false)
            #expect(tool["outputSchema"] == nil)
            #expect(tool["inputSchema"]?["type"]?.string == "object")
            #expect(tool["inputSchema"]?["additionalProperties"] == .bool(false))
            let annotations = try #require(tool["annotations"])
            #expect(annotations["destructiveHint"] == .bool(false))
            #expect(annotations["openWorldHint"] == .bool(false))
            let readOnly = ["troy_context", "troy_search", "troy_read", "troy_projects"].contains(name)
            #expect(annotations["readOnlyHint"] == .bool(readOnly))
            let idempotent = readOnly || name == "troy_link"
            #expect(annotations["idempotentHint"] == .bool(idempotent))
            let alwaysLoad = ["troy_context", "troy_save", "troy_update"].contains(name)
            #expect(tool["_meta"]?["anthropic/alwaysLoad"] == (alwaysLoad ? .bool(true) : nil))
        }
        #expect(AgentGuide.instructions.count < 2_000)
        // Codex shows only this much of the instructions until the agent loads the tools, so the
        // rule itself (use it unasked, read at the start, save as you go) has to be in it.
        let lead = String(AgentGuide.instructions.prefix(AgentGuide.leadLength - 3))
        #expect(lead.contains("without being asked"))
        #expect(lead.contains("troy_context when you start work"))
        #expect(lead.contains("troy_save each decision, finding and finished piece of work"))
        #expect(AgentGuide.instructions.split(separator: "\n").first.map { $0.count <= AgentGuide.leadLength - 3 } == true)
    }

    @Test func noResultCarriesStructuredContent() throws {
        let h = try Harness()
        let project = h.newProject("Structured")
        let task = h.save(project, "task", "A task")
        let calls: [(String, [String: JSON])] = [
            ("troy_context", ["project": .int(project)]), ("troy_projects", [:]), ("troy_read", ["ids": [.int(task)]]),
            ("troy_search", ["query": "task"]), ("troy_update", ["id": .int(task), "status": "doing"]),
            ("troy_link", ["from": .int(task), "to": .int(task), "relation": "relates_to"]), ("troy_read", ["ids": [999]]),
        ]
        for (tool, arguments) in calls {
            let reply = h.rpc("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
            #expect(reply["result"]?["structuredContent"] == nil)
            #expect(reply.text.contains("structuredContent") == false)
        }
        #expect(h.rpc("tools/list")["result"]?.text.contains("structuredContent") == false)
    }

    @Test func databaseFailureIsAToolErrorNotAProtocolFailure() throws {
        let server = MCPServer(dbPath: "/dev/null/impossible/troy.db", environment: [:], workingDirectory: "/tmp", tag: "abc")
        func rpc(_ method: String, _ params: String = "{}") -> JSON {
            JSON.parse(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":\#(params)}"#) ?? "") ?? .null
        }
        #expect(rpc("server/discover")["result"]?["supportedVersions"] != nil)
        #expect(rpc("initialize", #"{"protocolVersion":"2025-11-25"}"#)["result"] != nil)
        #expect(rpc("tools/list")["result"]?["tools"]?.array?.count == 8)
        let call = rpc("tools/call", #"{"name":"troy_projects","arguments":{}}"#)
        #expect(call["result"]?["isError"] == .bool(true))
        #expect(call["result"]?["content"]?.at(0)?["text"]?.string?.contains("cannot open its database") == true)
        #expect(call["error"] == nil)
    }
}
