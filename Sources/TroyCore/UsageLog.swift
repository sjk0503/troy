import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One row of the usage log: what was called, how large it was and how long it took.
/// Holds names, sizes, counts and record numbers. Never titles, bodies, search words or folder paths.
public struct UsageEvent: Sendable, Equatable {
    /// One per server process, or per run of the session-start hook.
    public var session: String
    /// The client process that started this one, as "pid@startSeconds"; empty when unknown.
    /// The hook and the MCP server of one client session share it.
    public var host: String
    public var agent: String
    public var client: String
    /// "mcp" or "hook".
    public var source: String
    /// The tool or protocol method ("troy_save", "tools/list", "initialize"); "context" for the hook.
    public var event: String
    public var projectID: Int64?
    public var ok: Bool
    public var requestChars: Int
    public var requestBytes: Int
    public var responseChars: Int
    public var responseBytes: Int
    /// How long the call took, in microseconds.
    public var micros: Int
    /// A JSON object with counts and ids for this event; "{}" when there is nothing to add.
    public var detail: String

    public init(
        session: String, host: String, agent: String, client: String, source: String, event: String,
        projectID: Int64? = nil, ok: Bool = true, requestChars: Int = 0, requestBytes: Int = 0,
        responseChars: Int = 0, responseBytes: Int = 0, micros: Int = 0, detail: String = "{}"
    ) {
        self.session = session; self.host = host; self.agent = agent; self.client = client
        self.source = source; self.event = event; self.projectID = projectID; self.ok = ok
        self.requestChars = requestChars; self.requestBytes = requestBytes
        self.responseChars = responseChars; self.responseBytes = responseBytes
        self.micros = micros; self.detail = detail
    }

    /// One run of the session-start hook (`troy context --quiet`).
    /// `state` is "project" (the project's state was printed), "pending" (a repository without a
    /// project: the hint was printed) or "none" (nothing was printed).
    public static func hook(projectID: Int64?, state: String, printed: String, micros: Int) -> UsageEvent {
        UsageEvent(
            session: UsageLog.newSessionID(), host: UsageLog.hostProcess(), agent: "troy-cli", client: "",
            source: "hook", event: "context", projectID: projectID, ok: true,
            responseChars: printed.count, responseBytes: printed.utf8.count, micros: micros,
            detail: "{\"state\":\"\(state)\"}")
    }
}

/// A row read back from the log, with the moment it was written.
public struct LoggedUsage: Sendable, Equatable {
    /// Milliseconds since 1970.
    public var at: Int64
    public var event: UsageEvent

    public init(at: Int64, event: UsageEvent) {
        self.at = at
        self.event = event
    }

    public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// The usage log: a SQLite file next to the database. It stays on this Mac.
///
/// A file of its own rather than a table in `troy.db`: every write there changes
/// `PRAGMA data_version` and makes the app reload, a read-only tool must not take the
/// database's write lock to log itself, and the format of this log is expected to change,
/// which must never touch the append-only schema.
///
/// The log must never break or slow down the call it describes. `record` never throws and
/// hardly waits: a write gets a few milliseconds and the first open about a tenth of a second.
/// When the file is locked the rows wait in memory for a later call, and `close` waits up to a
/// second for whatever is left. Only a failure that cannot heal (not a usage log, a newer
/// format, a file that cannot be made) turns the log off for the rest of the process.
public final class UsageLog: @unchecked Sendable {
    public let path: String
    private let createFolder: Bool
    private let retentionDays: Int?

    private let lock = NSLock()
    private var database: Database?
    private var state = State.closed
    /// Rows not written yet, oldest first, with their time in milliseconds since 1970.
    private var queue: [(at: Int64, event: UsageEvent)] = []
    /// Rows dropped from a full queue since the last write that went through.
    private var dropped = 0

    private enum State { case closed, open, off }

