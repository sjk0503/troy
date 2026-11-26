import SwiftUI

/// The graph is always drawn on flat pure black, whatever the surrounding UI looks like.
struct GraphPalette {
    var background: Color
    var border: Color
    var text: Color
    var accent: Color
    /// Backing of a label: charcoal, a little blue.
    var surface: Color

    init(dark: Bool) {
        background = Color(red: 0, green: 0, blue: 0)
        border = Color.white.opacity(0.38)
        text = Color(red: 0.98, green: 0.96, blue: 0.90)
        accent = Color(red: 0.36, green: 0.88, blue: 1.0)
        surface = Color(red: 0.070, green: 0.080, blue: 0.115)
    }
}

/// Everything the drawing needs, as plain values, so the same code serves the live canvas and
/// the static previews.
struct GraphFrame: Sendable {
    var graph: PreparedGraph
    var positions: [CGPoint]
    var viewport: GraphViewport
    var selected: Int?
    var hovered: Int?
}

enum GraphDrawer {
    static func screenRadius(_ world: Double, zoom: CGFloat) -> CGFloat {
        max(3, CGFloat(world) * zoom)
    }

    private struct Batch {
        var line = Path()
        var arrows = Path()
    }

    private struct Geometry {
        var start: CGPoint
        var end: CGPoint
        var control: CGPoint
        var curved: Bool
        var direction: CGPoint
    }

    private static func unit(_ a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = max(0.0001, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: dx / l, y: dy / l)
    }

