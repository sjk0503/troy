import Foundation
import TroyCore
import TroyMCP

/// `troy stats`: what the usage log says about how Troy was used.
enum StatsCommand {
    static let command = Command(
        name: "stats", synopsis: "[--days N] [--json]",
        summary: "Summarize how agents used Troy and what it cost, from the usage log on this Mac.",
        flags: ["json"], options: ["days"]
    ) { parsed, console, context in
        let days = try parsed.int("days") ?? 7
        guard (1...UsageLog.keepDays).contains(days) else {
            throw UsageError(message: "--days must be between 1 and \(UsageLog.keepDays) (the log keeps \(UsageLog.keepDays) days), got \(days).")
        }
        let database = URL(fileURLWithPath: ((context.db ?? Store.defaultPath()) as NSString).expandingTildeInPath).standardizedFileURL.path
        let logPath = UsageLog.path(forDatabase: database)
        // Looking must leave nothing behind: neither the log nor the database is created here.
        guard UsageLog.exists(at: logPath) else {
            if parsed.flags.contains("json") {
                console.out(JSON.object(["log": .string(logPath), "exists": false, "days": .int(Int64(days))]).text)
            } else {
                console.out("No usage log yet at \(logPath).\nTroy starts one the first time an AI client starts its MCP server (TROY_USAGE=off turns it off).")
            }
            return 0
        }
        let until = Date()
        let since = until.addingTimeInterval(-Double(days) * 86_400)
        let rows = try UsageLog.read(at: logPath, since: since)
        let runningBefore = try UsageLog.sessionsRunningBefore(since, at: logPath)

        var names: [Int64: String] = [:]
        var growth: GraphGrowth?
        if FileManager.default.fileExists(atPath: database), let store = try? Store(path: database, agent: "troy-cli") {
            defer { store.close() }
            for summary in (try? store.projects(includeArchived: true)) ?? [] { names[summary.project.id] = summary.project.name }
            growth = try? store.growth(since: since)
        }
        let summary = UsageSummary(
            rows: rows, days: days, since: since, until: until, logPath: logPath, projectNames: names, growth: growth, runningBefore: runningBefore)
        console.out(parsed.flags.contains("json") ? json(summary).text : text(summary))
        return 0
    }

    // MARK: Text

