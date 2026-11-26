import Foundation

extension Store {
    /// Symmetric relations are stored with the smaller id first.
    static func orient(from: Int64, to: Int64, relation: Relation) -> (Int64, Int64) {
        relation.isSymmetric && from > to ? (to, from) : (from, to)
    }

    /// Inserts a link inside the open transaction. `wrote` is false when the link already existed unchanged.
    func insertLink(
        _ db: Database, from: Int64, to: Int64, relation: Relation, note: String, agent: String
    ) throws -> (link: RecordLink, wrote: Bool) {
        guard from != to else { throw TroyError.invalid("A record cannot be linked to itself (#\(from)).") }
        try requireRecord(db, id: from)
        try requireRecord(db, id: to)
        let (source, target) = Store.orient(from: from, to: to, relation: relation)
        let columns = "SELECT \(Columns.link) FROM links l WHERE l.source_id = ? AND l.target_id = ? AND l.relation = ?"
        let key: [SQLValue] = [.int(source), .int(target), .text(relation.rawValue)]
        if var existing = try db.first(columns, key, readLink) {
            if !note.isEmpty && note != existing.note {
                try db.run("UPDATE links SET note = ? WHERE id = ?", [.text(note), .int(existing.id)])
                existing.note = note
                return (existing, true)
            }
            return (existing, false)
        }
        if relation.rejectsCycles { try rejectCycle(db, source: source, target: target, relation: relation) }
        let now = Clock.nowMillis()
        try db.run(
            "INSERT INTO links (source_id, target_id, relation, note, created_by, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.int(source), .int(target), .text(relation.rawValue), .text(note), .text(agent), .int(now)]
        )
        let id = db.lastInsertRowID
        return (
            RecordLink(id: id, sourceID: source, targetID: target, relation: relation, note: note, createdBy: agent, createdAt: Clock.date(now)),
            true
        )
    }

    /// Adding `source → target` closes a cycle when `source` is already reachable from `target`.
    private func rejectCycle(_ db: Database, source: Int64, target: Int64, relation: Relation) throws {
        let reachable = try db.exists(
            """
            WITH RECURSIVE reach(id) AS (
              SELECT ?1
              UNION
              SELECT l.target_id FROM links l JOIN reach ON l.source_id = reach.id WHERE l.relation = ?2
            )
            SELECT 1 FROM reach WHERE id = ?3 LIMIT 1
            """,
            [.int(target), .text(relation.rawValue), .int(source)]
        )
        guard reachable else { return }
        // Rare path: rebuild one chain from `target` to `source` to name it in the message.
        var parent: [Int64: Int64] = [:]
        var queue: [Int64] = [target]
        var visited: Set<Int64> = [target]
        var index = 0
        search: while index < queue.count {
            let node = queue[index]
            index += 1
            let next = try db.query(
                "SELECT target_id FROM links WHERE source_id = ? AND relation = ?", [.int(node), .text(relation.rawValue)]
            ) { $0.int() }
            for neighbour in next where visited.insert(neighbour).inserted {
                parent[neighbour] = node
                if neighbour == source { break search }
                queue.append(neighbour)
            }
        }
        var chain: [Int64] = [source]
        var current = source
        while let before = parent[current] {
            chain.append(before)
            current = before
        }
        chain.reverse()
        let phrase = relation.forwardPhrase
        let path = (chain + [target]).map { "#\($0)" }.joined(separator: " \(phrase) ")
        throw TroyError.conflict(
            "Linking #\(source) \(phrase) #\(target) would close a cycle: \(path). Remove one of those links first, or link the other way round."
        )
    }

    func fetchLinks(_ db: Database, of id: Int64) throws -> [LinkedRecord] {
        try requireRecord(db, id: id)
        let rows = try db.query(
            """
            SELECT \(Columns.link), l.source_id = ?1, \(Columns.summary("o"))
            FROM links l JOIN records o ON o.id = CASE WHEN l.source_id = ?1 THEN l.target_id ELSE l.source_id END
            WHERE l.source_id = ?1 OR l.target_id = ?1
            """,
            [.int(id)]
        ) { row -> LinkedRecord in
            let link = readLink(row)
            let outgoing = row.int() != 0
            return LinkedRecord(link: link, other: readSummary(row), isOutgoing: outgoing)
        }
        let order = Dictionary(uniqueKeysWithValues: Relation.allCases.enumerated().map { ($1, $0) })
        return rows.sorted { a, b in
            if a.isOutgoing != b.isOutgoing { return a.isOutgoing }
            let ra = order[a.link.relation] ?? 0, rb = order[b.link.relation] ?? 0
            if ra != rb { return ra < rb }
            if a.link.createdAt != b.link.createdAt { return a.link.createdAt > b.link.createdAt }
            return a.link.id > b.link.id
        }
    }
}