    /// Draws the frame and returns the on-screen rect of every node title drawn, keyed by node id
    /// (the box that holds the text and its backing). Empty when nothing is drawn.
    ///
    /// Label placement depends on the selection and the geometry only, never on the hovered
    /// node, so the title under the pointer does not move. Hover changes edge and node emphasis.
    @discardableResult
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, frame: GraphFrame, dark: Bool) -> [Int64: CGRect] {
        let pal = GraphPalette(dark: dark)
        let bounds = CGRect(origin: .zero, size: size)
        ctx.fill(Path(bounds), with: .color(pal.background))
        let g = frame.graph
        let n = g.nodes.count
        guard n > 0, frame.positions.count == n else { return [:] }
        let vp = frame.viewport
        let z = vp.zoom
        let visible = bounds.insetBy(dx: -80, dy: -80)

        var sp = [CGPoint](), sr = [CGFloat]()
        sp.reserveCapacity(n)
        sr.reserveCapacity(n)
        for i in 0..<n {
            sp.append(vp.toScreen(frame.positions[i]))
            sr.append(screenRadius(g.radius[i], zoom: z))
        }

        // Emphasis: the hovered and the selected node, their links and their direct neighbours.
        var emph: [Int] = []
        if let h = frame.hovered { emph.append(h) }
        if let s = frame.selected, s != frame.hovered { emph.append(s) }
        let hasEmph = !emph.isEmpty
        // Hovering focuses hard on one neighbourhood. A selection alone marks its node and links
        // but leaves the rest of the map readable, because in the app something is nearly always selected.
        let focused = frame.hovered != nil
        var isEmph = [Bool](repeating: false, count: n)
        var strong = [Bool](repeating: !hasEmph, count: n)
        for e in emph { isEmph[e] = true; strong[e] = true }
        for e in emph {
            for nb in g.neighbors[e] { strong[nb] = true }
        }

        var onScreen: [Int] = []
        for i in 0..<n where visible.contains(sp[i]) { onScreen.append(i) }

        drawEdges(&ctx, g: g, sp: sp, sr: sr, zoom: z, visible: visible, isEmph: isEmph, hasEmph: hasEmph, focused: focused, pal: pal)
        drawNodes(
            &ctx, g: g, sp: sp, sr: sr, zoom: z, onScreen: onScreen, strong: strong, isEmph: isEmph,
            selected: frame.selected, fade: focused ? 0.3 : 0.82, pal: pal)

        var space = LabelSpace(sp: sp, sr: sr, canvas: bounds.insetBy(dx: 4, dy: 4), nodes: onScreen)
        let rects = drawLabels(
            &ctx, g: g, zoom: z, onScreen: onScreen, hovered: frame.hovered, selected: frame.selected,
            strong: strong, focused: focused, pal: pal, space: &space)
        if hasEmph {
            drawEdgeLabels(&ctx, g: g, visible: visible, isEmph: isEmph, pal: pal, space: &space, zoom: z)
        }
        var result: [Int64: CGRect] = [:]
        result.reserveCapacity(rects.count)
        for (i, r) in rects { result[g.nodes[i].id] = r }
        return result
    }

    // MARK: Edges

    private static func geometry(_ e: PreparedEdge, sp: [CGPoint], sr: [CGFloat], zoom: CGFloat) -> Geometry? {
        let ps = sp[e.source], pt = sp[e.target]
        let rs = sr[e.source], rt = sr[e.target]
        let dist = hypot(pt.x - ps.x, pt.y - ps.y)
        guard dist > rs + rt + 3 else { return nil }
        var control = CGPoint(x: (ps.x + pt.x) / 2, y: (ps.y + pt.y) / 2)
        let curved = e.bend != 0
        if curved {
            let a = e.sourceIsLow ? ps : pt
            let b = e.sourceIsLow ? pt : ps
            let d = unit(a, to: b)
            let off = CGFloat(e.bend) * zoom
            control.x += -d.y * off
            control.y += d.x * off
        }
        let ds = unit(ps, to: control)
        let dt = unit(pt, to: control)
        // Lines run into the halo, not the invisible hit circle.
        let vs = min(max(1.8, rs * 0.4), 9) * 1.6, vt = min(max(1.8, rt * 0.4), 9) * 1.6
        let start = CGPoint(x: ps.x + ds.x * vs, y: ps.y + ds.y * vs)
        let end = CGPoint(x: pt.x + dt.x * (vt + 1), y: pt.y + dt.y * (vt + 1))
        let direction = unit(control, to: end)
        return Geometry(start: start, end: end, control: control, curved: curved, direction: direction)
    }

    private static func strokeStyle(_ style: EdgeStyle, zoom: CGFloat, emphasised: Bool) -> StrokeStyle {
        let scale = Double(min(1.5, max(0.75, zoom)))
        let cap: Double = emphasised ? 2.1 : 1.6
        var w = min(cap, max(0.7, style.width * scale) * (emphasised ? 1.35 : 1))
        switch style.stroke {
        case .solid:
            return StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        case .dashed:
            return StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round, dash: [8 + w, 5 + w])
        case .dotted:
            w = min(max(w, 1.2), cap)
            return StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: [0.01, w * 2.1 + 2.5])
        }
    }

    private static func drawEdges(
        _ ctx: inout GraphicsContext, g: PreparedGraph, sp: [CGPoint], sr: [CGFloat], zoom: CGFloat,
        visible: CGRect, isEmph: [Bool], hasEmph: Bool, focused: Bool, pal: GraphPalette
    ) {
        guard !g.styles.isEmpty else { return }
        var base = [Batch](repeating: Batch(), count: g.styles.count)
        var high = [Batch](repeating: Batch(), count: g.styles.count)
        for e in g.edges {
            let a = sp[e.source], b = sp[e.target]
            let slack = abs(CGFloat(e.bend) * zoom) + 24
            let box = CGRect(
                x: min(a.x, b.x) - slack, y: min(a.y, b.y) - slack,
                width: abs(a.x - b.x) + 2 * slack, height: abs(a.y - b.y) + 2 * slack)
            guard box.intersects(visible), let geo = geometry(e, sp: sp, sr: sr, zoom: zoom) else { continue }
            let emphasised = hasEmph && (isEmph[e.source] || isEmph[e.target])
            let style = g.styles[e.style]
            var lineEnd = geo.end
            var arrow = Path()
            if e.hasArrow {
                let rawLen = (6 + CGFloat(style.width) * 1.6 * (emphasised ? 1.2 : 1)) * min(1, max(0.5, zoom * 1.1))
                let len = min(rawLen, emphasised ? 7 : 5.5)
                let d = geo.direction
                let baseCentre = CGPoint(x: geo.end.x - d.x * len, y: geo.end.y - d.y * len)
                let wing = len * 0.41
                arrow.move(to: geo.end)
                arrow.addLine(to: CGPoint(x: baseCentre.x - d.y * wing, y: baseCentre.y + d.x * wing))
                arrow.addLine(to: CGPoint(x: baseCentre.x + d.y * wing, y: baseCentre.y - d.x * wing))
                arrow.closeSubpath()
                lineEnd = CGPoint(x: geo.end.x - d.x * len * 0.7, y: geo.end.y - d.y * len * 0.7)
            }
            var line = Path()
            line.move(to: geo.start)
            if geo.curved {
                line.addQuadCurve(to: lineEnd, control: geo.control)
            } else {
                line.addLine(to: lineEnd)
            }
            if emphasised {
                high[e.style].line.addPath(line)
                high[e.style].arrows.addPath(arrow)
            } else {
                base[e.style].line.addPath(line)
                base[e.style].arrows.addPath(arrow)
            }
        }
        // An ivory underlay under each coloured pass keeps edges bright on the dark sky; the
        // dash pattern of the relation is the same in both.
        let baseAlpha = focused ? 0.3 : 0.58
        for (i, style) in g.styles.enumerated() {
            let a = style.stroke == .dotted && !focused ? 0.9 : baseAlpha
            let st = strokeStyle(style, zoom: zoom, emphasised: false)
            ctx.stroke(base[i].line, with: .color(pal.text.opacity(focused ? 0.07 : 0.15)), style: st)
            ctx.stroke(base[i].line, with: .color(style.color.opacity(a)), style: st)
            ctx.fill(base[i].arrows, with: .color(style.color.opacity(min(1, baseAlpha + 0.2))))
        }
        for (i, style) in g.styles.enumerated() {
            let st = strokeStyle(style, zoom: zoom, emphasised: true)
            ctx.stroke(high[i].line, with: .color(pal.text.opacity(0.22)), style: st)
            ctx.stroke(high[i].line, with: .color(style.color.opacity(0.95)), style: st)
            ctx.fill(high[i].arrows, with: .color(pal.text.opacity(0.55)))
            ctx.fill(high[i].arrows, with: .color(style.color.opacity(0.75)))
        }
    }

    private static func drawEdgeLabels(
        _ ctx: inout GraphicsContext, g: PreparedGraph, visible: CGRect,
        isEmph: [Bool], pal: GraphPalette, space: inout LabelSpace, zoom: CGFloat
    ) {
        // At most a handful per frame: each needs a text measurement and up to seven probes.
        var drawn = 0
        for e in g.edges where isEmph[e.source] || isEmph[e.target] {
            if drawn >= 14 { break }
            guard let label = e.label, !label.isEmpty,
                  let geo = geometry(e, sp: space.sp, sr: space.sr, zoom: zoom) else { continue }
            let text = Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(pal.text.opacity(0.9))
            let resolved = ctx.resolve(text)
            let sz = resolved.measure(in: CGSize(width: 240, height: 30))
            // Nudge along the edge; drop the label if nowhere is free.
            for t in [0.5, 0.42, 0.58, 0.34, 0.66, 0.26, 0.74] as [CGFloat] {
                let u = 1 - t
                let mid = CGPoint(
                    x: u * u * geo.start.x + 2 * u * t * geo.control.x + t * t * geo.end.x,
                    y: u * u * geo.start.y + 2 * u * t * geo.control.y + t * t * geo.end.y)
                guard visible.contains(mid) else { continue }
                let rect = CGRect(x: mid.x - sz.width / 2, y: mid.y - sz.height / 2, width: sz.width, height: sz.height)
                guard space.isFree(rect, ignoring: nil, extra: 3) else { continue }
                let pill = rect.insetBy(dx: -5, dy: -2)
                ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(pal.surface.opacity(0.94)))
                ctx.stroke(Path(roundedRect: pill, cornerRadius: pill.height / 2),
                           with: .color(pal.text.opacity(0.28)), lineWidth: 0.5)
                ctx.draw(resolved, at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
                space.rects.append(rect)
                drawn += 1
                break
            }
        }
    }

    // MARK: Nodes

    private static func drawNodes(
        _ ctx: inout GraphicsContext, g: PreparedGraph, sp: [CGPoint], sr: [CGFloat], zoom: CGFloat,
        onScreen: [Int], strong: [Bool], isEmph: [Bool], selected: Int?, fade: Double, pal: GraphPalette
    ) {
        var faded: [Int] = [], normal: [Int] = [], top: [Int] = []
        for i in onScreen {
            if isEmph[i] { top.append(i) } else if strong[i] { normal.append(i) } else { faded.append(i) }
        }
        // Gradients are cheap for hundreds of nodes; past that the soft light is kept for the
        // emphasised ones and the cores are flat.
        let rich = onScreen.count <= 700
        var symbolCache: [String: GraphicsContext.ResolvedImage] = [:]
        for i in faded + normal + top {
            let node = g.nodes[i]
            let c = sp[i], r = sr[i]
            let op = (strong[i] ? 1.0 : fade) * (node.isDimmed ? 0.6 : 1.0)
            let isSel = i == selected
            // `r` stays the hit radius; the visible light is a compact core inside a small halo.
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let hasSymbol = node.symbol != nil && (r >= 16 || ((isSel || isEmph[i]) && r >= 7))
            let body = min(max(1.8, r * 0.4), 9)
            let reach = body * (isSel ? 3.6 : 3.0) * (hasSymbol ? 1.15 : 1)

            // Halo: node colour fading to black, close to the core.
            let haloColor = isSel ? pal.accent : node.color
            if rich || isEmph[i] || isSel {
                let halo = Gradient(stops: [
                    .init(color: haloColor.opacity(0.55 * op), location: 0),
                    .init(color: haloColor.opacity(0.2 * op), location: 0.4),
                    .init(color: .clear, location: 1),
                ])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach)),
                    with: .radialGradient(halo, center: c, startRadius: 0, endRadius: reach))
            } else {
                let cr = body * 1.7
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr)),
                         with: .color(node.color.opacity(0.35 * op)))
            }
            if isSel {
                let ring = rect.insetBy(dx: -4.5, dy: -4.5)
                ctx.stroke(Path(ellipseIn: ring), with: .color(pal.accent), lineWidth: 2.2)
            }

            // Core: nearly white at the centre, tinting to the kind colour at the edge.
            let cb = hasSymbol ? body * 0.8 : body
            let coreRect = CGRect(x: c.x - cb, y: c.y - cb, width: 2 * cb, height: 2 * cb)
            if rich {
                let core = Gradient(stops: [
                    .init(color: Color.white.opacity(op), location: 0),
                    .init(color: Color.white.opacity(0.92 * op), location: 0.3),
                    .init(color: node.color.opacity(0.9 * op), location: 0.75),
                    .init(color: node.color.opacity(0), location: 1),
                ])
                ctx.fill(Path(ellipseIn: coreRect.insetBy(dx: -cb * 0.25, dy: -cb * 0.25)),
                         with: .radialGradient(core, center: c, startRadius: 0, endRadius: cb * 1.25))
            } else {
                ctx.fill(Path(ellipseIn: coreRect), with: .color(node.color.opacity(op)))
                let hot = cb * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hot, y: c.y - hot, width: 2 * hot, height: 2 * hot)),
                         with: .color(Color.white.opacity(op)))
            }

            // Doing: a thin ring around the light.
            let ringR = max(body * 2.1, min(r, body * 2.1 + 2))
            let ringRect = CGRect(x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR)
            if node.isRinged {
                ctx.stroke(Path(ellipseIn: isSel ? ringRect.insetBy(dx: 1, dy: 1) : ringRect),
                           with: .color(node.color.opacity(op * 0.95)), lineWidth: isSel ? 1.3 : 1.5)
            }
            if hasSymbol, let name = node.symbol {
                let image: GraphicsContext.ResolvedImage
                if let cached = symbolCache[name] {
                    image = cached
                } else {
                    var fresh = ctx.resolve(Image(systemName: name))
                    fresh.shading = .color(.white)
                    symbolCache[name] = fresh
                    image = fresh
                }
                let natural = image.size
                if natural.width > 0 && natural.height > 0 {
                    let box = max(8, min(r * 0.9, 22))
                    let scale = min(box / natural.width, box / natural.height)
                    let w = natural.width * scale, h = natural.height * scale
                    var layer = ctx
                    layer.opacity = op
                    layer.draw(image, in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
                }
            }
        }
    }

    // MARK: Labels

    /// Free-space bookkeeping for label placement. Node circles live in a coarse grid so a probe
    /// touches only the few circles near it, however many nodes are on screen.
    struct LabelSpace {
        var rects: [CGRect] = []
        let sp: [CGPoint]
        let sr: [CGFloat]
        /// The drawable area; a label may not leave it.
        let canvas: CGRect
        private let cell: CGFloat = 48
        private var cols = 1, rows = 1
        private var grid: [[Int]] = []
        private var maxRadius: CGFloat = 0

        init(sp: [CGPoint], sr: [CGFloat], canvas: CGRect, nodes: [Int]) {
            self.sp = sp
            self.sr = sr
            self.canvas = canvas
            cols = max(1, Int((canvas.width / cell).rounded(.up)))
            rows = max(1, Int((canvas.height / cell).rounded(.up)))
            grid = [[Int]](repeating: [], count: cols * rows)
            for i in nodes { maxRadius = max(maxRadius, sr[i]) }
            let reach = canvas.insetBy(dx: -maxRadius, dy: -maxRadius)
            for i in nodes where reach.contains(sp[i]) {
                grid[index(col: column(sp[i].x), row: row(sp[i].y))].append(i)
            }
        }

        private func column(_ x: CGFloat) -> Int { min(cols - 1, max(0, Int(((x - canvas.minX) / cell).rounded(.down)))) }
        private func row(_ y: CGFloat) -> Int { min(rows - 1, max(0, Int(((y - canvas.minY) / cell).rounded(.down)))) }
        private func index(col: Int, row: Int) -> Int { row * cols + col }

        /// Inside the canvas, free of other labels and of every node circle except `own`.
        func isFree(_ rect: CGRect, ignoring own: Int?, extra: CGFloat = 0, clearance: CGFloat = 0) -> Bool {
            guard canvas.contains(rect) else { return false }
            let padded = rect.insetBy(dx: -5 - clearance, dy: -2 - clearance)
            for r in rects where r.intersects(padded) { return false }
            let probe = padded.insetBy(dx: -(maxRadius + 2 + extra), dy: -(maxRadius + 2 + extra))
            for row in row(probe.minY)...row(probe.maxY) {
                for col in column(probe.minX)...column(probe.maxX) {
                    for i in grid[index(col: col, row: row)] where i != own {
                        let c = sp[i], rad = sr[i] + 2 + extra
                        let nx = min(max(c.x, padded.minX), padded.maxX)
                        let ny = min(max(c.y, padded.minY), padded.maxY)
                        if hypot(c.x - nx, c.y - ny) < rad { return false }
                    }
                }
            }
            return true
        }
    }

    private enum Align { case center, leading, trailing }

    private struct Candidate {
        var rect: CGRect
        var align: Align
        var leader: Bool
    }

    /// Where a label box of `sz` may go around a node, most natural first. The far ring is joined
    /// to the node with a short leader line.
    private static func candidates(around c: CGPoint, gap: CGFloat, sz: CGSize) -> [Candidate] {
        let w = sz.width, h = sz.height
        func box(_ x: CGFloat, _ y: CGFloat, _ a: Align, _ leader: Bool = false) -> Candidate {
            Candidate(rect: CGRect(x: x, y: y, width: w, height: h), align: a, leader: leader)
        }
        let d = gap * 0.75
        var list = [
            box(c.x - w / 2, c.y + gap, .center),
            box(c.x - w / 2, c.y - gap - h, .center),
            box(c.x + gap + 2, c.y - h / 2, .leading),
            box(c.x - gap - 2 - w, c.y - h / 2, .trailing),
            box(c.x + d, c.y + d, .leading),
            box(c.x - d - w, c.y + d, .trailing),
            box(c.x + d, c.y - d - h, .leading),
            box(c.x - d - w, c.y - d - h, .trailing),
        ]
        let far = gap + 18
        let f = far * 0.8
        list += [
            box(c.x - w / 2, c.y + far, .center, true),
            box(c.x - w / 2, c.y - far - h, .center, true),
            box(c.x + far + 4, c.y - h / 2, .leading, true),
            box(c.x - far - 4 - w, c.y - h / 2, .trailing, true),
            box(c.x + f, c.y + f, .leading, true),
            box(c.x - f - w, c.y + f, .trailing, true),
            box(c.x + f, c.y - f - h, .leading, true),
            box(c.x - f - w, c.y - f - h, .trailing, true),
        ]
        return list
    }

    private static let cyan = Color(red: 0.36, green: 0.88, blue: 1.0)

    private static func drawLabels(
        _ ctx: inout GraphicsContext, g: PreparedGraph, zoom: CGFloat, onScreen: [Int],
        hovered: Int?, selected: Int?, strong: [Bool], focused: Bool, pal: GraphPalette,
        space: inout LabelSpace
    ) -> [Int: CGRect] {
        let sp = space.sp, sr = space.sr
        let canvas = space.canvas
        var placed: [Int: CGRect] = [:]
        var onCanvas = Set<Int>()
        for i in onScreen where canvas.insetBy(dx: -12, dy: -12).contains(sp[i]) { onCanvas.insert(i) }

        let budget = GraphLabelLayout.budget(canvasArea: canvas.width * canvas.height, zoom: zoom, visible: onCanvas.count)
        var attemptsLeft = GraphLabelLayout.attempts(budget: budget, visible: onCanvas.count)
        let maxWidth = max(110, min(220, canvas.width * 0.3))
        let preferred = maxWidth * 0.68

        /// Tier 0: selected; 1: selected's neighbours and ringed work; 2: by priority; 3: hovered.
        @discardableResult
        func place(_ i: Int, tier: Int) -> Bool {
            guard placed[i] == nil, onCanvas.contains(i) else { return false }
            let isSel = i == selected
            let node = g.nodes[i]
            let font = Font.system(size: tier <= 1 ? 12 : 11.5, weight: tier <= 1 ? .semibold : .regular)
            func measure(_ s: String) -> CGFloat {
                ctx.resolve(Text(s).font(font)).measure(in: CGSize(width: 4000, height: 200)).width
            }
            let wrapped = GraphLabelLayout.wrap(
                g.titles[i], preferredWidth: preferred, maxWidth: maxWidth - (isSel ? 16 : 0),
                maxLines: 3, measure: measure)
            guard !wrapped.lines.isEmpty else { return false }

            let ink = isSel ? pal.text : pal.text.opacity(node.isDimmed ? 0.66 : (tier == 2 ? 0.92 : 1))
            let resolvedLines = wrapped.lines.map { ctx.resolve(Text($0).font(font).foregroundStyle(ink)) }
            let metrics = resolvedLines.map { $0.measure(in: CGSize(width: 4000, height: 200)) }
            let lineHeight = metrics.map(\.height).max() ?? 14
            let textW = metrics.map(\.width).max() ?? 0
            let pad = isSel ? CGSize(width: 8, height: 4) : CGSize(width: 5, height: 2)
            let sz = CGSize(
                width: textW + 2 * pad.width, height: lineHeight * CGFloat(resolvedLines.count) + 2 * pad.height)
            let c = sp[i]
            let gap = sr[i] + (isSel ? 11 : (node.isRinged ? 8 : 5))
            // Selected neighbours and ringed tasks keep a little extra air around their titles.
            let air: CGFloat = tier == 1 || isSel ? 2 : 0

            var chosen: Candidate?
            for cand in candidates(around: c, gap: gap, sz: sz) where space.isFree(cand.rect, ignoring: i, clearance: air) {
                chosen = cand
                break
            }
            if chosen == nil && isSel {
                // The selected node always gets its title: below it, pushed back inside the canvas.
                var forced = CGRect(x: c.x - sz.width / 2, y: c.y + gap, width: sz.width, height: sz.height)
                forced.origin.x = min(max(forced.minX, canvas.minX), max(canvas.minX, canvas.maxX - forced.width))
                forced.origin.y = min(max(forced.minY, canvas.minY), max(canvas.minY, canvas.maxY - forced.height))
                chosen = Candidate(rect: forced, align: .center, leader: false)
            }
            guard let cand = chosen else { return false }
            let rect = cand.rect

            if cand.leader {
                let nearest = CGPoint(x: min(max(c.x, rect.minX), rect.maxX), y: min(max(c.y, rect.minY), rect.maxY))
                let dir = unit(c, to: nearest)
                let from = CGPoint(x: c.x + dir.x * (sr[i] + 2), y: c.y + dir.y * (sr[i] + 2))
                var leader = Path()
                leader.move(to: from)
                leader.addLine(to: nearest)
                ctx.stroke(leader, with: .color(pal.text.opacity(0.4)), lineWidth: 0.8)
            }
            let faded = focused && !strong[i] && !isSel
            var layer = ctx
            layer.opacity = faded ? 0.4 : 1
            let backing = Path(roundedRect: rect, cornerRadius: isSel ? 7 : 5)
            if isSel {
                layer.fill(backing, with: .color(pal.surface.opacity(0.97)))
                layer.stroke(backing, with: .color(cyan), lineWidth: 1.2)
            } else {
                layer.fill(backing, with: .color(pal.surface.opacity(tier <= 1 ? 0.78 : 0.6)))
            }
            let inner = rect.insetBy(dx: pad.width, dy: pad.height)
            for (k, line) in resolvedLines.enumerated() {
                let y = inner.minY + CGFloat(k) * lineHeight
                switch cand.align {
                case .center: layer.draw(line, at: CGPoint(x: inner.midX, y: y), anchor: .top)
                case .leading: layer.draw(line, at: CGPoint(x: inner.minX, y: y), anchor: .topLeading)
                case .trailing: layer.draw(line, at: CGPoint(x: inner.maxX, y: y), anchor: .topTrailing)
                }
            }
            space.rects.append(rect)
            placed[i] = rect
            return true
        }

        guard budget > 0 else { return placed }
        // 1. The selected node.
        if let s = selected { place(s, tier: 0) }
        // 2. Its neighbours and the work in progress get first pick of the space, a bounded share.
        var reserved = max(3, budget / 3)
        if let s = selected {
            for i in g.labelOrder where reserved > 0 && attemptsLeft > 0 && g.neighbors[s].contains(i) {
                attemptsLeft -= 1
                if place(i, tier: 1) { reserved -= 1 }
            }
        }
        for i in g.labelOrder where reserved > 0 && attemptsLeft > 0 && g.nodes[i].isRinged {
            attemptsLeft -= 1
            if place(i, tier: 1) { reserved -= 1 }
        }
        // 3. The rest by priority (links, work in progress) up to the budget, within the attempt cap.
        for i in g.labelOrder where placed.count < budget && attemptsLeft > 0 {
            guard onCanvas.contains(i), placed[i] == nil else { continue }
            attemptsLeft -= 1
            place(i, tier: 2)
        }
        // 4. The hovered node last and only if there is room: nothing else moves for it.
        if let h = hovered, placed[h] == nil { place(h, tier: 3) }
        return placed
    }
}

