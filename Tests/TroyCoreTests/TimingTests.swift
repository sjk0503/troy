import Foundation
import Testing
@testable import TroyCore

@Suite struct TimingTests {
    @Test func fiveThousandRecords() throws {
        let dir = TempDir()
        let store = try dir.store("timing/1")
        let project = try store.makeProject("big")
        let clock = ContinuousClock()
        func measure<T>(_ label: String, _ body: () throws -> T) throws -> T {
            var result: T?
            let elapsed = try clock.measure { result = try body() }
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print("TIMING \(label): \(String(format: "%.1f", milliseconds)) ms")
            return result!
        }
        try measure("seed 5000 records (raw SQL, one transaction)") { try store.seed(project: project, count: 5000) }
        try store.sql("ANALYZE")

        let overview = try measure("overview") { try store.overview(projectID: project.id) }
        #expect(!overview.recent.isEmpty)
        let listed = try measure("list (200 newest)") { try store.list(RecordQuery(projectID: project.id)) }
        #expect(listed.count == 200)
        let all = try measure("list (1000)") { try store.list(RecordQuery(projectID: project.id, limit: 1000)) }
        #expect(all.count == 1000)
        let hits = try measure("search two terms, index") { try store.search(SearchQuery(text: "scheduler retry", projectID: project.id)) }
        #expect(!hits.isEmpty)
        let short = try measure("search two short terms, LIKE") { try store.search(SearchQuery(text: "id ab", projectID: project.id)) }
        _ = short
        let similar = try measure("similar (3000 scanned)") { try store.similar(title: "scheduler retry limit token", tags: ["store"], projectID: project.id) }
        #expect(!similar.isEmpty)
        let created = try measure("create one record (with similar + advisories)") {
            try store.create(RecordDraft(projectID: project.id, kind: .task, title: "export graph layout", paths: ["src"]))
        }
        #expect(created.record.id > 5000)
        let graph = try measure("graph") { try store.graph(projectID: project.id) }
        #expect(graph.records.count == Limits.graphRecords && graph.truncated)
        let markdown = try measure("export markdown") { try store.exportMarkdown(projectID: project.id) }
        #expect(markdown.count > 100_000)
        let plain = try dir.store("timing/2", searchIndex: false)
        let slow = try measure("search two terms, LIKE only") { try plain.search(SearchQuery(text: "scheduler retry", projectID: project.id)) }
        #expect(Set(slow.map(\.id)).count == slow.count)
    }
}
