import CoreGraphics
import Foundation

/// A d3-force style layout engine: many-body repulsion (Barnes-Hut above a few hundred nodes),
/// link springs, a weak pull to the centre, collision avoidance, a gentle group pull, velocity
/// damping and alpha cooling. Pure Swift, deterministic, and safe to run off the main thread.
///
/// Nodes are kept sorted by id, so `ids`, `x`, `y` and friends share one stable index space.
public struct ForceLayout: Sendable {
    public struct Node: Hashable, Sendable {
        public var id: Int64
        public var radius: Double
        public var group: Int?
        public init(id: Int64, radius: Double, group: Int? = nil) {
            self.id = id
            self.radius = radius
            self.group = group
        }
    }

    public struct Link: Hashable, Sendable {
        public var source: Int64
        public var target: Int64
        public var strength: Double
        public init(source: Int64, target: Int64, strength: Double = 0.5) {
            self.source = source
            self.target = target
            self.strength = strength
        }
    }

    // MARK: Constants and tuning

    public static let alphaMin = 0.001
    /// Chosen so that alpha falls from 1 to `alphaMin` in about 300 ticks.
    public static let alphaDecay = 1.0 - pow(alphaMin, 1.0 / 300.0)
    /// Above this many nodes the repulsion uses a Barnes-Hut quadtree.
    public static let bruteForceLimit = 256

    public var velocityDecay = 0.4
    /// Keep above zero while a node is being dragged so the layout stays warm.
    public var alphaTarget = 0.0
    public var repulsion = 220.0
    public var centerStrength = 0.05
    public var groupStrength = 0.12
    public var collisionPadding = 4.0
    public var theta = 0.9

    // MARK: State

    public private(set) var alpha = 0.0
    public private(set) var ids: [Int64] = []
    public private(set) var radii: [Double] = []
    public private(set) var x: [Double] = []
    public private(set) var y: [Double] = []
    public private(set) var vx: [Double] = []
    public private(set) var vy: [Double] = []
    public private(set) var nodeList: [Node] = []
    public private(set) var linkList: [Link] = []

    private var pinned: [Bool] = []
    private var groupIndex: [Int32] = []
    private var groupCount = 0
    private var linkSource: [Int32] = []
    private var linkTarget: [Int32] = []
    private var linkDistance: [Double] = []
    private var linkK: [Double] = []
    private var linkBias: [Double] = []
    private var finalized = true
    private var tree = QuadTree()
    private var grid = SpatialGrid()

    private struct Known {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var pinned: Bool
    }

    // MARK: Creation

    public init(nodes: [Node], links: [Link], saved: [Int64: CGPoint] = [:], initialAlpha: Double? = nil) {
        let (list, valid) = Self.normalize(nodes: nodes, links: links)
        var known: [Int64: Known] = [:]
        for node in list {
            if let p = saved[node.id], p.x.isFinite, p.y.isFinite {
                known[node.id] = Known(x: Double(p.x), y: Double(p.y), vx: 0, vy: 0, pinned: false)
            }
        }
        configure(list: list, valid: valid, known: known)
        let n = ids.count
        let missing = n - known.count
        if let initialAlpha {
            alpha = initialAlpha
        } else if n == 0 {
            alpha = 0
        } else if missing == 0 {
            alpha = 0.02
        } else {
            alpha = 0.3 + 0.7 * Double(missing) / Double(n)
        }
        finalized = false
    }

    /// Dedupes nodes (first wins), sorts by id, and keeps only links whose ends both exist.
    static func normalize(nodes: [Node], links: [Link]) -> ([Node], [Link]) {
        var seen = Set<Int64>()
        var list: [Node] = []
        list.reserveCapacity(nodes.count)
        for node in nodes where seen.insert(node.id).inserted {
            var clean = node
            clean.radius = node.radius.isFinite ? max(1, node.radius) : 6
            list.append(clean)
        }
        list.sort { $0.id < $1.id }
        var valid: [Link] = []
        valid.reserveCapacity(links.count)
        for link in links where link.source != link.target && seen.contains(link.source) && seen.contains(link.target) {
            var clean = link
            clean.strength = link.strength.isFinite ? min(1, max(0, link.strength)) : 0.5
            valid.append(clean)
        }
        return (list, valid)
    }

    // MARK: Incremental update

