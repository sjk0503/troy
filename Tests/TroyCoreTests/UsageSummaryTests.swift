import Foundation
import Testing
@testable import TroyCore

@Suite struct UsageSummaryTests {
    @Test func tokenEstimate() {
        #expect(UsageSummary.tokens(chars: 400, bytes: 400) == 100)
        // 30 Korean characters (90 bytes): about one token per 1.5 characters.
        #expect(UsageSummary.tokens(chars: 30, bytes: 90) == 20)
        #expect(UsageSummary.tokens(chars: 0, bytes: 0) == 0)
    }

    @Test func percentiles() {
        #expect(UsageSummary.percentile([], 0.5) == 0)
        #expect(UsageSummary.percentile([5], 0.95) == 5)
        #expect(UsageSummary.percentile(Array(1...100), 0.5) == 50)
        #expect(UsageSummary.percentile(Array(1...100), 0.95) == 95)
        #expect(UsageSummary.percentile([1, 2, 3, 4], 0.5) == 2)
    }

    @Test func numbersFromASeededLog() throws {
        let temp = TempDir()
        let path = temp.folder.appendingPathComponent("troy-usage.db").path
        let log = UsageLog(path: path, createFolder: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func row(
            _ event: String, session: String, host: String = "", client: String = "", source: String = "mcp",
            project: Int64? = nil, ok: Bool = true, request: Int = 0, response: Int = 0, micros: Int = 0,
            detail: String = "{}", ago days: Double = 0
        ) {
            log.record(UsageEvent(
                session: session, host: host, agent: "a", client: client, source: source, event: event, projectID: project, ok: ok,
                requestChars: request, requestBytes: request, responseChars: response, responseBytes: response,
                micros: micros, detail: detail), at: now - Int64(days * 86_400_000))
        }
        // Server A (claude-code, host 10@1) runs the hook and calls tools.
        row("context", session: "h1", host: "10@1", source: "hook", project: 1, response: 400, detail: #"{"state":"project"}"#)
        row("initialize", session: "A", host: "10@1", client: "claude-code", response: 2000)
        row("tools/list", session: "A", host: "10@1", client: "claude-code", response: 6000)
        row("troy_context", session: "A", host: "10@1", client: "claude-code", project: 1, request: 8, response: 800, micros: 1000,
            detail: #"{"state":"project","records":5,"doing":1,"advisories":0}"#)
        row("troy_save", session: "A", host: "10@1", client: "claude-code", project: 1, request: 120, response: 200, micros: 3000,
            detail: #"{"id":6,"kind":"task","advisories":["pathOverlap","conflict"],"similar":2,"deduplicated":false,"created_project":true}"#)
        row("troy_save", session: "A", host: "10@1", client: "claude-code", project: 1, request: 80, response: 100, micros: 2000,
            detail: #"{"id":6,"advisories":[],"similar":0,"deduplicated":true}"#)
        row("troy_update", session: "A", host: "10@1", client: "claude-code", project: 1, request: 40, response: 80, micros: 500,
            detail: #"{"id":6,"status":"doing","claim":"claimed","advisories":["pathOverlap"]}"#)
        // Server B (codex, host 20@1): no hook, a refused claim, a takeover, searches and a read.
        row("server/discover", session: "B", host: "20@1", client: "codex", response: 2000)
        row("troy_update", session: "B", host: "20@1", client: "codex", project: 1, ok: false, request: 30, response: 120,
            detail: #"{"id":6,"claim":"refused","error":"tool"}"#)
        row("troy_update", session: "B", host: "20@1", client: "codex", project: 1, request: 50, response: 90,
            detail: #"{"id":6,"claim":"takeover","advisories":[]}"#)
        row("troy_search", session: "B", host: "20@1", client: "codex", project: 2, request: 20, response: 300, detail: #"{"hits":3}"#)
        row("troy_search", session: "B", host: "20@1", client: "codex", project: 2, request: 20, response: 60, detail: #"{"hits":0}"#)
        row("troy_read", session: "B", host: "20@1", client: "codex", project: 1, request: 12, response: 900,
            detail: #"{"ids":[6,7],"found":2,"foreign":1}"#)
        // Server C started and never called a tool; a hook in a folder without a project.
        row("initialize", session: "C", host: "30@1", client: "claude-code", response: 2000)
        row("context", session: "h2", host: "40@1", source: "hook", response: 100, detail: #"{"state":"pending"}"#)
        // A failed search, a save that claims, a call that reached no tool.
        row("troy_search", session: "B", host: "20@1", client: "codex", project: 2, ok: false, request: 10, response: 50,
            detail: #"{"error":"tool"}"#)
        row("troy_save", session: "A", host: "10@1", client: "claude-code", project: 1, request: 30, response: 40,
            detail: #"{"id":8,"kind":"task","claim":"claimed","advisories":[]}"#)
        row("tools/call", session: "B", host: "20@1", client: "codex", ok: false, detail: #"{"error":"protocol"}"#)
        // A server that started before the period and called a tool inside it.
        row("initialize", session: "EARLY", host: "50@1", client: "codex", response: 2000, ago: 9)
        row("troy_context", session: "EARLY", host: "50@1", client: "codex", project: 1, request: 2, response: 100,
            detail: #"{"state":"pending"}"#)
        // Outside the period.
        row("troy_save", session: "OLD", client: "codex", project: 1, request: 999, response: 999, ago: 10)

        let since = Date(timeIntervalSinceNow: -7 * 86_400)
        let rows = try UsageLog.read(at: path, since: since)
        let s = UsageSummary(
            rows: rows, days: 7, since: since, until: Date(), logPath: path, projectNames: [1: "troy", 2: "other"],
            growth: GraphGrowth(recordsByKind: [.task: 2], links: 1, projects: 1),
            runningBefore: try UsageLog.sessionsRunningBefore(since, at: path))

        #expect(s.rows == 19)
        #expect(s.serverStarts == 3)
        #expect(s.startsByClient.map { "\($0.name) \($0.count)" } == ["claude-code 2", "codex 1"])
        #expect(s.startsWithToolCall == 2)
        #expect(s.runningFromBefore == 1)
        #expect(s.protocolErrors == 1)
        #expect(s.hookRuns == 2)
        #expect(s.hookByState.map(\.name).sorted() == ["pending", "project"])
        #expect(s.clientProcesses == 5)
        #expect(s.hookProcesses == 2)
        #expect(s.hookProcessesWithToolCall == 1)

        let save = try #require(s.tools.first { $0.name == "troy_save" })
        #expect(save.calls == 3)
        #expect(save.resultChars == 340)
        #expect(save.resultTokens == 85)
        #expect(save.medianMicros == 2000)
        #expect(save.p95Micros == 3000)
        let update = try #require(s.tools.first { $0.name == "troy_update" })
        #expect(update.calls == 3)
        #expect(update.errors == 1)
        #expect(s.toolCalls == 12)
        #expect(s.tools.first(where: { $0.name == "troy_search" })?.errors == 1)
        #expect(s.tools.map(\.name).prefix(3) == ["troy_save", "troy_search", "troy_update"])

        #expect(s.handshakeTokens == 3000)
        #expect(s.fixedTokensPerStart == 1000)
        #expect(s.hookTokens == 125)
        #expect(s.resultTokens == Double(800 + 200 + 100 + 80 + 120 + 90 + 300 + 60 + 900 + 50 + 40 + 100) / 4)
        #expect(s.argumentTokens == Double(8 + 120 + 80 + 40 + 30 + 50 + 20 + 20 + 12 + 10 + 30 + 2) / 4)

        #expect(s.claims == 3)
        #expect(s.takeovers == 1)
        #expect(s.refusedClaims == 1)
        #expect(s.saves == 3)
        #expect(s.savesWithAdvisories == 1)
        #expect(s.updatesWithAdvisories == 1)
        #expect(s.advisoryKinds.map { "\($0.name) \($0.count)" } == ["pathOverlap 2", "conflict 1"])
        #expect(s.savesWithSimilar == 1)
        #expect(s.duplicateSaves == 1)

        #expect(s.contextReads == 2)
        #expect(s.contextWithRecords == 1)
        #expect(s.contextPending == 1)
        // The failed search is among the tool's errors, not among searches without hits.
        #expect(s.searches == 2)
        #expect(s.searchesWithHits == 1)
        #expect(s.recordsRead == 2)
        #expect(s.foreignRecordsRead == 1)

        #expect(s.projectsCreatedOnSave == 1)
        #expect(s.busiest.map(\.name) == ["troy", "other"])
        #expect(s.busiest.first?.calls == 9)
        #expect(s.busiest.first?.saves == 3)

        #expect(s.series.count >= 7)
        #expect(s.series.reduce(0) { $0 + $1.serverStarts } == 3)
        #expect(s.series.reduce(0) { $0 + $1.toolCalls } == 12)
    }
}
