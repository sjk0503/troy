import Foundation
import Testing
import TroyCore
@testable import TroyMainUI

private let epoch = Date(timeIntervalSince1970: 0)

private func summary(_ id: Int64, project: Int64 = 1, title: String? = nil) -> RecordSummary {
    RecordSummary(id: id, projectID: project, kind: .note, status: .open, title: title ?? "Record \(id)",
                  createdAt: epoch, updatedAt: epoch)
}

/// A link as seen from the focus record: `outgoing` means the focus is the link's source.
private func linked(_ linkID: Int64, _ relation: Relation, other: RecordSummary, outgoing: Bool, focus: Int64 = 100) -> LinkedRecord {
    let link = RecordLink(
        id: linkID, sourceID: outgoing ? focus : other.id, targetID: outgoing ? other.id : focus,
        relation: relation, createdAt: epoch)
    return LinkedRecord(link: link, other: other, isOutgoing: outgoing)
}

private func detail(_ links: [LinkedRecord], project: Int64 = 1) -> RecordDetail {
    RecordDetail(record: Record(summary: summary(100, project: project), body: "", rev: 1), links: links)
}

@MainActor
struct LocalGraphTests {
    @Test func dependsOnSplitsIntoForwardAndInverseGroups() {
        let groups = LocalGraph.groups([
            linked(1, .dependsOn, other: summary(2, title: "Needs"), outgoing: true),
            linked(2, .dependsOn, other: summary(3, title: "Blocked"), outgoing: false),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].relation == .dependsOn && groups[0].outgoing)
        #expect(groups[0].items.map(\.other.id) == [2])
        #expect(groups[1].relation == .dependsOn && !groups[1].outgoing)
        #expect(groups[1].items.map(\.other.id) == [3])
    }

    @Test func symmetricLinksFromEitherSideShareOneGroup() {
        let groups = LocalGraph.groups([
            linked(1, .relatesTo, other: summary(2, title: "B"), outgoing: true),
            linked(2, .relatesTo, other: summary(3, title: "A"), outgoing: false),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].relation == .relatesTo && groups[0].outgoing)
        #expect(groups[0].items.map(\.other.id) == [3, 2], "sorted by title")
    }

    @Test func emptyLinksMakeNoGroups() {
        #expect(LocalGraph.groups([]).isEmpty)
    }

    @Test func sameOtherRecordInSeveralRelationsCountsOnce() {
        let other = summary(2)
        let counts = LocalGraph.counts(detail([
            linked(1, .dependsOn, other: other, outgoing: true),
            linked(2, .relatesTo, other: other, outgoing: true),
            linked(3, .derivedFrom, other: other, outgoing: false),
        ]))
        #expect(counts.links == 3)
        #expect(counts.records == 1)
        #expect(counts.otherProjectRecords == 0)
    }

    @Test func symmetricIncomingAndOutgoingOfOneRecordCoalesce() {
        let other = summary(2)
        let links = [
            linked(1, .relatesTo, other: other, outgoing: true),
            linked(2, .conflictsWith, other: other, outgoing: false),
        ]
        let counts = LocalGraph.counts(detail(links))
        #expect(counts.links == 2)
        #expect(counts.records == 1)
        #expect(LocalGraph.groups(links).map(\.relation) == [.relatesTo, .conflictsWith])
    }

    @Test func otherProjectRecordsAreDistinctRecordIDs() {
        let abroad = summary(2, project: 9)
        let counts = LocalGraph.counts(detail([
            linked(1, .dependsOn, other: abroad, outgoing: true),
            linked(2, .relatesTo, other: abroad, outgoing: true),
            linked(3, .partOf, other: summary(3, project: 9), outgoing: false),
            linked(4, .partOf, other: summary(4, project: 1), outgoing: true),
        ]))
        #expect(counts.links == 4)
        #expect(counts.records == 3)
        #expect(counts.otherProjectRecords == 2, "records 2 and 3, not three links")
    }

    @Test func sidesPutOutgoingDirectedLeftAndIncomingAndSymmetricRight() {
        let groups = LocalGraph.groups([
            linked(1, .dependsOn, other: summary(2), outgoing: true),
            linked(2, .dependsOn, other: summary(3), outgoing: false),
            linked(3, .relatesTo, other: summary(4), outgoing: true),
        ])
        let sides = LocalGraph.sides(groups)
        #expect(sides.left.map(\.relation) == [.dependsOn])
        #expect(sides.left.map(\.outgoing) == [true])
        #expect(sides.right.count == 2)
        #expect(sides.right.contains { $0.relation == .relatesTo })
    }

    @Test func balancedLayoutNeedsBothSidesWidthAndHeight() {
        let both = LocalGraph.groups([
            linked(1, .dependsOn, other: summary(2), outgoing: true),
            linked(2, .dependsOn, other: summary(3), outgoing: false),
        ])
        #expect(LocalGraph.layout(both, width: 900, height: 700) == .balanced)
        #expect(LocalGraph.layout(both, width: 800, height: 700) == .side)
        #expect(LocalGraph.layout(both, width: 900, height: 120) == .side)
        #expect(LocalGraph.layout(both, width: 500, height: 700) == .stacked)
        let oneSided = LocalGraph.groups([linked(1, .dependsOn, other: summary(2), outgoing: true)])
        #expect(LocalGraph.layout(oneSided, width: 1200, height: 900) == .side)
    }
}