    /// Replaces the nodes and links. Existing nodes keep their position, velocity and pin;
    /// new nodes are placed next to their neighbours. Returns whether anything changed; if so
    /// the simulation is reheated to `reheat` (never cooled).
    @discardableResult
    public mutating func update(
        nodes: [Node], links: [Link], saved: [Int64: CGPoint] = [:], reheat: Double = 0.35
    ) -> Bool {
        let (list, valid) = Self.normalize(nodes: nodes, links: links)
        if list == nodeList && valid == linkList { return false }
        var known: [Int64: Known] = [:]
        known.reserveCapacity(list.count)
        var oldIndex: [Int64: Int] = [:]
        oldIndex.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { oldIndex[id] = i }
        for node in list {
            if let i = oldIndex[node.id] {
                known[node.id] = Known(x: x[i], y: y[i], vx: vx[i], vy: vy[i], pinned: pinned[i])
            } else if let p = saved[node.id], p.x.isFinite, p.y.isFinite {
                known[node.id] = Known(x: Double(p.x), y: Double(p.y), vx: 0, vy: 0, pinned: false)
            }
        }
        configure(list: list, valid: valid, known: known)
        if !ids.isEmpty { alpha = max(alpha, reheat) }
        finalized = false
        return true
    }

    private mutating func configure(list: [Node], valid: [Link], known: [Int64: Known]) {
        let n = list.count
        var index: [Int64: Int] = [:]
        index.reserveCapacity(n)
        for (i, node) in list.enumerated() { index[node.id] = i }

        // Adjacency (for placement) and degree (for spring strength).
        var adjacency = [[Int]](repeating: [], count: n)
        var degree = [Int](repeating: 0, count: n)
        var ls: [Int32] = [], lt: [Int32] = []
        ls.reserveCapacity(valid.count)
        lt.reserveCapacity(valid.count)
        for link in valid {
            let s = index[link.source]!, t = index[link.target]!
            ls.append(Int32(s))
            lt.append(Int32(t))
            degree[s] += 1
            degree[t] += 1
            adjacency[s].append(t)
            adjacency[t].append(s)
        }

        // Positions: keep what is known, place the rest next to neighbours, seeds on a spiral.
        var px = [Double](repeating: 0, count: n)
        var py = [Double](repeating: 0, count: n)
        var pvx = [Double](repeating: 0, count: n)
        var pvy = [Double](repeating: 0, count: n)
        var pin = [Bool](repeating: false, count: n)
        var placed = [Bool](repeating: false, count: n)
        var baseRadius = 0.0
        var queue: [Int] = []
        queue.reserveCapacity(n)
        for i in 0..<n {
            if let k = known[list[i].id] {
                px[i] = k.x; py[i] = k.y; pvx[i] = k.vx; pvy[i] = k.vy
                pin[i] = k.pinned
                placed[i] = true
                baseRadius = max(baseRadius, hypot(k.x, k.y))
                queue.append(i)
            }
        }
        let golden = Double.pi * (3 - 5.0.squareRoot())
        var head = 0
        var nextSeed = 0
        var seedCount = 0
        while true {
            while head < queue.count {
                let u = queue[head]
                head += 1
                let spread = 40 + 3 * Double(adjacency[u].count).squareRoot()
                for v in adjacency[u] where !placed[v] {
                    var cx = 0.0, cy = 0.0, c = 0.0
                    for w in adjacency[v] where placed[w] { cx += px[w]; cy += py[w]; c += 1 }
                    let angle = Double(list[v].id & 0xFFFF) * golden
                    let d = spread + list[v].radius
                    px[v] = cx / c + cos(angle) * d
                    py[v] = cy / c + sin(angle) * d
                    placed[v] = true
                    queue.append(v)
                }
            }
            while nextSeed < n && placed[nextSeed] { nextSeed += 1 }
            if nextSeed >= n { break }
            let k = Double(seedCount)
            seedCount += 1
            let r = baseRadius + 40 * (k + 0.5).squareRoot()
            let a = k * golden
            px[nextSeed] = cos(a) * r
            py[nextSeed] = sin(a) * r
            placed[nextSeed] = true
            queue.append(nextSeed)
        }

        // Groups, in order of first appearance by node index.
        var groupMap: [Int: Int32] = [:]
        var gi = [Int32](repeating: -1, count: n)
        for i in 0..<n {
            if let g = list[i].group {
                if let m = groupMap[g] {
                    gi[i] = m
                } else {
                    let m = Int32(groupMap.count)
                    groupMap[g] = m
                    gi[i] = m
                }
            }
        }

        // Link springs: shorter for stronger links, softened by the degree of the ends.
        var dist = [Double](), kk = [Double](), bias = [Double]()
        dist.reserveCapacity(valid.count); kk.reserveCapacity(valid.count); bias.reserveCapacity(valid.count)
        for (l, link) in valid.enumerated() {
            let s = Int(ls[l]), t = Int(lt[l])
            dist.append(46 + list[s].radius + list[t].radius - 14 * link.strength)
            kk.append((0.3 + 0.7 * link.strength) / Double(max(1, min(degree[s], degree[t]))))
            bias.append(Double(degree[s]) / Double(degree[s] + degree[t]))
        }

        nodeList = list
        linkList = valid
        ids = list.map(\.id)
        radii = list.map(\.radius)
        x = px; y = py; vx = pvx; vy = pvy
        pinned = pin
        groupIndex = gi
        groupCount = groupMap.count
        linkSource = ls; linkTarget = lt
        linkDistance = dist; linkK = kk; linkBias = bias
    }

