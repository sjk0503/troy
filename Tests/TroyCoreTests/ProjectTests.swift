import Foundation
import Testing
@testable import TroyCore

@Suite struct ProjectTests {
    @Test func nameIsUniqueIgnoringCase() throws {
        let store = try Store(path: ":memory:")
        _ = try store.createProject(name: "Troy")
        #expect(thrown { _ = try store.createProject(name: "troy") }?.isConflict == true)
        #expect(thrown { _ = try store.createProject(name: "   ") }?.isInvalid == true)
        #expect(thrown { _ = try store.createProject(name: "a\0b") }?.isInvalid == true)
        #expect(thrown { _ = try store.createProject(name: String(repeating: "x", count: 121)) }?.isInvalid == true)
        let other = try store.createProject(name: "Other")
        #expect(thrown { _ = try store.updateProject(id: other.id, name: "TROY") }?.isConflict == true)
        #expect(try store.updateProject(id: other.id, name: "OTHER").name == "OTHER")
    }

    @Test func linkedPathsAreNormalizedAndExclusive() throws {
        let store = try Store(path: ":memory:")
        let a = try store.createProject(name: "a", paths: ["/work/a/", "/work/a/../a2"])
        #expect(a.paths == ["/work/a", "/work/a2"])
        let error = thrown { _ = try store.createProject(name: "b", paths: ["/work/a"]) }
        #expect(error?.isConflict == true)
        #expect(error?.message.contains("#\(a.id) a") == true)
        // Nothing was created by the failed call.
        #expect(try store.projects().count == 1)
        let b = try store.createProject(name: "b", paths: ["/work/b"])
        #expect(thrown { _ = try store.updateProject(id: b.id, paths: ["/work/b", "/work/a2"]) }?.isConflict == true)
        #expect(try store.updateProject(id: b.id, paths: ["/work/c"]).paths == ["/work/c"])
        #expect(try store.updateProject(id: a.id, paths: ["/work/b"]).paths == ["/work/b"])
        #expect(thrown { _ = try store.createProject(name: "rel", paths: ["relative"]) }?.isInvalid == true)
    }

    @Test func updateAndStatus() throws {
        let store = try Store(path: ":memory:")
        let project = try store.createProject(name: "p", summary: "first")
        let updated = try store.updateProject(id: project.id, summary: "second", status: .archived)
        #expect(updated.summary == "second")
        #expect(updated.status == .archived)
        #expect(updated.updatedAt > project.updatedAt)
        #expect(try store.projects().isEmpty)
        #expect(try store.projects(includeArchived: true).count == 1)
        #expect(thrown { _ = try store.project(id: 999) }?.isNotFound == true)
        #expect(thrown { _ = try store.updateProject(id: 999, name: "x") }?.isNotFound == true)
    }

