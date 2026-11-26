import Foundation
import Testing
import TroyCore
@testable import TroyMCP

/// One test per defect found in review of the server, each reproducing the reported input.
@Suite struct MCPReviewFindingsTests {
    // MARK: Numbers

    @Test func aWholeNumberTooLargeForAnIntegerDoesNotStopTheServer() throws {
        let h = try Harness()
        let project = h.newProject("Numbers")
        // 1e30 is a whole number as a double and far outside Int64.
        let reply = h.call("troy_save", ["project": .int(project), "kind": "note", "title": .double(1e30)])
        #expect(!reply.text.isEmpty)
        // The server is still answering.
        #expect(h.rpc("ping")["result"] != nil)
    }

    @Test func anIdThatCannotBeEchoedExactlyIsRefused() throws {
        let h = try Harness()
        let huge = try #require(h.raw(#"{"jsonrpc":"2.0","id":9223372036854775809,"method":"ping"}"#))
        #expect(huge["error"]?["code"] == .int(-32600))
        #expect(huge["id"]?.isNull == true)
        let fraction = try #require(h.raw(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#))
        #expect(fraction["error"]?["code"] == .int(-32600))
        // 7.0 is the integer 7 and comes back as 7.
        let whole = try #require(h.raw(#"{"jsonrpc":"2.0","id":7.0,"method":"ping"}"#))
        #expect(whole["id"] == .int(7))
        #expect(whole["result"] != nil)
    }

    // MARK: Writing to the right project

    @Test func aMissingIdNeverFallsBackToANameContainingTheDigits() throws {
        let h = try Harness()
        let release = h.newProject("release-42")
        for reference in [JSON.string("#42"), .string("42"), .int(42)] {
            let reply = h.call("troy_save", ["project": reference, "kind": "note", "title": "x"])
            #expect(reply.isError, "saved with project \(reference.text)")
            #expect(reply.text.contains("No project #42"))
            #expect(reply.text.contains("#\(release) release-42"))
        }
        #expect(try h.store.list(RecordQuery()).isEmpty)
    }

    @Test func savingNeedsTheIdOrTheExactName() throws {
        let h = try Harness()
        let project = h.newProject("release-42")
        let partial = h.call("troy_save", ["project": "release", "kind": "note", "title": "x"])
        #expect(partial.isError)
        #expect(partial.text.contains("No project is named \"release\""))
        #expect(partial.text.contains("#\(project) release-42"))
        #expect(try h.store.list(RecordQuery()).isEmpty)

        // Reading may use a partial name when it is unambiguous; writing may not.
        #expect(h.ok("troy_context", ["project": "release"]).hasPrefix("Project #\(project) \"release-42\""))
        #expect(h.ok("troy_save", ["project": "RELEASE-42", "kind": "note", "title": "x"]).hasPrefix("Saved #"))
    }

    @Test func theServersOwnConfigurationMayNameTheProject() throws {
        // TROY_PROJECT is set by the person in the client's server settings, so it counts as explicit.
        let store = try Store(path: ":memory:")
        let beta = try store.createProject(name: "Beta")
        let h = try Harness(store: store, environment: ["TROY_PROJECT": "Beta"])
        #expect(h.ok("troy_save", ["kind": "note", "title": "x"]).contains("in project #\(beta.id) Beta"))
        // And it is exact too.
        let loose = try Harness(store: store, environment: ["TROY_PROJECT": "Bet"])
        #expect(loose.call("troy_save", ["kind": "note", "title": "y"]).isError)
    }

    // MARK: What the agent reads

    @Test func aRepeatedSaveSaysWhichLinksItAdded() throws {
        let h = try Harness()
        let project = h.newProject("Again")
        let parent = h.save(project, "task", "Parent")
        let arguments: [String: JSON] = ["project": .int(project), "kind": "task", "title": "Child", "body": "same"]
        #expect(h.ok("troy_save", arguments).hasPrefix("Saved #"))
        var again = arguments
        again["parent"] = .int(parent)
        let reply = h.ok("troy_save", again)
        #expect(reply.hasPrefix("No second record was stored"))
        #expect(reply.contains("Linked: part of #\(parent)."))
        #expect(!reply.contains("Nothing new"))
    }

