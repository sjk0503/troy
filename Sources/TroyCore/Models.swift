import Foundation

// MARK: - Vocabulary

/// What a record is.
public enum RecordKind: String, CaseIterable, Codable, Sendable {
    case task, decision, note, result, prompt
}

/// Where a record stands. "Superseded" is not a status: a record is superseded
/// while at least one `supersedes` link points at it (see `RecordSummary.isSuperseded`).
public enum RecordStatus: String, CaseIterable, Codable, Sendable {
    /// Current and not being worked on.
    case open
    /// Someone is working on it now. Setting this claims the record.
    case doing
    case done
    /// Abandoned or no longer valid.
    case dropped

    public var isFinished: Bool { self == .done || self == .dropped }
}

/// The fixed set of link meanings. A link reads "source <relation> target".
public enum Relation: String, CaseIterable, Codable, Sendable {
    /// The source is a sub-task or component of the target.
    case partOf = "part_of"
    /// The source cannot be finished before the target is done.
    case dependsOn = "depends_on"
    /// The source was produced from, or justified by, the target.
    case derivedFrom = "derived_from"
    /// The source replaces the target.
    case supersedes
    /// Same topic. Symmetric.
    case relatesTo = "relates_to"
    /// Contradicting decisions or overlapping work. Symmetric.
    case conflictsWith = "conflicts_with"

    /// Symmetric relations are stored once, with the smaller record id as the source.
    public var isSymmetric: Bool { self == .relatesTo || self == .conflictsWith }

    /// Directed relations may not form a cycle.
    public var rejectsCycles: Bool { !isSymmetric }

    /// How the link reads from its source: "#1 part of #2".
    public var forwardPhrase: String {
        switch self {
        case .partOf: "part of"
        case .dependsOn: "depends on"
        case .derivedFrom: "derived from"
        case .supersedes: "supersedes"
        case .relatesTo: "relates to"
        case .conflictsWith: "conflicts with"
        }
    }

    /// How the link reads from its target: "#2 contains #1".
    public var inversePhrase: String {
        switch self {
        case .partOf: "contains"
        case .dependsOn: "blocks"
        case .derivedFrom: "led to"
        case .supersedes: "superseded by"
        case .relatesTo: "relates to"
        case .conflictsWith: "conflicts with"
        }
    }
}

public enum ProjectStatus: String, CaseIterable, Codable, Sendable {
    case active, archived
}

// MARK: - Projects

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    /// Unique, compared without case.
    public var name: String
    public var summary: String
    /// Absolute folders linked to this project (usually one git root). Used to pick
    /// the project for a working directory.
    public var paths: [String]
    public var status: ProjectStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64, name: String, summary: String, paths: [String], status: ProjectStatus, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.summary = summary; self.paths = paths
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ProjectStats: Hashable, Codable, Sendable {
    /// All records in the project.
    public var records: Int
    /// Tasks with status `open`.
    public var openTasks: Int
    /// Records with status `doing`.
    public var doing: Int
    /// Latest `updatedAt` among the project's records.
    public var lastActivity: Date?

    public init(records: Int = 0, openTasks: Int = 0, doing: Int = 0, lastActivity: Date? = nil) {
        self.records = records; self.openTasks = openTasks; self.doing = doing; self.lastActivity = lastActivity
    }
}

public struct ProjectSummary: Identifiable, Hashable, Codable, Sendable {
    public var project: Project
    public var stats: ProjectStats
    public var id: Int64 { project.id }

    public init(project: Project, stats: ProjectStats) {
        self.project = project; self.stats = stats
    }
}

// MARK: - Records

