import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import TroyGraph

/// Small deterministic generator so tests never depend on `random()`.
private struct Rng {
    var state: UInt64
    mutating func next(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(n))
    }
}

private func makeGraph(nodes n: Int, edges m: Int, seed: UInt64 = 1, radius: Double = 8, groups: Bool = false)
    -> ([ForceLayout.Node], [ForceLayout.Link])
{
    var rng = Rng(state: seed)
    let nodes = (0..<n).map { ForceLayout.Node(id: Int64($0 + 1), radius: radius, group: groups ? $0 % 3 : nil) }
    var links: [ForceLayout.Link] = []
    // A spanning tree first so the graph is connected, then random extras.
    for i in 1..<max(1, n) {
        links.append(.init(source: Int64(rng.next(i) + 1), target: Int64(i + 1), strength: 0.6))
    }
    while links.count < m {
        let a = rng.next(n), b = rng.next(n)
        if a != b { links.append(.init(source: Int64(a + 1), target: Int64(b + 1), strength: 0.4)) }
    }
    return (nodes, links)
}

@Suite struct ForceLayoutTests {
    @Test func deterministic() {
        let (nodes, links) = makeGraph(nodes: 60, edges: 90)
        var a = ForceLayout(nodes: nodes, links: links)
        var b = ForceLayout(nodes: nodes, links: links)
        a.settle()
        b.settle()
        #expect(a.x == b.x)
        #expect(a.y == b.y)
        // Large enough to use the Barnes-Hut tree.
        let (bn, bl) = makeGraph(nodes: 400, edges: 600, seed: 3)
        var c = ForceLayout(nodes: bn, links: bl)
        var d = ForceLayout(nodes: bn, links: bl)
        c.settle()
        d.settle()
        #expect(c.x == d.x && c.y == d.y)
    }

    @Test func settlesWithinBoundedTicks() {
        let (nodes, links) = makeGraph(nodes: 100, edges: 150)
        var layout = ForceLayout(nodes: nodes, links: links)
        var ticks = 0
        while layout.alpha >= ForceLayout.alphaMin && ticks < 1000 {
            layout.tick()
            ticks += 1
        }
        #expect(layout.alpha < ForceLayout.alphaMin)
        #expect(ticks <= 400)
        #expect(layout.isSettled)
        let before = layout.x
        layout.tick()
        #expect(layout.x == before, "a settled layout must not move")
    }

    @Test func noOverlapAfterSettling() {
        let (nodes, links) = makeGraph(nodes: 40, edges: 60, radius: 10)
        var layout = ForceLayout(nodes: nodes, links: links)
        layout.settle()
        for i in 0..<layout.count {
            for j in (i + 1)..<layout.count {
                let d = hypot(layout.x[i] - layout.x[j], layout.y[i] - layout.y[j])
                #expect(d >= layout.radii[i] + layout.radii[j] - 1e-6)
            }
        }
    }

    @Test func savedPositionsAreStartPositions() {
        let (nodes, links) = makeGraph(nodes: 10, edges: 12)
        var saved: [Int64: CGPoint] = [:]
        for n in nodes { saved[n.id] = CGPoint(x: Double(n.id) * 100, y: -Double(n.id) * 30) }
        var layout = ForceLayout(nodes: nodes, links: links, saved: saved)
        for (i, id) in layout.ids.enumerated() {
            #expect(layout.x[i] == Double(saved[id]!.x))
            #expect(layout.y[i] == Double(saved[id]!.y))
        }
        // With everything saved the layout starts cool, so it only relaxes a little.
        #expect(layout.alpha < 0.1)
        layout.tick()
        let moved = (0..<layout.count).map { hypot(layout.x[$0] - Double(saved[layout.ids[$0]]!.x), layout.y[$0] - Double(saved[layout.ids[$0]]!.y)) }
        #expect((moved.max() ?? 0) < 25)
    }