    /// 'TRYU' in ASCII, so the log is never taken for a Troy database or the other way round.
    static let applicationID: Int32 = 0x5452_5955
    static let version: Int64 = 1
    /// Rows older than this are removed when a server process opens the log.
    public static let keepDays = 90
    /// How long a write on the path of a tool call waits for a lock. The reply waits for it, and
    /// the wait is not in `micros`, so it must stay close to nothing: a locked file only queues the row.
    static let callTimeoutMillis = 5
    /// How long opening the file may take on the path of a call; a file being set up elsewhere queues the row.
    static let callOpenBudget: TimeInterval = 0.1
    /// What `close` may wait in all: the last chance for the queued rows, and the only one a hook run gets.
    static let closeTimeoutMillis = 1_000
    /// Rows kept while the file is locked; beyond this the oldest go and are counted.
    static let queueLimit = 500

    static let schema = """
    CREATE TABLE usage (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      at             INTEGER NOT NULL,
      session        TEXT NOT NULL,
      host           TEXT NOT NULL DEFAULT '',
      agent          TEXT NOT NULL DEFAULT '',
      client         TEXT NOT NULL DEFAULT '',
      source         TEXT NOT NULL,
      event          TEXT NOT NULL,
      project_id     INTEGER,
      ok             INTEGER NOT NULL DEFAULT 1,
      request_chars  INTEGER NOT NULL DEFAULT 0,
      request_bytes  INTEGER NOT NULL DEFAULT 0,
      response_chars INTEGER NOT NULL DEFAULT 0,
      response_bytes INTEGER NOT NULL DEFAULT 0,
      micros         INTEGER NOT NULL DEFAULT 0,
      detail         TEXT NOT NULL DEFAULT '{}'
    ) STRICT;
    CREATE INDEX usage_at ON usage(at);
    """

    /// Where the log of the database at `databasePath` lives: `troy.db` → `troy-usage.db`.
    public static func path(forDatabase databasePath: String) -> String {
        let expanded = (databasePath as NSString).expandingTildeInPath
        if expanded.lowercased().hasSuffix(".db") { return String(expanded.dropLast(3)) + "-usage.db" }
        return expanded + "-usage.db"
    }

    /// The log that belongs to the database at `databasePath`. Nil for an in-memory database and
    /// when `TROY_USAGE` is "off". With `createFolder` false the log never creates the folder it
    /// lives in (the session-start hook must not leave anything behind where Troy was never used).
    /// With `createFolder` true (the MCP server) it also removes rows older than `keepDays` when it opens.
    public static func forDatabase(
        at databasePath: String, environment: [String: String] = ProcessInfo.processInfo.environment, createFolder: Bool
    ) -> UsageLog? {
        guard databasePath != ":memory:", !databasePath.isEmpty else { return nil }
        if environment["TROY_USAGE"]?.lowercased() == "off" { return nil }
        return UsageLog(path: path(forDatabase: databasePath), createFolder: createFolder, retentionDays: createFolder ? keepDays : nil)
    }

    /// Nothing is opened until the first `record`.
    public init(path: String, createFolder: Bool = false, retentionDays: Int? = nil) {
        self.path = (path as NSString).expandingTildeInPath
        self.createFolder = createFolder
        self.retentionDays = retentionDays
    }

    deinit { database?.close() }

    /// False once a failure that cannot heal (not a usage log, a newer format, a file that cannot be
    /// created or opened) has turned the log off for this process.
    public var isOn: Bool { lock.withLock { state != .off } }

    /// The most rows kept in memory while the file is locked. Tests lower it.
    var queueLimit = UsageLog.queueLimit

    /// Rows waiting for the file to be free. For tests.
    var queued: Int { lock.withLock { queue.count } }

