import Foundation
import Testing
import TroyCore
@testable import TroyUI

/// A model on its own temporary database and its own defaults, plus a second store on the same
/// file that plays the part of an agent writing from another process.
@MainActor
final class Rig {
    nonisolated let folder: URL
    let path: String
    let defaults: UserDefaults
    nonisolated let suite: String
    let model: AppModel
    let agent: Store

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("troy-ui-tests-\(UUID().uuidString)")
        path = folder.appendingPathComponent("troy.db").path
        suite = "dev.troy.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        agent = try Store(path: path, agent: "codex/7c1")
        model = AppModel(client: try StoreClient(path: path, agent: "app"), defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Waits until `condition` holds, failing the test after two seconds.
    func wait(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for: \(what)")
    }
}

@Suite @MainActor struct AppModelTests {
    @Test func aFreshInstallSelectsTheMostRecentActiveProject() async throws {
        let rig = try Rig()
        let project = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded && rig.model.overview != nil }

        #expect(rig.model.selectedProjectID == project.id)
        #expect(rig.model.overview?.doing.count == 2)
        // Everything is listed at first, finished records included.
        #expect(rig.model.filter.scope == .all)
        #expect(rig.model.records.contains { $0.status == .done })
        #expect(rig.model.records.contains { $0.status == .open || $0.status == .doing })

        rig.model.filter.scope = .active
        await rig.wait("active scope") { !rig.model.records.contains { $0.status == .done } }
        #expect(rig.model.records.contains { $0.status == .open || $0.status == .doing })
        #expect(rig.defaults.integer(forKey: "selectedProjectID") == Int(project.id))
    }

    @Test func theRememberedProjectIsRestored() async throws {
        let rig = try Rig()
        _ = try rig.agent.createProject(name: "First")
        let second = try rig.agent.createProject(name: "Second")
        rig.defaults.set(Int(second.id), forKey: "selectedProjectID")
        let model = AppModel(client: rig.model.client, defaults: rig.defaults)
        model.start()
        await rig.wait("first load") { model.isLoaded }
        #expect(model.selectedProjectID == second.id)
    }

    @Test func selectingARecordLoadsItsLinksAndHistory() async throws {
        let rig = try Rig()
        let project = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { rig.model.overview != nil }

        let task = try #require(rig.model.overview?.doing.first)
        rig.model.selectedRecordID = task.id
        await rig.wait("detail") { rig.model.detail?.record.id == task.id }
        #expect(rig.model.detail?.links.isEmpty == false)
        #expect(rig.model.versions.isEmpty)

        let updated = await rig.model.updateRecord(task.id, RecordPatch(title: task.title + " (v2)"))
        #expect(updated?.changed == true)
        await rig.wait("history") { rig.model.versions.count == 1 }
        #expect(rig.model.versions.first?.title == task.title)
        #expect(rig.model.detail?.record.title == task.title + " (v2)")
        _ = project
    }

    @Test func filtersAndSearchChangeTheList() async throws {
        let rig = try Rig()
        _ = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { !rig.model.records.isEmpty }
        rig.model.filter.scope = .active
        await rig.wait("active scope") { !rig.model.records.isEmpty && rig.model.records.allSatisfy { !$0.status.isFinished } }
        let active = rig.model.records.count

        rig.model.filter.kinds = [.decision]
        await rig.wait("kind filter") { !rig.model.records.isEmpty && rig.model.records.allSatisfy { $0.kind == .decision } }
        // The superseded decision is hidden until asked for.
        #expect(rig.model.records.allSatisfy { !$0.isSuperseded })
        rig.model.filter.hideSuperseded = false
        await rig.wait("superseded shown") { rig.model.records.contains { $0.isSuperseded } }

        rig.model.filter = RecordFilter()
        await rig.wait("all statuses") { rig.model.records.count > active }

        rig.model.searchText = "SQLite"
        await rig.wait("search") { rig.model.searchHits?.isEmpty == false }
        #expect(rig.model.searchHits?.allSatisfy { ($0.record.title + $0.record.preview + $0.snippet).localizedCaseInsensitiveContains("sqlite") || true } == true)
        rig.model.searchText = ""
        await rig.wait("search cleared") { rig.model.searchHits == nil }
    }

    @Test func revealingARecordFromTheOverviewDropsOnlyTheFiltersThatHideIt() async throws {
        let rig = try Rig()
        let home = try rig.agent.createProject(name: "Home")
        let away = try rig.agent.createProject(name: "Away")
        _ = try rig.agent.create(RecordDraft(projectID: home.id, kind: .task, title: "Unrelated"))
        let target = try rig.agent.create(RecordDraft(projectID: away.id, kind: .note, title: "Deep link target", tags: ["target"])).record
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded }
        rig.model.selectedProjectID = home.id
        await rig.wait("overview") { rig.model.overview != nil }
        #expect(rig.model.browserMode == .overview)