    // MARK: Queries

    public var count: Int { ids.count }
    public var linkCount: Int { linkList.count }
    public var isSettled: Bool { ids.isEmpty || (alpha < Self.alphaMin && alphaTarget <= 0) }

    public var points: [CGPoint] {
        (0..<ids.count).map { CGPoint(x: x[$0], y: y[$0]) }
    }

    public var positions: [Int64: CGPoint] {
        var result: [Int64: CGPoint] = [:]
        result.reserveCapacity(ids.count)
        for i in 0..<ids.count { result[ids[i]] = CGPoint(x: x[i], y: y[i]) }
        return result
    }

    public func index(of id: Int64) -> Int? {
        var lo = 0, hi = ids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ids[mid] < id { lo = mid + 1 } else { hi = mid }
        }
        return lo < ids.count && ids[lo] == id ? lo : nil
    }

    public func isPinned(_ id: Int64) -> Bool {
        index(of: id).map { pinned[$0] } ?? false
    }

    // MARK: Control

    public mutating func pin(_ id: Int64, at point: CGPoint) {
        guard let i = index(of: id), point.x.isFinite, point.y.isFinite else { return }
        pinned[i] = true
        x[i] = Double(point.x)
        y[i] = Double(point.y)
        vx[i] = 0
        vy[i] = 0
    }

    public mutating func unpin(_ id: Int64) {
        if let i = index(of: id) { pinned[i] = false }
    }

    /// Raises alpha to at least `value` so the layout relaxes again.
    public mutating func reheat(_ value: Double = 0.3) {
        guard !ids.isEmpty else { return }
        alpha = max(alpha, value)
        finalized = false
    }

    /// Runs ticks until the layout has cooled. Returns the number of ticks used.
    @discardableResult
    public mutating func settle(maxTicks: Int = 2000) -> Int {
        var ticks = 0
        while !isSettled && ticks < maxTicks {
            tick()
            ticks += 1
        }
        return ticks
    }

    // MARK: Tick

    public mutating func tick() {
        guard !isSettled else { return }
        alpha += (alphaTarget - alpha) * Self.alphaDecay
        applyLinks()
        applyCharge()
        applyCenter()
        applyGroups()
        applyCollision()
        integrate()
        if alpha < Self.alphaMin && alphaTarget <= 0 && !finalized {
            resolveOverlaps()
            finalized = true
        }
    }

    @inline(__always)
    private static func jitter(_ i: Int, _ j: Int) -> Double {
        (Double((i &* 7919 &+ j &* 104_729) % 997) / 997.0 - 0.5) * 1e-2
    }

    private mutating func applyLinks() {
        let alpha = self.alpha
        for l in 0..<linkSource.count {
            let s = Int(linkSource[l]), t = Int(linkTarget[l])
            var dx = x[t] + vx[t] - x[s] - vx[s]
            var dy = y[t] + vy[t] - y[s] - vy[s]
            if dx == 0 && dy == 0 { dx = Self.jitter(s, t); dy = Self.jitter(t, s) }
            let len = (dx * dx + dy * dy).squareRoot()
            let f = (len - linkDistance[l]) / len * alpha * linkK[l]
            dx *= f
            dy *= f
            let b = linkBias[l]
            vx[t] -= dx * b
            vy[t] -= dy * b
            vx[s] += dx * (1 - b)
            vy[s] += dy * (1 - b)
        }
    }

    private mutating func applyCharge() {
        let n = ids.count
        guard n > 1 else { return }
        let k = -repulsion * alpha
        let minD2 = 100.0
        if n <= Self.bruteForceLimit {
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    var dx = x[j] - x[i], dy = y[j] - y[i]
                    var d2 = dx * dx + dy * dy
                    if d2 == 0 { dx = Self.jitter(i, j); dy = Self.jitter(j, i); d2 = dx * dx + dy * dy }
                    if d2 < minD2 { d2 = minD2 }
                    let w = k / d2
                    vx[i] += dx * w
                    vy[i] += dy * w
                    vx[j] -= dx * w
                    vy[j] -= dy * w
                }
            }
            return
        }
        tree.build(x: x, y: y)
        let t = tree
        let theta2 = theta * theta
        var stack = [Int32](repeating: 0, count: 256)
        for i in 0..<n {
            let xi = x[i], yi = y[i]
            var ax = 0.0, ay = 0.0
            var top = 0
            stack[0] = 0
            top = 1
            while top > 0 {
                top -= 1
                let node = Int(stack[top])
                let c0 = t.child[node * 4], c1 = t.child[node * 4 + 1]
                let c2 = t.child[node * 4 + 2], c3 = t.child[node * 4 + 3]
                let isLeaf = c0 < 0 && c1 < 0 && c2 < 0 && c3 < 0
                if isLeaf {
                    let s = Int(t.start[node]), e = s + Int(t.count[node])
                    for p in s..<e {
                        let j = Int(t.perm[p])
                        if j == i { continue }
                        var dx = x[j] - xi, dy = y[j] - yi
                        var d2 = dx * dx + dy * dy
                        if d2 == 0 { dx = Self.jitter(i, j); dy = Self.jitter(j, i); d2 = dx * dx + dy * dy }
                        if d2 < minD2 { d2 = minD2 }
                        let w = k / d2
                        ax += dx * w
                        ay += dy * w
                    }
                } else {
                    let dx = t.cx[node] - xi, dy = t.cy[node] - yi
                    let d2 = dx * dx + dy * dy
                    let size = t.size[node]
                    if size * size < theta2 * d2 {
                        let w = k * t.mass[node] / max(d2, minD2)
                        ax += dx * w
                        ay += dy * w
                    } else {
                        if c0 >= 0 { stack[top] = c0; top += 1 }
                        if c1 >= 0 { stack[top] = c1; top += 1 }
                        if c2 >= 0 { stack[top] = c2; top += 1 }
                        if c3 >= 0 { stack[top] = c3; top += 1 }
                    }
                }
            }
            vx[i] += ax
            vy[i] += ay
        }
    }

    private mutating func applyCenter() {
        let k = centerStrength * alpha
        for i in 0..<ids.count {
            vx[i] -= x[i] * k
            vy[i] -= y[i] * k
        }
    }

    private mutating func applyGroups() {
        guard groupCount > 0 else { return }
        var sx = [Double](repeating: 0, count: groupCount)
        var sy = [Double](repeating: 0, count: groupCount)
        var cnt = [Double](repeating: 0, count: groupCount)
        for i in 0..<ids.count {
            let g = Int(groupIndex[i])
            if g >= 0 { sx[g] += x[i]; sy[g] += y[i]; cnt[g] += 1 }
        }
        let k = groupStrength * alpha
        for i in 0..<ids.count {
            let g = Int(groupIndex[i])
            if g >= 0 && cnt[g] > 1 {
                vx[i] += (sx[g] / cnt[g] - x[i]) * k
                vy[i] += (sy[g] / cnt[g] - y[i]) * k
            }
        }
    }

    private mutating func applyCollision() {
        let n = ids.count
        guard n > 1 else { return }
        let maxR = radii.max() ?? 1
        grid.build(x: x, y: y, minCell: 2 * maxR + collisionPadding)
        let pad = collisionPadding
        let strength = 0.7
        for i in 0..<n {
            let (cx, cy) = grid.cell(x[i], y[i])
            let ri = radii[i]
            for gy in max(0, cy - 1)...min(grid.ny - 1, cy + 1) {
                for gx in max(0, cx - 1)...min(grid.nx - 1, cx + 1) {
                    let c = gy * grid.nx + gx
                    var p = Int(grid.cellStart[c])
                    let e = Int(grid.cellStart[c + 1])
                    while p < e {
                        let j = Int(grid.items[p])
                        p += 1
                        if j <= i { continue }
                        let rr = ri + radii[j] + pad
                        var dx = x[i] + vx[i] - x[j] - vx[j]
                        var dy = y[i] + vy[i] - y[j] - vy[j]
                        var d2 = dx * dx + dy * dy
                        if d2 >= rr * rr { continue }
                        if d2 == 0 { dx = Self.jitter(i, j); dy = Self.jitter(j, i); d2 = dx * dx + dy * dy }
                        let dist = d2.squareRoot()
                        let l = (rr - dist) / dist * strength
                        dx *= l
                        dy *= l
                        let ri2 = ri * ri, rj2 = radii[j] * radii[j]
                        let wi = rj2 / (ri2 + rj2)
                        vx[i] += dx * wi
                        vy[i] += dy * wi
                        vx[j] -= dx * (1 - wi)
                        vy[j] -= dy * (1 - wi)
                    }
                }
            }
        }
    }

    private mutating func integrate() {
        let keep = 1 - velocityDecay
        let vmax = 80.0
        for i in 0..<ids.count {
            if pinned[i] {
                vx[i] = 0
                vy[i] = 0
                continue
            }
            var a = vx[i] * keep, b = vy[i] * keep
            a = min(vmax, max(-vmax, a))
            b = min(vmax, max(-vmax, b))
            vx[i] = a
            vy[i] = b
            x[i] += a
            y[i] += b
        }
    }

    /// Hard separation so that no two circles overlap once the layout has cooled.
    private mutating func resolveOverlaps(passes: Int = 40) {
        let n = ids.count
        guard n > 1 else { return }
        let maxR = radii.max() ?? 1
        let gap = 1.0
        for _ in 0..<passes {
            grid.build(x: x, y: y, minCell: 2 * maxR + gap + 2)
            var moved = false
            for i in 0..<n {
                let (cx, cy) = grid.cell(x[i], y[i])
                for gy in max(0, cy - 1)...min(grid.ny - 1, cy + 1) {
                    for gx in max(0, cx - 1)...min(grid.nx - 1, cx + 1) {
                        let c = gy * grid.nx + gx
                        var p = Int(grid.cellStart[c])
                        let e = Int(grid.cellStart[c + 1])
                        while p < e {
                            let j = Int(grid.items[p])
                            p += 1
                            if j <= i { continue }
                            let need = radii[i] + radii[j] + gap
                            var dx = x[i] - x[j], dy = y[i] - y[j]
                            var d2 = dx * dx + dy * dy
                            if d2 >= need * need { continue }
                            if pinned[i] && pinned[j] { continue }
                            if d2 == 0 { dx = Self.jitter(i, j) + 1e-3; dy = Self.jitter(j, i); d2 = dx * dx + dy * dy }
                            let dist = d2.squareRoot()
                            let push = (need - dist) / dist
                            let wi: Double = pinned[i] ? 0 : (pinned[j] ? 1 : 0.5)
                            x[i] += dx * push * wi
                            y[i] += dy * push * wi
                            x[j] -= dx * push * (1 - wi)
                            y[j] -= dy * push * (1 - wi)
                            moved = true
                        }
                    }
                }
            }
            if !moved { break }
        }
    }
}