    @Test func projectsSortByRecentActivityAndCarryStats() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let quiet = try store.makeProject("quiet")
        let busy = try store.makeProject("busy")
        try store.add(busy, "one")
        try store.add(busy, "two", status: .doing)
        try store.add(busy, "note", kind: .note)
        let list = try store.projects()
        #expect(list.map(\.project.name) == ["busy", "quiet"])
        let stats = try #require(list.first).stats
        #expect(stats.records == 3)
        #expect(stats.openTasks == 1)
        #expect(stats.doing == 1)
        #expect(stats.lastActivity != nil)
        #expect(try store.stats(projectID: quiet.id) == ProjectStats())
    }

    @Test func resolveByIdNameSubstringAndAmbiguity() throws {
        let store = try Store(path: ":memory:")
        let troy = try store.createProject(name: "Troy")
        let web = try store.createProject(name: "troy-web-client")
        let api = try store.createProject(name: "billing-api")
        let old = try store.createProject(name: "legacy")
        _ = try store.updateProject(id: old.id, status: .archived)

        #expect(try store.resolveProject(reference: "\(api.id)", directory: nil).id == api.id)
        #expect(try store.resolveProject(reference: "TROY", directory: nil).id == troy.id)
        #expect(try store.resolveProject(reference: "billing", directory: nil).id == api.id)
        #expect(try store.resolveProject(reference: "web", directory: nil).id == web.id)
        // An archived project can be named explicitly.
        #expect(try store.resolveProject(reference: "legacy", directory: nil).id == old.id)
        // …but a fragment does not match archived projects.
        #expect(thrown { _ = try store.resolveProject(reference: "legac", directory: nil) }?.isNotFound == true)

        let ambiguous = thrown { _ = try store.resolveProject(reference: "i", directory: nil) }
        #expect(ambiguous?.isInvalid == true)
        #expect(ambiguous?.message.contains("#\(api.id) billing-api") == true)

        let missing = thrown { _ = try store.resolveProject(reference: "nothing", directory: nil) }
        #expect(missing?.isNotFound == true)
        #expect(missing?.message.contains("#\(troy.id) Troy") == true)
        #expect(missing?.message.contains("#\(web.id) troy-web-client") == true)
        #expect(missing?.message.contains("legacy") == false)
    }

    @Test func resolveByDirectoryPicksLongestLinkedPath() throws {
        let store = try Store(path: ":memory:")
        let mono = try store.createProject(name: "mono", paths: ["/work/mono"])
        let web = try store.createProject(name: "web", paths: ["/work/mono/packages/web"])
        let other = try store.createProject(name: "other", paths: ["/work/mon"])
        #expect(try store.resolveProject(reference: nil, directory: "/work/mono").id == mono.id)
        #expect(try store.resolveProject(reference: nil, directory: "/work/mono/tools/x").id == mono.id)
        #expect(try store.resolveProject(reference: nil, directory: "/work/mono/packages/web/src/").id == web.id)
        #expect(try store.resolveProject(reference: nil, directory: "/work/mon/x").id == other.id)
        // /work/mono-two is not below /work/mono or /work/mon.
        let error = thrown { _ = try store.resolveProject(reference: nil, directory: "/work/mono-two") }
        #expect(error?.isNotFound == true)
        #expect(error?.message.contains("#\(mono.id) mono") == true)
        #expect(thrown { _ = try store.resolveProject(reference: nil, directory: nil) }?.isNotFound == true)
        // An archived project is not picked by directory.
        _ = try store.updateProject(id: web.id, status: .archived)
        #expect(try store.resolveProject(reference: nil, directory: "/work/mono/packages/web/src").id == mono.id)
    }

    @Test func deleteRemovesEverythingAndKeepsTheIndexConsistent() throws {
        let store = try Store(path: ":memory:", agent: "a")
        let doomed = try store.makeProject("doomed")
        let keeper = try store.makeProject("keeper")
        let a = try store.add(doomed, "alpha record", body: "searchable words here")
        let b = try store.add(doomed, "beta record", parent: a.id)
        let k = try store.add(keeper, "keeper record", body: "searchable words here too")
        _ = try store.link(from: k.id, to: a.id, relation: .relatesTo)
        _ = try store.update(id: a.id, RecordPatch(title: "alpha renamed"))
        #expect(try store.count("SELECT count(*) FROM record_versions") > 0)

        try store.deleteProject(id: doomed.id)
        #expect(thrown { _ = try store.project(id: doomed.id) }?.isNotFound == true)
        #expect(thrown { _ = try store.record(id: b.id) }?.isNotFound == true)
        #expect(try store.count("SELECT count(*) FROM records") == 1)
        #expect(try store.count("SELECT count(*) FROM links") == 0)
        #expect(try store.count("SELECT count(*) FROM record_versions") == 0)
        #expect(try store.count("SELECT count(*) FROM project_paths") == 0)
        try store.sql("INSERT INTO records_fts(records_fts) VALUES('integrity-check')")
        #expect(try store.search(SearchQuery(text: "searchable")).map(\.id) == [k.id])
        #expect(try store.links(of: k.id).isEmpty)
        #expect(thrown { try store.deleteProject(id: doomed.id) }?.isNotFound == true)
    }
}

/// The first save in a repository creates its project (`Store.saveCreatingProject`).
@Suite struct RepositoryProjectTests {
    private func draft(_ title: String) -> RecordDraft {
        RecordDraft(projectID: 0, kind: .note, title: title)
    }

