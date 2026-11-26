import Foundation

// Conversions between SQLite rows and the public model types.

enum Clock {
    static func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

enum JSONText {
    static func decodeStrings(_ text: String) -> [String] {
        if text == "[]" || text.isEmpty { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    static func encode(_ strings: [String]) -> String {
        if strings.isEmpty { return "[]" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(strings), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

enum Columns {
    /// The columns `readSummary` consumes, in order, for the records table aliased as `alias`.
    static func summary(_ alias: String = "r") -> String {
        """
        \(alias).id, \(alias).project_id, \(alias).kind, \(alias).status, \(alias).title, \
        substr(\(alias).body, 1, \(Limits.previewChars)), \(alias).tags, \(alias).paths, \(alias).source, \
        \(alias).assignee, \(alias).claimed_at, \
        EXISTS (SELECT 1 FROM links WHERE target_id = \(alias).id AND relation = 'supersedes'), \
        (SELECT count(*) FROM links WHERE source_id = \(alias).id) + (SELECT count(*) FROM links WHERE target_id = \(alias).id), \
        \(alias).created_at, \(alias).updated_at
        """
    }

    static let link = "l.id, l.source_id, l.target_id, l.relation, l.note, l.created_by, l.created_at"
    static let project = "id, name, summary, status, created_at, updated_at"
}

func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func readSummary(_ row: Row) -> RecordSummary {
    let id = row.int()
    let projectID = row.int()
    let kind = RecordKind(rawValue: row.text()) ?? .note
    let status = RecordStatus(rawValue: row.text()) ?? .open
    let title = row.text()
    let preview = collapseWhitespace(row.text())
    let tags = JSONText.decodeStrings(row.text())
    let paths = JSONText.decodeStrings(row.text())
    let source = row.text()
    let assignee = row.optText()
    let claimedAt = row.optInt().map(Clock.date)
    let superseded = row.int() != 0
    let linkCount = Int(row.int())
    let created = Clock.date(row.int())
    let updated = Clock.date(row.int())
    return RecordSummary(
        id: id, projectID: projectID, kind: kind, status: status, title: title, preview: preview, tags: tags, paths: paths,
        source: source, assignee: assignee, claimedAt: claimedAt, isSuperseded: superseded, linkCount: linkCount,
        createdAt: created, updatedAt: updated
    )
}

func readLink(_ row: Row) -> RecordLink {
    RecordLink(
        id: row.int(), sourceID: row.int(), targetID: row.int(), relation: Relation(rawValue: row.text()) ?? .relatesTo,
        note: row.text(), createdBy: row.text(), createdAt: Clock.date(row.int())
    )
}

func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
