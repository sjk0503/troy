import SwiftUI

/// User-visible strings of the graph canvas. Defaults are English; pass localized values.
public struct GraphCanvasLabels: Sendable, Equatable {
    public var graph: String
    public var zoomIn: String
    public var zoomOut: String
    public var fit: String

    public init(
        graph: String = "Graph", zoomIn: String = "Zoom in", zoomOut: String = "Zoom out",
        fit: String = "Fit to view"
    ) {
        self.graph = graph
        self.zoomIn = zoomIn
        self.zoomOut = zoomOut
        self.fit = fit
    }
}

/// An interactive, calm 2D node-link graph.
///
/// Pan by dragging the background; zoom with pinch, scroll or the buttons; drag a node or its title
/// to pin it; hover to see a node's neighbourhood and full title; click to select; double-click to open.
/// Keyboard (pressing the graph focuses it): arrows move the selection to the nearest node in that
/// direction, shift+arrows pan, + / - zoom, 0 fits, Return opens, Escape clears.
///
/// The canvas always renders on its own dark "night sky", whatever the app appearance.
public struct GraphCanvas: View {
    private let nodes: [GraphNode]
    private let edges: [GraphEdge]
    private let savedPositions: [Int64: CGPoint]
    private let labels: GraphCanvasLabels
    private let revealRequest: Int
    private let onOpen: (Int64) -> Void
    private let onPositionsSettled: ([Int64: CGPoint]) -> Void
    @Binding private var selection: Int64?

    @State private var controller = GraphController()
    @FocusState private var graphFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Inputs: Equatable {
        var nodes: [GraphNode]
        var edges: [GraphEdge]
    }

    public init(
        nodes: [GraphNode], edges: [GraphEdge], selection: Binding<Int64?>,
        savedPositions: [Int64: CGPoint] = [:],
        labels: GraphCanvasLabels = .init(),
        revealRequest: Int = 0,
        onOpen: @escaping (Int64) -> Void = { _ in },
        onPositionsSettled: @escaping ([Int64: CGPoint]) -> Void = { _ in }
    ) {
        self.nodes = nodes
        self.edges = edges
        self._selection = selection
        self.savedPositions = savedPositions
        self.labels = labels
        self.revealRequest = revealRequest
        self.onOpen = onOpen
        self.onPositionsSettled = onPositionsSettled
    }