    @Test func firstSaveCreatesTheProjectAndLaterSavesReuseIt() throws {
        let store = try Store(path: ":memory:")
        let first = try store.saveCreatingProject(draft("One"), folders: ["/work/dev/app/Sources"], repositoryRoots: ["/work/dev/app"])
        #expect(first.createdProject)
        #expect(first.project.name == "app")
        #expect(first.project.paths == ["/work/dev/app"])
        #expect(first.result.record.projectID == first.project.id)
        let second = try store.saveCreatingProject(draft("Two"), folders: ["/work/dev/app"], repositoryRoots: ["/work/dev/app"])
        #expect(!second.createdProject)
        #expect(second.project.id == first.project.id)
        #expect(try store.projects().count == 1)
        // The folder's own link wins over the repository root.
        let nested = try store.createProject(name: "inner", paths: ["/work/dev/app/inner"])
        let third = try store.saveCreatingProject(draft("Three"), folders: ["/work/dev/app/inner/x"], repositoryRoots: ["/work/dev/app"])
        #expect(third.project.id == nested.id && !third.createdProject)
    }

    @Test func takenNamesGetTheParentFolderThenANumber() throws {
        let store = try Store(path: ":memory:")
        _ = try store.createProject(name: "APP")
        let a = try store.saveCreatingProject(draft("a"), folders: [], repositoryRoots: ["/one/dev/app"])
        #expect(a.project.name == "app (dev)")
        let b = try store.saveCreatingProject(draft("b"), folders: [], repositoryRoots: ["/two/dev/app"])
        #expect(b.project.name == "app (dev) 2")
        let c = try store.saveCreatingProject(draft("c"), folders: [], repositoryRoots: ["/three/dev/app"])
        #expect(c.project.name == "app (dev) 3")
        // A root right below / has no parent name to add.
        _ = try store.createProject(name: "top")
        #expect(try store.saveCreatingProject(draft("d"), folders: [], repositoryRoots: ["/top"]).project.name == "top 2")
    }

    @Test func anArchivedProjectIsNeverDuplicated() throws {
        let cases = [("/work/app", "/work/app"), ("/work/app/sub", "/work/app")]
        for (linked, root) in cases {
            let store = try Store(path: ":memory:")
            let old = try store.createProject(name: "old", paths: [linked])
            _ = try store.updateProject(id: old.id, status: .archived)
            #expect(try store.project(forFolders: [root], repositoryRoots: [root]) == .archived(try store.project(id: old.id)))
            let error = thrown { _ = try store.saveCreatingProject(draft("x"), folders: [root], repositoryRoots: [root]) }
            #expect(error?.isConflict == true)
            #expect(error?.message.contains("#\(old.id) \"old\" is archived") == true, "\(error?.message ?? "")")
            #expect(error?.message.contains("Unarchive it in the Troy app") == true)
            #expect(try store.projects(includeArchived: true).count == 1)
            #expect(try store.list(RecordQuery()).isEmpty)
        }
        // Without a root there is nothing to collide with.
        let store = try Store(path: ":memory:")
        #expect(try store.project(forFolders: ["/elsewhere"], repositoryRoots: []) == .none)
    }