/// A record without its full body. Lists, search results, the graph and link targets use this.
public struct RecordSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var projectID: Int64
    public var kind: RecordKind
    public var status: RecordStatus
    public var title: String
    /// The start of the body on one line, at most `Limits.previewChars` characters.
    public var preview: String
    public var tags: [String]
    /// Files or folders this work touches, relative to the project root.
    public var paths: [String]
    /// Who created it, for example "claude-code/a3f" or "app".
    public var source: String
    /// Who is working on it. Set only while `status == .doing`.
    public var assignee: String?
    public var claimedAt: Date?
    /// True while another record supersedes this one.
    public var isSuperseded: Bool
    /// Number of links touching this record.
    public var linkCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64, projectID: Int64, kind: RecordKind, status: RecordStatus, title: String, preview: String = "",
        tags: [String] = [], paths: [String] = [], source: String = "", assignee: String? = nil, claimedAt: Date? = nil,
        isSuperseded: Bool = false, linkCount: Int = 0, createdAt: Date, updatedAt: Date
    ) {
        self.id = id; self.projectID = projectID; self.kind = kind; self.status = status; self.title = title
        self.preview = preview; self.tags = tags; self.paths = paths; self.source = source; self.assignee = assignee
        self.claimedAt = claimedAt; self.isSuperseded = isSuperseded; self.linkCount = linkCount
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A record with its full body.
public struct Record: Identifiable, Hashable, Codable, Sendable {
    public var summary: RecordSummary
    /// Markdown.
    public var body: String
    /// Increases by one on every change. Used for optimistic edits.
    public var rev: Int

    public var id: Int64 { summary.id }
    public var projectID: Int64 { summary.projectID }
    public var kind: RecordKind { summary.kind }
    public var status: RecordStatus { summary.status }
    public var title: String { summary.title }
    public var tags: [String] { summary.tags }
    public var paths: [String] { summary.paths }

    public init(summary: RecordSummary, body: String, rev: Int) {
        self.summary = summary; self.body = body; self.rev = rev
    }
}

/// What a record looked like before one change. Only the fields that changed are set.
public struct RecordVersion: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var recordID: Int64
    /// The revision that was replaced.
    public var rev: Int
    /// Who made the change.
    public var actor: String
    public var changedAt: Date
    public var title: String?
    public var body: String?
    public var kind: RecordKind?
    public var status: RecordStatus?
    public var tags: [String]?
    public var paths: [String]?
    public var projectID: Int64?
    /// Who held the record before this change, when the holder changed (a release or a takeover).
    public var assignee: String?

    public init(
        id: Int64, recordID: Int64, rev: Int, actor: String, changedAt: Date, title: String? = nil, body: String? = nil,
        kind: RecordKind? = nil, status: RecordStatus? = nil, tags: [String]? = nil, paths: [String]? = nil, projectID: Int64? = nil,
        assignee: String? = nil
    ) {
        self.id = id; self.recordID = recordID; self.rev = rev; self.actor = actor; self.changedAt = changedAt
        self.title = title; self.body = body; self.kind = kind; self.status = status
        self.tags = tags; self.paths = paths; self.projectID = projectID; self.assignee = assignee
    }
}

// MARK: - Links

public struct RecordLink: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    /// For symmetric relations this is the smaller of the two record ids.
    public var sourceID: Int64
    public var targetID: Int64
    public var relation: Relation
    /// Optional reason, free text.
    public var note: String
    public var createdBy: String
    public var createdAt: Date

    public init(id: Int64, sourceID: Int64, targetID: Int64, relation: Relation, note: String = "", createdBy: String = "", createdAt: Date) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.relation = relation
        self.note = note; self.createdBy = createdBy; self.createdAt = createdAt
    }
}

/// A link seen from one of its two records.
public struct LinkedRecord: Identifiable, Hashable, Codable, Sendable {
    public var link: RecordLink
    /// The record on the other end.
    public var other: RecordSummary
    /// True when the record being viewed is the link's source.
    public var isOutgoing: Bool
    public var id: Int64 { link.id }

    /// "part of", "contains", "depends on", "blocks", …
    public var phrase: String {
        isOutgoing || link.relation.isSymmetric ? link.relation.forwardPhrase : link.relation.inversePhrase
    }

    public init(link: RecordLink, other: RecordSummary, isOutgoing: Bool) {
        self.link = link; self.other = other; self.isOutgoing = isOutgoing
    }
}

// MARK: - Writing

public struct LinkDraft: Hashable, Codable, Sendable {
    public var to: Int64
    public var relation: Relation
    public var note: String

    public init(to: Int64, relation: Relation, note: String = "") {
        self.to = to; self.relation = relation; self.note = note
    }
}

public struct RecordDraft: Hashable, Sendable {
    public var projectID: Int64
    public var kind: RecordKind
    public var title: String
    public var body: String
    public var tags: [String]
    public var paths: [String]
    /// `.doing` claims the new record for the store's agent.
    public var status: RecordStatus
    /// Shorthand for a `part_of` link to this record.
    public var parent: Int64?
    /// Links from the new record. Created in the same transaction.
    public var links: [LinkDraft]

    public init(
        projectID: Int64, kind: RecordKind, title: String, body: String = "", tags: [String] = [], paths: [String] = [],
        status: RecordStatus = .open, parent: Int64? = nil, links: [LinkDraft] = []
    ) {
        self.projectID = projectID; self.kind = kind; self.title = title; self.body = body; self.tags = tags
        self.paths = paths; self.status = status; self.parent = parent; self.links = links
    }
}

