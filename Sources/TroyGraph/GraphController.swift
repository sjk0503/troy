import AppKit
import Observation
import SwiftUI

struct LayoutFrame: Sendable {
    var generation: Int
    var points: [CGPoint]
    var alpha: Double
    var settled: Bool
}

/// Owns the layout engine and steps it off the main thread.
actor LayoutRunner {
    private var layout: ForceLayout
    private var generation = 0

    init(layout: ForceLayout) { self.layout = layout }

    private func frame() -> LayoutFrame {
        LayoutFrame(generation: generation, points: layout.points, alpha: layout.alpha, settled: layout.isSettled)
    }

    func current() -> LayoutFrame { frame() }

    func advance(maxTicks: Int, budgetSeconds: Double) -> LayoutFrame {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budgetSeconds * 1e9)
        var ticks = 0
        while ticks < maxTicks && !layout.isSettled {
            layout.tick()
            ticks += 1
            if DispatchTime.now().uptimeNanoseconds > deadline { break }
        }
        return frame()
    }

    func update(
        nodes: [ForceLayout.Node], links: [ForceLayout.Link], saved: [Int64: CGPoint]
    ) -> LayoutFrame {
        layout.update(nodes: nodes, links: links, saved: saved)
        generation += 1
        return frame()
    }

    func pin(_ id: Int64, at point: CGPoint) {
        layout.pin(id, at: point)
        layout.reheat(0.3)
    }

    func setAlphaTarget(_ value: Double) {
        layout.alphaTarget = value
        if value > 0 { layout.reheat(value) }
    }

    func reheat(_ value: Double) { layout.reheat(value) }
}

/// Thread-safe holder of the label rectangles (node id to screen rect) of the latest draw.
final class LabelHitStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rects: [Int64: CGRect] = [:]

    func set(_ new: [Int64: CGRect]) {
        lock.lock(); rects = new; lock.unlock()
    }

    func snapshot() -> [Int64: CGRect] {
        lock.lock(); defer { lock.unlock() }
        return rects
    }
}

@MainActor
@Observable
final class GraphController {
    // Observed: the drawing reads these.
    var graph = PreparedGraph()
    var positions: [CGPoint] = []
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero
    var hovered: Int?

    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var onOpen: (Int64) -> Void = { _ in }
    @ObservationIgnored var onSettled: ([Int64: CGPoint]) -> Void = { _ in }
    @ObservationIgnored var onSelect: (Int64?) -> Void = { _ in }

    @ObservationIgnored private var runner: LayoutRunner?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tween: Task<Void, Never>?
    @ObservationIgnored private var viewSize: CGSize = .zero
    @ObservationIgnored private var autoFit = true
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private var syncToken = 0
    @ObservationIgnored private var wake = 0
    @ObservationIgnored private var notifiedSettled = false
    @ObservationIgnored private var internalSelection: Int64??
    @ObservationIgnored private var drag: DragState?
    @ObservationIgnored private var hoverOrigin: CGPoint?
    /// Label rectangles from the last draw. Written from the synchronous Canvas renderer, so it is
    /// lock-protected and not observed: drawing never mutates SwiftUI state.
    @ObservationIgnored let labelStore = LabelHitStore()
    @ObservationIgnored private var lastClick: (id: Int64, time: TimeInterval)?

    private enum DragKind {
        case pan(origin: CGPoint)
        case node(Int64, grab: CGPoint)
        case ignored
    }

    private struct DragState {
        var kind: DragKind
        /// Node id under the pointer when the press began (node or its label); nil on background.
        var initialID: Int64?
        var moved = false
        /// True once this drag raised the layout's alpha target; it must be lowered when the drag ends.
        var raisedTarget = false
    }

    var viewport: GraphViewport { GraphViewport(zoom: zoom, offset: offset) }

    // MARK: Inputs

    func configure(
        reduceMotion: Bool, onOpen: @escaping (Int64) -> Void,
        onSettled: @escaping ([Int64: CGPoint]) -> Void, onSelect: @escaping (Int64?) -> Void
    ) {
        self.reduceMotion = reduceMotion
        self.onOpen = onOpen
        self.onSettled = onSettled
        self.onSelect = onSelect
    }