// MARK: - Static rendering

/// A non-interactive rendering of a graph with fixed positions, fitted into its frame.
/// Used by previews and snapshots; the interactive view is `GraphCanvas`.
public struct GraphStaticView: View {
    private let graph: PreparedGraph
    private let positions: [CGPoint]
    private let selected: Int?
    private let hovered: Int?

    public init(
        nodes: [GraphNode], edges: [GraphEdge], positions: [Int64: CGPoint],
        selection: Int64? = nil, hovered: Int64? = nil
    ) {
        let prepared = PreparedGraph(nodes: nodes, edges: edges)
        graph = prepared
        self.positions = prepared.nodes.map { positions[$0.id] ?? .zero }
        selected = selection.flatMap { prepared.indexByID[$0] }
        self.hovered = hovered.flatMap { prepared.indexByID[$0] }
    }

    public var body: some View {
        let graph = graph, positions = positions, selected = selected, hovered = hovered
        Canvas(opaque: true) { ctx, size in
            let viewport = GraphViewport.fit(points: positions, radii: graph.radius, titles: graph.titles, size: size)
            let frame = GraphFrame(
                graph: graph, positions: positions, viewport: viewport, selected: selected, hovered: hovered)
            GraphDrawer.draw(&ctx, size: size, frame: frame, dark: true)
        }
    }
}