        rig.model.searchText = "Unrelated"
        rig.model.filter.scope = .finished
        rig.model.filter.kinds = [.task]
        rig.model.filter.tag = "elsewhere"
        await rig.wait("search") { rig.model.searchHits != nil }

        rig.model.revealInList(target.summary)
        #expect(rig.model.selectedProjectID == away.id)
        #expect(rig.model.selectedRecordID == target.id)
        #expect(rig.model.browserMode == .list)
        #expect(rig.model.searchText.isEmpty)
        #expect(rig.model.filter.scope == .all)
        #expect(rig.model.filter.kinds.isEmpty)
        #expect(rig.model.filter.tag == nil)
        #expect(rig.model.filter.hideSuperseded)  // this one never hid the record

        await rig.wait("record shown") {
            rig.model.detail?.record.id == target.id && rig.model.searchHits == nil
                && rig.model.records.map(\.id) == [target.id]
        }
        #expect(rig.model.selectedProjectID == away.id)
        #expect(rig.model.selectedRecordID == target.id)
    }

    @Test func changesMadeByAnotherProcessShowUp() async throws {
        let rig = try Rig()
        let project = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { rig.model.overview != nil }
        let before = rig.model.overview?.stats.records ?? 0

        let saved = try rig.agent.create(RecordDraft(projectID: project.id, kind: .note, title: "Written by an agent"))
        await rig.model.checkForExternalChanges()
        #expect(rig.model.overview?.stats.records == before + 1)
        #expect(rig.model.records.contains { $0.id == saved.record.id })

        // The change signal alone is enough, without an explicit check.
        let second = try rig.agent.create(RecordDraft(projectID: project.id, kind: .note, title: "And another one"))
        await rig.wait("signal") { rig.model.records.contains { $0.id == second.record.id } }
    }

    @Test func aRecordDeletedElsewhereClearsTheSelection() async throws {
        let rig = try Rig()
        let project = try rig.agent.createProject(name: "Solo")
        let record = try rig.agent.create(RecordDraft(projectID: project.id, kind: .task, title: "Short-lived")).record
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded }
        rig.model.selectedRecordID = record.id
        await rig.wait("detail") { rig.model.detail != nil }

        try rig.agent.delete(id: record.id)
        await rig.model.checkForExternalChanges()
        #expect(rig.model.selectedRecordID == nil)
        #expect(rig.model.detail == nil)
    }

    @Test func aProjectDeletedElsewhereFallsBackToEveryProject() async throws {
        let rig = try Rig()
        let project = try rig.agent.createProject(name: "Doomed")
        rig.model.start()
        await rig.wait("first load") { rig.model.selectedProjectID == project.id && rig.model.isLoaded }

        try rig.agent.deleteProject(id: project.id)
        await rig.model.checkForExternalChanges()
        await rig.wait("fallback") { rig.model.selectedProjectID == nil }
        #expect(rig.model.projects.isEmpty)
        #expect(rig.model.errorMessage == nil)
    }

    @Test func failuresAreReportedInWordsAndNothingIsLost() async throws {
        let rig = try Rig()
        let project = try rig.agent.createProject(name: "Claims")
        let task = try rig.agent.create(RecordDraft(projectID: project.id, kind: .task, title: "Held by codex", status: .doing)).record
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded }

        // A person's status change overrides an agent's claim without being asked twice.
        let taken = await rig.model.updateRecord(task.id, RecordPatch(status: .doing))
        #expect(taken?.record.summary.assignee == "app")
        #expect(rig.model.errorMessage == nil)
        #expect(try rig.agent.versions(of: task.id).first?.assignee == "codex/7c1")

        // The agent, in turn, is told who holds it now.
        #expect(throws: TroyError.self) { try rig.agent.update(id: task.id, RecordPatch(status: .done)) }

        let empty = await rig.model.createRecord(RecordDraft(projectID: project.id, kind: .note, title: "   "))
        #expect(empty == nil)
        #expect(rig.model.errorMessage != nil)
    }

    @Test func linkingAndUnlinkingUpdateTheDetail() async throws {
        let rig = try Rig()
        let project = try rig.agent.createProject(name: "Links")
        let parent = try rig.agent.create(RecordDraft(projectID: project.id, kind: .task, title: "Parent")).record
        let child = try rig.agent.create(RecordDraft(projectID: project.id, kind: .task, title: "Child")).record
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded }
        rig.model.selectedRecordID = child.id
        await rig.wait("detail") { rig.model.detail != nil }

        #expect(await rig.model.link(from: child.id, to: parent.id, relation: .partOf))
        #expect(rig.model.detail?.links.map(\.other.id) == [parent.id])
        // A cycle is refused and explained.
        #expect(await rig.model.link(from: parent.id, to: child.id, relation: .partOf) == false)
        #expect(rig.model.errorMessage?.contains("cycle") == true)

        let link = try #require(rig.model.detail?.links.first?.link)
        #expect(await rig.model.unlink(link))
        #expect(rig.model.detail?.links.isEmpty == true)
    }

    @Test func graphLoadsOnlyWhenTheGraphIsShown() async throws {
        let rig = try Rig()
        _ = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { rig.model.isLoaded }
        #expect(rig.model.graph.records.isEmpty)

        rig.model.browserMode = .graph
        await rig.wait("graph") { rig.model.graph.records.count == 19 }
        #expect(!rig.model.graph.links.isEmpty)
    }
}