    static func text(_ s: UsageSummary) -> String {
        var lines: [String] = []
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("Troy usage, last \(s.days) day\(s.days == 1 ? "" : "s") (\(format.string(from: s.since)) to \(format.string(from: s.until)))")
        lines.append("Log: \(s.logPath) (\(n(s.rows)) row\(s.rows == 1 ? "" : "s") in the period)")
        if s.rows == 0 {
            lines.append("")
            lines.append("Nothing was logged in this period.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("SESSIONS")
        var starts = "Server starts: \(n(s.serverStarts))"
        if !s.startsByClient.isEmpty { starts += " (" + s.startsByClient.map { "\($0.name) \(n($0.count))" }.joined(separator: ", ") + ")" }
        lines.append(starts + ", \(n(s.startsWithToolCall)) made at least one tool call")
        if s.runningFromBefore > 0 {
            lines.append("Servers started before the period that made calls in it: \(n(s.runningFromBefore))")
        }
        if s.hookRuns > 0 {
            lines.append("Session-start hook runs: \(n(s.hookRuns)) (" + s.hookByState.map { "\($0.name) \(n($0.count))" }.joined(separator: ", ") + ")")
        }
        if s.clientProcesses > 0 {
            var line = "Client processes seen: \(n(s.clientProcesses))"
            if s.hookProcesses > 0 {
                line += "; of the \(n(s.hookProcesses)) that ran the hook, \(n(s.hookProcessesWithToolCall)) also made a tool call"
            }
            lines.append(line)
            if s.hookProcesses > 0 {
                lines.append("  (matched by process: only when the client starts the hook and the server directly, as `troy guide --hook` sets it up; a wrapped hook is not matched)")
            }
        }

        lines.append("")
        lines.append("TOOLS (text returned in estimated tokens)")
        if s.tools.isEmpty {
            lines.append("No tool calls.")
        } else {
            let width = max(4, s.tools.map(\.name.count).max() ?? 4)
            lines.append("  " + "tool".padding(toLength: width, withPad: " ", startingAt: 0)
                + "  calls  errors     chars   ~tokens   median      p95")
            for tool in s.tools {
                lines.append("  " + tool.name.padding(toLength: width, withPad: " ", startingAt: 0)
                    + pad(n(tool.calls), 7) + pad(n(tool.errors), 8) + pad(n(tool.resultChars), 10)
                    + pad(n(Int(tool.resultTokens.rounded())), 10) + pad(ms(tool.medianMicros), 9) + pad(ms(tool.p95Micros), 9))
            }
        }

        if s.protocolErrors > 0 {
            lines.append("Protocol errors (tools/call that reached no tool: unknown name or bad arguments): \(n(s.protocolErrors))")
        }

        lines.append("")
        lines.append("CONTEXT COST (estimated tokens, from text size; exact numbers are in each client's own session logs)")
        lines.append("Instructions and tool definitions: ~\(t(s.handshakeTokens)) (~\(t(s.fixedTokensPerStart)) per server start)")
        if s.hookRuns > 0 { lines.append("Session-start hook output: ~\(t(s.hookTokens))") }
        lines.append("Tool results: ~\(t(s.resultTokens))")
        lines.append("Tool arguments: ~\(t(s.argumentTokens))")
        lines.append("Total: ~\(t(s.totalTokens))")

        let coordination = s.claims + s.refusedClaims + s.savesWithAdvisories + s.updatesWithAdvisories + s.savesWithSimilar + s.duplicateSaves
        lines.append("")
        lines.append("COORDINATION")
        if coordination == 0 {
            lines.append("No claims, advisories, similar records or duplicates.")
        } else {
            lines.append("Claims: \(n(s.claims)) (\(n(s.takeovers)) takeover\(s.takeovers == 1 ? "" : "s")), refused claims: \(n(s.refusedClaims))")
            var advisories = "Advisories: \(n(s.savesWithAdvisories)) of \(n(s.saves)) saves, \(n(s.updatesWithAdvisories)) of \(n(s.updates)) updates"
            if !s.advisoryKinds.isEmpty { advisories += " (" + s.advisoryKinds.map { "\($0.name) \(n($0.count))" }.joined(separator: ", ") + ")" }
            lines.append(advisories)
            lines.append("Saves that showed similar records: \(n(s.savesWithSimilar)); saves returned as duplicates: \(n(s.duplicateSaves))")
        }

        lines.append("")
        lines.append("MEMORY")
        lines.append("Context reads: \(n(s.contextReads)), \(n(s.contextWithRecords)) found a project with records, \(n(s.contextPending)) found a folder without a project")
        lines.append("Searches that ran: \(n(s.searches)), \(n(s.searchesWithHits)) with hits, \(n(s.searches - s.searchesWithHits)) without")
        lines.append("Records read: \(n(s.recordsRead)), \(n(s.foreignRecordsRead)) last written by another agent")

        lines.append("")
        lines.append("PROJECTS")
        lines.append("Created on first save: \(n(s.projectsCreatedOnSave)); with troy_new_project: \(n(s.projectsCreatedByTool))")
        if !s.busiest.isEmpty {
            lines.append("Busiest:")
            for busy in s.busiest {
                let name = busy.name.isEmpty ? "#\(busy.projectID)" : "#\(busy.projectID) \(busy.name)"
                lines.append("  \(name): \(n(busy.calls)) call\(busy.calls == 1 ? "" : "s"), \(n(busy.saves)) save\(busy.saves == 1 ? "" : "s"), ~\(t(busy.tokens)) tokens")
            }
        }

        lines.append("")
        lines.append("GRAPH GROWTH (from the database)")
        if let growth = s.growth {
            var records = "Records created: \(n(growth.records))"
            let kinds = RecordKind.allCases.compactMap { kind in growth.recordsByKind[kind].map { "\(kind.rawValue) \(n($0))" } }
            if !kinds.isEmpty { records += " (" + kinds.joined(separator: ", ") + ")" }
            lines.append(records)
            lines.append("Links created: \(n(growth.links)); projects created: \(n(growth.projects))")
        } else {
            lines.append("The database is not there or cannot be read.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: JSON

    static func json(_ s: UsageSummary) -> JSON {
        func i(_ value: Int) -> JSON { .int(Int64(value)) }
        func r(_ value: Double) -> JSON { .int(Int64(value.rounded())) }
        func counts(_ list: [UsageSummary.Count]) -> JSON { .object(Dictionary(list.map { ($0.name, i($0.count)) }, uniquingKeysWith: { first, _ in first })) }
        let iso = ISO8601DateFormatter()
        var growth: JSON = .null
        if let g = s.growth {
            growth = [
                "records": i(g.records),
                "records_by_kind": .object(Dictionary(g.recordsByKind.map { ($0.key.rawValue, i($0.value)) }, uniquingKeysWith: { first, _ in first })),
                "links": i(g.links), "projects": i(g.projects),
            ]
        }
        return [
            "log": .string(s.logPath), "exists": true, "days": i(s.days),
            "since": .string(iso.string(from: s.since)), "until": .string(iso.string(from: s.until)), "rows": i(s.rows),
            "tokens_note": "Estimated from text size (ascii/4 + non-ASCII/1.5); exact numbers are in each client's own session logs.",
            "sessions": [
                "server_starts": i(s.serverStarts), "by_client": counts(s.startsByClient),
                "with_tool_call": i(s.startsWithToolCall), "running_from_before": i(s.runningFromBefore),
                "hook_runs": i(s.hookRuns), "hook_by_state": counts(s.hookByState),
                "client_processes": i(s.clientProcesses), "hook_processes": i(s.hookProcesses),
                "hook_processes_with_tool_call": i(s.hookProcessesWithToolCall),
            ],
            "tools": .array(s.tools.map { tool in
                [
                    "name": .string(tool.name), "calls": i(tool.calls), "errors": i(tool.errors),
                    "result_chars": i(tool.resultChars), "result_tokens": r(tool.resultTokens),
                    "argument_tokens": r(tool.argumentTokens),
                    "median_micros": i(tool.medianMicros), "p95_micros": i(tool.p95Micros),
                ]
            }),
            "protocol_errors": i(s.protocolErrors),
            "tokens": [
                "instructions_and_tools": r(s.handshakeTokens), "hook": r(s.hookTokens),
                "tool_results": r(s.resultTokens), "tool_arguments": r(s.argumentTokens),
                "total": r(s.totalTokens), "fixed_per_server_start": r(s.fixedTokensPerStart),
            ],
            "coordination": [
                "claims": i(s.claims), "refused_claims": i(s.refusedClaims), "takeovers": i(s.takeovers),
                "saves": i(s.saves), "updates": i(s.updates),
                "saves_with_advisories": i(s.savesWithAdvisories), "updates_with_advisories": i(s.updatesWithAdvisories),
                "advisories_by_kind": counts(s.advisoryKinds),
                "saves_with_similar": i(s.savesWithSimilar), "duplicate_saves": i(s.duplicateSaves),
            ],
            "memory": [
                "context_reads": i(s.contextReads), "context_with_records": i(s.contextWithRecords),
                "context_pending": i(s.contextPending),
                "searches": i(s.searches), "searches_with_hits": i(s.searchesWithHits),
                "searches_without_hits": i(s.searches - s.searchesWithHits),
                "records_read": i(s.recordsRead), "records_read_foreign": i(s.foreignRecordsRead),
            ],
            "projects": [
                "created_on_save": i(s.projectsCreatedOnSave), "created_with_tool": i(s.projectsCreatedByTool),
                "busiest": .array(s.busiest.map { busy in
                    ["id": .int(busy.projectID), "name": .string(busy.name), "calls": i(busy.calls), "saves": i(busy.saves), "tokens": r(busy.tokens)]
                }),
            ],
            "growth": growth,
            "daily": .array(s.series.map { day in
                ["date": .string(day.date), "server_starts": i(day.serverStarts), "tool_calls": i(day.toolCalls), "tokens": r(day.tokens)]
            }),
        ]
    }

    // MARK: Formatting

    /// A whole number with thousands separators.
    static func n(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    static func t(_ tokens: Double) -> String { n(Int(tokens.rounded())) }

    static func ms(_ micros: Int) -> String {
        micros < 10_000 ? String(format: "%.1f ms", Double(micros) / 1000) : "\(n(micros / 1000)) ms"
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
    }
}
