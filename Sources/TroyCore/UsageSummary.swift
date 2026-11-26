import Foundation

/// The numbers `troy stats` prints, computed from the rows of the usage log and, when the
/// database exists, from the database itself.
public struct UsageSummary: Sendable {
    /// Troy cannot tokenize. A rough rule from text size: about four ASCII characters per token,
    /// and about one and a half non-ASCII characters (Korean takes three UTF-8 bytes per character,
    /// so `(bytes - chars) / 2` counts those characters).
    public static func tokens(chars: Int, bytes: Int) -> Double {
        let nonASCII = max(0, Double(bytes - chars) / 2)
        let ascii = max(0, Double(chars) - nonASCII)
        return ascii / 4 + nonASCII / 1.5
    }

    public static let handshake: Set<String> = ["initialize", "server/discover", "tools/list"]

    public struct Tool: Sendable {
        public var name: String
        public var calls = 0
        public var errors = 0
        public var resultChars = 0
        public var resultTokens = 0.0
        public var argumentTokens = 0.0
        public var medianMicros = 0
        public var p95Micros = 0
    }

    public struct Busy: Sendable {
        public var projectID: Int64
        public var name: String
        public var calls = 0
        public var saves = 0
        public var tokens = 0.0
    }

    public struct Count: Sendable {
        public var name: String
        public var count: Int
    }

    public struct Day: Sendable {
        public var date: String
        public var serverStarts = 0
        public var toolCalls = 0
        public var tokens = 0.0
    }

    public var days: Int
    public var since: Date
    public var until: Date
    public var logPath: String
    public var rows: Int

    public var serverStarts = 0
    public var startsByClient: [Count] = []
    public var startsWithToolCall = 0
    /// Servers that were already running when the period began and made calls in it.
    public var runningFromBefore = 0

    public var hookRuns = 0
    public var hookByState: [Count] = []
    public var clientProcesses = 0
    public var hookProcesses = 0
    public var hookProcessesWithToolCall = 0

    public var tools: [Tool] = []
    /// `tools/call` requests that reached no tool: an unknown name, or arguments that are not an object.
    public var protocolErrors = 0
    public var toolCalls: Int { tools.reduce(0) { $0 + $1.calls } }

    public var handshakeTokens = 0.0
    public var hookTokens = 0.0
    public var resultTokens = 0.0
    public var argumentTokens = 0.0
    public var fixedTokensPerStart: Double { serverStarts == 0 ? 0 : handshakeTokens / Double(serverStarts) }
    public var totalTokens: Double { handshakeTokens + hookTokens + resultTokens + argumentTokens }

    public var claims = 0
    public var refusedClaims = 0
    public var takeovers = 0
    public var saves = 0
    public var updates = 0
    public var savesWithAdvisories = 0
    public var updatesWithAdvisories = 0
    public var advisoryKinds: [Count] = []
    public var savesWithSimilar = 0
    public var duplicateSaves = 0

    public var contextReads = 0
    public var contextWithRecords = 0
    public var contextPending = 0
    public var searches = 0
    public var searchesWithHits = 0
    public var recordsRead = 0
    public var foreignRecordsRead = 0

    public var projectsCreatedOnSave = 0
    public var projectsCreatedByTool = 0
    public var busiest: [Busy] = []

    public var growth: GraphGrowth?
    public var series: [Day] = []

    // MARK: Computing