    @Test func incrementalUpdateKeepsOldPositions() {
        let (nodes, links) = makeGraph(nodes: 30, edges: 40)
        var layout = ForceLayout(nodes: nodes, links: links)
        layout.settle()
        let before = layout.positions
        var more = nodes
        more.append(.init(id: 1000, radius: 8))
        var moreLinks = links
        moreLinks.append(.init(source: 5, target: 1000))
        let changed = layout.update(nodes: more, links: moreLinks)
        #expect(changed)
        let after = layout.positions
        for (id, p) in before { #expect(after[id] == p) }
        let neighbour = before[5]!, placed = after[1000]!
        #expect(hypot(placed.x - neighbour.x, placed.y - neighbour.y) < 120, "new node starts next to its neighbour")
        #expect(!layout.isSettled, "update reheats")
        #expect(layout.alpha < 0.5, "gently, not a restart")
        layout.settle()
        var maxMove = 0.0
        for (id, p) in before { maxMove = max(maxMove, hypot(layout.positions[id]!.x - p.x, layout.positions[id]!.y - p.y)) }
        #expect(maxMove < 150, "the old layout is only nudged")
        // Same input again: nothing changes, no reheat.
        let again = layout.update(nodes: more, links: moreLinks)
        #expect(!again)
    }

    @Test func pinnedNodeStaysPut() {
        let (nodes, links) = makeGraph(nodes: 20, edges: 25)
        var layout = ForceLayout(nodes: nodes, links: links)
        layout.pin(3, at: CGPoint(x: 500, y: 500))
        layout.settle()
        #expect(layout.positions[3] == CGPoint(x: 500, y: 500))
        #expect(layout.isPinned(3))
        // Survives an update.
        layout.update(nodes: nodes + [.init(id: 99, radius: 8)], links: links)
        #expect(layout.isPinned(3))
    }

    @Test func missingEndpointsAndDuplicatesAreIgnored() {
        let nodes: [ForceLayout.Node] = [
            .init(id: 1, radius: 5), .init(id: 2, radius: 5), .init(id: 1, radius: 99), .init(id: 3, radius: 5),
        ]
        let links: [ForceLayout.Link] = [
            .init(source: 1, target: 2), .init(source: 2, target: 777), .init(source: 888, target: 1),
            .init(source: 3, target: 3),
        ]
        var layout = ForceLayout(nodes: nodes, links: links)
        #expect(layout.count == 3)
        #expect(layout.linkCount == 1)
        #expect(layout.radii[0] == 5, "the first duplicate wins")
        layout.settle()
        #expect(layout.x.allSatisfy(\.isFinite) && layout.y.allSatisfy(\.isFinite))

        let graph = PreparedGraph(
            nodes: [GraphNode(id: 1, title: "a", color: .red), GraphNode(id: 2, title: "b", color: .red)],
            edges: [
                GraphEdge(id: 1, source: 1, target: 2, color: .gray), GraphEdge(id: 2, source: 1, target: 9, color: .gray),
            ])
        #expect(graph.edges.count == 1)
    }

    @Test func groupsPullTogether() {
        // Two groups with no links at all: only the group force can tell them apart.
        let nodes = (0..<30).map { ForceLayout.Node(id: Int64($0 + 1), radius: 6, group: $0 % 2) }
        var layout = ForceLayout(nodes: nodes, links: [])
        layout.settle()
        var intra = 0.0, inter = 0.0, ni = 0.0, ne = 0.0
        for i in 0..<30 {
            for j in (i + 1)..<30 {
                let d = hypot(layout.x[i] - layout.x[j], layout.y[i] - layout.y[j])
                if i % 2 == j % 2 { intra += d; ni += 1 } else { inter += d; ne += 1 }
            }
        }
        #expect(intra / ni < inter / ne)
    }

    @Test func parallelEdgesAreBentApart() {
        let nodes = [GraphNode(id: 1, title: "a", color: .red), GraphNode(id: 2, title: "b", color: .red)]
        let edges = [
            GraphEdge(id: 1, source: 1, target: 2, color: .gray),
            GraphEdge(id: 2, source: 2, target: 1, color: .gray),
            GraphEdge(id: 3, source: 1, target: 2, color: .gray),
        ]
        let graph = PreparedGraph(nodes: nodes, edges: edges)
        #expect(Set(graph.edges.map(\.bend)).count == 3)
    }

    @Test func preparedTitlesKeepTheWholeText() {
        let korean = String(repeating: "가", count: 20) + "끝" + String(repeating: "나", count: 20)
        let english = "Investigate why the nightly export job silently drops attachments larger than ten megabytes"
        let graph = PreparedGraph(
            nodes: [
                GraphNode(id: 1, title: korean, color: .red),
                GraphNode(id: 2, title: english, color: .red),
                GraphNode(id: 3, title: "  two\n lines\t here ", color: .red),
            ], edges: [])
        #expect(graph.titles[0] == korean)
        #expect(graph.titles[1] == english)
        #expect(!graph.titles.joined().contains("\u{2026}"))
        #expect(graph.titles[2] == "two lines here")
        #expect(GraphMetrics.normalizedTitle("short") == "short")
    }

    /// Deterministic stand-in for rendered text: Hangul 16 points a character, everything else 8.
    private func fakeMeasure(_ s: String) -> CGFloat {
        s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 16 : 8) }
    }

    @Test func wrapKeepsFullEnglishAndKoreanTitlesInTwoOrThreeLines() {
        let english = "Investigate why the nightly export job drops large attachments"
        let a = GraphLabelLayout.wrap(english, preferredWidth: 150, maxWidth: 220, maxLines: 3, measure: fakeMeasure)
        #expect(!a.truncated)
        #expect((2...3).contains(a.lines.count))
        #expect(a.lines.joined(separator: " ") == english)
        #expect(a.lines.allSatisfy { fakeMeasure($0) <= 220 })

        let korean = "사용자가 로그인할 때 이중 인증 코드를 입력하도록 안내"
        let b = GraphLabelLayout.wrap(korean, preferredWidth: 150, maxWidth: 220, maxLines: 3, measure: fakeMeasure)
        #expect(!b.truncated)
        #expect((2...3).contains(b.lines.count))
        #expect(b.lines.joined(separator: " ") == korean, "wrapped on spaces, no word cut and nothing dropped")
        #expect(b.lines.allSatisfy { fakeMeasure($0) <= 220 })

        let short = GraphLabelLayout.wrap("Fix login", preferredWidth: 150, maxWidth: 220, maxLines: 3, measure: fakeMeasure)
        #expect(short.lines == ["Fix login"] && !short.truncated)
    }

    @Test func wrapBreaksTextWithoutSpacesBetweenCharacters() {
        let run = String(repeating: "가", count: 30)
        let r = GraphLabelLayout.wrap(run, preferredWidth: 150, maxWidth: 220, maxLines: 3, measure: fakeMeasure)
        #expect(!r.truncated)
        #expect(r.lines.joined() == run)
        #expect(r.lines.allSatisfy { fakeMeasure($0) <= 220 })
    }

    @Test func onlyExceptionallyLongTitlesGetATailEllipsis() {
        let huge = String(repeating: "lorem ipsum dolor ", count: 40)
        let r = GraphLabelLayout.wrap(huge, preferredWidth: 150, maxWidth: 220, maxLines: 3, measure: fakeMeasure)
        #expect(r.truncated)
        #expect(r.lines.count == 3)
        #expect(r.lines.last?.hasSuffix("\u{2026}") == true)
        #expect(r.lines.allSatisfy { fakeMeasure($0) <= 220 })
        #expect(r.lines.dropLast().allSatisfy { !$0.contains("\u{2026}") })
        #expect(huge.hasPrefix(r.lines[0]))
    }

    @Test func labelBudgetFollowsAreaAndNeverExceedsWhatIsVisible() {
        let area: CGFloat = 1000 * 700
        let crowded = GraphLabelLayout.budget(canvasArea: area, zoom: 1, visible: 2000)
        #expect(crowded >= 5 && crowded <= 36)
        #expect(GraphLabelLayout.attempts(budget: crowded, visible: 2000) <= crowded * 3 + 12)
        #expect(GraphLabelLayout.budget(canvasArea: area * 4, zoom: 1, visible: 2000) > crowded)
        #expect(GraphLabelLayout.budget(canvasArea: area, zoom: 0.3, visible: 2000) <= crowded)
        #expect(GraphLabelLayout.budget(canvasArea: area, zoom: 1, visible: 3) == 3, "a sparse graph labels everything")
        #expect(GraphLabelLayout.budget(canvasArea: area, zoom: 1, visible: 0) == 0)
    }

    @Test func labelOrderFavoursConnectedAndInProgressNodes() {
        let nodes = [
            GraphNode(id: 1, title: "hub", color: .red, weight: 3),
            GraphNode(id: 2, title: "leaf", color: .red),
            GraphNode(id: 3, title: "doing", color: .red, isRinged: true),
            GraphNode(id: 4, title: "done", color: .red, isDimmed: true),
            GraphNode(id: 5, title: "spoke", color: .red),
        ]
        let edges = [
            GraphEdge(id: 1, source: 1, target: 2, color: .gray),
            GraphEdge(id: 2, source: 1, target: 5, color: .gray),
            GraphEdge(id: 3, source: 1, target: 4, color: .gray),
        ]
        let g = PreparedGraph(nodes: nodes, edges: edges)
        #expect(g.degree[g.indexByID[1]!] == 3)
        let order = g.labelOrder.map { g.nodes[$0].id }
        #expect(order.first == 1)
        let doing = order.firstIndex(of: 3)!
        #expect(doing < order.firstIndex(of: 2)!, "work in progress outranks a plain leaf")
        #expect(order.firstIndex(of: 4)! > order.firstIndex(of: 2)!, "finished work ranks below a plain leaf")
        #expect(order.count == 5)
    }

    @Test func fitFillsTheView() {
        let pts = [CGPoint(x: -200, y: -100), CGPoint(x: 200, y: 100)]
        let size = CGSize(width: 1000, height: 700)
        let vp = GraphViewport.fit(points: pts, radii: [8, 8], titles: ["a", "b"], size: size)
        let a = vp.toScreen(pts[0]), b = vp.toScreen(pts[1])
        #expect(abs(b.x - a.x) > size.width * 0.7 || abs(b.y - a.y) > size.height * 0.7)
        let one = GraphViewport.fit(points: [.zero], radii: [8], titles: ["x"], size: size)
        #expect(one.zoom <= 2.6 + 1e-9, "a tiny graph is not gigantic")
    }

    @Test func timing2000Nodes3000Edges() {
        let (nodes, links) = makeGraph(nodes: 2000, edges: 3000, seed: 5)
        let clock = ContinuousClock()
        var layout = ForceLayout(nodes: nodes, links: links)
        // Single tick cost, averaged over a warm-up of 20 ticks.
        let tickTime = clock.measure { for _ in 0..<20 { layout.tick() } } / 20
        var fresh = ForceLayout(nodes: nodes, links: links)
        var ticks = 0
        let settleTime = clock.measure { ticks = fresh.settle() }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("TIMING (\(build)): 2000 nodes / 3000 edges: tick \(tickTime), settle \(settleTime) in \(ticks) ticks")
        #expect(fresh.isSettled)
        #if DEBUG
        #expect(settleTime < .seconds(120))
        #else
        #expect(settleTime < .seconds(10))
        #expect(tickTime < .milliseconds(30))
        #endif
    }
}
