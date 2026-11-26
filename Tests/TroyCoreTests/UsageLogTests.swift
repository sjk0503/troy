import Foundation
import Testing
@testable import TroyCore

/// A connection that holds the log's write lock, the way a person running `sqlite3` would.
final class LockHolder: @unchecked Sendable {
    let db: Database

    init(_ path: String) throws {
        db = try Database(path: path)
        try db.execute("PRAGMA busy_timeout = 2000")
        try db.execute("BEGIN IMMEDIATE")
    }

    func release() throws {
        try db.execute("COMMIT")
        db.close()
    }
}

func usageEvent(_ event: String, session: String = "s1", source: String = "mcp", detail: String = "{}") -> UsageEvent {
    UsageEvent(session: session, host: "1@2", agent: "tester/1", client: "test", source: source, event: event, detail: detail)
}

func allRows(_ path: String) throws -> [LoggedUsage] {
    try UsageLog.read(at: path, since: Date(timeIntervalSince1970: 0))
}

/// How long `body` took, in seconds.
func seconds(_ body: () throws -> Void) rethrows -> Double {
    let start = Date()
    try body()
    return Date().timeIntervalSince(start)
}

@Suite struct UsageLogTests {
    @Test func pathSitsNextToTheDatabase() {
        #expect(UsageLog.path(forDatabase: "/a/troy.db") == "/a/troy-usage.db")
        #expect(UsageLog.path(forDatabase: "/a/Other.DB") == "/a/Other-usage.db")
        #expect(UsageLog.path(forDatabase: "/a/data") == "/a/data-usage.db")
        #expect(UsageLog.forDatabase(at: ":memory:", environment: [:], createFolder: true) == nil)
    }

    @Test func recordsAndReadsBack() throws {
        let temp = TempDir()
        let log = try #require(UsageLog.forDatabase(at: temp.file, environment: [:], createFolder: true))
        var event = usageEvent("troy_save", detail: #"{"id":4}"#)
        event.projectID = 3
        event.ok = false
        event.requestChars = 10; event.requestBytes = 12; event.responseChars = 20; event.responseBytes = 30; event.micros = 1234
        log.record(event)
        log.record(usageEvent("tools/list"))
        let rows = try allRows(log.path)
        #expect(rows.map(\.event) == [event, usageEvent("tools/list")])
        #expect(abs(rows[0].date.timeIntervalSinceNow) < 60)
        // The file is the log's own, not a Troy database, and the database itself was not made.
        #expect(!FileManager.default.fileExists(atPath: temp.file))
        let db = try Database(path: log.path, create: false)
        #expect(try db.int("PRAGMA application_id") == Int64(UsageLog.applicationID))
        #expect(try db.int("PRAGMA user_version") == 1)
        #expect(try db.first("PRAGMA journal_mode") { $0.text() } == "wal")
        db.close()
    }

    @Test func offInTheEnvironment() {
        #expect(UsageLog.forDatabase(at: "/x/troy.db", environment: ["TROY_USAGE": "off"], createFolder: true) == nil)
        #expect(UsageLog.forDatabase(at: "/x/troy.db", environment: ["TROY_USAGE": "OFF"], createFolder: true) == nil)
        #expect(UsageLog.forDatabase(at: "/x/troy.db", environment: ["TROY_USAGE": "on"], createFolder: true) != nil)
    }

    @Test func withoutCreateFolderNothingIsCreated() throws {
        let temp = TempDir()
        let database = temp.folder.appendingPathComponent("deeper/troy.db").path
        let log = try #require(UsageLog.forDatabase(at: database, environment: [:], createFolder: false))
        UsageLog.forDatabase(at: database, environment: [:], createFolder: false)?.record(.hook(projectID: nil, state: "none", printed: "", micros: 5))
        log.record(usageEvent("context", source: "hook"))
        #expect(!log.isOn)
        #expect(!FileManager.default.fileExists(atPath: temp.folder.path))
    }

    @Test func aForeignFileIsLeftAlone() throws {
        let temp = TempDir()
        // A Troy database where the log should be.
        let store = try Store(path: temp.folder.appendingPathComponent("troy-usage.db").path)
        _ = try store.makeProject("kept")
        store.close()
        let log = UsageLog(path: temp.folder.appendingPathComponent("troy-usage.db").path, createFolder: true)
        log.record(usageEvent("initialize"))
        #expect(!log.isOn)
        let reopened = try Store(path: log.path)
        #expect(try reopened.projects().map(\.project.name) == ["kept"])
        #expect(try reopened.count("SELECT count(*) FROM sqlite_master WHERE name = 'usage'") == 0)
        reopened.close()
        #expect(thrown { _ = try allRows(log.path) }?.isDatabase == true)

        // Some other SQLite file without an application id.
        let other = temp.folder.appendingPathComponent("other.db").path
        let plain = try Database(path: other)
        try plain.execute("CREATE TABLE notes (x TEXT); INSERT INTO notes VALUES ('mine')")
        plain.close()
        let second = UsageLog(path: other, createFolder: true)
        second.record(usageEvent("initialize"))
        #expect(!second.isOn)
        let check = try Database(path: other, create: false)
        #expect(try check.int("SELECT count(*) FROM sqlite_master") == 1)
        check.close()
    }

    @Test func aNewerLogFormatIsLeftAlone() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let first = UsageLog(path: path, createFolder: true)
        first.record(usageEvent("initialize"))
        first.close()
        let db = try Database(path: path)
        try db.execute("PRAGMA user_version = 2")
        db.close()
        let log = UsageLog(path: path, createFolder: true)
        log.record(usageEvent("tools/list"))
        #expect(!log.isOn)
        #expect(thrown { _ = try allRows(path) }?.message.contains("newer version") == true)
    }

