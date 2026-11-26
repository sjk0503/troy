import CoreGraphics
import Foundation
import SwiftUI

enum GraphMetrics {
    /// World-space radius of a node: grows with the square root of its weight, capped.
    static func radius(weight: Double) -> Double {
        let w = weight.isFinite ? max(0, weight) : 0
        return min(18, 5.5 + 2.4 * w.squareRoot())
    }

    /// The whole title on one line: every run of whitespace or line breaks becomes a single space.
    /// Nothing is ever cut; shortening is a drawing decision made against real text metrics.
    static func normalizedTitle(_ title: String) -> String {
        title.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Label policy that does not need a graphics context: how many titles a view may show, and how a
/// title is broken into lines. Widths come from a caller-supplied `measure`, so the live canvas
/// passes real rendered text metrics and tests pass a deterministic stand-in.
enum GraphLabelLayout {
    struct Wrapped: Equatable, Sendable {
        var lines: [String]
        /// Only for exceptionally long titles: the last line ends in an ellipsis.
        var truncated: Bool
    }

    /// Titles offered a place for a canvas of `canvasArea` square points. Fewer, well placed
    /// labels beat a crowd: the count follows the area, grows a little when zoomed in, and is never
    /// more than the number of visible nodes (sparse graphs label everything).
    static func budget(canvasArea: CGFloat, zoom: CGFloat, visible: Int) -> Int {
        guard visible > 0, canvasArea > 0 else { return 0 }
        let z = Double(min(2, max(0.6, zoom)))
        let raw = Int((Double(canvasArea) / 52_000 * z).rounded())
        return min(visible, min(36, max(5, raw)))
    }

    /// Upper bound on placement attempts per frame, so 2000 nodes cost as little as 20.
    static func attempts(budget: Int, visible: Int) -> Int {
        min(visible, budget * 3 + 12)
    }

    private static let maxAnalysedCharacters = 600
    static let ellipsis = "\u{2026}"

    private struct Piece {
        var text: String
        var width: CGFloat
        /// Continues the previous piece without a space (the parts of a word too long for a line).
        var attached: Bool
    }

    /// Breaks `title` into word-aware lines, balanced so no line is left with a lone fragment.
    /// It tries `preferredWidth` first and accepts two lines, widens towards `maxWidth` and then
    /// accepts up to `maxLines`. Spaces separate words (Korean included); a word wider than
    /// `maxWidth` and text without spaces break between characters. Only past `maxLines` is the
    /// last line cut with a tail ellipsis.
    static func wrap(
        _ title: String, preferredWidth: CGFloat, maxWidth: CGFloat, maxLines: Int,
        measure: (String) -> CGFloat
    ) -> Wrapped {
        var text = GraphMetrics.normalizedTitle(title)
        guard !text.isEmpty, maxLines > 0 else { return Wrapped(lines: [], truncated: false) }
        let maxWidth = max(1, maxWidth)
        let preferred = min(max(1, preferredWidth), maxWidth)
        var cut = false
        if text.count > maxAnalysedCharacters {
            text = String(text.prefix(maxAnalysedCharacters))
            cut = true
        }
        if !cut && measure(text) <= preferred { return Wrapped(lines: [text], truncated: false) }

        let space = max(0, measure("a a") - measure("aa"))
        var pieces: [Piece] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let w = measure(String(word))
            if w <= maxWidth {
                pieces.append(Piece(text: String(word), width: w, attached: false))
            } else {
                for (k, ch) in word.enumerated() {
                    pieces.append(Piece(text: String(ch), width: measure(String(ch)), attached: k > 0))
                }
            }
        }
        let widest = pieces.map(\.width).max() ?? 0

        func greedy(_ width: CGFloat) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var start = 0
            var used: CGFloat = 0
            for i in pieces.indices {
                let add = i == start ? pieces[i].width : pieces[i].width + (pieces[i].attached ? 0 : space)
                if i > start && used + add > width {
                    out.append(start..<i)
                    start = i
                    used = pieces[i].width
                } else {
                    used += add
                }
            }
            out.append(start..<pieces.count)
            return out
        }
        func balanced(_ width: CGFloat) -> [Range<Int>] {
            let first = greedy(width)
            guard first.count > 1 else { return first }
            var lo = max(widest, width * 0.4), hi = width
            var best = first
            for _ in 0..<8 where lo < hi {
                let mid = (lo + hi) / 2
                let trial = greedy(mid)
                if trial.count == first.count { best = trial; hi = mid } else { lo = mid }
            }
            return best
        }
        func join(_ range: Range<Int>) -> String {
            var s = ""
            for i in range {
                if i > range.lowerBound && !pieces[i].attached { s += " " }
                s += pieces[i].text
            }
            return s
        }

        let candidates = [preferred, (preferred + maxWidth) / 2, maxWidth]
        var chosen: [Range<Int>] = []
        for (k, width) in candidates.enumerated() {
            let ranges = balanced(width)
            let limit = k == candidates.count - 1 ? maxLines : min(2, maxLines)
            chosen = ranges
            if ranges.count <= limit { break }
        }
        var lines = chosen.map(join)
        var truncated = false
        if lines.count > maxLines || cut {
            var keep = Array(lines.prefix(maxLines))
            let tail = lines.count > maxLines ? lines[(maxLines - 1)...].joined(separator: " ") : lines[lines.count - 1]
            keep[maxLines - 1 < keep.count ? maxLines - 1 : keep.count - 1] = tail
            lines = keep
            lines[lines.count - 1] = ellipsized(lines[lines.count - 1], maxWidth: maxWidth, measure: measure)
            truncated = true
        }
        return Wrapped(lines: lines, truncated: truncated)
    }

