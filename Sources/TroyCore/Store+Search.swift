import Foundation

extension Store {
    // MARK: Search

    func searchRecords(_ db: Database, _ query: SearchQuery, useIndex: Bool) throws -> [SearchHit] {
        try TextRules.checkNoNUL(query.text, field: "Search text")
        guard query.text.count <= Limits.searchQuery else {
            throw TroyError.invalid("Search text is \(query.text.count) characters long; the limit is \(Limits.searchQuery).")
        }
        let terms = SearchTerms.split(query.text)
        guard !terms.isEmpty else { throw TroyError.invalid("Search text is empty.") }
        let limit = min(max(query.limit, 1), Limits.searchLimit)

        var clauses: [String] = []
        var args: [SQLValue] = []
        appendFilters(&clauses, &args, projectID: query.projectID, kinds: query.kinds, statuses: query.statuses, tag: query.tag)
        // The LIKE test is the definition of a match. The index only narrows the candidates, so both
        // paths return the same records.
        for term in terms {
            let pattern = SQLValue.text(SearchTerms.likePattern(term))
            clauses.append(
                "(r.title LIKE ? ESCAPE '\\' OR r.body LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM json_each(r.tags) WHERE value LIKE ? ESCAPE '\\'))"
            )
            args.append(contentsOf: [pattern, pattern, pattern])
        }

        let first = SQLValue.text(terms[0])
        let snippetColumns = """
        instr(lower(r.body), lower(?)), \
        substr(r.body, max(1, instr(lower(r.body), lower(?)) - 60), \(Limits.snippetChars)), length(r.body)
        """
        let snippetArgs: [SQLValue] = [first, first]

        let longTerms = terms.filter(SearchTerms.usesIndex)
        if useIndex, !longTerms.isEmpty {
            let match = longTerms.map(SearchTerms.ftsPhrase).joined(separator: " AND ")
            let sql = """
            SELECT \(Columns.summary()), \(snippetColumns)
            FROM records_fts JOIN records r ON r.id = records_fts.rowid
            WHERE records_fts MATCH ? AND \(clauses.joined(separator: " AND "))
            ORDER BY bm25(records_fts, 10.0, 5.0, 1.0), r.updated_at DESC, r.id DESC
            LIMIT ?
            """
            do {
                return try db.query(sql, snippetArgs + [.text(match)] + args + [.int(Int64(limit))], readHit)
            } catch TroyError.database {
                // The index could not answer (for example a damaged index); the LIKE path still can.
            }
        }

        var titleScore: [String] = []
        var titleArgs: [SQLValue] = []
        for term in terms {
            titleScore.append("(CASE WHEN r.title LIKE ? ESCAPE '\\' THEN 1 ELSE 0 END)")
            titleArgs.append(.text(SearchTerms.likePattern(term)))
        }
        let sql = """
        SELECT \(Columns.summary()), \(snippetColumns)
        FROM records r
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY \(titleScore.joined(separator: " + ")) DESC, r.updated_at DESC, r.id DESC
        LIMIT ?
        """
        return try db.query(sql, snippetArgs + args + titleArgs + [.int(Int64(limit))], readHit)
    }

    private func readHit(_ row: Row) -> SearchHit {
        let summary = readSummary(row)
        let position = Int(row.int())
        let text = row.text()
        let bodyLength = Int(row.int())
        let start = position > 0 ? max(1, position - 60) : 1
        var snippet = collapseWhitespace(text)
        if start > 1 { snippet = "…" + snippet }
        if start - 1 + Limits.snippetChars < bodyLength { snippet += "…" }
        return SearchHit(record: summary, snippet: snippet)
    }

    // MARK: Similar