    @Test func readingKeepsTheIndentationOfTheFirstLine() throws {
        let h = try Harness()
        let project = h.newProject("Code")
        let body = "\n\n    let a = 1\n    let b = 2\n\n"
        let id = h.save(project, "note", "Indented code", ["body": .string(body)])
        let text = h.ok("troy_read", ["ids": [.int(id)]])
        #expect(text.contains("\n\n    let a = 1\n    let b = 2"))
        #expect(TroyText.trimmingBlankLines(body) == "    let a = 1\n    let b = 2")
        #expect(TroyText.trimmingBlankLines("  \n\t\n") == "")
    }
}

@Suite struct ClientSettingsFindingsTests {
    private func file(_ contents: String?) throws -> String {
        let folder = NSTemporaryDirectory() + "troy-clients-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/settings.json"
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    private func guide(_ path: String) -> MCPClientGuide {
        MCPClientGuide(
            id: "test", name: "Test Client", method: .jsonFile(path: path, key: "mcpServers"), removeArgv: nil,
            statusFile: path, statusKey: "mcpServers", appPath: nil, manual: "{}")
    }

    private func object(_ path: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    @Test func aServerListInAnUnknownShapeIsRefusedNotReplaced() throws {
        let original = #"{"mcpServers":[{"name":"other"}]}"#
        let path = try file(original)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        #expect(throws: MCPClients.Failure.self) { try MCPClients.connect(guide(path), binary: "/bin/troy") }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    @Test func reconnectingKeepsWhatTheEntryAlreadyCarries() throws {
        let path = try file(#"{"mcpServers":{"troy":{"command":"/old/troy","args":["mcp"],"env":{"TROY_DB":"/data/troy.db"}}}}"#)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try MCPClients.connect(guide(path), binary: "/new/troy")
        let servers = try #require(try object(path)["mcpServers"] as? [String: Any])
        let troy = try #require(servers["troy"] as? [String: Any])
        #expect(troy["command"] as? String == "/new/troy")
        #expect((troy["env"] as? [String: String])?["TROY_DB"] == "/data/troy.db")
    }

    @Test func disconnectingKeepsABackupAndTheOtherServers() throws {
        let original = #"{"mcpServers":{"other":{"command":"x"},"troy":{"command":"/bin/troy","args":["mcp"]}}}"#
        let path = try file(original)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try MCPClients.disconnect(guide(path))
        let servers = try #require(try object(path)["mcpServers"] as? [String: Any])
        #expect(servers["troy"] == nil)
        #expect(servers["other"] != nil)
        #expect(try String(contentsOfFile: path + ".troy-backup", encoding: .utf8) == original)
    }

    @Test func anEmptyFileIsTreatedAsNoSettings() throws {
        let path = try file("  \n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try MCPClients.connect(guide(path), binary: "/bin/troy")
        #expect(MCPClients.isConnected(guide(path)) == true)
        #expect(FileManager.default.fileExists(atPath: path + ".troy-backup"))
    }

    // MARK: A save by the client while Troy is editing

    private func folder(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    private func listing(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder(of: path)).sorted()
    }

    @Test func aSaveByTheClientDuringTheEditStaysAndTroyBacksOff() throws {
        let saved = #"{"mcpServers":{"other":{"command":"x"},"fresh":{"command":"y"}}}"#
        let path = try file(#"{"mcpServers":{"other":{"command":"x"}}}"#)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        try "earlier backup".write(toFile: path + ".troy-backup", atomically: true, encoding: .utf8)
        #expect(throws: MCPClients.Failure.self) {
            try MCPClients.edit(file: path, shown: path, guide: guide(path)) { root in
                // The client saves its settings after Troy has read them.
                try saved.write(toFile: path, atomically: true, encoding: .utf8)
                root["mcpServers"] = ["troy": ["command": "/bin/troy"]]
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
        // The backup of an earlier edit is not given up for an edit that did not happen.
        #expect(try String(contentsOfFile: path + ".troy-backup", encoding: .utf8) == "earlier backup")
        // A copy of the client's save stays. The client may have read Troy's version while it
        // was in place and may yet save on top of it, and then this is the only copy left.
        let kept = try listing(path).filter { $0 != "settings.json" && $0 != "settings.json.troy-backup" }
        #expect(kept.count == 1)
        if let name = kept.first {
            #expect(try String(contentsOfFile: folder(of: path) + "/" + name, encoding: .utf8) == saved)
        }
    }

    @Test func aFileThatAppearsDuringTheEditIsNotReplaced() throws {
        let saved = #"{"mcpServers":{"fresh":{"command":"y"}}}"#
        let path = try file(nil)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        #expect(throws: MCPClients.Failure.self) {
            try MCPClients.edit(file: path, shown: path, guide: guide(path)) { root in
                try saved.write(toFile: path, atomically: true, encoding: .utf8)
                root["mcpServers"] = ["troy": ["command": "/bin/troy"]]
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == saved)
        #expect(try listing(path) == ["settings.json"])
    }

    @Test func theReplacedFileBecomesTheBackupAndItsPermissionsCarryOver() throws {
        let original = #"{"mcpServers":{"other":{"command":"x","env":{"TOKEN":"secret"}}}}"#
        let path = try file(original)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let replaced = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        try MCPClients.connect(guide(path), binary: "/bin/troy")
        #expect(MCPClients.isConnected(guide(path)) == true)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        #expect(try String(contentsOfFile: path + ".troy-backup", encoding: .utf8) == original)
        // Not a copy: the very file that was exchanged out, which is what makes the check exact.
        #expect(try FileManager.default.attributesOfItem(atPath: path + ".troy-backup")[.systemFileNumber] as? Int == replaced)
        #expect(try listing(path) == ["settings.json", "settings.json.troy-backup"])
    }

    @Test func aNewSettingsFileLeavesNothingElseBehind() throws {
        let path = try file(nil)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        try MCPClients.connect(guide(path), binary: "/bin/troy")
        #expect(MCPClients.isConnected(guide(path)) == true)
        #expect(try listing(path) == ["settings.json"])
    }

    @Test func aLinkedSettingsFileStaysALink() throws {
        let path = try file(#"{"mcpServers":{}}"#)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        let link = folder(of: path) + "/linked.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        try MCPClients.connect(guide(link), binary: "/bin/troy")
        #expect(try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(MCPClients.isConnected(guide(path)) == true)
        #expect(MCPClients.isConnected(guide(link)) == true)
    }

    @Test func somethingAtThePathThatCannotBeReadIsLeftAlone() throws {
        let path = try file(nil)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        #expect(throws: MCPClients.Failure.self) { try MCPClients.connect(guide(path), binary: "/bin/troy") }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try listing(path) == ["settings.json"])
    }

    /// The sequence found in review. The client saves after Troy has read the file; Troy's
    /// version is exchanged in; before it is exchanged back, the client reads it and saves on
    /// top of it. The second save lacks what the first one added, so the first one is kept.
    @Test func aSecondSaveOnTopOfTroysVersionKeepsTheFirstOne() throws {
        let read = "{}"
        let first = #"{"mcpServers":{"x":{"command":"x"}}}"#
        let troys = #"{"mcpServers":{"troy":{"command":"/bin/troy"}}}"#
        let second = #"{"mcpServers":{"troy":{"command":"/bin/troy"},"y":{"command":"y"}}}"#
        let path = try file(first)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        var exchanges = 0
        var failure: MCPClients.Failure?
        do {
            try MCPClients.replace(path, with: Data(troys.utf8), expecting: Data(read.utf8), shown: path) {
                exchanges += 1
                if exchanges == 1 { try? second.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        } catch let error as MCPClients.Failure {
            failure = error
        }
        #expect(exchanges == 3)
        // The client's latest save is what is in place.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == second)
        let kept = try listing(path).filter { $0 != "settings.json" }
        let contents = try kept.map { try String(contentsOfFile: folder(of: path) + "/" + $0, encoding: .utf8) }
        #expect(contents == [first, second])
        for name in kept { #expect(failure?.description.contains(name) == true) }
    }

    /// One save more than the test above: after its first save came back in place, the client
    /// saves again from what it holds in memory. Its first save is then in neither the file nor
    /// the last thing exchanged out, and still must not be lost.
    @Test func everySaveTroyTookOutOfTheWayIsKept() throws {
        let first = #"{"mcpServers":{"x":{"command":"x"}}}"#
        let troys = #"{"mcpServers":{"troy":{"command":"/bin/troy"}}}"#
        let second = #"{"mcpServers":{"troy":{"command":"/bin/troy"},"y":{"command":"y"}}}"#
        let third = #"{"mcpServers":{"troy":{"command":"/bin/troy"},"y":{"command":"y"},"z":{"command":"z"}}}"#
        let path = try file(first)
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        var exchanges = 0
        var failure: MCPClients.Failure?
        do {
            try MCPClients.replace(path, with: Data(troys.utf8), expecting: Data("{}".utf8), shown: path) {
                exchanges += 1
                if exchanges == 1 { try? second.write(toFile: path, atomically: true, encoding: .utf8) }
                if exchanges == 2 { try? third.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        } catch let error as MCPClients.Failure {
            failure = error
        }
        #expect(exchanges == 4)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == third)
        let kept = try listing(path).filter { $0 != "settings.json" }
        let contents = try kept.map { try String(contentsOfFile: folder(of: path) + "/" + $0, encoding: .utf8) }
        #expect(contents == [first, second, third])
        for name in kept { #expect(failure?.description.contains(name) == true) }
    }

    /// The kept copies have names as long as the spare file's. With a settings file whose name
    /// is close to the limit of the volume, either everything fits or nothing is touched.
    @Test func aNameNearTheLimitOfTheVolumeLosesNothing() throws {
        let first = #"{"mcpServers":{"x":{"command":"x"}}}"#
        let second = #"{"mcpServers":{"y":{"command":"y"}}}"#
        let base = NSTemporaryDirectory() + "troy-clients-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // ".troy-12345678-0" adds 16 characters; names may be 255 long.
        for (length, fits) in [(239, true), (240, false)] {
            let name = String(repeating: "s", count: length)
            let path = base + "/" + name
            try first.write(toFile: path, atomically: true, encoding: .utf8)
            var exchanges = 0
            #expect(throws: MCPClients.Failure.self) {
                try MCPClients.replace(path, with: Data("{}".utf8), expecting: Data("read earlier".utf8), shown: "settings") {
                    exchanges += 1
                    if exchanges == 1 { try? second.write(toFile: path, atomically: true, encoding: .utf8) }
                }
            }
            let others = try FileManager.default.contentsOfDirectory(atPath: base).filter { $0 != name }.sorted()
            let contents = try others.map { try String(contentsOfFile: base + "/" + $0, encoding: .utf8) }
            if fits {
                #expect(exchanges == 3)
                #expect(try String(contentsOfFile: path, encoding: .utf8) == second)
                #expect(contents == [first, second])
            } else {
                // The spare file could not even be created, so no exchange was tried.
                #expect(exchanges == 0)
                #expect(try String(contentsOfFile: path, encoding: .utf8) == first)
                #expect(contents.isEmpty)
            }
            for other in others { try FileManager.default.removeItem(atPath: base + "/" + other) }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    /// The path taken on volumes that cannot exchange two files in one step.
    @Test func withoutAnExchangeTheFileIsComparedBeforeItIsReplaced() throws {
        let path = try file("old")
        defer { try? FileManager.default.removeItem(atPath: folder(of: path)) }
        let new = Data("new".utf8)
        #expect(throws: MCPClients.Failure.self) {
            try MCPClients.replaceByRename(path, with: new, expecting: Data("something else".utf8), shown: path)
        }
        #expect(throws: MCPClients.Failure.self) {
            try MCPClients.replaceByRename(path, with: new, expecting: nil, shown: path)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old")
        #expect(try listing(path) == ["settings.json"])
        try MCPClients.replaceByRename(path, with: new, expecting: Data("old".utf8), shown: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new")
        #expect(try String(contentsOfFile: path + ".troy-backup", encoding: .utf8) == "old")
    }
}
