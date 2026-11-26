import Foundation
import Testing
@testable import TroyCore

@Suite struct BackupTests {
    /// While a client or the app keeps the database open, the newest writes are in the `-wal`
    /// file, and the database file alone can be as good as empty. The backup must not be.
    @Test func aBackupIsOneCompleteFileWhileTheLatestWritesAreStillInTheLog() throws {
        let dir = TempDir()
        let store = try dir.store()
        let project = try store.makeProject("kept", paths: ["/tmp/kept"])
        let first = try store.add(project, "First", body: "alpha body", tags: ["sync"])
        let second = try store.add(project, "Second", links: [LinkDraft(to: first.id, relation: .dependsOn)])
        _ = try store.update(id: first.id, RecordPatch(title: "First, renamed"))

        let copies = dir.folder.appendingPathComponent("copies").path
        try FileManager.default.createDirectory(atPath: copies, withIntermediateDirectories: true)
        try store.backup(to: copies + "/backup.db")
        // One file: nothing beside it is needed to read it, and nothing half-written is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: copies) == ["backup.db"])

        let copy = try Store(path: copies + "/backup.db", agent: "restored")
        #expect(try copy.count("PRAGMA application_id") == Int(Schema.applicationID))
        #expect(try copy.count("PRAGMA user_version") == Schema.currentVersion)
        #expect(try copy.projects().map(\.project.name) == ["kept"])
        #expect(try copy.project(id: project.id).paths == ["/tmp/kept"])
        #expect(try copy.record(id: first.id).title == "First, renamed")
        #expect(try copy.links(of: second.id).map(\.other.id) == [first.id])
        #expect(try copy.versions(of: first.id).count == 1)
        #expect(copy.ftsAvailable)
        #expect(try copy.search(SearchQuery(text: "alpha")).map(\.id) == [first.id])
        // The copy is its own database from here on.
        _ = try copy.add(project, "Only in the copy")
        #expect(try store.count("SELECT count(*) FROM records") == 2)
    }

    @Test func aBackupDoesNotReplaceAFileUnlessAsked() throws {
        let dir = TempDir()
        let store = try dir.store()
        _ = try store.makeProject("kept")
        let target = dir.folder.appendingPathComponent("existing.db").path
        try "not a backup".write(toFile: target, atomically: true, encoding: .utf8)

        #expect(thrown { try store.backup(to: target) }?.isInvalid == true)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "not a backup")

        try store.backup(to: target, replacing: true)
        #expect(try Store(path: target).projects().map(\.project.name) == ["kept"])
    }