    func similarRecords(
        _ db: Database, title: String, tags: [String], projectID: Int64, excluding: Set<Int64>, limit: Int
    ) throws -> [SimilarRecord] {
        let wanted = Similarity.bigrams(title + " " + tags.joined(separator: " "))
        guard !wanted.isEmpty, limit > 0 else { return [] }
        let candidates = try db.query(
            "SELECT id, title, tags FROM records WHERE project_id = ? ORDER BY updated_at DESC, id DESC LIMIT ?",
            [.int(projectID), .int(Int64(Limits.similarScan))]
        ) { row -> (Int64, Set<UInt64>) in
            let id = row.int()
            return (id, Similarity.bigrams(row.text() + " " + row.text()))
        }
        var scored: [(id: Int64, score: Double, order: Int)] = []
        for (order, candidate) in candidates.enumerated() where !excluding.contains(candidate.0) {
            let score = Similarity.dice(wanted, candidate.1)
            if score >= Limits.similarThreshold { scored.append((candidate.0, score, order)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        let top = Array(scored.prefix(limit))
        guard !top.isEmpty else { return [] }
        let summaries = Dictionary(
            uniqueKeysWithValues: try db.query(
                "SELECT \(Columns.summary()) FROM records r WHERE r.id IN (\(placeholders(top.count)))",
                top.map { .int($0.id) }, readSummary
            ).map { ($0.id, $0) }
        )
        return top.compactMap { item in summaries[item.id].map { SimilarRecord(record: $0, score: item.score) } }
    }

    // MARK: Advisories

    func computeAdvisories(_ db: Database, id: Int64, agent: String) throws -> [Advisory] {
        guard let record = try db.first(
            "SELECT \(Columns.summary()) FROM records r WHERE r.id = ?", [.int(id)], readSummary
        ) else { throw TroyError.notFound("No record #\(id).") }
        if record.status.isFinished { return [] }
        var result: [Advisory] = []

        // Someone else is doing something on the same files. Only work can collide, so this is for
        // tasks; a decision or a note that names the same folder is not in anyone's way.
        if record.kind == .task, !record.paths.isEmpty {
            let holder = record.status == .doing ? (record.assignee ?? agent) : agent
            // A task that has not started and already waits on the other one is told so below;
            // repeating it as an overlap would be noise.
            let awaited: Set<Int64> = record.status == .doing ? [] : Set(try db.query(
                "SELECT target_id FROM links WHERE source_id = ? AND relation = 'depends_on'", [.int(id)], { $0.int() }
            ))
            let others = try db.query(
                "SELECT \(Columns.summary()) FROM records r WHERE r.project_id = ? AND r.status = 'doing' AND r.id <> ? ORDER BY r.claimed_at, r.id",
                [.int(record.projectID), .int(id)], readSummary
            )
            for other in others where (other.assignee ?? "") != holder && !awaited.contains(other.id) {
                let shared = PathRules.sharedPaths(record.paths, other.paths)
                if !shared.isEmpty {
                    result.append(Advisory(kind: .pathOverlap, other: other, detail: shared.joined(separator: ", ")))
                }
            }
        }

        let unfinished = try db.query(
            """
            SELECT l.note, \(Columns.summary("t")) FROM links l JOIN records t ON t.id = l.target_id
            WHERE l.source_id = ? AND l.relation = 'depends_on' AND t.status NOT IN ('done', 'dropped')
            ORDER BY l.id
            """,
            [.int(id)]
        ) { row -> Advisory in
            let note = row.text()
            return Advisory(kind: .unfinishedDependency, other: readSummary(row), detail: note)
        }
        result.append(contentsOf: unfinished)

        let conflicts = try db.query(
            """
            SELECT l.note, \(Columns.summary("o")) FROM links l
            JOIN records o ON o.id = CASE WHEN l.source_id = ?1 THEN l.target_id ELSE l.source_id END
            WHERE (l.source_id = ?1 OR l.target_id = ?1) AND l.relation = 'conflicts_with' AND o.status NOT IN ('done', 'dropped')
            ORDER BY l.id
            """,
            [.int(id)]
        ) { row -> Advisory in
            let note = row.text()
            return Advisory(kind: .conflict, other: readSummary(row), detail: note)
        }
        result.append(contentsOf: conflicts)
        return result
    }
}
