import Foundation
import Testing
@testable import TroyCore

@Suite struct SimilarRecordTests {
    @Test func koreanTitlesWithDifferentParticlesAreSimilar() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let existing = try store.add(p, "토큰별 호출 제한")
        let unrelated = try store.add(p, "Database migration plan", tags: ["db"])
        let found = try store.similar(title: "토큰을 호출할 때 제한", tags: [], projectID: p.id)
        #expect(found.map(\.record.id) == [existing.id])
        let score = try #require(found.first?.score)
        #expect(score >= Limits.similarThreshold)
        #expect(score < Limits.duplicateThreshold)
        #expect(!found.map(\.record.id).contains(unrelated.id))
    }

    @Test func nearIdenticalTitlesScoreAsDuplicates() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let first = try store.add(p, "Add the export command")
        let saved = try store.create(RecordDraft(projectID: p.id, kind: .task, title: "Add the export command.", body: "different body"))
        let hit = try #require(saved.similar.first)
        #expect(hit.record.id == first.id)
        #expect(hit.score >= Limits.duplicateThreshold)
        #expect(saved.record.id != first.id)
        // The new record is never similar to itself.
        #expect(!saved.similar.map(\.record.id).contains(saved.record.id))
    }

    @Test func unrelatedTitlesAreNotReturnedAndOrderIsBestFirst() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let q = try store.makeProject("other")
        try store.add(p, "Quarterly marketing budget")
        let close = try store.add(p, "Retry policy for the scheduler")
        let closer = try store.add(p, "Retry policy for scheduler")
        try store.add(q, "Retry policy for the scheduler in another project")
        let found = try store.similar(title: "Retry policy for scheduler", tags: [], projectID: p.id)
        #expect(found.map(\.record.id) == [closer.id, close.id])
        #expect(found[0].score > found[1].score)
        #expect(try store.similar(title: "Zebra crossing", tags: [], projectID: p.id).isEmpty)
        #expect(try store.similar(title: "", tags: [], projectID: p.id).isEmpty)
    }

    @Test func excludingAndLimit() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let ids = try (0..<8).map { try store.add(p, "Retry policy variant \($0)").id }
        let all = try store.similar(title: "Retry policy variant", tags: [], projectID: p.id, limit: 20)
        #expect(all.count == 8)
        #expect(try store.similar(title: "Retry policy variant", tags: [], projectID: p.id).count == 5)
        let without = try store.similar(title: "Retry policy variant", tags: [], projectID: p.id, excluding: [ids[0], ids[1]], limit: 20)
        #expect(without.count == 6)
        #expect(!without.map(\.record.id).contains(ids[0]))
        #expect(try store.similar(title: "Retry policy variant", tags: [], projectID: p.id, limit: 0).isEmpty)
    }

    @Test func tagsContributeToTheScore() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let tagged = try store.add(p, "Cache invalidation", tags: ["performance", "backend"])
        let found = try store.similar(title: "Something unrelated", tags: ["performance", "backend"], projectID: p.id)
        #expect(found.first?.record.id == tagged.id)
    }
}
