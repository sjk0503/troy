import Foundation
import Testing
@testable import TroyCore

@Suite struct DerivedStateTests {
    @Test func supersededIsDerivedFromLinksAndNeverChangesStatus() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let a = try store.add(p, "A: old plan", kind: .decision, status: .doing)
        let b = try store.add(p, "B: new plan", kind: .decision)
        let c = try store.add(p, "C: newer plan", kind: .decision)
        let revision = try store.record(id: a.id).rev

        _ = try store.link(from: b.id, to: a.id, relation: .supersedes)
        _ = try store.link(from: c.id, to: a.id, relation: .supersedes)
        var current = try store.record(id: a.id)
        #expect(current.summary.isSuperseded)
        #expect(current.status == .doing)
        #expect(!(try store.record(id: b.id).summary.isSuperseded))
        #expect(try store.list(RecordQuery(projectID: p.id, includeSuperseded: false)).map(\.id).contains(a.id) == false)
        #expect(try store.list(RecordQuery(projectID: p.id, includeSuperseded: true)).map(\.id).contains(a.id))

        #expect(try store.unlink(from: b.id, to: a.id, relation: .supersedes))
        current = try store.record(id: a.id)
        #expect(current.summary.isSuperseded)
        #expect(current.status == .doing)

        #expect(try store.unlink(from: c.id, to: a.id, relation: .supersedes))
        current = try store.record(id: a.id)
        #expect(!current.summary.isSuperseded)
        #expect(current.status == .doing)
        #expect(current.summary.assignee == "a")
        #expect(current.rev == revision)
        #expect(try store.versions(of: a.id).isEmpty)
        // A symmetric or other relation does not supersede.
        _ = try store.link(from: b.id, to: a.id, relation: .derivedFrom)
        #expect(!(try store.record(id: a.id).summary.isSuperseded))
    }
}

@Suite struct AdvisoryTests {
    @Test func equalPathsOverlap() throws {
        let dir = TempDir()
        let mine = try dir.store("me/1")
        let theirs = try dir.store("them/2")
        let p = try mine.makeProject()
        let busy = try theirs.add(p, "their work", status: .doing, paths: ["src/Store.swift"])
        let saved = try mine.create(RecordDraft(projectID: p.id, kind: .task, title: "my work", paths: ["./src/Store.swift"]))
        let advisory = try #require(saved.advisories.first)
        #expect(saved.advisories.count == 1)
        #expect(advisory.kind == .pathOverlap)
        #expect(advisory.other.id == busy.id)
        #expect(advisory.detail == "src/Store.swift")
        // Claiming it keeps the advisory and reads the same from the other side.
        let claimed = try mine.update(id: saved.record.id, RecordPatch(status: .doing))
        #expect(claimed.advisories.map(\.other.id) == [busy.id])
        #expect(try theirs.advisories(for: busy.id).map(\.other.id) == [saved.record.id])
        #expect(try theirs.detail(id: busy.id).advisories.count == 1)
    }

    @Test func ancestorFolderAndCutBackGlobOverlap() throws {
        let dir = TempDir()
        let mine = try dir.store("me/1")
        let theirs = try dir.store("them/2")
        let p = try mine.makeProject()
        _ = try theirs.add(p, "folder work", status: .doing, paths: ["src"])
        let nested = try mine.add(p, "nested", paths: ["src/core/a.swift"])
        #expect(try mine.advisories(for: nested.id).first?.detail == "src/core/a.swift")
        let glob = try mine.add(p, "glob", paths: ["src/**/*.swift"])
        #expect(glob.paths == ["src"])
        #expect(try mine.advisories(for: glob.id).map(\.kind) == [.pathOverlap])
        let sibling = try mine.add(p, "sibling", paths: ["srcs/other.swift", "docs"])
        #expect(try mine.advisories(for: sibling.id).isEmpty)
        // Another project is never compared.
        let q = try mine.makeProject("elsewhere")
        let far = try mine.add(q, "far", paths: ["src"])
        #expect(try mine.advisories(for: far.id).isEmpty)
    }

    @Test func noAdvisoryForTheSameAgentOrFinishedRecords() throws {
        let dir = TempDir()
        let mine = try dir.store("me/1")
        let again = try dir.store("me/1")
        let theirs = try dir.store("them/2")
        let p = try mine.makeProject()
        let own = try mine.add(p, "own", status: .doing, paths: ["src"])
        let sameLabel = try again.add(p, "same label", paths: ["src/a"])
        #expect(try again.advisories(for: sameLabel.id).isEmpty)
        #expect(try mine.advisories(for: own.id).isEmpty)

        let held = try theirs.add(p, "theirs", status: .doing, paths: ["lib"])
        let finished = try mine.add(p, "finished", status: .done, paths: ["lib"])
        #expect(try mine.advisories(for: finished.id).isEmpty)
        let dropped = try mine.add(p, "dropped", status: .dropped, paths: ["lib"])
        #expect(try mine.advisories(for: dropped.id).isEmpty)
        let open = try mine.add(p, "open", paths: ["lib/x"])
        #expect(try mine.advisories(for: open.id).map(\.other.id) == [held.id])
        // Once the other work is finished it no longer collides.
        _ = try theirs.update(id: held.id, RecordPatch(status: .done))
        #expect(try mine.advisories(for: open.id).isEmpty)
        // A finished record gets none even when something else is doing the same paths.
        let busy = try theirs.add(p, "busy", status: .doing, paths: ["lib"])
        #expect(try mine.advisories(for: open.id).map(\.other.id) == [busy.id])
        _ = try mine.update(id: open.id, RecordPatch(status: .done))
        #expect(try mine.advisories(for: open.id).isEmpty)
    }

    @Test func unfinishedDependency() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let base = try store.add(p, "base")
        let top = try store.add(p, "top")
        _ = try store.link(from: top.id, to: base.id, relation: .dependsOn, note: "needs the schema")
        let advisories = try store.advisories(for: top.id)
        #expect(advisories.count == 1)
        #expect(advisories.first?.kind == .unfinishedDependency)
        #expect(advisories.first?.other.id == base.id)
        #expect(advisories.first?.detail == "needs the schema")
        // The dependency itself has nothing to be told.
        #expect(try store.advisories(for: base.id).isEmpty)
        _ = try store.update(id: base.id, RecordPatch(status: .done))
        #expect(try store.advisories(for: top.id).isEmpty)
        _ = try store.update(id: base.id, RecordPatch(status: .open))
        #expect(try store.advisories(for: top.id).count == 1)
        _ = try store.update(id: base.id, RecordPatch(status: .dropped))
        #expect(try store.advisories(for: top.id).isEmpty)
    }

    @Test func conflictLinks() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let one = try store.add(p, "one", kind: .decision)
        let two = try store.add(p, "two", kind: .decision)
        _ = try store.link(from: two.id, to: one.id, relation: .conflictsWith, note: "opposite choices")
        for (mine, other) in [(one, two), (two, one)] {
            let advisories = try store.advisories(for: mine.id)
            #expect(advisories.map(\.kind) == [.conflict])
            #expect(advisories.first?.other.id == other.id)
            #expect(advisories.first?.detail == "opposite choices")
        }
        _ = try store.update(id: two.id, RecordPatch(status: .done))
        #expect(try store.advisories(for: one.id).isEmpty)
        #expect(try store.advisories(for: two.id).isEmpty)
        #expect(thrown { _ = try store.advisories(for: 999) }?.isNotFound == true)
    }
}
