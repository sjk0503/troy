import Foundation
import Testing
@testable import TroyCore

@Suite struct RecordTests {
    @Test func limitsAndNULAreRejectedBeforeAnythingIsWritten() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        func draft(title: String = "ok", body: String = "", tags: [String] = [], paths: [String] = []) -> RecordDraft {
            RecordDraft(projectID: p.id, kind: .note, title: title, body: body, tags: tags, paths: paths)
        }
        #expect(thrown { _ = try store.create(draft(title: "  ")) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(title: String(repeating: "t", count: Limits.title + 1))) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(body: String(repeating: "b", count: Limits.body + 1))) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(title: "a\0b")) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(body: "a\0b")) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(tags: ["a\0"])) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(paths: ["a\0"])) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(tags: (0..<21).map { "t\($0)" })) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(draft(paths: (0..<51).map { "p\($0)" })) }?.isInvalid == true)
        #expect(thrown { _ = try store.create(RecordDraft(projectID: 999, kind: .note, title: "x")) }?.isNotFound == true)
        #expect(thrown { _ = try store.create(RecordDraft(projectID: p.id, kind: .note, title: "x", links: (0..<21).map { LinkDraft(to: Int64($0 + 1), relation: .relatesTo) })) }?.isInvalid == true)
        #expect(try store.count("SELECT count(*) FROM records") == 0)
        // Exactly at the limits is fine.
        _ = try store.create(draft(title: String(repeating: "t", count: Limits.title), body: String(repeating: "b", count: Limits.body)))
        #expect(thrown { _ = try store.update(id: 1, RecordPatch(title: "a\0b")) }?.isInvalid == true)
        #expect(thrown { _ = try store.update(id: 1, RecordPatch(append: "a\0b")) }?.isInvalid == true)
        #expect(thrown { _ = try store.update(id: 1, RecordPatch(append: "more")) }?.isInvalid == true)
    }

    @Test func tagsAndPathsAreNormalizedOnStore() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "t", tags: [" Swift ", "swift", "", "Core"], paths: ["./src/", "src/**/*.ts", "docs//a.md", ""])
        #expect(r.tags == ["Swift", "Core"])
        #expect(r.paths == ["src", "docs/a.md"])
        let updated = try store.update(id: r.id, RecordPatch(tags: ["core", "Swift"], paths: ["src/x/*"]))
        #expect(updated.record.tags == ["core", "Swift"])
        #expect(updated.record.paths == ["src/x"])
        // Slashes are stored as they are, not escaped.
        #expect(try store.count("SELECT count(*) FROM records WHERE paths = '[\"src/x\"]'") == 1)
    }

    @Test func createStoresFieldsAndPreview() throws {
        let store = try Store(path: ":memory:", agent: "codex/1")
        let p = try store.makeProject()
        let body = "First line\n\n   second    line\t\ttabbed " + String(repeating: "z", count: 400)
        let r = try store.add(p, "  Title  ", kind: .decision, body: body)
        #expect(r.title == "Title")
        #expect(r.body == body)
        #expect(r.rev == 1)
        #expect(r.summary.source == "codex/1")
        #expect(r.summary.assignee == nil)
        #expect(r.summary.preview.hasPrefix("First line second line tabbed zzz"))
        #expect(r.summary.preview.count <= Limits.previewChars)
        #expect(!r.summary.preview.contains("\n"))
        let listed = try #require(try store.list(RecordQuery(projectID: p.id)).first)
        #expect(listed.preview == r.summary.preview)
    }

    @Test func createWithParentAndLinksIsAtomic() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let epic = try store.add(p, "Epic")
        let dep = try store.add(p, "Dependency")
        let saved = try store.create(RecordDraft(
            projectID: p.id, kind: .task, title: "Child", parent: epic.id,
            links: [LinkDraft(to: dep.id, relation: .dependsOn, note: "needs it"), LinkDraft(to: epic.id, relation: .partOf)]
        ))
        #expect(saved.links.count == 2)
        #expect(Set(saved.links.map(\.relation)) == [.partOf, .dependsOn])
        #expect(saved.advisories.map(\.kind) == [.unfinishedDependency])

        let before = try store.count("SELECT count(*) FROM records")
        let linksBefore = try store.count("SELECT count(*) FROM links")
        let signals = store.signalsPosted
        let error = thrown {
            _ = try store.create(RecordDraft(
                projectID: p.id, kind: .task, title: "Broken", parent: epic.id, links: [LinkDraft(to: 9999, relation: .relatesTo)]
            ))
        }
        #expect(error?.isNotFound == true)
        #expect(try store.count("SELECT count(*) FROM records") == before)
        #expect(try store.count("SELECT count(*) FROM links") == linksBefore)
        #expect(store.signalsPosted == signals)
        #expect(try store.search(SearchQuery(text: "Broken")).isEmpty)
    }

    @Test func identicalRecordFromTheSameAgentWithinTheWindowIsReturned() throws {
        let dir = TempDir()
        let a = try dir.store("agent-a")
        let b = try dir.store("agent-b")
        let p = try a.makeProject()
        let first = try a.create(RecordDraft(projectID: p.id, kind: .note, title: "Same", body: "text"))
        #expect(!first.deduplicated)
        let signals = a.signalsPosted
        let second = try a.create(RecordDraft(projectID: p.id, kind: .note, title: "Same", body: "text"))
        #expect(second.deduplicated)
        #expect(second.record.id == first.record.id)
        #expect(a.signalsPosted == signals)
        // Another agent, another body or another kind is a different record.
        #expect(try !b.create(RecordDraft(projectID: p.id, kind: .note, title: "Same", body: "text")).deduplicated)
        #expect(try !a.create(RecordDraft(projectID: p.id, kind: .note, title: "Same", body: "other")).deduplicated)
        #expect(try !a.create(RecordDraft(projectID: p.id, kind: .task, title: "Same", body: "text")).deduplicated)
        #expect(try a.count("SELECT count(*) FROM records") == 4)
        // Outside the window it is stored again.
        try a.sql("UPDATE records SET created_at = created_at - \((Limits.dedupeWindowSeconds + 5) * 1000) WHERE id = \(first.record.id)")
        #expect(try !a.create(RecordDraft(projectID: p.id, kind: .note, title: "Same", body: "text")).deduplicated)
    }

    @Test func updateThatChangesNothingWritesNothing() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "Title", body: "body", tags: ["x"], paths: ["src"])
        let signals = store.signalsPosted
        let result = try store.update(id: r.id, RecordPatch(
            title: "Title", body: "body", append: nil, kind: .task, status: .open, tags: ["x"], paths: ["./src/"], projectID: p.id
        ))
        #expect(!result.changed)
        #expect(result.record.rev == 1)
        #expect(result.record.summary.updatedAt == r.summary.updatedAt)
        #expect(try store.versions(of: r.id).isEmpty)
        #expect(try store.update(id: r.id, RecordPatch()).changed == false)
        #expect(try store.update(id: r.id, RecordPatch(append: "")).changed == false)
        #expect(store.signalsPosted == signals)
    }

    @Test func versionsHoldOnlyThePreviousValuesOfChangedFields() throws {
        let store = try Store(path: ":memory:", agent: "writer")
        let p = try store.makeProject()
        let other = try store.makeProject("other")
        let r = try store.add(p, "First", body: "body one", tags: ["t"], paths: ["src"])

        let renamed = try store.update(id: r.id, RecordPatch(title: "Second"))
        #expect(renamed.changed)
        #expect(renamed.record.rev == 2)
        _ = try store.update(id: r.id, RecordPatch(status: .done, tags: ["t", "u"]))
        _ = try store.update(id: r.id, RecordPatch(append: "more", projectID: other.id))

        let versions = try store.versions(of: r.id)
        #expect(versions.count == 3)
        // Newest first.
        let (third, second, first) = (versions[0], versions[1], versions[2])
        #expect(first.rev == 1 && second.rev == 2 && third.rev == 3)
        #expect(first.title == "First" && first.body == nil && first.status == nil && first.tags == nil)
        #expect(second.status == .open && second.tags == ["t"] && second.title == nil && second.body == nil)
        #expect(third.body == "body one" && third.projectID == p.id && third.status == nil)
        #expect(first.actor == "writer")
        let current = try store.record(id: r.id)
        #expect(current.body == "body one\n\nmore")
        #expect(current.projectID == other.id)
        #expect(current.rev == 4)
        #expect(thrown { _ = try store.versions(of: 12345) }?.isNotFound == true)
    }

    @Test func atMostVersionKeepVersionsAreKept() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "v0")
        for index in 1...(Limits.versionKeep + 12) { _ = try store.update(id: r.id, RecordPatch(title: "v\(index)")) }
        #expect(try store.count("SELECT count(*) FROM record_versions WHERE record_id = \(r.id)") == Limits.versionKeep)
        let versions = try store.versions(of: r.id)
        #expect(versions.count == Limits.versionKeep)
        #expect(versions.first?.title == "v\(Limits.versionKeep + 11)")
        #expect(try store.versions(of: r.id, limit: 3).count == 3)
    }

    @Test func updatedAtIncreasesStrictlyAndUpdatedByIsRecorded() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        var last = try store.add(p, "x").summary.updatedAt
        for index in 0..<5 {
            let next = try store.update(id: 1, RecordPatch(title: "x\(index)")).record.summary.updatedAt
            #expect(next > last)
            last = next
        }
        // Even when the stored time is in the future.
        try store.sql("UPDATE records SET updated_at = updated_at + 600000")
        let future = try store.record(id: 1).summary.updatedAt
        let bumped = try store.update(id: 1, RecordPatch(title: "later")).record.summary.updatedAt
        #expect(bumped > future)
        try store.sql("SELECT 1")
        #expect(try store.count("SELECT count(*) FROM records WHERE updated_by = 'a'") == 1)
    }

    @Test func expectedRevisionMustMatch() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "x")
        #expect(try store.update(id: r.id, RecordPatch(title: "y", expectedRev: 1)).record.rev == 2)
        let error = thrown { _ = try store.update(id: r.id, RecordPatch(title: "z", expectedRev: 1)) }
        #expect(error?.isConflict == true)
        #expect(try store.record(id: r.id).title == "y")
        #expect(thrown { _ = try store.update(id: 777, RecordPatch(title: "z")) }?.isNotFound == true)
    }

    @Test func bodyAndAppendTogetherAreInvalid() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "x", body: "keep")
        #expect(thrown { _ = try store.update(id: r.id, RecordPatch(body: "a", append: "b")) }?.isInvalid == true)
        #expect(try store.record(id: r.id).body == "keep")
        let empty = try store.add(p, "empty")
        #expect(try store.update(id: empty.id, RecordPatch(append: "first")).record.body == "first")
        #expect(try store.update(id: empty.id, RecordPatch(append: "second")).record.body == "first\n\nsecond")
    }

    @Test func appendOverTheLimitIsRejected() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let r = try store.add(p, "x", body: String(repeating: "b", count: Limits.body - 5))
        #expect(thrown { _ = try store.update(id: r.id, RecordPatch(append: "123456")) }?.isInvalid == true)
        #expect(try store.record(id: r.id).rev == 1)
        #expect(try store.update(id: r.id, RecordPatch(append: "123")).record.body.count == Limits.body - 5 + 2 + 3)
    }

    @Test func movingARecordToAnotherProject() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let a = try store.makeProject("a")
        let b = try store.makeProject("b")
        let r = try store.add(a, "moving")
        let moved = try store.update(id: r.id, RecordPatch(projectID: b.id))
        #expect(moved.record.projectID == b.id)
        #expect(try store.list(RecordQuery(projectID: a.id)).isEmpty)
        #expect(try store.list(RecordQuery(projectID: b.id)).map(\.id) == [r.id])
        #expect(thrown { _ = try store.update(id: r.id, RecordPatch(projectID: 999)) }?.isNotFound == true)
    }

    @Test func twoStoresAppendingToTheSameRecordKeepBothTexts() throws {
        let dir = TempDir()
        let one = try dir.store("one")
        let two = try dir.store("two")
        let p = try one.makeProject()
        let r = try one.add(p, "shared", body: "start")
        _ = try one.update(id: r.id, RecordPatch(append: "from one"))
        _ = try two.update(id: r.id, RecordPatch(append: "from two"))
        _ = try one.update(id: r.id, RecordPatch(append: "again one"))
        let body = try two.record(id: r.id).body
        #expect(body == "start\n\nfrom one\n\nfrom two\n\nagain one")
        // Many concurrent appends from two stores on two threads.
        let group = DispatchGroup()
        for store in [one, two] {
            group.enter()
            DispatchQueue.global().async {
                for index in 0..<20 { _ = try? store.update(id: r.id, RecordPatch(append: "\(store.agent)-\(index)")) }
                group.leave()
            }
        }
        group.wait()
        let final = try one.record(id: r.id).body
        for store in ["one", "two"] { for index in 0..<20 { #expect(final.contains("\(store)-\(index)")) } }
    }

    @Test func listFiltersSortsAndPages() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let q = try store.makeProject("q")
        let t1 = try store.add(p, "task one", tags: ["Alpha"])
        let n1 = try store.add(p, "note one", kind: .note, status: .done)
        let t2 = try store.add(p, "task two", status: .doing, tags: ["beta"])
        _ = try store.add(q, "elsewhere")
        try store.sql("UPDATE records SET created_at = id * 1000, updated_at = id * 1000")
        _ = try store.update(id: t1.id, RecordPatch(title: "task one edited"))
        #expect(try store.list(RecordQuery(projectID: p.id)).map(\.id) == [t1.id, t2.id, n1.id])
        #expect(try store.list(RecordQuery(projectID: p.id, sort: .createdDescending)).map(\.id) == [t2.id, n1.id, t1.id])
        #expect(try store.list(RecordQuery()).count == 4)
        #expect(try store.list(RecordQuery(projectID: p.id, kinds: [.note])).map(\.id) == [n1.id])
        #expect(try store.list(RecordQuery(projectID: p.id, kinds: [.note, .task], statuses: [.open, .doing])).map(\.id) == [t1.id, t2.id])
        #expect(try store.list(RecordQuery(projectID: p.id, tag: "ALPHA")).map(\.id) == [t1.id])
        #expect(try store.list(RecordQuery(projectID: p.id, limit: 1, offset: 1)).map(\.id) == [t2.id])
        #expect(try store.list(RecordQuery(limit: 0)).isEmpty)
        #expect(try store.tags(projectID: p.id).map(\.tag).sorted() == ["Alpha", "beta"])
        #expect(try store.tags(projectID: nil).count == 2)
    }

    @Test func deleteRemovesTheRecordWithItsLinksAndVersions() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let a = try store.add(p, "a")
        let b = try store.add(p, "b")
        _ = try store.link(from: a.id, to: b.id, relation: .dependsOn)
        _ = try store.update(id: a.id, RecordPatch(title: "a2"))
        try store.delete(id: a.id)
        #expect(thrown { _ = try store.record(id: a.id) }?.isNotFound == true)
        #expect(try store.links(of: b.id).isEmpty)
        #expect(try store.count("SELECT count(*) FROM record_versions") == 0)
        #expect(thrown { try store.delete(id: a.id) }?.isNotFound == true)
        try store.sql("INSERT INTO records_fts(records_fts) VALUES('integrity-check')")
    }
}