    public init(rows logged: [LoggedUsage], days: Int, since: Date, until: Date, logPath: String,
         projectNames: [Int64: String], growth: GraphGrowth?, runningBefore: Set<String> = [], calendar: Calendar = .current) {
        self.days = days
        self.since = since
        self.until = until
        self.logPath = logPath
        self.rows = logged.count
        self.growth = growth

        let mcp = logged.filter { $0.event.source == "mcp" }
        let hooks = logged.filter { $0.event.source == "hook" }
        let calls = mcp.filter { !Self.handshake.contains($0.event.event) && $0.event.event != "tools/call" }
        protocolErrors = mcp.filter { $0.event.event == "tools/call" }.count

        // Server starts: one session id per server process. A client names itself in its first
        // message, so the last non-empty name of a session is the one to count it under.
        var clientOf: [String: String] = [:]
        var firstSeen: [String: Int64] = [:]
        for row in mcp {
            if !row.event.client.isEmpty || clientOf[row.event.session] == nil { clientOf[row.event.session] = row.event.client }
            if firstSeen[row.event.session] == nil { firstSeen[row.event.session] = row.at }
        }
        // A session with a row before the period started before it, whatever its first row in the period is.
        for session in runningBefore {
            clientOf[session] = nil
            firstSeen[session] = nil
        }
        serverStarts = clientOf.count
        startsByClient = Self.counted(clientOf.values.map { $0.isEmpty ? "(unnamed)" : $0 })
        let callSessions = Set(calls.map(\.event.session))
        startsWithToolCall = callSessions.filter { clientOf[$0] != nil }.count
        runningFromBefore = callSessions.intersection(runningBefore).count

        hookRuns = hooks.count
        hookByState = Self.counted(hooks.map { Self.string(Self.detail($0)["state"]) ?? "unknown" })
        clientProcesses = Set(logged.map(\.event.host).filter { !$0.isEmpty }).count
        let hookHosts = Set(hooks.map(\.event.host).filter { !$0.isEmpty })
        let callHosts = Set(calls.map(\.event.host))
        hookProcesses = hookHosts.count
        hookProcessesWithToolCall = hookHosts.intersection(callHosts).count

        // Per tool.
        var byTool: [String: [LoggedUsage]] = [:]
        for row in calls { byTool[row.event.event, default: []].append(row) }
        tools = byTool.map { name, rows in
            var tool = Tool(name: name)
            tool.calls = rows.count
            tool.errors = rows.filter { !$0.event.ok }.count
            tool.resultChars = rows.reduce(0) { $0 + $1.event.responseChars }
            tool.resultTokens = rows.reduce(0) { $0 + Self.responseTokens($1) }
            tool.argumentTokens = rows.reduce(0) { $0 + Self.requestTokens($1) }
            let times = rows.map(\.event.micros).sorted()
            tool.medianMicros = Self.percentile(times, 0.5)
            tool.p95Micros = Self.percentile(times, 0.95)
            return tool
        }.sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }

        // Context cost.
        handshakeTokens = mcp.filter { Self.handshake.contains($0.event.event) }.reduce(0) { $0 + Self.responseTokens($1) }
        hookTokens = hooks.reduce(0) { $0 + Self.responseTokens($1) }
        resultTokens = calls.reduce(0) { $0 + Self.responseTokens($1) }
        argumentTokens = calls.reduce(0) { $0 + Self.requestTokens($1) }

