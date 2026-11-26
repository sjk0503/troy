import Foundation
import Testing
@testable import TroyCore

@Suite struct OverviewTests {
    @Test func everySection() throws {
        let dir = TempDir()
        let mine = try dir.store("me/1")
        let theirs = try dir.store("them/2")
        let p = try mine.makeProject("demo", paths: ["/work/demo"])

        let epic = try mine.add(p, "Epic", status: .done)
        let ready = try mine.add(p, "Ready task", parent: epic.id)
        let base = try mine.add(p, "Base task")
        let blocked = try mine.add(p, "Blocked task", links: [LinkDraft(to: base.id, relation: .dependsOn)])
        let finishedDependency = try mine.add(p, "Finished dependency", status: .done)
        let notBlocked = try mine.add(p, "Not blocked", links: [LinkDraft(to: finishedDependency.id, relation: .dependsOn)])
        let mineDoing = try mine.add(p, "My work", status: .doing, paths: ["src"])
        let theirDoing = try theirs.add(p, "Their work", status: .doing, paths: ["src/core"])
        let blockedAndDoing = try mine.add(p, "Doing but waiting", status: .doing, links: [LinkDraft(to: base.id, relation: .dependsOn)])

        let keeper = try mine.add(p, "Keep SQLite", kind: .decision)
        let oldDecision = try mine.add(p, "Use JSON files", kind: .decision, status: .done)
        let dropped = try mine.add(p, "Use CoreData", kind: .decision, status: .dropped)
        let newer = try mine.add(p, "Use SQLite", kind: .decision, status: .done)
        _ = try mine.link(from: newer.id, to: oldDecision.id, relation: .supersedes)

        let clashOne = try mine.add(p, "Rewrite UI", kind: .decision)
        let clashTwo = try mine.add(p, "Keep UI", kind: .decision)
        _ = try mine.link(from: clashOne.id, to: clashTwo.id, relation: .conflictsWith, note: "contradict")

        let note = try mine.add(p, "Plain note", kind: .note)
        let result = try mine.add(p, "A result", kind: .result, status: .done)
        let other = try mine.makeProject("other")
        try mine.add(other, "Not in demo")
        // Deterministic recency: the later the id, the newer the record, except the note which is newest.
        try mine.sql("UPDATE records SET created_at = id * 1000, updated_at = id * 1000")
        try mine.sql("UPDATE records SET updated_at = 900000 WHERE id = \(note.id)")

        let overview = try mine.overview(projectID: p.id)
        #expect(overview.project.id == p.id)
        #expect(overview.stats.records == 17)
        #expect(overview.kindCounts[.task] == 9)
        #expect(overview.kindCounts[.decision] == 6)
        #expect(overview.kindCounts[.note] == 1)
        #expect(overview.kindCounts[.result] == 1)
        #expect(overview.kindCounts[.prompt] == nil)

        // Doing: oldest claim first.
        #expect(Set(overview.doing.map(\.id)) == [mineDoing.id, theirDoing.id, blockedAndDoing.id])
        #expect(overview.doing.map(\.claimedAt) == overview.doing.map(\.claimedAt).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })

        // Ready: open tasks waiting on nothing (or only on finished work).
        #expect(overview.ready.map(\.id) == [ready.id, base.id, notBlocked.id])

        // Blocked.
        #expect(overview.blocked.map(\.record.id) == [blocked.id, blockedAndDoing.id])
        #expect(overview.blocked.first?.waitingOn.map(\.id) == [base.id])

        // Collisions: the explicit conflict and the overlapping paths of two agents.
        let kinds = Dictionary(grouping: overview.collisions, by: \.kind)
        #expect(kinds[.conflict]?.count == 1)
        #expect(Set([kinds[.conflict]?.first?.first.id, kinds[.conflict]?.first?.second.id].compactMap { $0 }) == [clashOne.id, clashTwo.id])
        #expect(kinds[.conflict]?.first?.detail == "contradict")
        #expect(kinds[.pathOverlap]?.count == 1)
        let overlap = try #require(kinds[.pathOverlap]?.first)
        #expect(Set([overlap.first.id, overlap.second.id]) == [mineDoing.id, theirDoing.id])
        #expect(overlap.detail == "src/core")

        // Decisions in effect: not dropped, not superseded, newest first.
        let decisionIDs = overview.decisions.map(\.id)
        #expect(decisionIDs == [clashTwo.id, clashOne.id, newer.id, keeper.id])
        #expect(!decisionIDs.contains(dropped.id) && !decisionIDs.contains(oldDecision.id))

        // Recent: never repeats what is listed above.
        let listed = Set(overview.doing.map(\.id) + overview.ready.map(\.id) + overview.blocked.map(\.record.id)
            + overview.decisions.map(\.id) + overview.collisions.flatMap { [$0.first.id, $0.second.id] })
        #expect(overview.recent.allSatisfy { !listed.contains($0.id) })
        #expect(overview.recent.first?.id == note.id)
        let recentIDs = Set(overview.recent.map(\.id))
        #expect(recentIDs.isSuperset(of: [note.id, result.id, epic.id, dropped.id, oldDecision.id]))
        #expect(recentIDs.contains(finishedDependency.id))
        #expect(overview.recent.count <= Limits.overviewRecent)
        // No record from another project appears anywhere.
        let everything = overview.doing + overview.ready + overview.blocked.map(\.record) + overview.decisions + overview.recent
        #expect(everything.allSatisfy { $0.projectID == p.id })

        // Parents of listed records.
        #expect(overview.parents[ready.id] == [epic.id])
        #expect(overview.parents[base.id] == nil)
        #expect(overview.parents.keys.allSatisfy { everything.map(\.id).contains($0) })
    }

