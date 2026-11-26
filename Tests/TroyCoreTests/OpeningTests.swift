import Foundation
import Testing
@testable import TroyCore

@Suite struct OpeningTests {
    @Test func createsFolderAndFileAndReopensIdempotently() throws {
        let dir = TempDir()
        let nested = dir.folder.appendingPathComponent("a/b/troy.db").path
        let first = try Store(path: nested, agent: "x")
        let project = try first.createProject(name: "keep")
        #expect(FileManager.default.fileExists(atPath: nested))
        #expect(try first.count("PRAGMA user_version") == Schema.currentVersion)
        #expect(try first.count("PRAGMA application_id") == Int(Schema.applicationID))
        first.close()
        let second = try Store(path: nested, agent: "x")
        #expect(try second.projects().map(\.project.id) == [project.id])
        #expect(try second.count("PRAGMA user_version") == Schema.currentVersion)
        #expect(second.ftsAvailable)
        #expect(second.path == nested)
    }

    @Test func memoryStoreWorks() throws {
        let store = try Store(path: ":memory:")
        _ = try store.createProject(name: "m")
        #expect(try store.projects().count == 1)
    }

    @Test func refusesNewerSchema() throws {
        let dir = TempDir()
        let store = try dir.store()
        try store.sql("PRAGMA user_version = 99")
        store.close()
        let error = thrown { _ = try dir.store() }
        #expect(error?.isDatabase == true)
        #expect(error?.message.contains("newer version") == true)
    }

    @Test func refusesForeignSQLiteFile() throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.folder, withIntermediateDirectories: true)
        let foreign = try Database(path: dir.file)
        try foreign.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, text TEXT); INSERT INTO notes (text) VALUES ('mine')")
        foreign.close()
        let error = thrown { _ = try dir.store() }
        #expect(error?.isDatabase == true)
        #expect(error?.message.contains("not a Troy database") == true)
        // The foreign file is left untouched.
        let again = try Database(path: dir.file)
        #expect(try again.int("SELECT count(*) FROM notes") == 1)
        #expect(try again.int("PRAGMA user_version") == 0)
    }

    @Test func refusesFileWithAnotherApplicationID() throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.folder, withIntermediateDirectories: true)
        let foreign = try Database(path: dir.file)
        try foreign.execute("PRAGMA application_id = 12345; CREATE TABLE t (a)")
        foreign.close()
        #expect(thrown { _ = try dir.store() }?.isDatabase == true)
    }

    @Test func refusesFileThatIsNotSQLite() throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.folder, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: dir.file))
        #expect(thrown { _ = try dir.store() }?.isDatabase == true)
    }

    @Test func closedStoreThrows() throws {
        let store = try Store(path: ":memory:")
        store.close()
        #expect(thrown { _ = try store.projects() }?.isDatabase == true)
    }

    @Test func buildsSearchIndexForExistingRecordsWhenEnabledLater() throws {
        let dir = TempDir()
        let plain = try dir.store(searchIndex: false)
        #expect(!plain.ftsAvailable)
        let project = try plain.makeProject()
        try plain.add(project, "Scheduler retry policy", body: "exponential backoff")
        plain.close()
        let indexed = try dir.store()
        #expect(indexed.ftsAvailable)
        #expect(try indexed.search(SearchQuery(text: "backoff")).count == 1)
        #expect(try indexed.count("SELECT count(*) FROM records_fts WHERE records_fts MATCH '\"backoff\"'") == 1)
    }

    /// A migration that has been released is never edited. Files made by the release would keep
    /// the old definition, new files would get the new one, and both would carry the same
    /// version number. Change the schema by appending to `Schema.migrations`; a change to the
    /// search index needs a step that rebuilds it in existing files. Until the first release is
    /// out, a deliberate edit just updates the numbers below.
    @Test func releasedSchemaTextIsNotEdited() {
        func fingerprint(_ text: String) -> UInt64 {
            text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        }
        #expect(Schema.migrations.map(fingerprint) == [9_133_070_589_203_232_553])
        #expect(fingerprint(Schema.searchIndex) == 15_404_093_688_809_494_747)
    }

    /// Two clients starting on a fresh machine both find no file. Whoever comes second sees it
    /// empty, finished, or anything in between, and must never take it for a foreign database.
    @Test func openingANewFileFromManyThreadsAtOnceNeverRefusesIt() throws {
        final class Messages: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [String] = []
            func add(_ text: String) { lock.withLock { list.append(text) } }
            var all: [String] { lock.withLock { list } }
        }
        let failures = Messages()
        for _ in 0..<40 {
            let dir = TempDir()
            DispatchQueue.concurrentPerform(iterations: 8) { opener in
                do {
                    let store = try Store(path: dir.file, agent: "opener/\(opener)")
                    if !store.ftsAvailable { failures.add("opener \(opener) got no search index") }
                    _ = try store.projects()
                    store.close()
                } catch {
                    failures.add("\(error)")
                }
            }
            let check = try dir.store()
            #expect(try check.count("PRAGMA user_version") == Schema.currentVersion)
            #expect(try check.count("SELECT count(*) FROM sqlite_master WHERE name = 'records_fts'") == 1)
        }
        #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
    }
}