    func sync(nodes: [GraphNode], edges: [GraphEdge], saved: [Int64: CGPoint]) {
        let prepared = PreparedGraph(nodes: nodes, edges: edges)
        syncToken += 1
        let token = syncToken
        if let runner {
            Task { [weak self] in
                let frame = await runner.update(nodes: prepared.layoutNodes, links: prepared.layoutLinks, saved: saved)
                guard let self, token == self.syncToken else { return }
                self.replaceGraph(prepared)
                self.positions = frame.points
                self.appliedGeneration = frame.generation
                self.notifiedSettled = false
                self.wakeLoop()
            }
        } else {
            let layout = ForceLayout(nodes: prepared.layoutNodes, links: prepared.layoutLinks, saved: saved)
            runner = LayoutRunner(layout: layout)
            replaceGraph(prepared)
            positions = layout.points
            appliedGeneration = 0
            if autoFit { fitNow() }
            wakeLoop()
        }
    }

    /// Swaps the graph and re-resolves the hovered index by id so it never points past the new arrays.
    private func replaceGraph(_ prepared: PreparedGraph) {
        let hoveredID = hovered.flatMap { $0 < graph.nodes.count ? graph.nodes[$0].id : nil }
        graph = prepared
        let remapped = hoveredID.flatMap { prepared.indexByID[$0] }
        if remapped != hovered { hovered = remapped }
        if remapped == nil { hoverOrigin = nil }
    }

    func viewSizeChanged(_ size: CGSize) {
        let first = viewSize == .zero
        viewSize = size
        if autoFit && (first || !positions.isEmpty) { fitNow() }
    }

    // MARK: Simulation loop