    /// `line` cut at the end so that it plus an ellipsis fits `maxWidth`.
    static func ellipsized(_ line: String, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
        if measure(line + ellipsis) <= maxWidth { return line + ellipsis }
        let chars = Array(line)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(chars[0..<mid]) + ellipsis) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        var head = String(chars[0..<lo])
        while head.last == " " { head.removeLast() }
        return head + ellipsis
    }
}

struct EdgeStyle: Hashable, Sendable {
    var color: Color
    var stroke: GraphStroke
    /// Width in quarter points, so near-identical widths share one path.
    var widthQuarters: Int
    var width: Double { Double(widthQuarters) / 4 }
}

struct PreparedEdge: Sendable {
    var id: Int64
    var source: Int
    var target: Int
    var style: Int
    var hasArrow: Bool
    var label: String?
    /// Signed bend in world units; zero for a straight edge. Applied along the normal of the
    /// canonical (low index to high index) direction so parallel edges fan out.
    var bend: Double
    var sourceIsLow: Bool
}

/// The immutable, indexed form of the caller's nodes and edges that drawing and hit testing use.
/// Nodes are unique and sorted by id; edges with a missing end (or equal ends) are dropped.
struct PreparedGraph: Sendable {
    var nodes: [GraphNode] = []
    var indexByID: [Int64: Int] = [:]
    var radius: [Double] = []
    var titles: [String] = []
    var edges: [PreparedEdge] = []
    var styles: [EdgeStyle] = []
    var neighbors: [[Int]] = []
    /// Number of distinct neighbours per node.
    var degree: [Int] = []
    /// Node indices by label priority (links, then being worked on; ties by id): the order in
    /// which titles are offered space.
    var labelOrder: [Int] = []
    var layoutNodes: [ForceLayout.Node] = []
    var layoutLinks: [ForceLayout.Link] = []

    static let bendStep = 20.0

    init() {}