// MARK: - Barnes-Hut quadtree

struct QuadTree: Sendable {
    var cx: [Double] = []
    var cy: [Double] = []
    var mass: [Double] = []
    var size: [Double] = []
    var child: [Int32] = []
    var start: [Int32] = []
    var count: [Int32] = []
    var perm: [Int32] = []
    private var scratch: [Int32] = []

    mutating func build(x: [Double], y: [Double]) {
        let n = x.count
        cx.removeAll(keepingCapacity: true)
        cy.removeAll(keepingCapacity: true)
        mass.removeAll(keepingCapacity: true)
        size.removeAll(keepingCapacity: true)
        child.removeAll(keepingCapacity: true)
        start.removeAll(keepingCapacity: true)
        count.removeAll(keepingCapacity: true)
        perm.removeAll(keepingCapacity: true)
        guard n > 0 else { return }
        for i in 0..<n { perm.append(Int32(i)) }
        scratch = perm
        var minX = x[0], maxX = x[0], minY = y[0], maxY = y[0]
        for i in 1..<n {
            minX = min(minX, x[i]); maxX = max(maxX, x[i])
            minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        let s = max(maxX - minX, maxY - minY) + 1e-6
        _ = makeNode(lo: 0, hi: n, x0: minX, y0: minY, size: s, depth: 0, x: x, y: y)
    }

    private mutating func makeNode(
        lo: Int, hi: Int, x0: Double, y0: Double, size s: Double, depth: Int, x: [Double], y: [Double]
    ) -> Int32 {
        let id = Int32(cx.count)
        var sx = 0.0, sy = 0.0
        for p in lo..<hi {
            let i = Int(perm[p])
            sx += x[i]; sy += y[i]
        }
        let m = Double(hi - lo)
        cx.append(sx / m); cy.append(sy / m); mass.append(m); size.append(s)
        child.append(-1); child.append(-1); child.append(-1); child.append(-1)
        start.append(Int32(lo)); count.append(Int32(hi - lo))
        if hi - lo <= 1 || depth >= 24 { return id }

        let mx = x0 + s / 2, my = y0 + s / 2
        var c0 = 0, c1 = 0, c2 = 0, c3 = 0
        for p in lo..<hi {
            let i = Int(perm[p])
            switch (x[i] >= mx ? 1 : 0) | (y[i] >= my ? 2 : 0) {
            case 0: c0 += 1
            case 1: c1 += 1
            case 2: c2 += 1
            default: c3 += 1
            }
        }
        let b0 = lo, b1 = lo + c0, b2 = b1 + c1, b3 = b2 + c2
        var o0 = b0, o1 = b1, o2 = b2, o3 = b3
        for p in lo..<hi {
            let v = perm[p]
            let i = Int(v)
            switch (x[i] >= mx ? 1 : 0) | (y[i] >= my ? 2 : 0) {
            case 0: scratch[o0] = v; o0 += 1
            case 1: scratch[o1] = v; o1 += 1
            case 2: scratch[o2] = v; o2 += 1
            default: scratch[o3] = v; o3 += 1
            }
        }
        for p in lo..<hi { perm[p] = scratch[p] }
        let h = s / 2
        let base = Int(id) * 4
        if c0 > 0 { child[base] = makeNode(lo: b0, hi: b0 + c0, x0: x0, y0: y0, size: h, depth: depth + 1, x: x, y: y) }
        if c1 > 0 { child[base + 1] = makeNode(lo: b1, hi: b1 + c1, x0: mx, y0: y0, size: h, depth: depth + 1, x: x, y: y) }
        if c2 > 0 { child[base + 2] = makeNode(lo: b2, hi: b2 + c2, x0: x0, y0: my, size: h, depth: depth + 1, x: x, y: y) }
        if c3 > 0 { child[base + 3] = makeNode(lo: b3, hi: b3 + c3, x0: mx, y0: my, size: h, depth: depth + 1, x: x, y: y) }
        return id
    }
}

// MARK: - Uniform grid for collision

struct SpatialGrid: Sendable {
    var cellStart: [Int32] = []
    var items: [Int32] = []
    var nx = 1
    var ny = 1
    private var minX = 0.0
    private var minY = 0.0
    private var cellSize = 1.0
    private var cellOf: [Int32] = []

