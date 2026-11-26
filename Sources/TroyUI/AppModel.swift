import Foundation
import Observation
import TroyCore

/// Which statuses the record list shows.
nonisolated public enum StatusScope: String, CaseIterable, Sendable {
    /// Open and in progress.
    case active
    case all
    /// Done and dropped.
    case finished

    public var statuses: Set<RecordStatus> {
        switch self {
        case .active: [.open, .doing]
        case .all: []
        case .finished: [.done, .dropped]
        }
    }
}

nonisolated public struct RecordFilter: Hashable, Sendable {
    /// Empty shows every kind.
    public var kinds: Set<RecordKind> = []
    public var scope: StatusScope = .all
    public var tag: String?
    /// Hides records another record has replaced.
    public var hideSuperseded = true

    public init() {}
}

/// Something one window asks another to do. The panel and the status item menu set
/// `AppModel.intent`; the main window performs it and sets it back to `nil`.
nonisolated public enum AppIntent: Hashable, Sendable {
    case newRecord
    case newProject
    /// The panel's "Open graph": the whole project's graph, even if a record's local graph was open.
    case fullGraph
    /// The record's direct links as a graph, the same navigation as the inspector's local graph button.
    /// Only set once the record was really found (`--show local-graph --select <id>`).
    case localGraph(RecordSummary)
}

/// How the main window shows a project's records.
nonisolated public enum BrowserMode: String, CaseIterable, Sendable {
    case overview, list, graph
}

/// Everything the views show, and every action they can take.
///
/// Views read the properties and call the methods; they never open the database themselves.
/// Setting `selectedProjectID`, `selectedRecordID`, `filter`, `searchText`, `showsArchivedProjects`
/// or `browserMode` reloads what depends on it. The model also reloads when another process
/// changes the database (see `start`, `viewAppeared`).
@Observable
public final class AppModel {
    public let client: StoreClient

    // MARK: Projects

