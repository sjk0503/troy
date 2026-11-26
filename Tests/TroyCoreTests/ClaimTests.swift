import Foundation
import Testing
@testable import TroyCore

@Suite struct ClaimTests {
    @Test func claimingAndLeaving() throws {
        let dir = TempDir()
        let first = try dir.store("codex/a1f")
        let second = try dir.store("claude-code/9f2")
        let p = try first.makeProject()
        let r = try first.add(p, "work")

        let claimed = try first.update(id: r.id, RecordPatch(status: .doing))
        #expect(claimed.record.status == .doing)
        #expect(claimed.record.summary.assignee == "codex/a1f")
        #expect(claimed.record.summary.claimedAt != nil)

        // Same agent again: nothing to write.
        let again = try first.update(id: r.id, RecordPatch(status: .doing))
        #expect(!again.changed)
        #expect(again.record.summary.claimedAt == claimed.record.summary.claimedAt)

        let error = thrown { _ = try second.update(id: r.id, RecordPatch(status: .doing)) }
        #expect(error?.isConflict == true)
        #expect(error?.message.contains("codex/a1f") == true)
        #expect(error?.message.contains("#\(r.id)") == true)
        // The message says when the claim was made: "claimed just now", "claimed 2h ago".
        #expect(error?.message.contains("claimed just now") == true)
        #expect(try second.record(id: r.id).summary.assignee == "codex/a1f")

        // Other changes by another agent are not claims.
        #expect(try second.update(id: r.id, RecordPatch(title: "renamed")).record.summary.assignee == "codex/a1f")

        let taken = try second.update(id: r.id, RecordPatch(status: .doing, takeover: true))
        #expect(taken.changed)
        #expect(taken.record.summary.assignee == "claude-code/9f2")

        let done = try second.update(id: r.id, RecordPatch(status: .done))
        #expect(done.record.status == .done)
        #expect(done.record.summary.assignee == nil)
        #expect(done.record.summary.claimedAt == nil)

        // Free again: anyone can claim.
        #expect(try first.update(id: r.id, RecordPatch(status: .doing)).record.summary.assignee == "codex/a1f")
        let released = try first.update(id: r.id, RecordPatch(status: .open))
        #expect(released.record.summary.assignee == nil && released.record.summary.claimedAt == nil)
    }

    @Test func creatingAsDoingClaimsForTheCreator() throws {
        let store = try Store(path: ":memory:", agent: "codex/1")
        let p = try store.makeProject()
        let r = try store.add(p, "straight to work", status: .doing)
        #expect(r.summary.assignee == "codex/1")
        #expect(r.summary.claimedAt != nil)
        let done = try store.add(p, "done already", status: .done)
        #expect(done.summary.assignee == nil)
    }

    @Test func staleClaimsStillConflictAndShowTheirAge() throws {
        let dir = TempDir()
        let first = try dir.store("a")
        let second = try dir.store("b")
        let p = try first.makeProject()
        let r = try first.add(p, "old", status: .doing)
        try first.sql("UPDATE records SET claimed_at = claimed_at - 7200000")
        let error = thrown { _ = try second.update(id: r.id, RecordPatch(status: .doing)) }
        #expect(error?.message.contains("2h") == true)
    }
}
