import Foundation
import Testing
@testable import TroyCore

@Suite struct GraphExportTests {
    @Test func graphSnapshotRespectsTheProject() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject("p")
        let q = try store.makeProject("q")
        let a = try store.add(p, "a")
        let b = try store.add(p, "b", parent: a.id)
        let c = try store.add(q, "c")
        _ = try store.link(from: c.id, to: a.id, relation: .relatesTo)
        _ = try store.link(from: b.id, to: a.id, relation: .supersedes)

        let inP = try store.graph(projectID: p.id)
        #expect(Set(inP.records.map(\.id)) == [a.id, b.id])
        #expect(Set(inP.links.map(\.relation)) == [.partOf, .supersedes])
        #expect(!inP.truncated)
        #expect(inP.records.first { $0.id == a.id }?.isSuperseded == true)
        #expect(inP.records.first { $0.id == a.id }?.linkCount == 3)

        let all = try store.graph(projectID: nil)
        #expect(Set(all.records.map(\.id)) == [a.id, b.id, c.id])
        #expect(all.links.count == 3)
        #expect(thrown { _ = try store.graph(projectID: 999) }?.isNotFound == true)
        #expect(try store.graph(projectID: try store.makeProject("empty").id).records.isEmpty)
    }

    @Test func graphIsCappedAndKeepsOnlyLinksBetweenLoadedRecords() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        try store.seed(project: p, count: Limits.graphRecords + 5)
        // Record 1 is the oldest and falls outside the cap; link it to a record that is inside.
        try store.sql("UPDATE records SET updated_at = id")
        _ = try store.link(from: 1, to: Int64(Limits.graphRecords + 5), relation: .relatesTo)
        _ = try store.link(from: Int64(Limits.graphRecords), to: Int64(Limits.graphRecords + 5), relation: .relatesTo)
        let graph = try store.graph(projectID: p.id)
        #expect(graph.records.count == Limits.graphRecords)
        #expect(graph.truncated)
        #expect(graph.records.first?.id == Int64(Limits.graphRecords + 5))
        #expect(graph.links.count == 1)
        #expect(!graph.records.contains { $0.id == 1 })
    }

    @Test func markdownExportContainsEveryRecordAndLink() throws {
        let store = try Store(path: ":memory:", agent: "claude-code/a3f")
        let p = try store.makeProject("Troy", paths: ["/work/troy"])
        let q = try store.makeProject("Side")
        _ = try store.updateProject(id: p.id, summary: "Memory for agents")
        let epic = try store.add(p, "Native rewrite", body: "The plan.\n\nSecond paragraph.", tags: ["core", "swift"], paths: ["Sources/TroyCore"])
        let child = try store.add(p, "Write the store", status: .doing, body: "Details 한국어", parent: epic.id)
        let old = try store.add(p, "Old idea", kind: .decision)
        let new = try store.add(p, "New idea", kind: .decision)
        _ = try store.link(from: new.id, to: old.id, relation: .supersedes, note: "better")
        let side = try store.add(q, "Side note", kind: .note, body: "elsewhere")
        _ = try store.link(from: side.id, to: child.id, relation: .relatesTo)

        let markdown = try store.exportMarkdown(projectID: nil)
        for record in try store.list(RecordQuery()) {
            #expect(markdown.contains("#\(record.id) \(record.title)"))
            #expect(markdown.contains(record.kind.rawValue))
        }
        #expect(markdown.contains("The plan.\n\nSecond paragraph."))
        #expect(markdown.contains("Details 한국어"))
        #expect(markdown.contains("tags: core, swift"))
        #expect(markdown.contains("paths: Sources/TroyCore"))
        #expect(markdown.contains("status: doing by claude-code/a3f"))
        #expect(markdown.contains("superseded"))
        #expect(markdown.contains("## Project #\(p.id) Troy"))
        #expect(markdown.contains("## Project #\(q.id) Side"))
        #expect(markdown.contains("Memory for agents"))
        #expect(markdown.contains("/work/troy"))
        #expect(markdown.contains("## Links"))
        #expect(markdown.contains("#\(child.id) part_of #\(epic.id)"))
        #expect(markdown.contains("#\(new.id) supersedes #\(old.id) — better"))
        #expect(markdown.contains("#\(child.id) relates_to #\(side.id)"))
        // Grouped by project: the Side record comes after the Troy project heading and its records.
        let troyAt = try #require(markdown.range(of: "## Project #\(p.id)"))
        let sideAt = try #require(markdown.range(of: "## Project #\(q.id)"))
        let noteAt = try #require(markdown.range(of: "#\(side.id) Side note"))
        #expect(troyAt.lowerBound < sideAt.lowerBound && sideAt.lowerBound < noteAt.lowerBound)

        let onlySide = try store.exportMarkdown(projectID: q.id)
        #expect(onlySide.contains("Side note"))
        #expect(!onlySide.contains("Native rewrite"))
        #expect(onlySide.contains("#\(child.id) relates_to #\(side.id)"))
        #expect(!onlySide.contains("supersedes"))
        #expect(thrown { _ = try store.exportMarkdown(projectID: 999) }?.isNotFound == true)
        let empty = try Store(path: ":memory:").exportMarkdown(projectID: nil)
        #expect(empty.contains("0 projects"))
    }
}