    mutating func build(x: [Double], y: [Double], minCell: Double) {
        let n = x.count
        var lx = x[0], hx = x[0], ly = y[0], hy = y[0]
        for i in 1..<n {
            lx = min(lx, x[i]); hx = max(hx, x[i])
            ly = min(ly, y[i]); hy = max(hy, y[i])
        }
        minX = lx
        minY = ly
        let span = max(hx - lx, hy - ly)
        let maxDim = max(1, min(400, Int(2 * Double(n).squareRoot()) + 2))
        cellSize = max(minCell, span / Double(maxDim))
        nx = Int((hx - lx) / cellSize) + 1
        ny = Int((hy - ly) / cellSize) + 1
        let cells = nx * ny
        cellStart = [Int32](repeating: 0, count: cells + 1)
        cellOf = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let c = Int((y[i] - minY) / cellSize) * nx + Int((x[i] - minX) / cellSize)
            cellOf[i] = Int32(c)
            cellStart[c + 1] += 1
        }
        for c in 0..<cells { cellStart[c + 1] += cellStart[c] }
        items = [Int32](repeating: 0, count: n)
        var fill = cellStart
        for i in 0..<n {
            let c = Int(cellOf[i])
            items[Int(fill[c])] = Int32(i)
            fill[c] += 1
        }
    }

    @inline(__always)
    func cell(_ px: Double, _ py: Double) -> (Int, Int) {
        (min(nx - 1, max(0, Int((px - minX) / cellSize))), min(ny - 1, max(0, Int((py - minY) / cellSize))))
    }
}
