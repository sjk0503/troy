import Foundation
import Testing
import TroyCore
@testable import TroyMCP

@Suite struct TextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func agesFollowTheDocument() {
        func age(_ seconds: Double) -> String { TroyText.age(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(age(0) == "0m")
        #expect(age(59) == "0m")
        #expect(age(5 * 60) == "5m")
        #expect(age(59 * 60) == "59m")
        #expect(age(2 * 3600) == "2h")
        #expect(age(23 * 3600 + 3599) == "23h")
        #expect(age(3 * 86_400) == "3d")
        #expect(age(13 * 86_400) == "13d")
        #expect(age(14 * 86_400) == "2w")
        #expect(age(62 * 86_400) == "8w")
        #expect(age(70 * 86_400) == TroyText.date(now.addingTimeInterval(-70 * 86_400)))
        #expect(age(-100) == "0m")
        #expect(TroyText.date(now).count == 10)
    }

    func summary(
        _ status: RecordStatus, kind: RecordKind = .task, assignee: String? = nil, claimed: TimeInterval? = nil, superseded: Bool = false
    ) -> RecordSummary {
        RecordSummary(
            id: 1, projectID: 1, kind: kind, status: status, title: "T", assignee: assignee,
            claimedAt: claimed.map { now.addingTimeInterval(-$0) }, isSuperseded: superseded, createdAt: now, updatedAt: now)
    }

    @Test func taglines() {
        #expect(TroyText.tagline(summary(.open), now: now) == "[task/open]")
        #expect(TroyText.tagline(summary(.done, kind: .result), now: now) == "[result/done]")
        #expect(TroyText.tagline(summary(.doing, assignee: "codex/a1f", claimed: 2 * 3600), now: now) == "[task/doing by codex/a1f, 2h]")
        #expect(TroyText.tagline(summary(.doing, assignee: "codex/a1f", claimed: 30 * 3600), now: now) == "[task/doing by codex/a1f, 1d, stale]")
        #expect(TroyText.tagline(summary(.open, kind: .decision, superseded: true), now: now) == "[decision/open, superseded]")
        #expect(TroyText.tagline(summary(.doing), now: now) == "[task/doing]")
    }

    @Test func staleClaimsAreMarkedInContext() throws {
        let store = try Store(path: ":memory:", agent: "codex/a1f")
        let project = try store.createProject(name: "Stale")
        let record = try store.create(RecordDraft(projectID: project.id, kind: .task, title: "Old claim", status: .doing)).record
        let overview = try store.overview(projectID: project.id)
        let later = Date().addingTimeInterval(30 * 3600)
        let text = TroyText.context(overview, now: later)
        #expect(text.contains("#\(record.id) Old claim — codex/a1f, 1d, stale"))
    }

    @Test func projectsListing() {
        let project = Project(id: 3, name: "troy", summary: "", paths: ["/a", "/b"], status: .archived, createdAt: now, updatedAt: now)
        let stats = ProjectStats(records: 1, openTasks: 1, doing: 0, lastActivity: now.addingTimeInterval(-300))
        let text = TroyText.projects([ProjectSummary(project: project, stats: stats)], current: nil, now: now)
        #expect(text == "1 project:\n#3 troy [archived] — 1 record · 1 open · 0 in progress · 5m ago\n   folders: /a, /b")
        #expect(TroyText.projects([], current: nil).contains("troy_new_project"))
    }

    @Test func jsonWriterAndParser() throws {
        let value: JSON = ["text": "a\nb\u{2028}\"\\\u{1}é", "list": [1, true, .null, .double(1.5)], "n": 7]
        let line = value.text
        #expect(!line.contains("\n") && !line.contains("\u{2028}"))
        #expect(line == "{\"list\":[1,true,null,1.5],\"n\":7,\"text\":\"a\\nb\\u2028\\\"\\\\\\u0001é\"}")
        #expect(JSON.parse(line) == value)
        #expect(JSON.parse("true") == .bool(true))
        #expect(JSON.parse("1") == .int(1))
        #expect(JSON.parse("1.0") == .double(1))
        #expect(JSON.parse("{") == nil)
        #expect(JSON.parse(#"{"a":{"b":[{"c":"d"}]}}"#)?["a"]?["b"]?.at(0)?["c"]?.string == "d")
    }

    @Test func argumentIDLeniency() throws {
        #expect(Arguments.integer(from: .int(42)) == 42)
        #expect(Arguments.integer(from: .double(42)) == 42)
        #expect(Arguments.integer(from: .double(42.5)) == nil)
        #expect(Arguments.integer(from: .string("42")) == 42)
        #expect(Arguments.integer(from: .string(" #42 ")) == 42)
        #expect(Arguments.integer(from: .string("42.0")) == 42)
        #expect(Arguments.integer(from: .string("four")) == nil)
        #expect(Arguments.integer(from: .bool(true)) == nil)
        #expect(try Arguments.recordIDs(.string("#1, 2 3;3"), key: "ids", max: 20) == [1, 2, 3])
        #expect(throws: ToolError.self) { try Arguments.recordIDs(.int(0), key: "ids", max: 20) }
        #expect(try ToolRuntime.recordIDs(from: ["12,", "#13"]) == [12, 13])
    }
}

@Suite struct AgoTests {
    @Test func agesReadAsPhrases() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TroyText.ago(since: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(TroyText.ago(since: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
        #expect(TroyText.ago(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d ago")
        // Past nine weeks it is a date, which does not take "ago".
        let old = now.addingTimeInterval(-200 * 86_400)
        #expect(TroyText.ago(since: old, now: now) == "on \(TroyText.date(old))")
    }
}