    public var body: some View {
        let binding = $selection
        let _ = controller.configure(
            reduceMotion: reduceMotion, onOpen: onOpen, onSettled: onPositionsSettled,
            onSelect: { binding.wrappedValue = $0 })
        let count = controller.graph.nodes.count
        let selected = selection.flatMap { controller.graph.indexByID[$0] }
        let hovered = controller.hovered.flatMap { $0 < count ? $0 : nil }
        let frame = GraphFrame(
            graph: controller.graph, positions: controller.positions, viewport: controller.viewport,
            selected: selected, hovered: hovered)
        let store = controller.labelStore
        // Fixed contrast: the star chart is dark in both app appearances.
        let dark = true
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Canvas(opaque: true, rendersAsynchronously: false) { ctx, size in
                    store.set(GraphDrawer.draw(&ctx, size: size, frame: frame, dark: dark))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged {
                            // A press on the graph focuses the graph only; other focus is untouched.
                            if !graphFocused { graphFocused = true }
                            controller.dragChanged(start: $0.startLocation, current: $0.location)
                        }
                        .onEnded { controller.dragEnded(start: $0.startLocation, end: $0.location) }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): controller.hover(at: point)
                    case .ended: controller.hover(at: nil)
                    }
                }
                .background(
                    ScrollEventView(
                        onScroll: { controller.scrolled(at: $0, deltaY: $1, precise: $2) },
                        onMagnify: { controller.magnified(at: $0, by: $1) })
                )
                .help(hovered.map { controller.graph.nodes[$0].title } ?? "")
                .focusable()
                .focused($graphFocused)
                .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(labels.graph))
                .accessibilityChildren {
                    ForEach(controller.accessibilityIndices(selected: selection), id: \.self) { i in
                        if i < controller.graph.nodes.count {
                            let node = controller.graph.nodes[i]
                            Text(node.title)
                                .accessibilityAddTraits(node.id == selection ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { binding.wrappedValue = node.id }
                        }
                    }
                }

                hoverCard(width: geo.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                controls
            }
            .onChange(of: geo.size, initial: true) { _, size in controller.viewSizeChanged(size) }
        }
        .background(GraphPalette(dark: dark).background, ignoresSafeAreaEdges: [])
        .environment(\.colorScheme, .dark)
        .clipped()
        .onChange(of: Inputs(nodes: nodes, edges: edges), initial: true) {
            controller.sync(nodes: nodes, edges: edges, saved: savedPositions)
        }
        .onChange(of: selection) { _, new in controller.selectionChanged(to: new) }
        // Re-choosing the already selected star leaves `selection` unchanged; this brings it back.
        // If both onChange handlers fire, the second reveal is a no-op once the node is in view.
        .onChange(of: revealRequest) { controller.reveal(id: selection) }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Command and control combinations belong to the menus and the system.
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        let arrows: [KeyEquivalent: CGVector] = [
            .upArrow: CGVector(dx: 0, dy: -1), .downArrow: CGVector(dx: 0, dy: 1),
            .leftArrow: CGVector(dx: -1, dy: 0), .rightArrow: CGVector(dx: 1, dy: 0),
        ]
        if let d = arrows[press.key] {
            if press.modifiers.contains(.shift) {
                controller.pan(by: CGPoint(x: -d.dx * 60, y: -d.dy * 60))
            } else if let next = controller.neighbour(of: selection, direction: d) {
                selection = next
                controller.reveal(id: next)
            }
            return .handled
        }
        switch press.key {
        case .return:
            guard let selection else { return .ignored }
            onOpen(selection)
            return .handled
        case .escape:
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        default: break
        }
        switch press.characters {
        case "+", "=": controller.zoomBy(1.4, at: nil, animated: !reduceMotion)
        case "-", "_": controller.zoomBy(1 / 1.4, at: nil, animated: !reduceMotion)
        case "0": controller.fit(animated: !reduceMotion)
        default: return .ignored
        }
        return .handled
    }

    // MARK: Overlays

    /// The hovered node's title in a compact corner card: stationary, non-interactive, and away
    /// from the map centre. Limited to six wrapped lines; the canvas also carries the full title
    /// as a native help tooltip.
    @ViewBuilder
    private func hoverCard(width: CGFloat) -> some View {
        if let h = controller.hovered, h < controller.graph.nodes.count {
            let title = controller.graph.nodes[h].title
            GraphHoverTitle(title: title, width: width)
                .padding(12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        let solid = contrast == .increased
        return VStack(spacing: 0) {
            controlButton("plus", label: labels.zoomIn) { controller.zoomBy(1.4, at: nil, animated: !reduceMotion) }
            Divider().frame(width: 18).overlay(Color.white.opacity(0.3))
            controlButton("minus", label: labels.zoomOut) { controller.zoomBy(1 / 1.4, at: nil, animated: !reduceMotion) }
            Divider().frame(width: 18).overlay(Color.white.opacity(0.3))
            controlButton("viewfinder", label: labels.fit) { controller.fit(animated: !reduceMotion) }
        }
        .padding(.vertical, 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            if solid {
                shape.fill(Color.black)
            } else {
                shape.fill(Color.black.opacity(0.55)).background(.ultraThinMaterial, in: shape)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(solid ? 0.8 : 0.35), lineWidth: solid ? 1 : 0.5))
        .padding(12)
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(label)
    }
}

/// Compact hover preview: as tall as its text, at most six wrapped lines. The full title lives in
/// the canvas help tooltip and the inspector.
struct GraphHoverTitle: View {
    let title: String
    let width: CGFloat

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: max(100, min(300, width - 24)), alignment: .leading)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5))
    }
}