    @Test func oldRowsArePrunedWhenAServerOpensTheLog() throws {
        let temp = TempDir()
        let path = UsageLog.path(forDatabase: temp.file)
        let writer = UsageLog(path: path, createFolder: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        writer.record(usageEvent("old"), at: now - 91 * 86_400_000)
        writer.record(usageEvent("recent"), at: now - 89 * 86_400_000)
        writer.close()
        // The hook does not prune.
        UsageLog.forDatabase(at: temp.file, environment: [:], createFolder: false)?.record(usageEvent("context", source: "hook"))
        #expect(try allRows(path).map(\.event.event) == ["old", "recent", "context"])
        UsageLog.forDatabase(at: temp.file, environment: [:], createFolder: true)?.record(usageEvent("initialize"))
        #expect(try allRows(path).map(\.event.event) == ["recent", "context", "initialize"])
    }

    @Test func manyThreadsOpeningANewLogAllWrite() async throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let logs = (0..<8).map { _ in UsageLog(path: path, createFolder: true) }
        await withTaskGroup(of: Void.self) { group in
            for (index, log) in logs.enumerated() {
                group.addTask {
                    for row in 0..<25 { log.record(usageEvent("e\(row)", session: "t\(index)")) }
                }
            }
        }
        for log in logs { log.close() }
        #expect(logs.filter { !$0.isOn }.isEmpty)
        let rows = try allRows(path)
        #expect(rows.count == 200)
        for index in 0..<8 {
            #expect(rows.filter { $0.event.session == "t\(index)" }.map(\.event.event) == (0..<25).map { "e\($0)" })
        }
    }

