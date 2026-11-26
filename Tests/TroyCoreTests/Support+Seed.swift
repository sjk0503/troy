import Foundation
@testable import TroyCore

extension Store {
    /// Inserts `count` varied records straight through SQL in one transaction (for size tests).
    func seed(project: Project, count: Int) throws {
        let words = ["scheduler", "retry", "token", "limit", "export", "graph", "layout", "store", "search", "index", "claim", "agent",
                     "link", "cycle", "overview", "advisory", "migration", "schema", "trigger", "version", "panel", "window", "hotkey",
                     "settings", "cache", "backup", "toss", "payment", "auth", "session", "server", "client", "protocol", "stream"]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let kinds = ["task", "task", "task", "decision", "note", "result"]
        let statuses = ["open", "open", "done", "doing", "dropped"]
        try read { db in
            try db.transaction {
                let now = Clock.nowMillis()
                for index in 0..<count {
                    let title = (0..<(3 + next(4))).map { _ in words[next(words.count)] }.joined(separator: " ")
                    let body = (0..<(40 + next(60))).map { _ in words[next(words.count)] }.joined(separator: " ")
                    let kind = kinds[next(kinds.count)]
                    var status = statuses[next(statuses.count)]
                    if kind != "task" && status == "doing" { status = "open" }
                    let tags = JSONText.encode([words[next(words.count)], words[next(words.count)]])
                    let claimed: SQLValue = status == "doing" ? .int(now) : .null
                    try db.run(
                        """
                        INSERT INTO records (project_id, kind, status, title, body, tags, paths, source, assignee, claimed_at, created_at, updated_at, updated_by)
                        VALUES (?, ?, ?, ?, ?, ?, '[]', 'seed', ?, ?, ?, ?, 'seed')
                        """,
                        [.int(project.id), .text(kind), .text(status), .text(title), .text(body), .text(tags),
                         status == "doing" ? .text("seed/\(index % 3)") : .null, claimed,
                         .int(now - Int64(index) * 1000), .int(now - Int64(index) * 1000)]
                    )
                }
            }
        }
    }
}