    /// A link above a repository says where the repository happens to sit. It counts only when
    /// it is the root of a repository around this one; a plain folder's project never takes the
    /// repositories below it, whether it is active or archived.
    @Test func aLinkAboveARepositoryCountsOnlyAsAnEnclosingRepository() throws {
        let store = try Store(path: ":memory:")
        let above = try store.createProject(name: "above", paths: ["/work"])
        #expect(try store.project(forFolders: ["/work/app/src"], repositoryRoots: ["/work/app"]) == .none)
        #expect(try store.project(forFolders: ["/work/app/src"], repositoryRoots: ["/work/app"], enclosing: ["/work"])
            == .active(try store.project(id: above.id)))
        // A plain folder below the link has no boundary and belongs to it.
        #expect(try store.project(forFolders: ["/work/notes/2026"], repositoryRoots: []) == .active(try store.project(id: above.id)))
        // A link inside the repository, or on its root, counts as before, and the closest one wins.
        let inner = try store.createProject(name: "inner", paths: ["/work/app/tools"])
        #expect(try store.project(forFolders: ["/work/app/tools/x"], repositoryRoots: ["/work/app"]) == .active(try store.project(id: inner.id)))
        #expect(try store.project(forFolders: ["/work/app/tools/x"], repositoryRoots: ["/work/app"], enclosing: ["/work"])
            == .active(try store.project(id: inner.id)))
        // Between a link that does not count and an enclosing root further up, the root is taken.
        let between = try store.createProject(name: "between", paths: ["/work/area"])
        #expect(try store.project(forFolders: ["/work/area/lib"], repositoryRoots: ["/work/area/lib"], enclosing: ["/work"])
            == .active(try store.project(id: above.id)))
        #expect(try store.project(forFolders: ["/work/area/docs"], repositoryRoots: []) == .active(try store.project(id: between.id)))

        _ = try store.updateProject(id: above.id, status: .archived)
        #expect(try store.project(forFolders: ["/work/app"], repositoryRoots: ["/work/app"]) == .none)
        #expect(try store.project(forFolders: ["/work/app"], repositoryRoots: ["/work/app"], enclosing: ["/work"])
            == .archived(try store.project(id: above.id)))
        let saved = try store.saveCreatingProject(draft("x"), folders: ["/work/app"], repositoryRoots: ["/work/app"])
        #expect(saved.createdProject && saved.project.paths == ["/work/app"])
        #expect(thrown {
            _ = try store.saveCreatingProject(draft("y"), folders: ["/work/web"], repositoryRoots: ["/work/web"], enclosing: ["/work"])
        }?.isConflict == true)
    }

    /// A working folder in no repository gets its project the same way, linked to the folder the
    /// caller names.
    @Test func aPlainFolderGetsItsProjectOnTheFirstSave() throws {
        let store = try Store(path: ":memory:")
        #expect(thrown { _ = try store.saveCreatingProject(draft("x"), folders: ["/place/dev/cs"], repositoryRoots: []) }?.message
            == "No folder to link the project to.")
        let first = try store.saveCreatingProject(draft("One"), folders: ["/place/dev/cs"], repositoryRoots: [], plainFolder: "/place/dev/cs")
        #expect(first.createdProject && first.project.name == "cs" && first.project.paths == ["/place/dev/cs"])
        // A folder below it finds that project instead of making its own.
        let second = try store.saveCreatingProject(
            draft("Two"), folders: ["/place/dev/cs/notes"], repositoryRoots: [], plainFolder: "/place/dev/cs/notes")
        #expect(!second.createdProject && second.project.id == first.project.id)
        // An archived project on a folder below does not block the folder above: no repository is split.
        let below = try store.createProject(name: "old", paths: ["/place/dev/ws/old"])
        _ = try store.updateProject(id: below.id, status: .archived)
        let third = try store.saveCreatingProject(draft("Three"), folders: ["/place/dev/ws"], repositoryRoots: [], plainFolder: "/place/dev/ws")
        #expect(third.createdProject && third.project.name == "ws")
        // One on the folder itself or above it claims the folder, and nothing is created beside it.
        _ = try store.updateProject(id: third.project.id, status: .archived)
        let error = thrown {
            _ = try store.saveCreatingProject(
                draft("Four"), folders: ["/place/dev/ws/new"], repositoryRoots: [], plainFolder: "/place/dev/ws/new")
        }
        #expect(error?.isConflict == true && error?.message.contains("\"ws\" is archived") == true, "\(error?.message ?? "")")
        #expect(try store.projects(includeArchived: true).count == 3)
    }

    @Test func aFailedRecordLeavesNoProjectBehind() throws {
        let store = try Store(path: ":memory:")
        var bad = draft("Linked to nothing")
        bad.links = [LinkDraft(to: 999, relation: .relatesTo)]
        #expect(thrown { _ = try store.saveCreatingProject(bad, folders: [], repositoryRoots: ["/work/app"]) } != nil)
        #expect(try store.projects().isEmpty)
    }

    @Test func concurrentFirstSavesEndUpInOneProject() throws {
        let temp = TempDir()
        _ = try temp.store("setup/0")
        let count = 8
        let stores = try (0..<count).map { try temp.store("agent/\($0)") }
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                let saved = try stores[index].saveCreatingProject(
                    RecordDraft(projectID: 0, kind: .note, title: "Note \(index)"), folders: ["/race/app"], repositoryRoots: ["/race/app"])
                outcomes.add(saved)
            } catch {
                outcomes.fail("\(error)")
            }
        }
        #expect(outcomes.failures.isEmpty, "\(outcomes.failures)")
        #expect(Set(outcomes.saves.map(\.project.id)).count == 1)
        #expect(outcomes.saves.filter(\.createdProject).count == 1)
        let check = try temp.store("check/0")
        #expect(try check.projects().count == 1)
        #expect(try check.list(RecordQuery()).count == count)
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var saves: [RepositorySave] = []
        private(set) var failures: [String] = []
        func add(_ save: RepositorySave) { lock.withLock { saves.append(save) } }
        func fail(_ text: String) { lock.withLock { failures.append(text) } }
    }
}