/// Fields left `nil` keep their value.
public struct RecordPatch: Hashable, Sendable {
    public var title: String?
    /// Replaces the whole body. Cannot be combined with `append`.
    public var body: String?
    /// Added to the end of the body after a blank line.
    public var append: String?
    public var kind: RecordKind?
    public var status: RecordStatus?
    public var tags: [String]?
    public var paths: [String]?
    /// Moves the record to another project.
    public var projectID: Int64?
    /// Allows claiming a record that another agent is `doing`.
    public var takeover: Bool
    /// When set, the update fails with `.conflict` if the record's `rev` differs.
    public var expectedRev: Int?

    public init(
        title: String? = nil, body: String? = nil, append: String? = nil, kind: RecordKind? = nil, status: RecordStatus? = nil,
        tags: [String]? = nil, paths: [String]? = nil, projectID: Int64? = nil, takeover: Bool = false, expectedRev: Int? = nil
    ) {
        self.title = title; self.body = body; self.append = append; self.kind = kind; self.status = status
        self.tags = tags; self.paths = paths; self.projectID = projectID; self.takeover = takeover; self.expectedRev = expectedRev
    }
}

// MARK: - Advisories

public enum AdvisoryKind: String, Codable, Sendable {
    /// Another agent is `doing` a record that touches the same files.
    case pathOverlap
    /// The record depends on something that is not finished.
    case unfinishedDependency
    /// A `conflicts_with` link to a record that is not finished.
    case conflict
}

/// Something the caller should know before continuing. Advisories never block a write.
public struct Advisory: Hashable, Codable, Sendable {
    public var kind: AdvisoryKind
    /// The record this one collides with or waits on.
    public var other: RecordSummary
    /// The shared paths (comma separated) or the link note. May be empty.
    public var detail: String

    public init(kind: AdvisoryKind, other: RecordSummary, detail: String = "") {
        self.kind = kind; self.other = other; self.detail = detail
    }
}

public struct SimilarRecord: Hashable, Codable, Sendable {
    public var record: RecordSummary
    /// 0…1. At or above `Limits.duplicateThreshold` it is probably the same item.
    public var score: Double

    public init(record: RecordSummary, score: Double) {
        self.record = record; self.score = score
    }
}

public struct SaveResult: Hashable, Sendable {
    public var record: Record
    /// Links created together with the record.
    public var links: [RecordLink]
    /// True when an identical record had just been saved and that one was returned instead.
    public var deduplicated: Bool
    /// Existing records in the same project with a similar title or tags, best first.
    public var similar: [SimilarRecord]
    public var advisories: [Advisory]

    public init(record: Record, links: [RecordLink] = [], deduplicated: Bool = false, similar: [SimilarRecord] = [], advisories: [Advisory] = []) {
        self.record = record; self.links = links; self.deduplicated = deduplicated; self.similar = similar; self.advisories = advisories
    }
}

public struct UpdateResult: Hashable, Sendable {
    public var record: Record
    /// False when the patch changed nothing; nothing was written.
    public var changed: Bool
    public var advisories: [Advisory]

    public init(record: Record, changed: Bool, advisories: [Advisory] = []) {
        self.record = record; self.changed = changed; self.advisories = advisories
    }
}

// MARK: - Reading

public enum RecordSort: String, Codable, Sendable {
    case updatedDescending, createdDescending
}

public struct RecordQuery: Hashable, Sendable {
    /// `nil` means every project.
    public var projectID: Int64?
    /// Empty means every kind.
    public var kinds: Set<RecordKind>
    /// Empty means every status.
    public var statuses: Set<RecordStatus>
    public var tag: String?
    public var includeSuperseded: Bool
    public var sort: RecordSort
    public var limit: Int
    public var offset: Int

    public init(
        projectID: Int64? = nil, kinds: Set<RecordKind> = [], statuses: Set<RecordStatus> = [], tag: String? = nil,
        includeSuperseded: Bool = true, sort: RecordSort = .updatedDescending, limit: Int = 200, offset: Int = 0
    ) {
        self.projectID = projectID; self.kinds = kinds; self.statuses = statuses; self.tag = tag
        self.includeSuperseded = includeSuperseded; self.sort = sort; self.limit = limit; self.offset = offset
    }
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    /// `nil` searches every project.
    public var projectID: Int64?
    public var kinds: Set<RecordKind>
    public var statuses: Set<RecordStatus>
    public var tag: String?
    public var limit: Int