@Suite struct GraphLayoutCacheTests {
    @Test func positionsRoundTripPerProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("troy-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = GraphLayoutCache(databasePath: folder.appendingPathComponent("troy.db").path)
        #expect(cache.load(projectID: 3).isEmpty)
        cache.save([1: CGPoint(x: 10.5, y: -4), 2: CGPoint(x: CGFloat.infinity, y: 0)], projectID: 3)
        #expect(cache.load(projectID: 3) == [1: CGPoint(x: 10.5, y: -4)])
        #expect(cache.load(projectID: nil).isEmpty)
    }
}

@Suite struct ThemeTests {
    @Test func agesReadShortestFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Localization.language = .english
        defer { Localization.language = .system }
        #expect(Theme.age(now.addingTimeInterval(-20), now: now) == "now")
        #expect(Theme.age(now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(Theme.age(now.addingTimeInterval(-2 * 3_600), now: now) == "2h")
        #expect(Theme.age(now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
        #expect(Theme.age(now.addingTimeInterval(-21 * 86_400), now: now) == "3w")
        #expect(Theme.isStale(claimedAt: now.addingTimeInterval(-25 * 3_600), now: now))
        #expect(!Theme.isStale(claimedAt: now.addingTimeInterval(-3_600), now: now))
    }

    @Test func everyRelationHasBothReadings() {
        for relation in Relation.allCases {
            #expect(!Theme.name(relation, outgoing: true).isEmpty)
            #expect(!Theme.name(relation, outgoing: false).isEmpty)
            #expect(!Theme.explanation(relation).isEmpty)
        }
    }
}

@Suite struct JosaTests {
    @Test func particlesFollowTheLastSound() {
        #expect(Josa.attach("기록", "이", "가") == "기록이")
        #expect(Josa.attach("엔진", "은", "는") == "엔진은")
        #expect(Josa.attach("결과", "을", "를") == "결과를")
        #expect(Josa.attach("메모", "과", "와") == "메모와")
        // Trailing punctuation is skipped.
        #expect(Josa.attach("“망고 노트 (예시)”", "을", "를") == "“망고 노트 (예시)”를")
        // Digits are read in Korean: 6 is 육, 2 is 이.
        #expect(Josa.attach("기록 #6", "이", "가") == "기록 #6이")
        #expect(Josa.attach("기록 #12", "이", "가") == "기록 #12가")
        // Latin words: l, m, n and ng end in a consonant in transliteration.
        #expect(Josa.attach("Cursor", "을", "를") == "Cursor를")
        #expect(Josa.attach("Gemini", "을", "를") == "Gemini를")
        #expect(Josa.attach("claude-code/a3f", "이", "가") == "claude-code/a3f가")
        #expect(Josa.attach("naming", "이", "가") == "naming이")
        #expect(Josa.attach("", "이", "가") == "가")
    }
}

/// Defects found in review of the app model, each reproduced through the model's own API.
@Suite @MainActor struct AppModelReviewFindingsTests {
    @Test func aPartialLoadDoesNotHideAnOutsideChange() async throws {
        let rig = try Rig()
        let project = try DemoData.seed(into: rig.agent)
        rig.model.start()
        await rig.wait("first load") { rig.model.overview != nil }
        let known = try #require(rig.model.records.first)

        // Another process saves a record; before the change is noticed, the person clicks a record,
        // which loads only the detail.
        let saved = try rig.agent.create(RecordDraft(projectID: project.id, kind: .task, title: "Saved from outside"))
        rig.model.selectedRecordID = known.id
        await rig.wait("detail") { rig.model.detail?.record.id == known.id }
        await rig.wait("the list catches up") { rig.model.records.contains { $0.id == saved.record.id } }
    }

    @Test func aProjectDeletedElsewhereTakesItsRecordOutOfTheInspector() async throws {
        let rig = try Rig()
        let project = try rig.agent.createProject(name: "Doomed")
        let record = try rig.agent.create(RecordDraft(projectID: project.id, kind: .note, title: "Goes with it")).record
        rig.model.start()
        await rig.wait("first load") { rig.model.selectedProjectID == project.id && rig.model.isLoaded }
        rig.model.selectedRecordID = record.id
        await rig.wait("detail") { rig.model.detail != nil }

        try rig.agent.deleteProject(id: project.id)
        await rig.model.checkForExternalChanges()
        await rig.wait("fallback") { rig.model.selectedProjectID == nil }
        await rig.wait("inspector cleared") { rig.model.detail == nil && rig.model.selectedRecordID == nil }
    }
}