    private func wakeLoop() {
        wake += 1
        guard loop == nil, let runner else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seen = self.wake
                let animate = !self.reduceMotion
                let frame = await runner.advance(maxTicks: animate ? 4 : 100_000, budgetSeconds: animate ? 0.008 : 5)
                self.apply(frame)
                if frame.settled && seen == self.wake {
                    self.loop = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func apply(_ frame: LayoutFrame) {
        guard frame.generation == appliedGeneration, frame.points.count == graph.nodes.count else { return }
        positions = frame.points
        if autoFit {
            if frame.settled {
                fit(animated: true)
            } else {
                fitNow()
            }
        }
        if frame.settled && !notifiedSettled {
            notifiedSettled = true
            var result: [Int64: CGPoint] = [:]
            result.reserveCapacity(frame.points.count)
            for (i, node) in graph.nodes.enumerated() { result[node.id] = frame.points[i] }
            onSettled(result)
        }
    }

    // MARK: Viewport

    private func fitTarget() -> GraphViewport? {
        guard !positions.isEmpty, viewSize.width > 1 else { return nil }
        return GraphViewport.fit(points: positions, radii: graph.radius, titles: graph.titles, size: viewSize)
    }

    private func fitNow() {
        guard let target = fitTarget() else { return }
        tween?.cancel()
        zoom = target.zoom
        offset = target.offset
    }

    func fit(animated: Bool = true) {
        autoFit = true
        guard let target = fitTarget() else { return }
        if animated { animate(to: target) } else { fitNow() }
    }

    func userAdjustedView() {
        autoFit = false
        tween?.cancel()
    }

    func zoomBy(_ factor: CGFloat, at anchor: CGPoint?, animated: Bool = false) {
        userAdjustedView()
        let a = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = min(GraphViewport.maxZoom, max(GraphViewport.minZoom, zoom * factor))
        let ratio = newZoom / zoom
        let target = GraphViewport(
            zoom: newZoom,
            offset: CGPoint(x: a.x - (a.x - offset.x) * ratio, y: a.y - (a.y - offset.y) * ratio))
        if animated { animate(to: target) } else { zoom = target.zoom; offset = target.offset }
    }

    func scrolled(at point: CGPoint, deltaY: CGFloat, precise: Bool) {
        let k: CGFloat = precise ? 0.0045 : 0.06
        zoomBy(exp(deltaY * k), at: point)
    }

    func magnified(at point: CGPoint, by amount: CGFloat) {
        zoomBy(max(0.2, 1 + amount), at: point)
    }

    private func animate(to target: GraphViewport) {
        tween?.cancel()
        if reduceMotion {
            zoom = target.zoom
            offset = target.offset
            return
        }
        let from = viewport
        let begin = Date()
        let duration = 0.32
        tween = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(begin) / duration)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                self.zoom = from.zoom * pow(target.zoom / from.zoom, CGFloat(e))
                self.offset = CGPoint(
                    x: from.offset.x + (target.offset.x - from.offset.x) * CGFloat(e),
                    y: from.offset.y + (target.offset.y - from.offset.y) * CGFloat(e))
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Brings a node chosen from outside into view, keeping the zoom unless it is too far out.
    func reveal(id: Int64?) {
        // While the view still fits the whole graph every node is visible already. Panning here
        // would also switch auto-fit off, and a graph opened with a record selected would never fit.
        guard !autoFit else { return }
        guard let id, let i = graph.indexByID[id], i < positions.count, viewSize.width > 1 else { return }
        let world = positions[i]
        let screen = viewport.toScreen(world)
        let inner = CGRect(origin: .zero, size: viewSize).insetBy(dx: 56, dy: 56)
        let targetZoom = zoom < 0.6 ? 1.0 : zoom
        guard !inner.contains(screen) || targetZoom != zoom else { return }
        autoFit = false
        animate(to: GraphViewport(
            zoom: targetZoom,
            offset: CGPoint(x: viewSize.width / 2 - world.x * targetZoom, y: viewSize.height / 2 - world.y * targetZoom)))
    }

    // MARK: Selection (called by the view)

    func selectionChanged(to id: Int64?) {
        // The marker covers only the change caused by the click that set it; consume it so a stale
        // value can never suppress a later external selection of the same id.
        let known = internalSelection
        internalSelection = nil
        if let known, known == id { return }
        reveal(id: id)
    }

    // MARK: Keyboard

    /// The node nearest to the selected one in `direction` (screen axes, y down), or the heaviest
    /// node when nothing valid is selected.
    func neighbour(of id: Int64?, direction: CGVector) -> Int64? {
        let n = min(positions.count, graph.nodes.count)
        guard n > 0 else { return nil }
        guard let id, let i = graph.indexByID[id], i < n else {
            return graph.labelOrder.first(where: { $0 < n }).map { graph.nodes[$0].id }
        }
        var best: Int?
        var bestScore = CGFloat.infinity
        for j in 0..<n where j != i {
            let dx = positions[j].x - positions[i].x, dy = positions[j].y - positions[i].y
            let along = dx * direction.dx + dy * direction.dy
            guard along > 0 else { continue }
            let across = abs(dx * -direction.dy + dy * direction.dx)
            let score = along + 2 * across
            if score < bestScore { best = j; bestScore = score }
        }
        return best.map { graph.nodes[$0].id }
    }

    func pan(by delta: CGPoint) {
        userAdjustedView()
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
    }

    /// At most `limit` node indices for the accessibility tree: heaviest first, the selection always included.
    func accessibilityIndices(selected: Int64?, limit: Int = 300) -> [Int] {
        var result = Array(graph.labelOrder.prefix(limit))
        if let selected, let i = graph.indexByID[selected], !result.contains(i) {
            if result.count >= limit { result.removeLast() }
            result.append(i)
        }
        return result
    }

    // MARK: Pointer

    /// The node under `point`: circles first, then the labels drawn last frame, so a title selects
    /// its star as well. Stale label ids (graph reloaded since the draw) are ignored.
    func targetAt(_ point: CGPoint) -> Int? {
        if let i = nodeAt(point) { return i }
        var best: Int?
        var bestGap = CGFloat.infinity
        for (id, rect) in labelStore.snapshot() {
            guard let i = graph.indexByID[id], i < graph.nodes.count else { continue }
            let hit = rect.insetBy(dx: -4, dy: -2)
            guard hit.contains(point) else { continue }
            let gap = hypot(point.x - rect.midX, point.y - rect.midY)
            if gap < bestGap { best = i; bestGap = gap }
        }
        return best
    }

    private func stillOver(_ i: Int, _ point: CGPoint) -> Bool {
        guard i < graph.nodes.count, i < positions.count else { return false }
        if let origin = hoverOrigin, hypot(point.x - origin.x, point.y - origin.y) <= 4 { return true }
        let c = viewport.toScreen(positions[i])
        if hypot(c.x - point.x, c.y - point.y) <= max(GraphDrawer.screenRadius(graph.radius[i], zoom: zoom) + 3, 7) { return true }
        if let r = labelStore.snapshot()[graph.nodes[i].id] { return r.insetBy(dx: -4, dy: -2).contains(point) }
        return false
    }

    func nodeAt(_ point: CGPoint) -> Int? {
        let vp = viewport
        var best: Int?
        var bestGap = CGFloat.infinity
        for i in 0..<min(positions.count, graph.nodes.count) {
            let p = vp.toScreen(positions[i])
            let r = max(GraphDrawer.screenRadius(graph.radius[i], zoom: zoom) + 3, 7)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= r && d - r < bestGap {
                best = i
                bestGap = d - r
            }
        }
        return best
    }

    func hover(at point: CGPoint?) {
        guard drag == nil else { return }
        guard let point else {
            hoverOrigin = nil
            if hovered != nil { hovered = nil }
            return
        }
        // Hovering relayouts labels; keep the current node while the pointer is still on it.
        if let h = hovered, stillOver(h, point) { return }
        let target = targetAt(point)
        hoverOrigin = target == nil ? nil : point
        if target != hovered { hovered = target }
    }

    func dragChanged(start: CGPoint, current: CGPoint) {
        if drag == nil {
            if let i = targetAt(start), i < positions.count {
                let world = viewport.toWorld(start)
                let p = positions[i]
                let id = graph.nodes[i].id
                drag = DragState(
                    kind: .node(id, grab: CGPoint(x: p.x - world.x, y: p.y - world.y)), initialID: id)
                hovered = i
            } else {
                drag = DragState(kind: .pan(origin: offset), initialID: nil)
            }
        }
        guard var state = drag else { return }
        if case .node(let id, _) = state.kind, !(graph.indexByID[id].map { $0 < positions.count } ?? false) {
            // The graph was reloaded under the pointer and the node is gone.
            state.kind = .ignored
            drag = state
            return
        }
        let moved = state.moved || hypot(current.x - start.x, current.y - start.y) > 3
        let firstMove = moved && !state.moved
        state.moved = moved
        drag = state
        guard moved else { return }
        switch state.kind {
        case .pan(let origin):
            if firstMove { userAdjustedView() }
            offset = CGPoint(x: origin.x + current.x - start.x, y: origin.y + current.y - start.y)
        case .node(let id, let grab):
            guard let i = graph.indexByID[id], i < positions.count else { return }
            if firstMove {
                userAdjustedView()
                if let runner { Task { await runner.setAlphaTarget(0.3) } }
                state.raisedTarget = true
                drag = state
                notifiedSettled = false
            }
            let w = viewport.toWorld(current)
            let target = CGPoint(x: w.x + grab.x, y: w.y + grab.y)
            positions[i] = target
            if let runner { Task { await runner.pin(id, at: target) } }
            wakeLoop()
        case .ignored:
            break
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        defer { drag = nil }
        guard let state = drag else { return }
        if state.raisedTarget, let runner {
            // Also when the dragged node vanished mid-drag (kind became .ignored).
            Task { await runner.setAlphaTarget(0) }
            wakeLoop()
        }
        if case .ignored = state.kind { return }
        if state.moved { return }
        // A click acts on what was pressed, not on what the hover relayout put under the pointer now.
        let id = state.initialID.flatMap { graph.indexByID[$0] != nil ? $0 : nil }
        if state.initialID != nil && id == nil { return }
        internalSelection = .some(id)
        onSelect(id)
        let now = Date.timeIntervalSinceReferenceDate
        if let id {
            if let last = lastClick, last.id == id, now - last.time <= NSEvent.doubleClickInterval {
                lastClick = nil
                onOpen(id)
            } else {
                lastClick = (id, now)
            }
        } else {
            lastClick = nil
        }
    }
}