    /// Replacing the open database with a copy of itself would cut the other processes off from
    /// the file they write to. The save panel in Settings lets a person pick exactly that file.
    @Test func theDatabaseItselfIsNeverTheTarget() throws {
        let dir = TempDir()
        let store = try dir.store()
        let project = try store.makeProject("kept")
        _ = try store.add(project, "Still here")
        let link = dir.folder.appendingPathComponent("link.db").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.file)
        let upper = dir.folder.appendingPathComponent("TROY.DB").path
        for target in [dir.file, dir.file + "-wal", dir.file + "-shm", link, upper] {
            let error = thrown { try store.backup(to: target, replacing: true) }
            #expect(error?.isInvalid == true, "\(target)")
            #expect(error?.message.contains("the database itself") == true, "\(target)")
        }
        _ = try store.add(project, "After")
        #expect(try dir.store().count("SELECT count(*) FROM records") == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.folder.path).sorted() == ["link.db", "troy.db", "troy.db-shm", "troy.db-wal"])
    }

    /// Several backups started for the same new file: the name is claimed in one step, so
    /// exactly one of them writes it and the others are told it exists.
    @Test func onlyOneOfSeveralBackupsToTheSameNewFileSucceeds() throws {
        final class Tally: @unchecked Sendable {
            private let lock = NSLock()
            private var done = 0, refused = 0, other: [String] = []
            func record(_ error: TroyError?) {
                lock.withLock {
                    if let error { if error.isInvalid { refused += 1 } else { other.append(error.message) } } else { done += 1 }
                }
            }
            var result: (done: Int, refused: Int, other: [String]) { lock.withLock { (done, refused, other) } }
        }
        for _ in 0..<10 {
            let dir = TempDir()
            let stores = try (0..<6).map { index -> Store in
                let store = try Store(path: dir.folder.appendingPathComponent("source-\(index).db").path, agent: "a")
                _ = try store.makeProject("project \(index)")
                return store
            }
            let target = dir.folder.appendingPathComponent("backup.db").path
            let tally = Tally()
            DispatchQueue.concurrentPerform(iterations: stores.count) { index in
                tally.record(thrown { try stores[index].backup(to: target) })
            }
            #expect(tally.result.done == 1)
            #expect(tally.result.refused == stores.count - 1)
            #expect(tally.result.other.isEmpty, "\(tally.result.other)")
            // The one that won is a whole database, not the empty file that claimed the name.
            #expect(try Store(path: target).projects().count == 1)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.folder.path).filter { $0.contains("partial") }
            #expect(left.isEmpty)
        }
    }

    /// The way a finished copy gets its name on volumes that cannot rename without replacing.
    @Test func withoutAnExclusiveRenameTheNameIsClaimedFirst() throws {
        final class Tally: @unchecked Sendable {
            private let lock = NSLock()
            private var done = 0, refused = 0
            func record(_ error: TroyError?) { lock.withLock { if error == nil { done += 1 } else if error?.isInvalid == true { refused += 1 } } }
            var result: (done: Int, refused: Int) { lock.withLock { (done, refused) } }
        }
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.folder, withIntermediateDirectories: true)
        let target = dir.folder.appendingPathComponent("backup.db").path
        let partials = try (0..<6).map { index -> String in
            let path = dir.folder.appendingPathComponent("partial-\(index)").path
            try "copy \(index)".write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        let tally = Tally()
        DispatchQueue.concurrentPerform(iterations: partials.count) { index in
            tally.record(thrown { try Store.place(partials[index], at: target, replacing: false, exclusiveRename: false) })
        }
        #expect(tally.result.done == 1)
        #expect(tally.result.refused == partials.count - 1)
        // The winner's copy is what has the name, and the losers still have theirs.
        #expect(try String(contentsOfFile: target, encoding: .utf8).hasPrefix("copy "))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.folder.path).count == partials.count)
        // Replacing is the plain rename.
        try Store.place(partials.first { FileManager.default.fileExists(atPath: $0) }!, at: target, replacing: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.folder.path).count == partials.count - 1)
    }

    @Test func aBackupThatCannotBeWrittenSaysWhere() throws {
        let dir = TempDir()
        let store = try dir.store()
        let target = dir.folder.appendingPathComponent("no/such/folder/backup.db").path
        let error = thrown { try store.backup(to: target) }
        #expect(error?.isDatabase == true)
        #expect(error?.message.contains(target) == true)
    }

    /// SQLite pairs a database with its log by name alone. A backup put where the log of another
    /// database lies would be read together with that log, and show the other database's records.
    @Test func aBackupIsNotPutNextToAnotherDatabasesLog() throws {
        let dir = TempDir()
        let a = try Store(path: dir.folder.appendingPathComponent("a.db").path, agent: "a")
        _ = try a.makeProject("A only")
        let other = dir.folder.appendingPathComponent("b.db").path
        let b = try Store(path: other, agent: "b")
        _ = try b.makeProject("B only")  // still in b.db-wal, and b stays open

        let error = thrown { try a.backup(to: other, replacing: true) }
        #expect(error?.isInvalid == true)
        #expect(error?.message.contains("b.db-wal") == true)
        // That file can hold the other database's latest records, so nobody is told to remove it.
        #expect(error?.message.lowercased().contains("remove") == false)
        // Nothing was replaced: b is what it was, for its own connection and for a new one.
        #expect(try b.projects().map(\.project.name) == ["B only"])
        #expect(try Store(path: other).projects().map(\.project.name) == ["B only"])

        // What a database that is gone has left behind counts as well.
        let gone = dir.folder.appendingPathComponent("gone.db").path
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: gone + "-wal"))
        #expect(thrown { try a.backup(to: gone) }?.isInvalid == true)
        #expect(!FileManager.default.fileExists(atPath: gone))

        // With the other database closed and its files removed, the name is free to take.
        b.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: other + suffix) }
        try a.backup(to: other, replacing: true)
        #expect(try Store(path: other).projects().map(\.project.name) == ["A only"])
    }

    /// The other way round: a backup that is itself named like a log. The database named before
    /// the suffix would take it for its own log the next time it is written to.
    @Test func aBackupIsNotNamedLikeTheLogOfADatabase() throws {
        let dir = TempDir()
        let a = try Store(path: dir.folder.appendingPathComponent("a.db").path, agent: "a")
        _ = try a.makeProject("A only")
        let other = dir.folder.appendingPathComponent("b.db").path
        let b = try Store(path: other, agent: "b")
        _ = try b.makeProject("B only")
        b.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: other + suffix) }

        for name in ["b.db-wal", "b.db-shm", "b.db-journal", "anything-WAL"] {
            let target = dir.folder.appendingPathComponent(name).path
            let error = thrown { try a.backup(to: target, replacing: true) }
            #expect(error?.isInvalid == true, "\(name)")
            #expect(!FileManager.default.fileExists(atPath: target), "\(name)")
        }
        // The other database is untouched and can be written to again.
        let again = try Store(path: other, agent: "b")
        _ = try again.makeProject("B second")
        #expect(try again.projects().map(\.project.name).sorted() == ["B only", "B second"])
    }

    /// The unfinished copy is a file the backup made for itself. When the copy fails, that file
    /// goes and everything else in the folder stays as it was.
    @Test func aFailedBackupRemovesOnlyItsOwnUnfinishedFile() throws {
        let dir = TempDir()
        let store = try dir.store()
        _ = try store.makeProject("kept")
        let copies = dir.folder.appendingPathComponent("copies").path
        try FileManager.default.createDirectory(atPath: copies, withIntermediateDirectories: true)
        // Files that look like another backup's unfinished copy, and an ordinary neighbour.
        for name in ["backup.db.partial-AAAAAAAA", "backup.db.partial-00000000", "notes.txt"] {
            try "someone else's".write(toFile: copies + "/" + name, atomically: true, encoding: .utf8)
        }
        store.close()
        #expect(thrown { try store.backup(to: copies + "/backup.db") }?.isDatabase == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copies).sorted()
            == ["backup.db.partial-00000000", "backup.db.partial-AAAAAAAA", "notes.txt"])
        for name in ["backup.db.partial-AAAAAAAA", "backup.db.partial-00000000", "notes.txt"] {
            #expect(try String(contentsOfFile: copies + "/" + name, encoding: .utf8) == "someone else's")
        }
    }
}