    /// Appends one row. Never throws and never waits long. While another connection holds the
    /// file's lock the row waits in memory and goes out with the next call that finds the file free.
    public func record(_ event: UsageEvent) {
        record(event, at: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
    }

    /// `record` with the time given, so tests can write rows that look old.
    func record(_ event: UsageEvent, at millis: Int64) {
        lock.withLock {
            guard state != .off else { return }
            queue.append((millis, event))
            if queue.count > queueLimit {
                let excess = queue.count - queueLimit
                queue.removeFirst(excess)
                dropped += excess
            }
            flush(timeoutMillis: Self.callTimeoutMillis, openBudget: Self.callOpenBudget)
        }
    }

    /// Writes what is still queued, waiting up to a second for the lock, and closes the file.
    /// A later `record` opens it again unless the log is off.
    public func close() {
        lock.withLock {
            if state != .off, !queue.isEmpty {
                flush(timeoutMillis: Self.closeTimeoutMillis, openBudget: Double(Self.closeTimeoutMillis) / 1000)
            }
            database?.close()
            database = nil
            if state == .open { state = .closed }
        }
    }

    /// Writes the whole queue in one transaction. Called with the lock held.
    private func flush(timeoutMillis: Int, openBudget: TimeInterval) {
        guard !queue.isEmpty else { return }
        let db: Database
        switch openIfNeeded(budget: openBudget) {
        case .opened(let opened): db = opened
        case .busy:
            return
        case .failed:
            turnOff()
            return
        }
        do {
            try db.execute("PRAGMA busy_timeout = \(timeoutMillis)")
            try db.transaction {
                for (index, row) in queue.enumerated() {
                    var detail = row.event.detail
                    if index == 0, dropped > 0 { detail = Self.adding(dropped: dropped, to: detail) }
                    try insert(db, row.event, at: row.at, detail: detail)
                }
            }
            queue.removeAll()
            dropped = 0
        } catch {
            // Busy: the rows stay queued for the next call. Anything else will not heal.
            if !db.lastFailureWasBusy { turnOff() }
        }
    }

    private func insert(_ db: Database, _ event: UsageEvent, at millis: Int64, detail: String) throws {
        try db.run(
            """
            INSERT INTO usage (at, session, host, agent, client, source, event, project_id, ok,
              request_chars, request_bytes, response_chars, response_bytes, micros, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int(millis), .text(event.session), .text(event.host), .text(Self.label(event.agent)), .text(Self.label(event.client)),
                .text(event.source), .text(event.event), .opt(event.projectID), .int(event.ok ? 1 : 0),
                .int(Int64(event.requestChars)), .int(Int64(event.requestBytes)),
                .int(Int64(event.responseChars)), .int(Int64(event.responseBytes)),
                .int(Int64(event.micros)), .text(detail),
            ])
    }

    /// The agent and client names as the log keeps them. Both come from outside (`TROY_AGENT`, the
    /// client's own name) and could hold a folder path or other typed text, which the log never
    /// stores: a value is kept only when it looks like a label, otherwise it becomes "other".
    /// A label is letters, digits, spaces, `.`, `_` and `-`, with at most one `/` between a name and a tag.
    static func label(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        guard value.count <= 64 else { return "other" }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty }) else { return "other" }
        let allowed = value.allSatisfy { $0 == "/" || $0 == " " || $0 == "." || $0 == "_" || $0 == "-" || $0.isLetter || $0.isNumber }
        return allowed ? value : "other"
    }

    /// `detail` with `"dropped": count` added as its first member.
    static func adding(dropped count: Int, to detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return "{\"dropped\":\(count)}" }
        let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("}") ? "{\"dropped\":\(count)}" : "{\"dropped\":\(count),\(rest)"
    }

    private func turnOff() {
        database?.close()
        database = nil
        state = .off
        queue.removeAll()
    }

    // MARK: Opening

    private enum Opening {
        case opened(Database)
        /// Another process held a lock while the file was being set up: try again with the next row.
        case busy
        /// Not this log, a newer format, or a file that cannot be made: off for good.
        case failed
    }

    private func openIfNeeded(budget: TimeInterval) -> Opening {
        switch state {
        case .off: return .failed
        case .open:
            if let database { return .opened(database) }
            state = .closed
            return openIfNeeded(budget: budget)
        case .closed:
            do {
                let db = try open(budget: budget)
                database = db
                state = .open
                return .opened(db)
            } catch is Busy {
                return .busy
            } catch {
                return .failed
            }
        }
    }

    private struct Busy: Error {}
    private struct NotOurs: Error {}

    private func open(budget: TimeInterval) throws -> Database {
        let deadline = Date().addingTimeInterval(budget)
        let folder = (path as NSString).deletingLastPathComponent
        if createFolder {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } else {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { throw NotOurs() }
        }
        let db = try Database(path: path)
        do {
            do {
                try Self.prepare(db, deadline: deadline, waitMillis: max(1, min(250, Int(budget * 250))))
            } catch {
                if db.lastFailureWasBusy { throw Busy() }
                throw error
            }
            if let days = retentionDays {
                // Pruning is housekeeping: a lock held elsewhere only postpones it to the next start.
                let cutoff = Int64((Date().timeIntervalSince1970 - Double(days) * 86_400) * 1000)
                _ = try? db.run("DELETE FROM usage WHERE at < ?", [.int(cutoff)])
            }
            return db
        } catch {
            db.close()
            throw error
        }
    }

    /// Checks that the file is this log, or empty, and sets it up. Several processes may do this
    /// to one new file at the same moment.
    /// `waitMillis` is the busy timeout of each statement, kept well below the budget so one
    /// statement cannot overrun it.
    private static func prepare(_ db: Database, deadline: Date, waitMillis: Int) throws {
        try db.execute("PRAGMA busy_timeout = \(waitMillis)")
        // One snapshot for all three: a file another process is setting up is then seen as empty
        // or as finished, never as half of each, which would look like somebody else's file.
        let identity = try retrying(db, until: deadline) { try readIdentity(db) }
        guard identity.isNew || identity.isOurs else { throw NotOurs() }
        // A fresh file's switch to WAL is refused at once, without the busy timeout, while another
        // connection holds a lock on it; ask again until it goes through or the budget is spent.
        try retrying(db, until: deadline) { try db.execute("PRAGMA journal_mode = WAL") }
        try db.execute("PRAGMA synchronous = NORMAL")
        guard identity.isNew else { return }
        try retrying(db, until: deadline) {
            try db.transaction {
                // Another process may have finished the setup while this one waited for the lock.
                let current = try readIdentity(db)
                if current.isOurs { return }
                guard current.isNew else { throw NotOurs() }
                try db.execute("PRAGMA application_id = \(applicationID)")
                try db.execute(schema)
                try db.execute("PRAGMA user_version = \(version)")
            }
        }
    }

    private struct Identity {
        var applicationID: Int64
        var userVersion: Int64
        var tables: Int64
        var isNew: Bool { applicationID == 0 && userVersion == 0 && tables == 0 }
        /// A newer log format is left alone too: this build would write rows it no longer reads that way.
        var isOurs: Bool { applicationID == Int64(UsageLog.applicationID) && userVersion == UsageLog.version }
    }

    private static func readIdentity(_ db: Database) throws -> Identity {
        try db.snapshot {
            Identity(
                applicationID: try db.int("PRAGMA application_id") ?? 0,
                userVersion: try db.int("PRAGMA user_version") ?? 0,
                tables: try db.int("SELECT count(*) FROM sqlite_master") ?? 0)
        }
    }

    /// Runs `body` again while it fails on a lock another connection holds, until `deadline`.
    @discardableResult
    private static func retrying<T>(_ db: Database, until deadline: Date, _ body: () throws -> T) throws -> T {
        var pause: UInt32 = 1_000
        while true {
            do {
                return try body()
            } catch {
                let left = deadline.timeIntervalSinceNow
                guard db.lastFailureWasBusy, left > 0 else { throw error }
                usleep(min(pause + UInt32.random(in: 0...pause), UInt32(left * 1_000_000)))
                guard Date() < deadline else { throw error }
                pause = min(pause * 2, 20_000)
            }
        }
    }

    // MARK: Reading

    /// Whether a log file exists at `path`. Looking never creates one.
    public static func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    /// The rows written at or after `since`, oldest first. Never creates the file.
    /// Throws `.notFound` when there is no log and `.database` when the file is not a usage log
    /// this build can read.
    public static func read(at path: String, since: Date) throws -> [LoggedUsage] {
        let cutoff = Int64(since.timeIntervalSince1970 * 1000)
        return try reading(path) { db in
            try db.query(
                """
                SELECT at, session, host, agent, client, source, event, project_id, ok, request_chars, request_bytes,
                  response_chars, response_bytes, micros, detail
                FROM usage WHERE at >= ? ORDER BY at, id
                """, [.int(cutoff)]
            ) { row in
                let at = row.int()
                let event = UsageEvent(
                    session: row.text(), host: row.text(), agent: row.text(), client: row.text(), source: row.text(),
                    event: row.text(), projectID: row.optInt(), ok: row.int() != 0,
                    requestChars: Int(row.int()), requestBytes: Int(row.int()),
                    responseChars: Int(row.int()), responseBytes: Int(row.int()),
                    micros: Int(row.int()), detail: row.text())
                return LoggedUsage(at: at, event: event)
            }
        } ?? []
    }

    /// The sessions with rows at or after `since` that also have a row before it: servers that
    /// were already running when the period began, and so did not start in it.
    public static func sessionsRunningBefore(_ since: Date, at path: String) throws -> Set<String> {
        let cutoff = SQLValue.int(Int64(since.timeIntervalSince1970 * 1000))
        return Set(try reading(path) { db in
            try db.query(
                "SELECT DISTINCT session FROM usage WHERE at < ? AND session IN (SELECT session FROM usage WHERE at >= ?)",
                [cutoff, cutoff]) { $0.text() }
        } ?? [])
    }

    /// Runs `body` in one read transaction on the log, after checking it is one. Nil for a file that is still empty.
    private static func reading<T>(_ path: String, _ body: (Database) throws -> T) throws -> T? {
        let path = (path as NSString).expandingTildeInPath
        guard exists(at: path) else { throw TroyError.notFound("There is no usage log at \(path) yet.") }
        let db = try Database(path: path, create: false)
        defer { db.close() }
        try db.execute("PRAGMA busy_timeout = 2000")
        return try db.snapshot {
            let identity = try readIdentity(db)
            if identity.isNew { return nil }
            guard identity.applicationID == Int64(applicationID) else {
                throw TroyError.database("\(path) is not a Troy usage log. Move it away and Troy starts a new one.")
            }
            guard identity.userVersion == version else {
                throw TroyError.database("\(path) was written by a newer version of Troy (log format \(identity.userVersion); this build reads \(version)). Update Troy to read it.")
            }
            return try body(db)
        }
    }

    // MARK: Identity of this process

    /// Shells and launchers that sit between a client and the process it starts.
    static let launchers: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "mksh", "tcsh", "csh", "env", "nohup", "nice", "timeout",
        "gtimeout", "time", "script", "caffeinate", "login", "exec", "xargs", "lockf",
    ]

    /// What `sysctl` says about one process.
    struct ProcessFacts: Equatable {
        var parent: Int32
        var name: String
        var startSeconds: Int
    }

    /// The client process that started this one: the nearest ancestor that is not a shell, as "pid@startSeconds".
    /// Empty when it cannot tell, or when only shells lie between this process and launchd.
    ///
    /// A best effort. It matches a hook run with the server of the same client only when the
    /// client starts both directly or through a shell, which is the form `troy guide --hook`
    /// prints. A hook wrapped in a script (Python, Node) reports the wrapper instead.
    public static func hostProcess() -> String {
        host(startingAt: getppid(), lookup: processFacts)
    }

    /// The walk behind `hostProcess`, with the lookup passed in so it can be tested without real processes.
    static func host(startingAt pid: Int32, lookup: (Int32) -> ProcessFacts?) -> String {
        var current = pid
        // A cap in case a process table changes under the walk and forms a loop.
        for _ in 0..<32 {
            guard current > 1, let facts = lookup(current) else { return "" }
            if !isLauncher(facts.name) { return "\(current)@\(facts.startSeconds)" }
            current = facts.parent
        }
        return ""
    }

    static func isLauncher(_ name: String) -> Bool {
        // A login shell is listed as "-zsh".
        var name = name.lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return launchers.contains(name)
    }

    static func processFacts(_ pid: Int32) -> ProcessFacts? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessFacts(parent: info.kp_eproc.e_ppid, name: name, startSeconds: Int(info.kp_proc.p_starttime.tv_sec))
        #else
        return nil
        #endif
    }

    /// A new random session id.
    public static func newSessionID() -> String {
        String(format: "%08x%08x", UInt32.random(in: 0...UInt32.max), UInt32.random(in: 0...UInt32.max))
    }
}
