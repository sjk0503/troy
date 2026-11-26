import Foundation
#if canImport(Darwin)
import notify
#endif

/// The only way to read and write a Troy database. The MCP server, the command line tool
/// and the menu bar app each open their own `Store` on the same file.
///
/// Rules every method follows (details in docs/ARCHITECTURE.md):
/// - Thread-safe: public methods are serialized by an internal lock.
/// - Every write runs in one `BEGIN IMMEDIATE` transaction and posts `ChangeSignal` after it commits.
/// - Input is validated against `Limits` before anything is written. Bad input throws `.invalid`.
/// - Missing rows throw `.notFound`. Unexpected SQLite failures throw `.database`.
public final class Store: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var database: Database?
    private var label: String
    private let searchIndexAvailable: Bool
    private let filePath: String
    /// How many change signals this store has posted. For tests.
    private(set) var signalsPosted = 0

    /// Who is acting through this store, for example "claude-code/a3f" or "app".
    /// Written to `source`, `assignee`, `created_by` and `updated_by`.
    public var agent: String {
        get { lock.withLock { label } }
        set { lock.withLock { label = Store.cleanLabel(newValue) } }
    }

    /// False when this SQLite build has no FTS5 trigram tokenizer; search then uses LIKE only.
    public var ftsAvailable: Bool { searchIndexAvailable }

    /// The file this store reads and writes.
    public var path: String { filePath }

    /// Opens the database at `path`, creating the file and its folder when missing, then
    /// applies pending migrations and creates the search index when possible.
    /// Pass ":memory:" for a private in-memory database (tests).
    /// `searchIndex: false` skips the full-text index, so search uses LIKE only.
    public init(path: String, agent: String = "", searchIndex: Bool = true) throws {
        let isMemory = path == ":memory:"
        let resolved = isMemory ? path : (path as NSString).expandingTildeInPath
        if !isMemory {
            let folder = URL(fileURLWithPath: resolved).deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw TroyError.database("Cannot create the folder \(folder.path): \(error.localizedDescription)")
            }
        }
        let opened = try Database(path: resolved)
        let hasIndex: Bool
        do {
            hasIndex = try Store.prepare(opened, path: resolved, searchIndex: searchIndex)
        } catch {
            opened.close()
            throw error
        }
        self.database = opened
        self.filePath = resolved
        self.label = Store.cleanLabel(agent)
        self.searchIndexAvailable = hasIndex
    }

    deinit { database?.close() }

    /// `$TROY_DB` when set, otherwise `~/Library/Application Support/Troy/troy.db`.
    public static func defaultPath() -> String {
        if let custom = ProcessInfo.processInfo.environment["TROY_DB"], !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Troy/troy.db").path
    }

    /// Changes whenever another connection commits to the file (`PRAGMA data_version`).
    public func dataVersion() throws -> Int {
        try read { db in Int(try db.int("PRAGMA data_version") ?? 0) }
    }

    /// Runs `PRAGMA optimize` and closes the connection. The store cannot be used afterwards.
    public func close() {
        lock.withLock {
            guard let db = database else { return }
            try? db.execute("PRAGMA optimize")
            db.close()
            database = nil
        }
    }

    // MARK: Projects

    /// Projects with their stats, most recently active first (projects without records sort by `updatedAt`).
    public func projects(includeArchived: Bool = false) throws -> [ProjectSummary] {
        try read { db in try projectList(db, includeArchived: includeArchived) }
    }

    public func project(id: Int64) throws -> Project {
        try read { db in try fetchProject(db, id: id) }
    }

    public func stats(projectID: Int64) throws -> ProjectStats {
        try read { db in
            _ = try fetchProject(db, id: projectID)
            return try projectStats(db, projectID: projectID)
        }
    }

    /// Finds the project a caller means.
    /// - `reference` given: digits are an id; otherwise an exact name (case-insensitive); otherwise the
    ///   only project whose name contains it. Archived projects can be named explicitly.
    /// - `reference` nil: the active project whose linked path is `directory` or its closest ancestor.
    /// Throws `.notFound` with a message that lists the active projects when nothing matches,
    /// and `.invalid` when a name matches more than one project.
    /// - Parameter exactName: accept an id or an exact name only. Callers that are about to write
    ///   use this, so a partial name never files a record in the wrong project.
    public func resolveProject(reference: String?, directory: String?, exactName: Bool = false) throws -> Project {
        try read { db in try resolve(db, reference: reference, directory: directory, exactName: exactName) }
    }

    /// Creates a project. A name already in use throws `.conflict`. A path already linked to
    /// another project throws `.conflict` naming that project.
    public func createProject(name: String, summary: String = "", paths: [String] = []) throws -> Project {
        let name = try TextRules.required(name, field: "Project name", max: Limits.projectName)
        let summary = try TextRules.optional(summary, field: "Project summary", max: Limits.projectSummary)
        let paths = try PathRules.projectPaths(paths)
        return try write { db in (try insertProject(db, name: name, summary: summary, paths: paths), true) }
    }

    /// Changes the given fields. `paths` replaces the whole list.
    public func updateProject(
        id: Int64, name: String? = nil, summary: String? = nil, status: ProjectStatus? = nil, paths: [String]? = nil
    ) throws -> Project {
        let name = try name.map { try TextRules.required($0, field: "Project name", max: Limits.projectName) }
        let summary = try summary.map { try TextRules.optional($0, field: "Project summary", max: Limits.projectSummary) }
        let paths = try paths.map { try PathRules.projectPaths($0) }
        return try write { db in try changeProject(db, id: id, name: name, summary: summary, status: status, paths: paths) }
    }

    /// Deletes the project with its records, their links and versions.
    public func deleteProject(id: Int64) throws {
        try write { db in
            guard try db.run("DELETE FROM projects WHERE id = ?", [.int(id)]) > 0 else {
                throw TroyError.notFound("No project #\(id).")
            }
            return ((), true)
        }
    }

    // MARK: Records

    public func record(id: Int64) throws -> Record {
        try read { db in try fetchRecord(db, id: id) }
    }

    /// The record, its links seen from it (outgoing first, then by relation), and its advisories.
    public func detail(id: Int64) throws -> RecordDetail {
        try read { db in
            RecordDetail(
                record: try fetchRecord(db, id: id),
                links: try fetchLinks(db, of: id),
                advisories: try computeAdvisories(db, id: id, agent: label)
            )
        }
    }

    public func list(_ query: RecordQuery) throws -> [RecordSummary] {
        try read { db in try listRecords(db, query) }
    }

    /// Stores a record and its links in one transaction.
    /// - A `.doing` status claims the record for `agent`.
    /// - A record identical in every field saved by the same agent within
    ///   `Limits.dedupeWindowSeconds` is returned instead, with `deduplicated == true`. A save that
    ///   differs in anything (tags, paths, status) is a new record: nothing typed is dropped.
    /// - A link to a missing record, or one that would close a cycle, throws and nothing is stored.
    /// The result carries similar existing records and advisories; neither blocks the save.
    public func create(_ draft: RecordDraft) throws -> SaveResult {
        let checked = try CheckedDraft(draft)
        return try lock.withLock {
            let outcome = try write { db in try insertRecord(db, checked, agent: label) }
            return try saveResult(outcome)
        }
    }

    /// The reply to a save that just committed: the record, plus similar records and advisories.
    func saveResult(_ outcome: InsertOutcome) throws -> SaveResult {
        try read { db in
            let record = try fetchRecord(db, id: outcome.id)
            if outcome.deduplicated {
                // No similar records for a repeat: the caller already saw them the first time.
                return SaveResult(
                    record: record, links: outcome.links, deduplicated: true,
                    advisories: try computeAdvisories(db, id: record.id, agent: label)
                )
            }
            let similar = try similarRecords(
                db, title: record.title, tags: record.tags, projectID: record.projectID, excluding: [record.id], limit: 5
            )
            return SaveResult(
                record: record, links: outcome.links, deduplicated: false, similar: similar,
                advisories: try computeAdvisories(db, id: record.id, agent: label)
            )
        }
    }

    /// Applies the patch. Nothing is written when no field would change.
    /// - Any status change while another agent holds the claim throws `.conflict` naming that agent
    ///   and when it claimed, unless `takeover` is set. A successful claim sets `assignee` and `claimedAt`.
    /// - Leaving `.doing` clears `assignee` and `claimedAt`.
    /// - `append` is applied in SQL (`body = body || ?`), so concurrent appends are all kept.
    /// - `expectedRev` that differs from the stored `rev` throws `.conflict`.
    public func update(id: Int64, _ patch: RecordPatch) throws -> UpdateResult {
        let checked = try CheckedPatch(patch)
        return try lock.withLock {
            let changed = try write { db in
                let changed = try applyPatch(db, id: id, checked, agent: label)
                return (changed, changed)
            }
            return try read { db in
                UpdateResult(
                    record: try fetchRecord(db, id: id), changed: changed,
                    advisories: try computeAdvisories(db, id: id, agent: label)
                )
            }
        }
    }

    /// Deletes the record with its links and versions.
    public func delete(id: Int64) throws {
        try write { db in
            guard try db.run("DELETE FROM records WHERE id = ?", [.int(id)]) > 0 else {
                throw TroyError.notFound("No record #\(id).")
            }
            return ((), true)
        }
    }

    /// Previous states, newest first.
    public func versions(of id: Int64, limit: Int = Limits.versionKeep) throws -> [RecordVersion] {
        try read { db in try fetchVersions(db, of: id, limit: limit) }
    }

    /// Tags in use, most used first. `nil` counts across every project.
    public func tags(projectID: Int64?) throws -> [TagCount] {
        try read { db in try tagCounts(db, projectID: projectID) }
    }

    // MARK: Links

    /// Links two records. For a symmetric relation the order of `from` and `to` does not matter.
    /// Linking twice returns the existing link (and updates its note when a new note is given).
    /// Throws `.invalid` for a self link, `.notFound` for a missing record, and `.conflict` naming
    /// the path when a directed relation would close a cycle.
    public func link(from: Int64, to: Int64, relation: Relation, note: String = "") throws -> RecordLink {
        let note = try TextRules.optional(note, field: "Link note", max: Limits.linkNote)
        return try write { db in
            let result = try insertLink(db, from: from, to: to, relation: relation, note: note, agent: label)
            return (result.link, result.wrote)
        }
    }

    /// Removes the link. Returns false when there was none.
    @discardableResult
    public func unlink(from: Int64, to: Int64, relation: Relation) throws -> Bool {
        try write { db in
            let (source, target) = Store.orient(from: from, to: to, relation: relation)
            let removed = try db.run(
                "DELETE FROM links WHERE source_id = ? AND target_id = ? AND relation = ?",
                [.int(source), .int(target), .text(relation.rawValue)]
            ) > 0
            return (removed, removed)
        }
    }

    public func deleteLink(id: Int64) throws {
        try write { db in
            guard try db.run("DELETE FROM links WHERE id = ?", [.int(id)]) > 0 else {
                throw TroyError.notFound("No link #\(id).")
            }
            return ((), true)
        }
    }

    /// Links touching the record: outgoing first, then by relation in `Relation.allCases` order,
    /// then newest first.
    public func links(of id: Int64) throws -> [LinkedRecord] {
        try read { db in try fetchLinks(db, of: id) }
    }

    // MARK: Search and similarity

    /// Records containing every term of `text` in the title, tags or body, ignoring case.
    /// Best match first when the index is used, otherwise title matches first, then newest.
    public func search(_ query: SearchQuery) throws -> [SearchHit] {
        try read { db in try searchRecords(db, query, useIndex: searchIndexAvailable) }
    }

    /// Existing records in the project whose title and tags resemble the given ones, best first.
    /// Compares character bigrams, so Korean particles and partial words still match.
    public func similar(
        title: String, tags: [String], projectID: Int64, excluding: Set<Int64> = [], limit: Int = 5
    ) throws -> [SimilarRecord] {
        try read { db in
            try similarRecords(db, title: title, tags: tags, projectID: projectID, excluding: excluding, limit: limit)
        }
    }

    /// What the caller should know before working on this record. Empty for finished records.
    public func advisories(for id: Int64) throws -> [Advisory] {
        try read { db in try computeAdvisories(db, id: id, agent: label) }
    }

    // MARK: Project state

    public func overview(projectID: Int64) throws -> ProjectOverview {
        try read { db in try buildOverview(db, projectID: projectID) }
    }

    /// Records (most recently updated first, at most `Limits.graphRecords`) and the links between them.
    /// `nil` loads every project.
    public func graph(projectID: Int64?) throws -> GraphSnapshot {
        try read { db in try buildGraph(db, projectID: projectID) }
    }

    // MARK: Export

    /// Everything in the project (or in every project) as Markdown, links included.
    public func exportMarkdown(projectID: Int64?) throws -> String {
        try read { db in try buildExport(db, projectID: projectID) }
    }

    // MARK: Backup

    /// Writes a complete copy of the database to `path` as one file. Safe while this or any
    /// other process is writing: the copy is the state at one moment.
    ///
    /// Copying the database file by hand is not the same. In WAL mode the most recent writes
    /// live in the `-wal` file next to it until SQLite moves them over, which can be a long
    /// time while a client or the app keeps the database open.
    ///
    /// An existing file at `path` is refused unless `replacing` is true. Refused always: the
    /// database itself with the files SQLite keeps next to it, a name that has such files of
    /// another database next to it, and a name that ends like one of them.
    public func backup(to path: String, replacing: Bool = false) throws {
        let target = (path as NSString).expandingTildeInPath
        let files = FileManager.default
        // Replacing the open database with a copy of itself would cut every other process off from
        // the file it is writing to, and leave the old log to be replayed onto the new file.
        let resolved = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
        let own = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        if filePath != ":memory:", ["", "-wal", "-shm", "-journal"].contains(where: { (own + $0).caseInsensitiveCompare(resolved) == .orderedSame }) {
            throw TroyError.invalid("\(target) is the database itself. Choose another file for the backup.")
        }
        if !replacing, files.fileExists(atPath: target) {
            throw TroyError.invalid("\(target) already exists. Choose another name, or remove it first.")
        }
        // SQLite pairs a database with its log by name alone. A backup named like a log would be
        // taken for the log of the database named before the suffix, and overwritten by it.
        if let suffix = ["-wal", "-shm", "-journal"].first(where: { target.lowercased().hasSuffix($0) }) {
            throw TroyError.invalid("\(target) cannot take the backup: SQLite reads a file whose name ends in \(suffix) as part of the database named before it. Choose another name.")
        }
        // And a log left at this name by another database, one that is open now or one that is
        // gone, would be replayed onto the backup.
        func refuseBesideAnotherDatabase() throws {
            guard let found = ["-wal", "-shm", "-journal"].map({ target + $0 }).first(where: { files.fileExists(atPath: $0) }) else { return }
            // No advice to remove the file: it can hold the latest records of that other database.
            throw TroyError.invalid("\(target) cannot take the backup: \(found) lies next to it and belongs to a database of that name, which may be open now and may keep its latest records in that file. Choose another name for the backup.")
        }
        try refuseBesideAnotherDatabase()
        // Written somewhere else until it is whole, so a copy that stops half-way never passes for
        // a backup: in a folder next to the target that the system makes for this call alone,
        // under a name nothing else has. What is removed afterwards is only ever that folder.
        var template = Array("\(target).partial-XXXXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw TroyError.database("Cannot write \(target): \(String(cString: strerror(errno)))")
        }
        let workFolder = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { try? files.removeItem(atPath: workFolder) }
        let partial = workFolder + "/copy.db"
        try lock.withLock {
            guard let db = database else { throw TroyError.database("The store is closed.") }
            do {
                try db.run("VACUUM INTO ?", [.text(partial)])
            } catch {
                throw TroyError.database("Cannot write \(target): \((error as? TroyError)?.message ?? "\(error)")")
            }
        }
        // Once more, right before the name is taken: the copy took a while to write.
        try refuseBesideAnotherDatabase()
        try Store.place(partial, at: target, replacing: replacing)
    }

    /// Moves a finished copy to its name. Unless `replacing`, it takes the name only if nothing
    /// has it, so two backups started for the same new file cannot both succeed.
    static func place(_ partial: String, at target: String, replacing: Bool, exclusiveRename: Bool = true) throws {
        func cannotWrite(_ code: Int32) -> TroyError { .database("Cannot write \(target): \(String(cString: strerror(code)))") }
        let exists = TroyError.invalid("\(target) already exists. Choose another name, or remove it first.")
        guard !replacing else {
            guard rename(partial, target) == 0 else { throw cannotWrite(errno) }
            return
        }
        #if canImport(Darwin)
        if exclusiveRename {
            // One step of the file system: the copy gets the name, or learns that it is taken.
            if renamex_np(partial, target, UInt32(RENAME_EXCL)) == 0 { return }
            let code = errno
            if code == EEXIST { throw exists }
            guard code == ENOTSUP else { throw cannotWrite(code) }
        }
        #endif
        // This volume cannot rename without replacing. Claim the name with an empty file, which
        // every file system creates in one step, and put the copy in its place straight away.
        let descriptor = open(target, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw code == EEXIST ? exists : cannotWrite(code)
        }
        try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).close()
        guard rename(partial, target) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: target)
            throw cannotWrite(code)
        }
    }

    // MARK: Plumbing

    static func cleanLabel(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(Limits.agentLabel))
    }

    /// Runs `body` under the lock with the open connection.
    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try lock.withLock {
            guard let db = database else { throw TroyError.database("The store is closed.") }
            return try db.snapshot { try body(db) }
        }
    }

    /// Runs `body` in one transaction. When it reports that it wrote something, posts the change signal after the commit.
    func write<T>(_ body: (Database) throws -> (value: T, wrote: Bool)) throws -> T {
        try lock.withLock {
            guard let db = database else { throw TroyError.database("The store is closed.") }
            let result = try db.transaction { try body(db) }
            if result.wrote {
                signalsPosted += 1
                ChangeSignal.post()
            }
            return result.value
        }
    }

    /// Checks the file, applies the pending migrations and creates the search index. Returns whether the index exists.
    private static func prepare(_ db: Database, path: String, searchIndex: Bool) throws -> Bool {
        try db.execute("PRAGMA busy_timeout = 5000")
        let applicationID: Int64
        let userVersion: Int64
        let tableCount: Int64
        do {
            // One snapshot for all three. A file that another process is setting up at this moment
            // is then seen either as empty or as finished, never as the old identity next to the
            // new version, which would look like somebody else's database.
            (applicationID, userVersion, tableCount) = try db.snapshot {
                (
                    try db.int("PRAGMA application_id") ?? 0,
                    try db.int("PRAGMA user_version") ?? 0,
                    try db.int("SELECT count(*) FROM sqlite_master") ?? 0
                )
            }
        } catch {
            if db.lastFailureWasBusy {
                throw TroyError.database("\(path) is locked by another process. Try again in a moment.")
            }
            throw TroyError.database("\(path) is not a readable SQLite database (\(error)).")
        }
        let isNew = applicationID == 0 && userVersion == 0 && tableCount == 0
        if !isNew && applicationID != Int64(Schema.applicationID) {
            throw TroyError.database("\(path) is not a Troy database. Choose another file or remove this one.")
        }
        try checkVersion(userVersion, path: path)
        // Switching a new file to WAL turns a read lock into a write lock, the one step SQLite never
        // waits in (two connections doing the same would wait on each other). When several
        // processes create the file at the same moment all but one are turned away at once, so
        // ask again: by then the file is in WAL mode and the statement has nothing left to do.
        try whileBusy(db) { try db.execute("PRAGMA journal_mode = WAL") }
        try db.execute("""
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        PRAGMA temp_store = MEMORY;
        """)
        // An up-to-date file needs no write lock to open. Asking for one anyway would make every
        // launch wait on whichever process happens to be writing.
        if Int(userVersion) < Schema.currentVersion { try db.transaction {
            let version = try db.int("PRAGMA user_version") ?? 0
            try checkVersion(version, path: path)
            guard Int(version) < Schema.currentVersion else { return }
            if version == 0 { try db.execute("PRAGMA application_id = \(Schema.applicationID)") }
            for number in Int(version)..<Schema.currentVersion {
                try db.execute(Schema.migrations[number])
            }
            try db.execute("PRAGMA user_version = \(Schema.currentVersion)")
        } }
        guard searchIndex else { return false }
        let indexParts = try db.int(
            "SELECT count(*) FROM sqlite_master WHERE name IN ('records_fts', 'records_fts_insert', 'records_fts_delete', 'records_fts_update')"
        ) ?? 0
        if indexParts == 4 { return true }
        do {
            try db.transaction {
                let existed = try db.exists("SELECT 1 FROM sqlite_master WHERE name = 'records_fts'")
                try db.execute(Schema.searchIndex)
                if !existed, try db.exists("SELECT 1 FROM records LIMIT 1") {
                    try db.execute("INSERT INTO records_fts(records_fts) VALUES('rebuild')")
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Runs `body` again while it fails because another connection holds a lock, for the steps
    /// SQLite refuses at once instead of waiting. Gives up once `busy_timeout` has passed since
    /// the first attempt; an attempt may itself wait that long inside SQLite.
    private static func whileBusy(_ db: Database, _ body: () throws -> Void) throws {
        let deadline = Date().addingTimeInterval(5)
        var pause: UInt32 = 1_000
        while true {
            do {
                return try body()
            } catch {
                let left = deadline.timeIntervalSinceNow
                guard db.lastFailureWasBusy, left > 0 else { throw error }
                usleep(min(pause + UInt32.random(in: 0...pause), UInt32(left * 1_000_000)))
                // The sleep may have run long; do not start another attempt past the deadline.
                guard Date() < deadline else { throw error }
                pause = min(pause * 2, 40_000)
            }
        }
    }

    private static func checkVersion(_ version: Int64, path: String) throws {
        if version > Int64(Schema.currentVersion) {
            throw TroyError.database(
                "\(path) was written by a newer version of Troy (schema \(version); this build understands up to \(Schema.currentVersion)). Update Troy to open it."
            )
        }
    }
}

/// Tells other processes that the database changed. Darwin notifications carry no payload;
/// receivers check `Store.dataVersion()` before reloading.
public enum ChangeSignal {
    public static let name = "dev.troy.store.changed"

    /// Posts the notification. Called by `Store` after every committed write.
    public static func post() {
        #if canImport(Darwin)
        notify_post(name)
        #endif
    }

    /// Calls `handler` on `queue` whenever any process posts the notification.
    /// Keep the returned token; pass it to `cancel` to stop. The token is -1 when registration failed.
    public static func observe(on queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> Int32 {
        #if canImport(Darwin)
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
        return status == UInt32(NOTIFY_STATUS_OK) ? token : -1
        #else
        return -1
        #endif
    }

    public static func cancel(_ token: Int32) {
        #if canImport(Darwin)
        if token >= 0 { notify_cancel(token) }
        #endif
    }
}