@Suite struct ProjectNameLengthTests {
    @Test func longFolderNamesNeverTrapAndStayWithinTheLimit() throws {
        let store = try Store(path: ":memory:")
        let longParent = String(repeating: "p", count: 200)
        let longFolder = String(repeating: "f", count: 200)
        let roots = [
            "/x/\(longParent)/app",          // the parent alone is longer than the limit
            "/x/\(longParent)/app",          // same name again: needs the parent and a number
            "/y/\(String(repeating: "q", count: 118))/app",
            "/z/\(longParent)/\(longFolder)",
            "/w/\(longParent)/\(longFolder)",
            "/v/\(longParent)/\(longFolder)",
        ]
        var names = Set<String>()
        for (index, root) in roots.enumerated() {
            let draft = RecordDraft(projectID: 0, kind: .note, title: "n\(index)")
            // The same root twice is the same project; make each root distinct by its first folder.
            let saved = try store.saveCreatingProject(draft, folders: [], repositoryRoots: [root + (index == 1 ? "-two" : "")])
            #expect(saved.project.name.count <= Limits.projectName, "\(saved.project.name.count)")
            #expect(!saved.project.name.isEmpty)
            names.insert(saved.project.name.lowercased())
        }
        #expect(names.count == roots.count)
        // A taken name with a parent longer than the limit still gets a free name.
        _ = try store.createProject(name: "lib")
        let saved = try store.saveCreatingProject(
            RecordDraft(projectID: 0, kind: .note, title: "m"), folders: [], repositoryRoots: ["/u/\(longParent)/lib"])
        #expect(saved.project.name.count <= Limits.projectName)
    }
}

@Suite struct CanonicalPathTests {
    private func folder() throws -> String {
        let path = PathRules.canonical(NSTemporaryDirectory()) + "/troy-canon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func aSymlinkSpellingIsTheSameFolder() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let real = base + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: real)
        #expect(PathRules.canonical(base + "/link/sub") == real + "/sub")
        let store = try Store(path: ":memory:")
        let project = try store.createProject(name: "Real", paths: [base + "/link"])
        #expect(try store.resolveProject(reference: nil, directory: real + "/x").id == project.id)
        // The other spelling cannot be linked to a second project.
        #expect(thrown { _ = try store.createProject(name: "Other", paths: [real]) }?.isConflict == true)
        let saved = try store.saveCreatingProject(
            RecordDraft(projectID: 0, kind: .note, title: "x"), folders: [real], repositoryRoots: [real])
        #expect(saved.project.id == project.id && !saved.createdProject)
    }

    @Test func aCaseVariantIsTheSameFolderOnACaseInsensitiveVolume() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let upper = base + "/TROY"
        try FileManager.default.createDirectory(atPath: upper, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: base + "/troy") else { return }  // case-sensitive volume
        #expect(PathRules.canonical(base + "/troy") == upper)
        let store = try Store(path: ":memory:")
        let project = try store.createProject(name: "Upper", paths: [upper])
        let saved = try store.saveCreatingProject(
            RecordDraft(projectID: 0, kind: .note, title: "x"), folders: [base + "/troy"], repositoryRoots: [base + "/troy"])
        #expect(saved.project.id == project.id && !saved.createdProject)
        #expect(thrown { _ = try store.createProject(name: "Lower", paths: [base + "/troy"]) }?.isConflict == true)
    }

    @Test func theDataVolumeSpellingIsTheSameFolder() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let data = "/System/Volumes/Data" + base
        guard FileManager.default.fileExists(atPath: data) else { return }
        #expect(PathRules.canonical(data) == base)
        let store = try Store(path: ":memory:")
        let first = try store.saveCreatingProject(
            RecordDraft(projectID: 0, kind: .note, title: "a"), folders: [data], repositoryRoots: [data])
        #expect(first.project.paths == [base])
        let second = try store.saveCreatingProject(
            RecordDraft(projectID: 0, kind: .note, title: "b"), folders: [base], repositoryRoots: [base])
        #expect(second.project.id == first.project.id && !second.createdProject)
        #expect(try store.projects().count == 1)
    }

    @Test func aMissingFolderKeepsItsTypedRest() throws {
        #expect(PathRules.canonical("/no/such/place/") == "/no/such/place")
        let tmp = PathRules.canonical("/tmp")
        #expect(PathRules.canonical("/tmp/troy-none-\(1)/a") == tmp + "/troy-none-1/a")
    }
}
