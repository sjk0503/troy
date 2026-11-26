import Foundation
import Testing
@testable import TroyCore

@Suite struct LinkTests {
    private func setup() throws -> (Store, Project, [Record]) {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject()
        let records = try (1...4).map { try store.add(p, "record \($0)") }
        return (store, p, records)
    }

    @Test func symmetricLinksAreStoredOnceWithTheSmallerIdFirst() throws {
        let (store, _, r) = try setup()
        let forward = try store.link(from: r[3].id, to: r[1].id, relation: .relatesTo, note: "same topic")
        #expect(forward.sourceID == r[1].id && forward.targetID == r[3].id)
        let reverse = try store.link(from: r[1].id, to: r[3].id, relation: .relatesTo)
        #expect(reverse.id == forward.id)
        #expect(reverse.note == "same topic")
        let conflict = try store.link(from: r[2].id, to: r[0].id, relation: .conflictsWith)
        #expect(conflict.sourceID == r[0].id)
        #expect(try store.count("SELECT count(*) FROM links") == 2)
        // Seen from both ends.
        #expect(try store.links(of: r[1].id).first?.other.id == r[3].id)
        let other = try #require(try store.links(of: r[3].id).first)
        #expect(other.other.id == r[1].id && other.phrase == "relates to" && !other.isOutgoing)
        // Unlinking works from either side.
        #expect(try store.unlink(from: r[3].id, to: r[1].id, relation: .relatesTo))
        #expect(try !store.unlink(from: r[1].id, to: r[3].id, relation: .relatesTo))
    }

    @Test func directedLinksAreIdempotentAndKeepTheirDirection() throws {
        let (store, _, r) = try setup()
        let signals = store.signalsPosted
        let a = try store.link(from: r[0].id, to: r[1].id, relation: .dependsOn)
        #expect(store.signalsPosted == signals + 1)
        let b = try store.link(from: r[0].id, to: r[1].id, relation: .dependsOn)
        #expect(a.id == b.id)
        #expect(store.signalsPosted == signals + 1)
        let reverse = try store.link(from: r[1].id, to: r[0].id, relation: .partOf)
        #expect(reverse.sourceID == r[1].id)
        // A different relation between the same pair is a different link.
        #expect(try store.link(from: r[0].id, to: r[1].id, relation: .derivedFrom).id != a.id)
        #expect(try store.count("SELECT count(*) FROM links") == 3)
        let out = try store.links(of: r[0].id)
        #expect(out.map(\.isOutgoing) == [true, true, false])
        #expect(out.first?.phrase == "part of" || out.first?.phrase == "depends on")
        #expect(out.last?.phrase == "part of" || out.last?.phrase == "contains")
    }

    @Test func noteIsUpdatedOnlyByANonEmptyDifferentNote() throws {
        let (store, _, r) = try setup()
        let first = try store.link(from: r[0].id, to: r[1].id, relation: .derivedFrom, note: "because")
        #expect(first.note == "because")
        #expect(try store.link(from: r[0].id, to: r[1].id, relation: .derivedFrom).note == "because")
        #expect(try store.link(from: r[0].id, to: r[1].id, relation: .derivedFrom, note: "since").note == "since")
        #expect(try store.links(of: r[0].id).first?.link.note == "since")
        #expect(thrown { _ = try store.link(from: r[0].id, to: r[2].id, relation: .relatesTo, note: String(repeating: "n", count: 241)) }?.isInvalid == true)
    }

    @Test func invalidLinks() throws {
        let (store, _, r) = try setup()
        #expect(thrown { _ = try store.link(from: r[0].id, to: r[0].id, relation: .relatesTo) }?.isInvalid == true)
        #expect(thrown { _ = try store.link(from: r[0].id, to: 999, relation: .relatesTo) }?.isNotFound == true)
        #expect(thrown { _ = try store.link(from: 999, to: r[0].id, relation: .partOf) }?.isNotFound == true)
        #expect(thrown { try store.deleteLink(id: 999) }?.isNotFound == true)
        #expect(try store.count("SELECT count(*) FROM links") == 0)
    }

