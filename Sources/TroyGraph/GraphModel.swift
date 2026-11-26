import SwiftUI

/// One node of the graph. The graph module knows nothing about what a node stands for.
public struct GraphNode: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var color: Color
    /// SF Symbol name drawn inside the node when it is large enough on screen.
    public var symbol: String?
    /// >= 0, for example the number of links. More weight means a larger node (sub-linear).
    public var weight: Double
    /// Finished or superseded: drawn faded.
    public var isDimmed: Bool
    /// Being worked on: drawn with a ring.
    public var isRinged: Bool
    /// Nodes sharing a group are pulled gently together.
    public var group: Int?

    public init(
        id: Int64, title: String, color: Color, symbol: String? = nil, weight: Double = 0,
        isDimmed: Bool = false, isRinged: Bool = false, group: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.color = color
        self.symbol = symbol
        self.weight = weight
        self.isDimmed = isDimmed
        self.isRinged = isRinged
        self.group = group
    }
}

public enum GraphStroke: Hashable, Sendable { case solid, dashed, dotted }

public struct GraphEdge: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var source: Int64
    public var target: Int64
    public var color: Color
    public var stroke: GraphStroke
    /// Points at zoom 1.
    public var width: Double
    /// Arrowhead at the target end.
    public var hasArrow: Bool
    /// Drawn only while the edge is highlighted.
    public var label: String?
    /// 0...1, how hard the edge pulls its ends together.
    public var strength: Double

    public init(
        id: Int64, source: Int64, target: Int64, color: Color, stroke: GraphStroke = .solid,
        width: Double = 1, hasArrow: Bool = false, label: String? = nil, strength: Double = 0.5
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.color = color
        self.stroke = stroke
        self.width = width
        self.hasArrow = hasArrow
        self.label = label
        self.strength = strength
    }
}
