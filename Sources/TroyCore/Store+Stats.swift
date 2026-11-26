import Foundation

/// How much the graph grew in a period, for `troy stats`. Counts only, read in one snapshot.
public struct GraphGrowth: Sendable, Equatable {
    /// Records created in the period by kind; kinds with none are left out.
    public var recordsByKind: [RecordKind: Int]
    public var links: Int
    public var projects: Int

    public init(recordsByKind: [RecordKind: Int] = [:], links: Int = 0, projects: Int = 0) {
        self.recordsByKind = recordsByKind; self.links = links; self.projects = projects
    }

    public var records: Int { recordsByKind.values.reduce(0, +) }
}

extension Store {
    /// Records, links and projects created at or after `since` that still exist.
    public func growth(since: Date) throws -> GraphGrowth {
        let cutoff = SQLValue.int(Int64(since.timeIntervalSince1970 * 1000))
        return try read { db in
            var byKind: [RecordKind: Int] = [:]
            for (kind, count) in try db.query(
                "SELECT kind, count(*) FROM records WHERE created_at >= ? GROUP BY kind", [cutoff], { ($0.text(), Int($0.int())) }
            ) {
                if let kind = RecordKind(rawValue: kind) { byKind[kind] = count }
            }
            return GraphGrowth(
                recordsByKind: byKind,
                links: Int(try db.int("SELECT count(*) FROM links WHERE created_at >= ?", [cutoff]) ?? 0),
                projects: Int(try db.int("SELECT count(*) FROM projects WHERE created_at >= ?", [cutoff]) ?? 0))
        }
    }
}