    @Test(arguments: [Relation.partOf, .dependsOn, .derivedFrom, .supersedes])
    func directedCyclesAreRefusedWithTheChain(relation: Relation) throws {
        let (store, _, r) = try setup()
        _ = try store.link(from: r[0].id, to: r[1].id, relation: relation)
        _ = try store.link(from: r[1].id, to: r[2].id, relation: relation)
        _ = try store.link(from: r[2].id, to: r[3].id, relation: relation)
        let error = thrown { _ = try store.link(from: r[3].id, to: r[0].id, relation: relation) }
        #expect(error?.isConflict == true)
        let message = try #require(error?.message)
        for record in r { #expect(message.contains("#\(record.id)")) }
        #expect(message.contains("cycle"))
        #expect(try store.count("SELECT count(*) FROM links") == 3)
        // A two-record loop too.
        #expect(thrown { _ = try store.link(from: r[1].id, to: r[0].id, relation: relation) }?.isConflict == true)
        // The same loop in another relation is fine, and so is a shortcut that closes no loop.
        #expect(try store.link(from: r[3].id, to: r[0].id, relation: .relatesTo).relation == .relatesTo)
        #expect(try store.link(from: r[0].id, to: r[3].id, relation: relation).relation == relation)
    }

    @Test func severalParentsAndCrossProjectLinksAreAllowed() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let p = try store.makeProject("p")
        let q = try store.makeProject("q")
        let child = try store.add(p, "child")
        let parentOne = try store.add(p, "parent one")
        let parentTwo = try store.add(q, "parent two in another project")
        _ = try store.link(from: child.id, to: parentOne.id, relation: .partOf)
        _ = try store.link(from: child.id, to: parentTwo.id, relation: .partOf)
        let links = try store.links(of: child.id)
        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.isOutgoing })
        #expect(Set(links.map(\.other.id)) == [parentOne.id, parentTwo.id])
        // Diamond shapes are not cycles.
        let top = try store.add(q, "top")
        _ = try store.link(from: parentOne.id, to: top.id, relation: .partOf)
        _ = try store.link(from: parentTwo.id, to: top.id, relation: .partOf)
        #expect(try store.links(of: top.id).count == 2)
    }

    @Test func linksDisappearWithTheirRecordAndOnUnlink() throws {
        let (store, _, r) = try setup()
        let link = try store.link(from: r[0].id, to: r[1].id, relation: .dependsOn)
        _ = try store.link(from: r[2].id, to: r[1].id, relation: .partOf)
        #expect(try store.links(of: r[1].id).count == 2)
        try store.delete(id: r[0].id)
        #expect(try store.links(of: r[1].id).count == 1)
        #expect(try store.count("SELECT count(*) FROM links WHERE id = \(link.id)") == 0)
        let remaining = try #require(try store.links(of: r[1].id).first)
        try store.deleteLink(id: remaining.link.id)
        #expect(try store.links(of: r[1].id).isEmpty)
        #expect(try store.unlink(from: r[2].id, to: r[1].id, relation: .partOf) == false)
    }

    @Test func linkCountAndOrdering() throws {
        let (store, _, r) = try setup()
        _ = try store.link(from: r[0].id, to: r[1].id, relation: .relatesTo)
        _ = try store.link(from: r[0].id, to: r[2].id, relation: .dependsOn)
        _ = try store.link(from: r[0].id, to: r[3].id, relation: .partOf)
        _ = try store.link(from: r[1].id, to: r[0].id, relation: .derivedFrom)
        let links = try store.links(of: r[0].id)
        // Outgoing first, then relation order part_of, depends_on, relates_to; incoming last.
        #expect(links.map(\.link.relation) == [.partOf, .dependsOn, .relatesTo, .derivedFrom])
        #expect(try store.record(id: r[0].id).summary.linkCount == 4)
        #expect(try store.record(id: r[3].id).summary.linkCount == 1)
    }
}