        // Coordination and memory, from what each tool noted about itself. Every field may be
        // missing: a row written before the tool reported it simply counts as nothing.
        var kinds: [String] = []
        for row in calls {
            let detail = Self.detail(row)
            switch row.event.event {
            case "troy_save":
                saves += 1
                let advisories = Self.advisories(detail["advisories"])
                if advisories.count > 0 { savesWithAdvisories += 1 }
                kinds += advisories.kinds
                if Self.int(detail["similar"]) > 0 { savesWithSimilar += 1 }
                if Self.truthy(detail["deduplicated"]) { duplicateSaves += 1 }
                if Self.truthy(detail["created_project"]) { projectsCreatedOnSave += 1 }
            case "troy_update":
                updates += 1
                let advisories = Self.advisories(detail["advisories"])
                if advisories.count > 0 { updatesWithAdvisories += 1 }
                kinds += advisories.kinds
            default: break
            }
            // A save with status "doing" creates the task already held, so saves claim too.
            if row.event.event == "troy_save" || row.event.event == "troy_update" {
                switch Self.string(detail["claim"]) {
                case "claimed": claims += 1
                case "takeover": claims += 1; takeovers += 1
                case "refused": refusedClaims += 1
                default: break
                }
            }
            switch row.event.event {
            case "troy_context":
                contextReads += 1
                switch Self.string(detail["state"]) {
                case "project": if Self.int(detail["records"]) > 0 { contextWithRecords += 1 }
                case "pending": contextPending += 1
                default: break
                }
            case "troy_search":
                // A search that failed (an unknown project, bad arguments) found nothing because it
                // never ran; it shows among the tool's errors, not here.
                guard row.event.ok else { break }
                searches += 1
                if Self.int(detail["hits"]) > 0 { searchesWithHits += 1 }
            case "troy_read":
                recordsRead += Self.int(detail["found"])
                foreignRecordsRead += Self.int(detail["foreign"])
            case "troy_new_project":
                // Counted from the outcome until the tool notes it itself.
                if detail["created_project"] == nil ? row.event.ok : Self.truthy(detail["created_project"]) { projectsCreatedByTool += 1 }
            default: break
            }
        }
        advisoryKinds = Self.counted(kinds)

        // The busiest projects.
        var busy: [Int64: Busy] = [:]
        for row in calls {
            guard let id = row.event.projectID else { continue }
            var entry = busy[id] ?? Busy(projectID: id, name: projectNames[id] ?? "")
            entry.calls += 1
            if row.event.event == "troy_save" { entry.saves += 1 }
            entry.tokens += Self.responseTokens(row) + Self.requestTokens(row)
            busy[id] = entry
        }
        busiest = Array(busy.values.sorted { ($0.calls, $1.projectID) > ($1.calls, $0.projectID) }.prefix(10))

        // A series per local day, every day of the period included.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var byDay: [String: Day] = [:]
        var day = calendar.startOfDay(for: since)
        while day <= until {
            let key = formatter.string(from: day)
            byDay[key] = Day(date: key)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for row in logged {
            let key = formatter.string(from: row.date)
            var entry = byDay[key] ?? Day(date: key)
            entry.tokens += Self.responseTokens(row) + Self.requestTokens(row)
            if row.event.source == "mcp", !Self.handshake.contains(row.event.event), row.event.event != "tools/call" { entry.toolCalls += 1 }
            byDay[key] = entry
        }
        for at in firstSeen.values {
            let key = formatter.string(from: Date(timeIntervalSince1970: Double(at) / 1000))
            byDay[key, default: Day(date: key)].serverStarts += 1
        }
        series = byDay.values.sorted { $0.date < $1.date }
    }

    static func responseTokens(_ row: LoggedUsage) -> Double { tokens(chars: row.event.responseChars, bytes: row.event.responseBytes) }
    static func requestTokens(_ row: LoggedUsage) -> Double { tokens(chars: row.event.requestChars, bytes: row.event.requestBytes) }

    /// Nearest rank; 0 for no values.
    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Most frequent first, then by name.
    static func counted(_ values: [String]) -> [Count] {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).map { Count(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    static func detail(_ row: LoggedUsage) -> [String: Any] {
        guard let data = row.event.detail.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func int(_ value: Any?) -> Int {
        switch value {
        case let items as [Any]: return items.count
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? 1 : 0 }
            let double = number.doubleValue
            return double.isFinite ? Int(double) : 0
        default: return 0
        }
    }

    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: return number.doubleValue != 0
        case let text as String: return !text.isEmpty
        default: return false
        }
    }

    static func string(_ value: Any?) -> String? { value as? String }

    /// Saves note the kinds of their advisories as an array; other tools may note only a count.
    static func advisories(_ value: Any?) -> (count: Int, kinds: [String]) {
        if let items = value as? [Any] { return (items.count, items.compactMap { $0 as? String }) }
        return (int(value), [])
    }
}