    @Test func aLockedLogQueuesRowsAndWritesThemInOrderLater() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        log.record(usageEvent("first"))
        let holder = try LockHolder(path)
        let waited = seconds {
            for index in 1...5 { log.record(usageEvent("queued\(index)")) }
        }
        // A call never waits for the log: a few milliseconds each, then the row is queued.
        #expect(waited < 0.15, "five calls on a locked log took \(waited) s")
        #expect(log.isOn)
        #expect(log.queued == 5)
        try holder.release()
        log.record(usageEvent("after"))
        #expect(log.queued == 0)
        #expect(try allRows(path).map(\.event.event) == ["first", "queued1", "queued2", "queued3", "queued4", "queued5", "after"])
    }

    @Test func aFullQueueDropsTheOldestAndSaysHowMany() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        log.queueLimit = 3
        log.record(usageEvent("first"))
        let holder = try LockHolder(path)
        for index in 1...6 { log.record(usageEvent("q\(index)", detail: #"{"id":\#(index)}"#)) }
        #expect(log.queued == 3)
        try holder.release()
        log.record(usageEvent("after"))
        let rows = try allRows(path)
        // The newest row counts against the limit too, so "after" pushed q4 out as well;
        // the first row that got through says how many went.
        #expect(rows.map(\.event.event) == ["first", "q5", "q6", "after"])
        #expect(rows[1].event.detail == #"{"dropped":4,"id":5}"#)
        #expect(rows[2].event.detail == #"{"id":6}"#)
    }

    @Test func onlyLabelsReachTheAgentAndClientColumns() throws {
        #expect(UsageLog.label("claude-code/a3f") == "claude-code/a3f")
        #expect(UsageLog.label("Claude Code") == "Claude Code")
        #expect(UsageLog.label("codex_cli.v2") == "codex_cli.v2")
        #expect(UsageLog.label("클로드/1") == "클로드/1")
        #expect(UsageLog.label("") == "")
        #expect(UsageLog.label("/Users/me/dev/secret") == "other")
        #expect(UsageLog.label("a/b/c") == "other")
        #expect(UsageLog.label("name/") == "other")
        #expect(UsageLog.label("/tag") == "other")
        #expect(UsageLog.label("x:y") == "other")
        #expect(UsageLog.label("~/dev") == "other")
        #expect(UsageLog.label(String(repeating: "a", count: 65)) == "other")
        #expect(UsageLog.label(String(repeating: "a", count: 64)) == String(repeating: "a", count: 64))

        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        log.record(UsageEvent(session: "s", host: "", agent: "/Users/me/dev/secret", client: "C:\\dev", source: "mcp", event: "x"))
        let row = try #require(try allRows(path).first)
        #expect(row.event.agent == "other")
        #expect(row.event.client == "other")
    }

    @Test func sessionsRunningBeforeThePeriod() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        log.record(usageEvent("initialize", session: "early"), at: now - 9 * 86_400_000)
        log.record(usageEvent("troy_save", session: "early"), at: now - 1000)
        log.record(usageEvent("initialize", session: "gone"), at: now - 9 * 86_400_000)
        log.record(usageEvent("initialize", session: "new"), at: now - 1000)
        #expect(try UsageLog.sessionsRunningBefore(Date(timeIntervalSinceNow: -7 * 86_400), at: path) == ["early"])
    }

    @Test func droppedIsAddedToAnEmptyDetail() {
        #expect(UsageLog.adding(dropped: 2, to: "{}") == #"{"dropped":2}"#)
        #expect(UsageLog.adding(dropped: 2, to: #"{"a":1}"#) == #"{"dropped":2,"a":1}"#)
        #expect(UsageLog.adding(dropped: 2, to: "junk") == #"{"dropped":2}"#)
    }

    @Test func closeWritesWhatIsQueued() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        log.record(usageEvent("first"))
        let holder = try LockHolder(path)
        log.record(usageEvent("queued"))
        #expect(log.queued == 1)
        // Nothing else is recorded after the lock goes: only close can write the queued row.
        try holder.release()
        #expect(log.queued == 1)
        log.close()
        #expect(log.queued == 0)
        #expect(try allRows(path).map(\.event.event) == ["first", "queued"])
    }

    @Test func closeOnAStillLockedLogGivesUpWithinASecond() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        log.record(usageEvent("first"))
        let holder = try LockHolder(path)
        log.record(usageEvent("lost"))
        let waited = seconds { log.close() }
        #expect(waited < 1.6, "close took \(waited) s")
        try holder.release()
        #expect(try allRows(path).map(\.event.event) == ["first"])
    }

    @Test func aHookRunWritesWhenFreeAndGivesUpQuietlyWhenLocked() throws {
        let temp = TempDir()
        try FileManager.default.createDirectory(at: temp.folder, withIntermediateDirectories: true)
        let hook = UsageEvent.hook(projectID: 7, state: "project", printed: "Project #7 \"x\"\n", micros: 900)
        // What the hook does: one row, then close, which is where a one-shot process may wait.
        func runHook() {
            let log = UsageLog.forDatabase(at: temp.file, environment: [:], createFolder: false)
            log?.record(hook)
            log?.close()
        }
        runHook()
        let path = UsageLog.path(forDatabase: temp.file)
        let rows = try allRows(path)
        #expect(rows.count == 1)
        #expect(rows[0].event.source == "hook")
        #expect(rows[0].event.detail == #"{"state":"project"}"#)
        #expect(rows[0].event.projectID == 7)

        let holder = try LockHolder(path)
        let waited = seconds { runHook() }
        #expect(waited < 1.6, "a hook on a locked log took \(waited) s")
        try holder.release()
        #expect(try allRows(path).count == 1)
    }

    @Test func readingNeverCreatesTheLog() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        #expect(thrown { _ = try UsageLog.read(at: path, since: Date()) }?.isNotFound == true)
        #expect(!FileManager.default.fileExists(atPath: temp.folder.path))
    }

    // MARK: Host process

    @Test func hostSkipsShellsAndStopsAtLaunchd() {
        let table: [Int32: UsageLog.ProcessFacts] = [
            50: .init(parent: 40, name: "zsh", startSeconds: 5),
            40: .init(parent: 30, name: "-bash", startSeconds: 4),
            30: .init(parent: 20, name: "env", startSeconds: 3),
            20: .init(parent: 1, name: "node", startSeconds: 2),
            60: .init(parent: 1, name: "sh", startSeconds: 6),
        ]
        #expect(UsageLog.host(startingAt: 50) { table[$0] } == "20@2")
        #expect(UsageLog.host(startingAt: 20) { table[$0] } == "20@2")
        #expect(UsageLog.host(startingAt: 60) { table[$0] } == "")
        #expect(UsageLog.host(startingAt: 99) { table[$0] } == "")
        #expect(UsageLog.host(startingAt: 1) { table[$0] } == "")
    }

    @Test func hostOfThisProcessIsAnAncestorThatIsNotAShell() throws {
        let host = UsageLog.hostProcess()
        let parts = host.split(separator: "@")
        try #require(parts.count == 2, "host is \"\(host)\"")
        let pid = try #require(Int32(parts[0]))
        let facts = try #require(UsageLog.processFacts(pid))
        #expect(!UsageLog.isLauncher(facts.name))
        #expect(String(facts.startSeconds) == parts[1])
        // It is an ancestor of this process.
        var current = getppid()
        var found = false
        for _ in 0..<32 where current > 1 {
            if current == pid { found = true; break }
            guard let up = UsageLog.processFacts(current) else { break }
            current = up.parent
        }
        #expect(found)
        #expect(UsageLog.hostProcess() == host)
    }

    // MARK: Growth

    @Test func growthCountsWhatWasCreatedInThePeriod() throws {
        let temp = TempDir()
        let store = try temp.store()
        let project = try store.makeProject("p")
        let a = try store.add(project, "a")
        let b = try store.add(project, "b", kind: .decision)
        _ = try store.link(from: a.id, to: b.id, relation: .relatesTo)
        try store.sql("UPDATE records SET created_at = 1000 WHERE id = \(a.id)")
        let growth = try store.growth(since: Date(timeIntervalSinceNow: -3600))
        #expect(growth.recordsByKind == [.decision: 1])
        #expect(growth.links == 1)
        #expect(growth.projects == 1)
        #expect(try store.growth(since: Date(timeIntervalSinceNow: 3600)) == GraphGrowth())
    }
}
