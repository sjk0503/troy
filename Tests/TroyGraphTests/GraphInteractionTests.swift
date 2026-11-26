import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import TroyGraph

/// Click and hover behaviour of node captions. Everything is assigned by hand: no layout run,
/// no window, no timing.
@MainActor
@Suite struct GraphInteractionTests {
    /// Ids are deliberately not 0-based indices, so an id/index mix-up shows up as a wrong node.
    private static let idA: Int64 = 10
    private static let idB: Int64 = 20
    private static let posA = CGPoint(x: 100, y: 100)
    private static let posB = CGPoint(x: 400, y: 300)

    private final class Recorder {
        var selected: [Int64?] = []
        var opened: [Int64] = []
    }

    private func makeController() -> (GraphController, Recorder) {
        let controller = GraphController()
        let recorder = Recorder()
        controller.configure(
            reduceMotion: true,
            onOpen: { recorder.opened.append($0) },
            onSettled: { _ in },
            onSelect: { recorder.selected.append($0) })
        controller.graph = PreparedGraph(
            nodes: [
                GraphNode(id: Self.idA, title: "Alpha", color: .blue),
                GraphNode(id: Self.idB, title: "Beta", color: .green),
            ],
            edges: [])
        // Zoom 1 and zero offset: screen coordinates equal world coordinates.
        controller.positions = [Self.posA, Self.posB]
        return (controller, recorder)
    }

    private func click(_ controller: GraphController, at point: CGPoint, between: () -> Void = {}) {
        controller.dragChanged(start: point, current: point)
        between()
        controller.dragEnded(start: point, end: point)
    }

    @Test func clickOnLabelSelectsItsNodeEvenIfRectsChangeBeforeMouseUp() {
        let (controller, recorder) = makeController()
        let labelA = CGRect(x: 150, y: 92, width: 80, height: 16)
        let labelB = CGRect(x: 450, y: 292, width: 80, height: 16)
        controller.labelStore.set([Self.idA: labelA, Self.idB: labelB])

        let press = CGPoint(x: labelA.midX, y: labelA.midY)
        click(controller, at: press) {
            // A hover relayout moves the captions; B's caption now sits under the pointer.
            controller.labelStore.set([Self.idB: labelA, Self.idA: labelB])
        }

        #expect(recorder.selected == [Self.idA])
    }

    @Test func hoverOverLabelResolvesTheMappedNodeId() throws {
        let (controller, _) = makeController()
        let labelB = CGRect(x: 450, y: 292, width: 80, height: 16)
        controller.labelStore.set([Self.idB: labelB])

        controller.hover(at: CGPoint(x: labelB.midX, y: labelB.midY))

        let index = try #require(controller.hovered)
        #expect(controller.graph.nodes[index].id == Self.idB)
    }

    @Test func clickOnStaleLabelRectDoesNotSelectAnotherNode() {
        let (controller, recorder) = makeController()
        let stale = CGRect(x: 250, y: 190, width: 80, height: 16)
        // 999 is not in the graph any more: the graph was reloaded after the last draw.
        controller.labelStore.set([999: stale])
        let point = CGPoint(x: stale.midX, y: stale.midY)

        controller.hover(at: point)
        click(controller, at: point)

        #expect(controller.hovered == nil)
        #expect(recorder.selected == [nil])
        #expect(recorder.opened.isEmpty)
    }

    @Test func circleWinsOverAnOverlappingCaption() throws {
        let (controller, recorder) = makeController()
        // B's caption is drawn right over A's circle.
        let overlapping = CGRect(x: Self.posA.x - 40, y: Self.posA.y - 8, width: 80, height: 16)
        controller.labelStore.set([Self.idB: overlapping])

        #expect(controller.targetAt(Self.posA) == controller.graph.indexByID[Self.idA])

        click(controller, at: Self.posA)
        #expect(recorder.selected == [Self.idA])

        // Away from the circle, the same caption still belongs to B.
        let edge = CGPoint(x: overlapping.maxX - 2, y: overlapping.midY)
        #expect(controller.targetAt(edge) == controller.graph.indexByID[Self.idB])
    }

    @Test func hoverTitleHugsItsContent() throws {
        func height(_ title: String) throws -> Int {
            let renderer = ImageRenderer(content: GraphHoverTitle(title: title, width: 800))
            renderer.proposedSize = ProposedViewSize(width: 800, height: 450)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return image.height
        }
        let short = try height("Short")
        let long = try height(String(repeating: "한", count: 240))
        #expect(short > 0)
        #expect(short < 80)
        #expect(long > short)
        #expect(long <= 450)
    }
}