    init(nodes input: [GraphNode], edges inputEdges: [GraphEdge]) {
        var seen = Set<Int64>()
        var unique: [GraphNode] = []
        unique.reserveCapacity(input.count)
        for node in input where seen.insert(node.id).inserted { unique.append(node) }
        unique.sort { $0.id < $1.id }
        nodes = unique
        indexByID.reserveCapacity(unique.count)
        for (i, node) in unique.enumerated() { indexByID[node.id] = i }
        radius = unique.map { GraphMetrics.radius(weight: $0.weight) }
        titles = unique.map { GraphMetrics.normalizedTitle($0.title) }
        layoutNodes = unique.enumerated().map { ForceLayout.Node(id: $1.id, radius: radius[$0], group: $1.group) }

        var styleIndex: [EdgeStyle: Int] = [:]
        var seenEdges = Set<Int64>()
        var adjacency = [Set<Int>](repeating: [], count: unique.count)
        var pairs: [Int: [Int]] = [:]
        for e in inputEdges {
            guard let s = indexByID[e.source], let t = indexByID[e.target], s != t,
                  seenEdges.insert(e.id).inserted else { continue }
            let width = e.width.isFinite ? max(0.25, min(8, e.width)) : 1
            let style = EdgeStyle(color: e.color, stroke: e.stroke, widthQuarters: Int((width * 4).rounded()))
            let si: Int
            if let existing = styleIndex[style] {
                si = existing
            } else {
                si = styles.count
                styles.append(style)
                styleIndex[style] = si
            }
            let lo = min(s, t), hi = max(s, t)
            pairs[lo * unique.count + hi, default: []].append(edges.count)
            edges.append(PreparedEdge(
                id: e.id, source: s, target: t, style: si, hasArrow: e.hasArrow,
                label: e.label, bend: 0, sourceIsLow: s < t))
            adjacency[s].insert(t)
            adjacency[t].insert(s)
            layoutLinks.append(ForceLayout.Link(source: e.source, target: e.target, strength: e.strength))
        }
        // The dictionary is only looked up, never iterated, so the result is deterministic.
        for list in pairs.values where list.count > 1 {
            for (k, edgeIndex) in list.enumerated() {
                edges[edgeIndex].bend = (Double(k) - Double(list.count - 1) / 2) * Self.bendStep
            }
        }
        neighbors = adjacency.map { $0.sorted() }
        degree = neighbors.map(\.count)
        // Most connected first; work in progress (ringed) ranks up, finished work down.
        let score: [Double] = unique.enumerated().map { i, node in
            let w = node.weight.isFinite ? max(0, node.weight) : 0
            return w + Double(degree[i]) * 0.5 + (node.isRinged ? 4 : 0) - (node.isDimmed ? 2 : 0)
        }
        labelOrder = Array(0..<unique.count).sorted {
            score[$0] != score[$1] ? score[$0] > score[$1] : unique[$0].id < unique[$1].id
        }
    }
}

/// Maps world coordinates to screen coordinates: `screen = world * zoom + offset`.
struct GraphViewport: Sendable, Equatable {
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero

    static let minZoom: CGFloat = 0.04
    static let maxZoom: CGFloat = 8

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    /// A viewport that shows every node inside `size` and uses the space it has (never zooming
    /// past `maxZoom`). It fits the circles with a modest margin: the graph should open spread
    /// across the canvas, and titles are placed around the nodes (and moved inside the canvas)
    /// when they are drawn, so they do not need to be fitted whole.
    static func fit(
        points: [CGPoint], radii: [Double], titles: [String] = [], size: CGSize, maxZoom: CGFloat = 2.6
    ) -> GraphViewport {
        guard !points.isEmpty, size.width > 1, size.height > 1 else { return GraphViewport() }
        let hasTitles = !titles.isEmpty
        let marginX = hasTitles ? min(72, max(28, size.width * 0.07)) : max(24, size.width * 0.04)
        let marginY = max(26, size.height * 0.06)
        let availW = max(40, size.width - 2 * marginX), availH = max(40, size.height - 2 * marginY)
        // Screen extent of a point at zoom z: the circle plus a title row below it.
        func bounds(_ z: CGFloat) -> CGRect {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for (i, p) in points.enumerated() {
                let r = max(3, CGFloat(radii[i]) * z)
                minX = min(minX, p.x * z - r); maxX = max(maxX, p.x * z + r)
                minY = min(minY, p.y * z - r - 2); maxY = max(maxY, p.y * z + r + (hasTitles ? 16 : 2))
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        var z: CGFloat = 1
        for _ in 0..<8 {
            let b = bounds(z)
            let next = z * min(availW / max(1, b.width), availH / max(1, b.height))
            z = min(maxZoom, max(minZoom, next))
        }
        let b = bounds(z)
        return GraphViewport(
            zoom: z,
            offset: CGPoint(x: size.width / 2 - b.midX, y: size.height / 2 - b.midY))
    }
}

public enum GraphLayoutSolver {
    /// Runs the layout engine to rest and returns the positions. Used by previews and snapshots.
    public static func settledPositions(
        nodes: [GraphNode], edges: [GraphEdge], saved: [Int64: CGPoint] = [:]
    ) -> [Int64: CGPoint] {
        let graph = PreparedGraph(nodes: nodes, edges: edges)
        var layout = ForceLayout(nodes: graph.layoutNodes, links: graph.layoutLinks, saved: saved)
        layout.settle()
        return layout.positions
    }
}