    public private(set) var projects: [ProjectSummary] = []
    /// `nil` means every project.
    public var selectedProjectID: Int64? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            defaults.set(selectedProjectID ?? 0, forKey: Keys.project)
            if let detail, detail.record.projectID != selectedProjectID, selectedProjectID != nil { selectedRecordID = nil }
            overview = nil
            // The old project's graph must not be drawn under the new project's name and positions.
            graph = GraphSnapshot()
            isGraphLoaded = false
            // The detail too: when the project went away, so did the record the inspector shows.
            reloadSoon([.overview, .records, .tags, .graph, .detail])
        }
    }
    public var showsArchivedProjects = false {
        didSet { if showsArchivedProjects != oldValue { reloadSoon(.projects) } }
    }
    public var selectedProject: Project? { projects.first { $0.id == selectedProjectID }?.project }

    /// The state of the selected project. `nil` while loading or when every project is selected.
    public private(set) var overview: ProjectOverview?

    // MARK: Record list

    public var filter = RecordFilter() {
        didSet { if filter != oldValue { reloadSoon(.records) } }
    }
    /// Text typed in the main window's search field. Searching replaces `records` with `searchHits`.
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchDebounce?.cancel()
            searchDebounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await self?.reload(.records)
            }
        }
    }
    /// The filtered records of the selected project, newest first.
    public private(set) var records: [RecordSummary] = []
    /// Search results for `searchText`; `nil` when the field is empty.
    public private(set) var searchHits: [SearchHit]?
    public private(set) var tags: [TagCount] = []

    // MARK: Selection

    public var selectedRecordID: Int64? {
        didSet {
            guard selectedRecordID != oldValue else { return }
            if selectedRecordID == nil { detail = nil; versions = [] }
            reloadSoon(.detail)
        }
    }
    /// The selected record with its links and advisories.
    public private(set) var detail: RecordDetail?
    public private(set) var versions: [RecordVersion] = []

    /// Shows a record in the list: its project, no search, and no filter that would hide it.
    public func revealInList(_ record: RecordSummary) {
        if selectedProjectID != nil, selectedProjectID != record.projectID { selectedProjectID = record.projectID }
        var filter = self.filter
        if !filter.scope.statuses.contains(record.status) { filter.scope = .all }
        if !filter.kinds.isEmpty, !filter.kinds.contains(record.kind) { filter.kinds = [] }
        if let tag = filter.tag, !record.tags.contains(tag) { filter.tag = nil }
        if record.isSuperseded { filter.hideSuperseded = false }
        self.filter = filter
        searchText = ""
        browserMode = .list
        selectedRecordID = record.id
    }

    // MARK: Graph

    public var browserMode: BrowserMode = .overview {
        didSet { if browserMode != oldValue, browserMode == .graph { reloadSoon(.graph) } }
    }
    /// Loaded only while `browserMode == .graph`.
    public private(set) var graph = GraphSnapshot()
    /// False until the selected project's graph has arrived, so the screen can wait instead of
    /// flashing an empty state.
    public private(set) var isGraphLoaded = false

    // MARK: Requests between windows

    /// Set by the panel or a menu after it has asked for the main window; the main window acts on it.
    public var intent: AppIntent?

    // MARK: Status

    /// False until the first load has finished.
    public private(set) var isLoaded = false
    /// The last failure, in words a person can act on. Views show it and set it back to `nil`.
    public var errorMessage: String? {
        didSet { if errorMessage == nil { lastError = nil } }
    }
    /// The failure behind `errorMessage` when the store reported it, so a view can tell a conflict
    /// from bad input without reading the words. Cleared together with the message.
    public private(set) var lastError: TroyError?
    /// Increases whenever the interface language changes; root views use it as their identity.
    public var languageRevision = 0

    public let layoutCache: GraphLayoutCache
    private let defaults: UserDefaults

    private var lastDataVersion: Int?
    private var signalToken: Int32?
    private var signalDebounce: Task<Void, Never>?
    private var searchDebounce: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var visibleViews = 0

    private enum Keys {
        static let project = "selectedProjectID"
    }

    /// - Parameter defaults: where the selected project is remembered between launches.
    public init(client: StoreClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        layoutCache = GraphLayoutCache(databasePath: client.path)
        let stored = defaults.object(forKey: Keys.project) as? Int
        if let stored, stored > 0 { selectedProjectID = Int64(stored) }
        choosesProjectOnLoad = stored == nil
    }

    /// True until the first load has picked a project for a fresh install.
    private var choosesProjectOnLoad: Bool

    // MARK: Lifecycle

    /// Loads everything and starts listening for changes made by other processes. Call once.
    public func start() {
        guard signalToken == nil else { return }
        signalToken = ChangeSignal.observe(on: .main) { [weak self] in
            Task { @MainActor in self?.signalReceived() }
        }
        reloadSoon(.all)
    }

    /// Call when the panel or a window becomes visible. Checks for outside changes at once and
    /// keeps checking every few seconds until the matching `viewDisappeared`.
    public func viewAppeared() {
        visibleViews += 1
        Task { await checkForExternalChanges() }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.checkForExternalChanges()
            }
        }
    }

    public func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 { poll?.cancel(); poll = nil }
    }

    /// Reloads when another connection has committed since the last load.
    public func checkForExternalChanges() async {
        guard let version = try? await client.run({ try $0.dataVersion() }) else { return }
        if version != lastDataVersion { await reload(.all) }
    }

    /// Reloads everything the views show.
    public func refresh() async { await reload(.all) }

    private func signalReceived() {
        signalDebounce?.cancel()
        signalDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.checkForExternalChanges()
        }
    }

    // MARK: Loading

    nonisolated private struct Parts: OptionSet, Sendable {
        let rawValue: Int
        static let projects = Parts(rawValue: 1)
        static let overview = Parts(rawValue: 2)
        static let records = Parts(rawValue: 4)
        static let tags = Parts(rawValue: 8)
        static let detail = Parts(rawValue: 16)
        static let graph = Parts(rawValue: 32)
        static let all: Parts = [.projects, .overview, .records, .tags, .detail, .graph]
    }

    /// What a load was asked for. Results are applied only if the model still wants the same thing.
    nonisolated private struct Request: Sendable, Equatable {
        var parts: Parts
        var projectID: Int64?
        var includeArchived: Bool
        var filter: RecordFilter
        var search: String
        var recordID: Int64?
        var wantsGraph: Bool
    }

    nonisolated private struct Loaded: Sendable {
        var version: Int
        var projects: [ProjectSummary]?
        var overview: ProjectOverview?
        var projectMissing = false
        var records: [RecordSummary]?
        var hits: [SearchHit]?
        var tags: [TagCount]?
        var detail: RecordDetail?
        var versions: [RecordVersion] = []
        var recordMissing = false
        var graph: GraphSnapshot?
    }

    private func request(_ parts: Parts) -> Request {
        Request(
            parts: parts, projectID: selectedProjectID, includeArchived: showsArchivedProjects, filter: filter,
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines), recordID: selectedRecordID,
            wantsGraph: browserMode == .graph)
    }

    private func reloadSoon(_ parts: Parts) {
        Task { await reload(parts) }
    }

    private func reload(_ parts: Parts) async {
        let asked = request(parts)
        do {
            let loaded = try await client.run { store in try Self.load(asked, from: store) }
            apply(loaded, for: asked)
        } catch {
            report(error)
        }
    }

    nonisolated private static func load(_ request: Request, from store: Store) throws -> Loaded {
        var loaded = Loaded(version: try store.dataVersion())
        let parts = request.parts
        if parts.contains(.projects) {
            loaded.projects = try store.projects(includeArchived: request.includeArchived)
        }
        if parts.contains(.overview), let projectID = request.projectID {
            do { loaded.overview = try store.overview(projectID: projectID) } catch TroyError.notFound {
                loaded.projectMissing = true
            }
        }
        if parts.contains(.records), !loaded.projectMissing {
            let filter = request.filter
            if request.search.isEmpty {
                loaded.records = try store.list(RecordQuery(
                    projectID: request.projectID, kinds: filter.kinds, statuses: filter.scope.statuses, tag: filter.tag,
                    includeSuperseded: !filter.hideSuperseded, limit: Limits.listLimit))
            } else {
                loaded.hits = try store.search(SearchQuery(
                    text: request.search, projectID: request.projectID, kinds: filter.kinds,
                    statuses: filter.scope.statuses, tag: filter.tag, limit: Limits.searchLimit))
            }
        }
        if parts.contains(.tags) {
            loaded.tags = try store.tags(projectID: request.projectID)
        }
        if parts.contains(.detail), let recordID = request.recordID {
            do {
                loaded.detail = try store.detail(id: recordID)
                loaded.versions = try store.versions(of: recordID)
            } catch TroyError.notFound {
                loaded.recordMissing = true
            }
        }
        if parts.contains(.graph), request.wantsGraph, !loaded.projectMissing {
            loaded.graph = try store.graph(projectID: request.projectID)
        }
        return loaded
    }

    private func apply(_ loaded: Loaded, for asked: Request) {
        let current = request(asked.parts)
        if asked.parts == .all {
            lastDataVersion = loaded.version
        } else if let seen = lastDataVersion, loaded.version != seen {
            // A partial load noticed that another process wrote. Remembering the new version here
            // would hide that from the change check, and the rest of the screen would stay stale.
            reloadSoon(.all)
        }

        if let projects = loaded.projects, current.includeArchived == asked.includeArchived {
            self.projects = projects
            if choosesProjectOnLoad {
                choosesProjectOnLoad = false
                if selectedProjectID == nil, let first = projects.first(where: { $0.project.status == .active }) {
                    selectedProjectID = first.id
                    return
                }
            }
        }
        if loaded.projectMissing, current.projectID == asked.projectID {
            // The selected project was deleted elsewhere: fall back to every project.
            selectedProjectID = nil
            isLoaded = true
            return
        }
        guard current.projectID == asked.projectID else { return }

        if asked.parts.contains(.overview) { overview = loaded.overview }
        if asked.parts.contains(.records), current.filter == asked.filter, current.search == asked.search {
            if let records = loaded.records { self.records = records; searchHits = nil }
            if let hits = loaded.hits { searchHits = hits }
        }
        if let tags = loaded.tags { self.tags = tags }
        if asked.parts.contains(.detail), current.recordID == asked.recordID {
            if loaded.recordMissing {
                selectedRecordID = nil
            } else if asked.recordID != nil {
                detail = loaded.detail
                versions = loaded.versions
            }
        }
        if let graph = loaded.graph, current.wantsGraph {
            self.graph = graph
            isGraphLoaded = true
        }
        isLoaded = true
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? TroyError)?.message ?? error.localizedDescription
    }

    private func report(_ error: Error) {
        errorMessage = Self.describe(error)
        lastError = error as? TroyError
    }

    // MARK: Actions

    /// Runs a write, reloads, and reports a failure through `errorMessage`.
    private func perform<T: Sendable>(_ work: @escaping @Sendable (Store) throws -> T) async -> T? {
        do {
            let value = try await client.run(work)
            await reload(.all)
            return value
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    public func createRecord(_ draft: RecordDraft) async -> SaveResult? {
        await perform { try $0.create(draft) }
    }

    /// Changes a record. A status change made here is the person's decision, so it overrides an
    /// agent's claim: agents have to pass `takeover` themselves, the app does it for them.
    @discardableResult
    public func updateRecord(_ id: Int64, _ patch: RecordPatch) async -> UpdateResult? {
        var patch = patch
        if patch.status != nil { patch.takeover = true }
        return await perform { [patch] in try $0.update(id: id, patch) }
    }

    @discardableResult
    public func deleteRecord(_ id: Int64) async -> Bool {
        if selectedRecordID == id { selectedRecordID = nil }
        return await perform { try $0.delete(id: id) } != nil
    }

    @discardableResult
    public func link(from: Int64, to: Int64, relation: Relation, note: String = "") async -> Bool {
        await perform { try $0.link(from: from, to: to, relation: relation, note: note) } != nil
    }

    @discardableResult
    public func unlink(_ link: RecordLink) async -> Bool {
        await perform { try $0.deleteLink(id: link.id) } != nil
    }

    @discardableResult
    public func createProject(name: String, summary: String = "", paths: [String] = []) async -> Project? {
        let project = await perform { try $0.createProject(name: name, summary: summary, paths: paths) }
        if let project { selectedProjectID = project.id }
        return project
    }

    @discardableResult
    public func updateProject(
        _ id: Int64, name: String? = nil, summary: String? = nil, status: ProjectStatus? = nil, paths: [String]? = nil
    ) async -> Bool {
        await perform { try $0.updateProject(id: id, name: name, summary: summary, status: status, paths: paths) } != nil
    }

    @discardableResult
    public func deleteProject(_ id: Int64) async -> Bool {
        if selectedProjectID == id { selectedProjectID = nil }
        return await perform { try $0.deleteProject(id: id) } != nil
    }

    // MARK: Reads that do not change what the views show

    /// A search for pickers and the panel. Does not touch `searchText` or `searchHits`.
    public func search(_ text: String, projectID: Int64?, limit: Int = 12) async -> [SearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return (try? await client.run { try $0.search(SearchQuery(text: trimmed, projectID: projectID, limit: limit)) }) ?? []
    }

    public func record(_ id: Int64) async -> Record? {
        try? await client.run { try $0.record(id: id) }
    }

    /// The project as it is stored right now, for an editor about to save over it.
    public func project(_ id: Int64) async -> Project? {
        try? await client.run { try $0.project(id: id) }
    }

    /// Existing records that resemble a title being typed, for the editor's duplicate hint.
    public func similar(title: String, tags: [String], projectID: Int64, excluding: Set<Int64> = []) async -> [SimilarRecord] {
        (try? await client.run { try $0.similar(title: title, tags: tags, projectID: projectID, excluding: excluding) }) ?? []
    }

    public func exportMarkdown(projectID: Int64?) async -> String? {
        do { return try await client.run { try $0.exportMarkdown(projectID: projectID) } } catch {
            report(error)
            return nil
        }
    }
}
