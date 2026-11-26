import Foundation
import Testing
@testable import TroyCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite struct SharedFileTests {
    @Test func aWriteThroughOneStoreIsVisibleThroughTheOther() throws {
        let dir = TempDir()
        let writer = try dir.store("writer")
        let reader = try dir.store("reader")
        let before = try reader.dataVersion()
        let p = try writer.makeProject("shared")
        let r = try writer.add(p, "seen by both", body: "hello")
        #expect(try reader.project(id: p.id).name == "shared")
        #expect(try reader.record(id: r.id).title == "seen by both")
        #expect(try reader.search(SearchQuery(text: "hello")).map(\.id) == [r.id])
        let after = try reader.dataVersion()
        #expect(after != before)
        // A read does not change it, a further write does.
        #expect(try reader.dataVersion() == after)
        _ = try writer.update(id: r.id, RecordPatch(title: "again"))
        #expect(try reader.dataVersion() != after)
        // The writer's own commits do not change its own counter.
        let own = try writer.dataVersion()
        _ = try writer.update(id: r.id, RecordPatch(title: "third"))
        #expect(try writer.dataVersion() == own)
    }

    @Test func eachCommittedWritePostsExactlyOneSignal() throws {
        let store = try Store(path: ":memory:", agent: "a")
        var expected = 0
        func check(_ label: String, wrote: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            if wrote { expected += 1 }
            #expect(store.signalsPosted == expected, Comment(rawValue: label), sourceLocation: sourceLocation)
        }
        let p = try store.createProject(name: "p"); check("createProject", wrote: true)
        _ = try store.updateProject(id: p.id, summary: "s"); check("updateProject", wrote: true)
        _ = try store.updateProject(id: p.id, summary: "s"); check("noop updateProject", wrote: false)
        let a = try store.add(p, "a"); check("create", wrote: true)
        let b = try store.create(RecordDraft(projectID: p.id, kind: .task, title: "b", parent: a.id, links: [LinkDraft(to: a.id, relation: .dependsOn)])).record
        check("create with links", wrote: true)
        _ = try store.update(id: a.id, RecordPatch(title: "a2")); check("update", wrote: true)
        _ = try store.update(id: a.id, RecordPatch(title: "a2")); check("noop update", wrote: false)
        _ = try store.link(from: a.id, to: b.id, relation: .relatesTo); check("link", wrote: true)
        _ = try store.link(from: a.id, to: b.id, relation: .relatesTo); check("repeat link", wrote: false)
        _ = try store.link(from: a.id, to: b.id, relation: .relatesTo, note: "why"); check("link note", wrote: true)
        try store.unlink(from: a.id, to: b.id, relation: .relatesTo); check("unlink", wrote: true)
        try store.unlink(from: a.id, to: b.id, relation: .relatesTo); check("unlink none", wrote: false)
        _ = try? store.link(from: a.id, to: a.id, relation: .partOf); check("failed link", wrote: false)
        try store.delete(id: b.id); check("delete", wrote: true)
        try store.deleteProject(id: p.id); check("deleteProject", wrote: true)
        // Reads never signal.
        _ = try store.projects(); _ = try store.search(SearchQuery(text: "x")); check("reads", wrote: false)
    }

    @Test func observersAreNotified() async throws {
        let store = try Store(path: ":memory:", agent: "a")
        let counter = Counter()
        let queue = DispatchQueue(label: "signal-test")
        let token = ChangeSignal.observe(on: queue) { counter.increment() }
        defer { ChangeSignal.cancel(token) }
        #expect(token >= 0)
        _ = try store.createProject(name: "signal")
        for _ in 0..<50 where counter.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(counter.count >= 1)
    }

    @Test func busyWritersTakeTurns() throws {
        let dir = TempDir()
        let one = try dir.store("one")
        let two = try dir.store("two")
        let p = try one.makeProject()
        let group = DispatchGroup()
        let failures = Counter()
        for store in [one, two] {
            group.enter()
            DispatchQueue.global().async {
                for index in 0..<40 {
                    do { _ = try store.create(RecordDraft(projectID: p.id, kind: .note, title: "\(store.agent) \(index)")) } catch { failures.increment() }
                }
                group.leave()
            }
        }
        group.wait()
        #expect(failures.count == 0)
        #expect(try one.count("SELECT count(*) FROM records") == 80)
        try one.sql("INSERT INTO records_fts(records_fts) VALUES('integrity-check')")
    }
}
