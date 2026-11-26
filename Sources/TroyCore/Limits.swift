/// The single source of every size limit. The store enforces them; the MCP tool
/// schemas and the app's editors declare the same numbers.
public enum Limits {
    // Stored data
    public static let projectName = 120
    public static let projectSummary = 5_000
    public static let projectPaths = 20
    public static let projectPathLength = 1_024
    public static let title = 240
    public static let body = 100_000
    public static let tagCount = 20
    public static let tagLength = 60
    public static let recordPaths = 50
    public static let recordPathLength = 300
    public static let linkNote = 240
    public static let agentLabel = 80
    /// Links accepted in one `RecordDraft`.
    public static let draftLinks = 20

    // Reading
    public static let searchQuery = 300
    public static let searchTerms = 8
    public static let searchLimit = 100
    public static let listLimit = 1_000
    public static let previewChars = 200
    public static let snippetChars = 220
    /// Records the graph view loads for one project.
    public static let graphRecords = 2_000

    // History
    /// Versions kept per record. Older ones are deleted by the version trigger.
    public static let versionKeep = 50

    // Similar records and duplicates
    /// How many of a project's most recently updated records are compared with a new title.
    public static let similarScan = 3_000
    public static let similarThreshold = 0.30
    public static let duplicateThreshold = 0.85
    /// An identical record saved again by the same agent within this window is not stored twice.
    public static let dedupeWindowSeconds = 600

    // Claims
    /// A `doing` claim older than this is shown as stale.
    public static let staleClaimHours = 24

    // Overview sections
    public static let overviewDoing = 20
    public static let overviewReady = 15
    public static let overviewBlocked = 10
    public static let overviewCollisions = 10
    public static let overviewDecisions = 12
    public static let overviewRecent = 8
}
