import Foundation
import SQLite3
import Testing
@testable import TroyCore

/// One test per defect found in review, each reproducing the reported scenario.
@Suite struct ReviewFindingsTests {
    @Test func releasingAnotherAgentsClaimNeedsTakeoverToo() throws {
        let dir = TempDir()
        let first = try dir.store("claude-code/a3f")
        let second = try dir.store("codex/7c1")
        let project = try first.createProject(name: "Claims")
        let task = try first.create(RecordDraft(projectID: project.id, kind: .task, title: "Held", status: .doing)).record

        // open-then-doing must not be a way round the claim.
        for status in [RecordStatus.open, .done, .dropped, .doing] {
            let error = thrown { _ = try second.update(id: task.id, RecordPatch(status: status)) }
            #expect(error?.isConflict == true, "status \(status) was not refused")
            #expect(error?.message.contains("claude-code/a3f") == true)
        }
        #expect(try first.record(id: task.id).summary.assignee == "claude-code/a3f")

        // Other fields stay editable: a note on someone's task is not a claim.
        #expect(try second.update(id: task.id, RecordPatch(append: "Seen by codex.")).changed)
        // The holder itself, and an explicit takeover, go through.
        #expect(try second.update(id: task.id, RecordPatch(status: .done, takeover: true)).record.status == .done)
        #expect(try second.record(id: task.id).summary.assignee == nil)
    }

    @Test func aTakeoverLeavesThePreviousHolderInTheHistory() throws {
        let dir = TempDir()
        let first = try dir.store("claude-code/a3f")
        let second = try dir.store("codex/7c1")
        let project = try first.createProject(name: "History")
        let task = try first.create(RecordDraft(projectID: project.id, kind: .task, title: "Passed on")).record
        _ = try first.update(id: task.id, RecordPatch(status: .doing))
        _ = try second.update(id: task.id, RecordPatch(status: .doing, takeover: true))

        let record = try first.record(id: task.id)
        let versions = try first.versions(of: task.id)
        #expect(record.rev == 3)
        #expect(versions.map(\.rev) == [2, 1])
        #expect(versions[0].assignee == "claude-code/a3f")
        #expect(versions[0].actor == "codex/7c1")
        #expect(versions[0].status == nil)
        #expect(versions[1].status == .open)
    }

    @Test func tagsThatWouldNeedEscapingAreRefused() throws {
        let store = try Store(path: ":memory:", agent: "tester/1")
        let project = try store.createProject(name: "Tags")
        for tag in ["a\"b", "back\\slash", "tab\there"] {
            let error = thrown { _ = try store.create(RecordDraft(projectID: project.id, kind: .note, title: "memo", tags: [tag])) }
            #expect(error?.isInvalid == true, "tag \(tag.debugDescription) was accepted")
        }
        // Slashes, dots, spaces inside and Korean are ordinary tag characters, and both search paths find them.
        let saved = try store.create(RecordDraft(projectID: project.id, kind: .note, title: "memo", tags: ["ui/ux", "v1.2", "고객 인터뷰"])).record
        let plain = try Store(path: ":memory:", agent: "tester/1", searchIndex: false)
        let twin = try plain.createProject(name: "Tags")
        let copy = try plain.create(RecordDraft(projectID: twin.id, kind: .note, title: "memo", tags: ["ui/ux", "v1.2", "고객 인터뷰"])).record
        for term in ["ui/ux", "v1.2", "고객 인터뷰", "인터뷰", "ux"] {
            #expect(try store.search(SearchQuery(text: term)).map(\.id) == [saved.id], "index path missed \(term)")
            #expect(try plain.search(SearchQuery(text: term)).map(\.id) == [copy.id], "LIKE path missed \(term)")
        }
    }

    @Test(arguments: [true, false])
    func patternCharactersBeforeACombiningMarkAreStillLiteral(searchIndex: Bool) throws {
        let store = try Store(path: ":memory:", agent: "tester/1", searchIndex: searchIndex)
        let project = try store.createProject(name: "Escaping")
        let underscore = try store.create(RecordDraft(projectID: project.id, kind: .note, title: "has _\u{0301} inside")).record
        _ = try store.create(RecordDraft(projectID: project.id, kind: .note, title: "has x\u{0301} inside"))
        let quoted = try store.create(RecordDraft(projectID: project.id, kind: .note, title: "say t\"\u{0301}b loudly")).record

        #expect(try store.search(SearchQuery(text: "_\u{0301}")).map(\.id) == [underscore.id])
        #expect(try store.search(SearchQuery(text: "t\"\u{0301}b")).map(\.id) == [quoted.id])
        #expect(SearchTerms.likePattern("_\u{0301}") == "%\\_\u{0301}%")
        #expect(SearchTerms.ftsPhrase("t\"\u{0301}b") == "\"t\"\"\u{0301}b\"")
    }

