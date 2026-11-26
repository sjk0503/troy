import Foundation
import TroyCore

/// The text agents read. Pure functions from model values to strings, shared by the MCP
/// tools and the `troy` command line so both print the same words.
public enum TroyText {
    // MARK: Ages and dates

    /// `5m`, `2h`, `3d`, `2w`, then a date.
    public static func age(since then: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(then))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 14 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 9 { return "\(weeks)w" }
        return date(then)
    }

    /// The same as a phrase: "just now", "5m ago", "3d ago", and "on 2026-09-01" once it is a date.
    public static func ago(since then: Date, now: Date = Date()) -> String {
        let short = age(since: then, now: now)
        if short == "0m" { return "just now" }
        return short.contains("-") ? "on \(short)" : "\(short) ago"
    }

    /// `2026-11-24` in the local time zone.
    public static func date(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isStale(_ record: RecordSummary, now: Date) -> Bool {
        guard record.status == .doing, let claimed = record.claimedAt else { return false }
        return now.timeIntervalSince(claimed) > Double(Limits.staleClaimHours) * 3600
    }

    /// `[task/open]`, `[task/doing by codex/a1f, 2h]`, `[decision/open, superseded]`.
    public static func tagline(_ record: RecordSummary, now: Date = Date()) -> String {
        var inner = "\(record.kind.rawValue)/\(record.status.rawValue)"
        if record.status == .doing, let holder = record.assignee {
            inner += " by \(holder)"
            if let claimed = record.claimedAt { inner += ", \(age(since: claimed, now: now))" }
            if isStale(record, now: now) { inner += ", stale" }
        }
        if record.isSuperseded { inner += ", superseded" }
        return "[\(inner)]"
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: Context

    public static let contextDefaultChars = 6_000
    public static let contextMinChars = 1_000

    private struct Section {
        var title: String
        var lines: [String]
    }

    /// The project's state: in progress, ready, blocked, watch out, decisions, recent.
    /// Sections are cut from the bottom to stay within `maxChars`.
    public static func context(_ overview: ProjectOverview, maxChars: Int = contextDefaultChars, now: Date = Date()) -> String {
        let maxChars = max(contextMinChars, maxChars)
        let project = overview.project
        let stats = overview.stats

        var header = "Project #\(project.id) \"\(project.name)\""
        if !project.paths.isEmpty { header += " — " + clip(project.paths.joined(separator: ", "), 200) }
        var facts = [plural(stats.records, "record"), "\(stats.openTasks) open \(stats.openTasks == 1 ? "task" : "tasks")", "\(stats.doing) in progress"]
        facts.append(stats.lastActivity.map { "last activity \(ago(since: $0, now: now))" } ?? "no activity yet")
        header += "\n" + facts.joined(separator: " · ")
        let summary = oneLine(project.summary)
        if !summary.isEmpty { header += "\n" + clip(summary, 240) }
        let footer = "Keep this current without being asked: troy_save {\"project\":\(project.id),…} each decision, finding and finished piece of work as it happens, and claim a task with troy_update before working on it. Read bodies with troy_read {\"ids\":[…]}."

        func parentSuffix(_ id: Int64) -> String {
            guard let parents = overview.parents[id], !parents.isEmpty else { return "" }
            return " · part of " + parents.map { "#\($0)" }.joined(separator: ", ")
        }

        var sections: [Section] = []
        let doing = overview.doing.map { record -> String in
            var line = "#\(record.id) \(record.title)"
            if let holder = record.assignee {
                var who = holder
                if let claimed = record.claimedAt { who += ", \(age(since: claimed, now: now))" }
                if isStale(record, now: now) { who += ", stale" }
                line += " — " + who
            }
            line += parentSuffix(record.id)
            if !record.paths.isEmpty { line += " · paths: " + record.paths.prefix(3).joined(separator: ", ") }
            return line
        }
        sections.append(Section(title: "IN PROGRESS", lines: doing))
        sections.append(Section(title: "READY", lines: overview.ready.map { "#\($0.id) \($0.title)\(parentSuffix($0.id))" }))
        sections.append(Section(title: "BLOCKED", lines: overview.blocked.map { item in
            "#\(item.record.id) \(item.record.title) — waits on " + item.waitingOn.map { "#\($0.id)" }.joined(separator: ", ")
        }))
        sections.append(Section(title: "WATCH OUT", lines: overview.collisions.map { collision in
            let (a, b) = (collision.first.id, collision.second.id)
            let detail = oneLine(collision.detail)
            switch collision.kind {
            case .pathOverlap:
                return "#\(a) and #\(b) are both in progress and touch " + (detail.isEmpty ? "the same files" : detail)
            case .conflict:
                return "#\(a) conflicts with #\(b)" + (detail.isEmpty ? "" : ": " + detail)
            case .unfinishedDependency:
                return "#\(a) depends on #\(b), which is not finished"
            }
        }))
        sections.append(Section(title: "DECISIONS IN EFFECT", lines: overview.decisions.map {
            "#\($0.id) \($0.title) (\(date($0.createdAt)))"
        }))
        sections.append(Section(title: "RECENT", lines: overview.recent.map {
            "#\($0.id) \(tagline($0, now: now)) \($0.title) · \(age(since: $0.updatedAt, now: now))"
        }))
        sections = sections.filter { !$0.lines.isEmpty }

        func block(_ section: Section, lines: Int? = nil) -> String {
            section.title + "\n" + section.lines.prefix(lines ?? section.lines.count).joined(separator: "\n")
        }
        func assemble(_ blocks: [String]) -> String { ([header] + blocks + [footer]).joined(separator: "\n\n") }

        let full = assemble(sections.map { block($0) })
        if full.count <= maxChars { return full }

        let reserve = 170
        var budget = maxChars - header.count - footer.count - 4 - reserve
        var blocks: [String] = []
        var dropped: [String] = []
        var stopped = false
        for section in sections {
            if stopped { dropped.append("\(section.title) (\(section.lines.count))"); continue }
            let whole = block(section)
            if whole.count + 2 <= budget {
                blocks.append(whole)
                budget -= whole.count + 2
                continue
            }
            stopped = true
            var kept = 0
            var used = section.title.count + 1
            for line in section.lines where used + line.count + 1 <= budget - 40 {
                used += line.count + 1
                kept += 1
            }
            if kept > 0 {
                let left = section.lines.count - kept
                blocks.append(block(section, lines: kept) + "\n… \(left) more not shown (raise max_chars)")
            } else {
                dropped.append("\(section.title) (\(section.lines.count))")
            }
        }
        if !dropped.isEmpty {
            blocks.append("Left out to stay within max_chars: " + dropped.joined(separator: ", ") + ". Raise max_chars, or use troy_search.")
        }
        return assemble(blocks)
    }

    /// The reply of `troy_context` in a folder that has no project yet: a repository, or a working
    /// folder in no repository that Troy takes for a project. Nothing is created by reading: the
    /// first save with this folder as `project` creates it.
    public static func pending(root: String, isRepository: Bool, projects: [Project]) -> String {
        let others = projects.isEmpty
            ? "There are no projects yet."
            : "Other projects: " + projects.map { "#\($0.id) \($0.name)" }.joined(separator: ", ") + "."
        return """
        No project yet for this \(isRepository ? "repository" : "folder"): \(root)
        Record this session's work without being asked: troy_save each decision (with its reason), finding and finished piece of work as it happens. The first save with "project": \(JSON.string(root).text) creates the project, named after the folder and linked to it.
        \(others)
        """
    }

    // MARK: Records

    /// A record with its links and advisories, for `troy_read`.
    public static func record(
        _ detail: RecordDetail, projectName: String?, updatedBy: String?, maxChars: Int, now: Date = Date()
    ) -> String {
        let record = detail.record
        let summary = record.summary
        var out = "#\(record.id) \(tagline(summary, now: now)) \(record.title)\n"
        var meta = ["project #\(record.projectID)" + (projectName.map { " \($0)" } ?? "")]
        if !record.tags.isEmpty { meta.append("tags: " + record.tags.joined(separator: ", ")) }
        if !record.paths.isEmpty { meta.append("paths: " + record.paths.joined(separator: ", ")) }
        meta.append("created \(date(summary.createdAt))")
        var updated = "updated \(ago(since: summary.updatedAt, now: now))"
        if let who = (updatedBy?.isEmpty == false ? updatedBy : nil) ?? (summary.source.isEmpty ? nil : summary.source) {
            updated += " by \(who)"
        }
        meta.append(updated)
        out += meta.joined(separator: " · ")

        // Blank lines around the body go; the first line keeps its indentation, because four
        // leading spaces are an indented code block in Markdown.
        let body = trimmingBlankLines(record.body)
        if !body.isEmpty {
            out += "\n\n"
            if body.count > maxChars {
                out += String(body.prefix(maxChars))
                out += "\n[Body cut at \(maxChars) of \(body.count) characters. Pass a larger max_chars to read all of it.]"
            } else {
                out += body
            }
        }
        if !detail.links.isEmpty {
            out += "\n\nLinks:"
            for item in detail.links {
                var line = "\n- \(item.phrase) #\(item.other.id) \(tagline(item.other, now: now)) \(item.other.title)"
                if item.other.projectID != record.projectID { line += " (project #\(item.other.projectID))" }
                let note = oneLine(item.link.note)
                if !note.isEmpty { line += " — " + note }
                out += line
            }
        }
        if !detail.advisories.isEmpty { out += "\n" + advisories(detail.advisories, now: now) }
        return out
    }

    /// `Watch out:` followed by one line per advisory.
    public static func advisories(_ items: [Advisory], now: Date = Date()) -> String {
        var lines = ["Watch out:"]
        for item in items {
            let other = "#\(item.other.id) \(tagline(item.other, now: now))"
            let detail = oneLine(item.detail)
            switch item.kind {
            case .pathOverlap:
                lines.append("- \(other) touches the same paths" + (detail.isEmpty ? "" : ": " + detail))
            case .unfinishedDependency:
                lines.append("- depends on \(other), which is not finished")
            case .conflict:
                lines.append("- conflicts with \(other)" + (detail.isEmpty ? ", which is not finished" : ": " + detail))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Writes

    static func quoted(_ title: String) -> String { "\"\(title)\"" }

    /// `text` without the blank lines before and after it, and without trailing whitespace.
    /// The indentation of the first line is kept.
    static func trimmingBlankLines(_ text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        var joined = lines.joined(separator: "\n")
        while let last = joined.last, last.isWhitespace { joined.removeLast() }
        return joined
    }

    /// The reply to `troy_save`.
    public static func saved(_ result: SaveResult, project: Project, now: Date = Date()) -> String {
        let record = result.record
        let head = "#\(record.id) \(tagline(record.summary, now: now)) \(quoted(record.title)) in project #\(project.id) \(project.name)."
        var lines = [
            result.deduplicated
                ? "No second record was stored: an identical one was just saved as \(head)"
                : "Saved \(head)"
        ]
        if !result.links.isEmpty {
            let parts = result.links.map { link -> String in
                let other = link.sourceID == record.id ? link.targetID : link.sourceID
                return "\(link.relation.forwardPhrase) #\(other)"
            }
            // A repeated save can still carry links the first one did not; say that they are there.
            lines.append("Linked: " + parts.joined(separator: ", ") + ".")
        }
        if result.deduplicated {
            if !result.advisories.isEmpty { lines.append(advisories(result.advisories, now: now)) }
            return lines.joined(separator: "\n")
        }
        if !result.similar.isEmpty {
            lines.append("Similar records already exist. Link them with troy_link, or reuse one instead of duplicating:")
            for item in result.similar {
                let percent = Int((item.score * 100).rounded())
                let same = item.score >= Limits.duplicateThreshold ? ", probably the same item" : ""
                lines.append("- #\(item.record.id) \(tagline(item.record, now: now)) \(item.record.title) (\(percent)%\(same))")
            }
        }
        if !result.advisories.isEmpty { lines.append(advisories(result.advisories, now: now)) }
        return lines.joined(separator: "\n")
    }

    /// What a patch changed, for example `status open → doing; tags changed`.
    public static func changes(from old: Record, to new: Record, patch: RecordPatch) -> String {
        var parts: [String] = []
        if old.status != new.status { parts.append("status \(old.status.rawValue) → \(new.status.rawValue)") }
        if old.kind != new.kind { parts.append("kind \(old.kind.rawValue) → \(new.kind.rawValue)") }
        if old.title != new.title { parts.append("title changed") }
        if let append = patch.append, !append.isEmpty, old.body != new.body {
            parts.append("appended \(plural(append.count, "character"))")
        } else if old.body != new.body {
            parts.append("body replaced")
        }
        if old.tags != new.tags { parts.append("tags: " + (new.tags.isEmpty ? "none" : new.tags.joined(separator: ", "))) }
        if old.paths != new.paths { parts.append("paths: " + (new.paths.isEmpty ? "none" : new.paths.joined(separator: ", "))) }
        return parts.joined(separator: "; ")
    }

    // MARK: Search

    public static func search(
        hits: [SearchHit], query: String, scope: String, more: Bool, limit: Int, now: Date = Date()
    ) -> String {
        guard !hits.isEmpty else {
            return "No results for \"\(query)\" in \(scope). Try fewer or different words, or search every project with all_projects: true."
        }
        var lines = ["\(plural(hits.count, "result")) for \"\(query)\" in \(scope):"]
        for (index, hit) in hits.enumerated() {
            let record = hit.record
            lines.append("\(index + 1). #\(record.id) \(tagline(record, now: now)) \(record.title) · \(age(since: record.updatedAt, now: now))")
            let snippet = oneLine(hit.snippet)
            if !snippet.isEmpty { lines.append("   " + clip(snippet, Limits.snippetChars + 2)) }
        }
        if more {
            lines.append("There may be more results. Narrow the query, or raise limit (now \(limit), at most 50).")
        }
        return lines.joined(separator: "\n")
    }

    /// The reply of `troy_search` for a folder that has no project yet.
    public static func searchPending(query: String, root: String, isRepository: Bool) -> String {
        "No results for \"\(query)\": this \(isRepository ? "repository" : "folder") has no project yet, so nothing is saved for it. The first troy_save with \"project\": \(JSON.string(root).text) creates it. To search the other projects pass all_projects: true."
    }

    // MARK: Projects

    public static func projects(_ list: [ProjectSummary], current: Int64?, now: Date = Date()) -> String {
        guard !list.isEmpty else {
            return "No projects yet. Create one with troy_new_project {\"name\":\"…\"}."
        }
        var lines = ["\(plural(list.count, "project")):"]
        for item in list {
            let project = item.project
            var line = "#\(project.id) \(project.name)"
            if project.status == .archived { line += " [archived]" }
            let stats = item.stats
            var facts = [plural(stats.records, "record"), "\(stats.openTasks) open", "\(stats.doing) in progress"]
            if let last = stats.lastActivity { facts.append(ago(since: last, now: now)) }
            line += " — " + facts.joined(separator: " · ")
            if project.id == current { line += " ← this folder" }
            lines.append(line)
            if !project.paths.isEmpty { lines.append("   folders: " + project.paths.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }
}