    public init(text: String, projectID: Int64? = nil, kinds: Set<RecordKind> = [], statuses: Set<RecordStatus> = [], tag: String? = nil, limit: Int = 20) {
        self.text = text; self.projectID = projectID; self.kinds = kinds; self.statuses = statuses; self.tag = tag; self.limit = limit
    }
}

public struct SearchHit: Identifiable, Hashable, Codable, Sendable {
    public var record: RecordSummary
    /// Text around the first match in the body, or the start of the body.
    public var snippet: String
    public var id: Int64 { record.id }

    public init(record: RecordSummary, snippet: String) {
        self.record = record; self.snippet = snippet
    }
}

/// A record with everything needed to show or explain it.
public struct RecordDetail: Hashable, Sendable {
    public var record: Record
    public var links: [LinkedRecord]
    public var advisories: [Advisory]

    public init(record: Record, links: [LinkedRecord] = [], advisories: [Advisory] = []) {
        self.record = record; self.links = links; self.advisories = advisories
    }
}

public struct BlockedRecord: Hashable, Codable, Sendable {
    public var record: RecordSummary
    /// Unfinished records it depends on.
    public var waitingOn: [RecordSummary]

    public init(record: RecordSummary, waitingOn: [RecordSummary]) {
        self.record = record; self.waitingOn = waitingOn
    }
}

/// Two unfinished records that may get in each other's way.
public struct Collision: Hashable, Codable, Sendable {
    public var first: RecordSummary
    public var second: RecordSummary
    /// `.conflict` (an explicit link) or `.pathOverlap` (both `doing`, same files, different agents).
    public var kind: AdvisoryKind
    public var detail: String

    public init(first: RecordSummary, second: RecordSummary, kind: AdvisoryKind, detail: String = "") {
        self.first = first; self.second = second; self.kind = kind; self.detail = detail
    }
}

/// The state of a project at a glance: what the context tool and the menu bar panel show.
public struct ProjectOverview: Hashable, Sendable {
    public var project: Project
    public var stats: ProjectStats
    public var kindCounts: [RecordKind: Int]
    /// Records being worked on, oldest claim first.
    public var doing: [RecordSummary]
    /// Open tasks that wait on nothing.
    public var ready: [RecordSummary]
    /// Open or doing tasks that depend on unfinished records.
    public var blocked: [BlockedRecord]
    public var collisions: [Collision]
    /// Decisions in effect: not dropped and not superseded, newest first.
    public var decisions: [RecordSummary]
    /// Most recently updated records that are not listed above.
    public var recent: [RecordSummary]
    /// For every record listed above: the ids it is `part_of`.
    public var parents: [Int64: [Int64]]

    public init(
        project: Project, stats: ProjectStats, kindCounts: [RecordKind: Int] = [:], doing: [RecordSummary] = [], ready: [RecordSummary] = [],
        blocked: [BlockedRecord] = [], collisions: [Collision] = [], decisions: [RecordSummary] = [], recent: [RecordSummary] = [],
        parents: [Int64: [Int64]] = [:]
    ) {
        self.project = project; self.stats = stats; self.kindCounts = kindCounts; self.doing = doing; self.ready = ready
        self.blocked = blocked; self.collisions = collisions; self.decisions = decisions; self.recent = recent; self.parents = parents
    }
}

/// Records and links to draw.
public struct GraphSnapshot: Hashable, Sendable {
    public var records: [RecordSummary]
    /// Links whose two ends are both in `records`.
    public var links: [RecordLink]
    /// True when the project has more records than `Limits.graphRecords`.
    public var truncated: Bool

    public init(records: [RecordSummary] = [], links: [RecordLink] = [], truncated: Bool = false) {
        self.records = records; self.links = links; self.truncated = truncated
    }
}

public struct TagCount: Hashable, Codable, Sendable {
    public var tag: String
    public var count: Int

    public init(tag: String, count: Int) {
        self.tag = tag; self.count = count
    }
}

// MARK: - Errors

public enum TroyError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    /// The project, record or link does not exist.
    case notFound(String)
    /// The input is not acceptable. The message says what to change.
    case invalid(String)
    /// The write would collide: a claim held by another agent, a stale revision, a cycle, a duplicate name.
    case conflict(String)
    /// SQLite failed in a way the caller cannot fix.
    case database(String)

    public var message: String {
        switch self {
        case .notFound(let text), .invalid(let text), .conflict(let text), .database(let text): text
        }
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