    @Test func sectionsAreCappedAtTheirLimits() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        for index in 0..<40 { try store.add(p, "task \(index)") }
        for index in 0..<30 { try store.add(p, "decision \(index)", kind: .decision) }
        for index in 0..<30 { try store.add(p, "note \(index)", kind: .note) }
        let overview = try store.overview(projectID: p.id)
        #expect(overview.ready.count == Limits.overviewReady)
        #expect(overview.decisions.count == Limits.overviewDecisions)
        #expect(overview.recent.count == Limits.overviewRecent)
        #expect(overview.stats.openTasks == 40)
        #expect(thrown { _ = try store.overview(projectID: 999) }?.isNotFound == true)
        let empty = try store.overview(projectID: try store.makeProject("empty").id)
        #expect(empty.doing.isEmpty && empty.ready.isEmpty && empty.recent.isEmpty && empty.parents.isEmpty)
    }
}

@Suite struct ReadyListTests {
    @Test func aReplacedTaskIsNotReady() throws {
        let store = try Store(path: ":memory:", agent: "tester/1")
        let project = try store.createProject(name: "Ready")
        let old = try store.create(RecordDraft(projectID: project.id, kind: .task, title: "Write the importer by hand")).record
        let kept = try store.create(RecordDraft(projectID: project.id, kind: .task, title: "Polish the settings screen")).record
        #expect(try store.overview(projectID: project.id).ready.map(\.id) == [old.id, kept.id])

        let newer = try store.create(RecordDraft(
            projectID: project.id, kind: .task, title: "Generate the importer from the schema",
            links: [LinkDraft(to: old.id, relation: .supersedes)])).record
        #expect(try store.overview(projectID: project.id).ready.map(\.id) == [kept.id, newer.id])

        // Removing the link brings the old task back exactly as it was.
        try store.unlink(from: newer.id, to: old.id, relation: .supersedes)
        #expect(try store.overview(projectID: project.id).ready.map(\.id) == [old.id, kept.id, newer.id])
    }
}