    @Test func aRepeatedSaveStillChecksAndAddsItsLinks() throws {
        let store = try Store(path: ":memory:", agent: "tester/1")
        let project = try store.createProject(name: "Again")
        let parent = try store.create(RecordDraft(projectID: project.id, kind: .task, title: "Parent")).record
        let draft = RecordDraft(projectID: project.id, kind: .task, title: "Child", body: "same text")
        let first = try store.create(draft)

        var broken = draft
        broken.parent = 9_999
        #expect(thrown { _ = try store.create(broken) }?.isNotFound == true)

        var linked = draft
        linked.parent = parent.id
        let second = try store.create(linked)
        #expect(second.deduplicated)
        #expect(second.record.id == first.record.id)
        #expect(second.links.map(\.targetID) == [parent.id])
        #expect(try store.links(of: first.record.id).map(\.other.id) == [parent.id])
    }
}

@Suite struct AdvisoryNoiseTests {
    @Test func pathOverlapIsOnlyForWorkThatCanActuallyCollide() throws {
        let dir = TempDir()
        let claude = try dir.store("claude-code/184")
        let reader = try dir.store("codex/7c1")
        let project = try claude.createProject(name: "shop")
        let decision = try claude.create(RecordDraft(
            projectID: project.id, kind: .decision, title: "Split payments behind an adapter", paths: ["src/payments"])).record
        let adapter = try claude.create(RecordDraft(
            projectID: project.id, kind: .task, title: "Write the Toss adapter", paths: ["src/payments"], status: .doing)).record
        let callers = try claude.create(RecordDraft(
            projectID: project.id, kind: .task, title: "Move the callers", paths: ["src/payments"],
            links: [LinkDraft(to: adapter.id, relation: .dependsOn)])).record
        let unrelated = try claude.create(RecordDraft(
            projectID: project.id, kind: .task, title: "Refund screen", paths: ["src/payments/refund.swift"])).record

        // A decision that names the folder is in nobody's way.
        #expect(try reader.advisories(for: decision.id).isEmpty)
        // A task waiting on the busy one hears about it once, as a dependency.
        #expect(try reader.advisories(for: callers.id).map(\.kind) == [.unfinishedDependency])
        // A task with no such link still gets the overlap.
        #expect(try reader.advisories(for: unrelated.id).map(\.kind) == [.pathOverlap])
        // Once the waiting task is started anyway, both warnings apply.
        _ = try reader.update(id: callers.id, RecordPatch(status: .doing))
        #expect(Set(try reader.advisories(for: callers.id).map(\.kind)) == [.pathOverlap, .unfinishedDependency])
    }
}

@Suite struct AppReviewFindingsCoreTests {
    @Test func aSaveThatDiffersInAnythingIsANewRecord() throws {
        let store = try Store(path: ":memory:", agent: "app")
        let project = try store.createProject(name: "Dedupe")
        let draft = RecordDraft(projectID: project.id, kind: .task, title: "Same", body: "text")
        let first = try store.create(draft)
        #expect(try store.create(draft).deduplicated)

        var tagged = draft
        tagged.tags = ["urgent"]
        let second = try store.create(tagged)
        #expect(!second.deduplicated)
        #expect(second.record.id != first.record.id)
        #expect(second.record.tags == ["urgent"])

        var started = draft
        started.status = .doing
        let third = try store.create(started)
        #expect(!third.deduplicated)
        #expect(third.record.status == .doing)

        var located = draft
        located.paths = ["src"]
        #expect(try !store.create(located).deduplicated)
    }

    @Test func openingAnUpToDateFileDoesNotWaitForAWriter() throws {
        let dir = TempDir()
        let first = try dir.store("writer/1")
        _ = try first.createProject(name: "Busy")
        // Another connection holds the write lock, as a process in the middle of a save would.
        var holder: OpaquePointer?
        #expect(sqlite3_open(dir.file, &holder) == SQLITE_OK)
        defer { sqlite3_close(holder) }
        #expect(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) }

        let started = Date()
        let second = try dir.store("reader/2")
        #expect(Date().timeIntervalSince(started) < 1.5, "opening waited for the busy timeout")
        #expect(second.ftsAvailable)
        #expect(try second.projects().count == 1)
    }
}
