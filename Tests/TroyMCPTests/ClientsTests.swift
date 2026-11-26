import Foundation
import Testing
@testable import TroyMCP

@Suite struct ClientsTests {
    func temporaryFile(_ name: String = "settings.json", contents: String? = nil) throws -> String {
        let folder = NSTemporaryDirectory() + "troy-clients-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + name
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    func guide(path: String, key: String = "mcpServers") -> MCPClientGuide {
        MCPClientGuide(
            id: "test", name: "Test Client", method: .jsonFile(path: path, key: key), removeArgv: nil,
            statusFile: path, statusKey: key, appPath: nil, manual: "{}")
    }

    func read(_ path: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    @Test func connectMergesIntoAnExistingFile() throws {
        let path = try temporaryFile(contents: #"{"theme":"dark","mcpServers":{"other":{"command":"x","args":["y"]}}}"#)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let client = guide(path: path)
        #expect(MCPClients.isConnected(client) == false)
        let message = try MCPClients.connect(client, binary: "/Applications/Troy.app/Contents/Helpers/troy")
        #expect(message.contains("Restart Test Client"))
        let root = try read(path)
        #expect(root["theme"] as? String == "dark")
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        let troy = try #require(servers["troy"] as? [String: Any])
        #expect(troy["command"] as? String == "/Applications/Troy.app/Contents/Helpers/troy")
        #expect(troy["args"] as? [String] == ["mcp"])
        #expect(MCPClients.isConnected(client) == true)
        // The previous file is kept.
        let backup = try read(path + ".troy-backup")
        #expect((backup["mcpServers"] as? [String: Any])?["troy"] == nil)
        // Connecting again keeps one entry.
        try MCPClients.connect(client, binary: "/other/troy")
        let again = try #require((try read(path))["mcpServers"] as? [String: Any])
        #expect(again.count == 2)
        #expect((again["troy"] as? [String: Any])?["command"] as? String == "/other/troy")
    }

    @Test func connectCreatesMissingFileAndFolder() throws {
        let base = try temporaryFile()
        let path = (base as NSString).deletingLastPathComponent + "/nested/deeper/mcp.json"
        defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
        let client = guide(path: path, key: "servers")
        #expect(MCPClients.isConnected(client) == false)
        try MCPClients.connect(client, binary: "/usr/local/bin/troy")
        let servers = try #require((try read(path))["servers"] as? [String: Any])
        #expect(servers["troy"] != nil)
        #expect(MCPClients.isConnected(client) == true)
    }

    @Test func connectRefusesFilesItCannotParse() throws {
        let path = try temporaryFile(contents: "// comment\n{ \"mcpServers\": {} }")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let client = guide(path: path)
        #expect(MCPClients.isConnected(client) == nil)
        #expect(throws: MCPClients.Failure.self) { try MCPClients.connect(client, binary: "/x/troy") }
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("// comment"))
    }

    @Test func disconnectRemovesOnlyTroy() throws {
        let path = try temporaryFile(contents: #"{"mcpServers":{"other":{"command":"x"},"troy":{"command":"y","args":["mcp"]}}}"#)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let client = guide(path: path)
        #expect(MCPClients.isConnected(client) == true)
        let message = try MCPClients.disconnect(client)
        #expect(message.contains("removed"))
        let servers = try #require((try read(path))["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["other"])
        #expect(MCPClients.isConnected(client) == false)
        #expect(throws: MCPClients.Failure.self) { try MCPClients.disconnect(client) }
    }

    @Test func tomlClientsAreRecognisedByTheirSection() throws {
        let path = try temporaryFile("config.toml", contents: "model = \"x\"\n\n[mcp_servers.troy]\ncommand = \"/x/troy\"\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let client = MCPClientGuide(
            id: "codex", name: "Codex", method: .command(argv: ["codex"]), removeArgv: nil, statusFile: path, statusKey: nil,
            appPath: nil, manual: "")
        #expect(MCPClients.isConnected(client) == true)
        try "[mcp_servers.other]\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(MCPClients.isConnected(client) == false)
    }

    @Test func guidesPointAtTheBinary() {
        let guides = MCPClients.guides(binary: "/opt/my tools/troy")
        #expect(guides.map(\.id) == ["claude-code", "codex", "claude-desktop", "cursor", "vscode", "gemini"])
        for guide in guides {
            #expect(guide.manual.contains("troy") && guide.manual.contains("mcp"))
        }
        #expect(guides[0].manual.contains("'/opt/my tools/troy'"))
        #expect(AgentGuide.sessionStartHook(binary: "/x/troy").contains("/x/troy context --quiet"))
        #expect(JSON.parse(AgentGuide.sessionStartHook(binary: "/x/troy")) != nil)
    }

    /// Claude Code refuses a tool no rule allows in a session nobody watches, so connecting it
    /// says which rule to add. Only the person changes their permissions; Troy prints the line.
    @Test func claudeCodeSaysWhichPermissionRuleItStillNeeds() {
        let guides = MCPClients.guides(binary: "/x/troy")
        #expect(guides[0].followUp?.contains("\"permissions\": { \"allow\": [\"mcp__\(MCPClients.serverName)\"] }") == true)
        #expect(guides.dropFirst().allSatisfy { $0.followUp == nil })
    }
}
