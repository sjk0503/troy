import Foundation
import Testing
import TroyCore
@testable import TroyMCP

@Suite struct ToolTests {
    // MARK: Happy paths

    @Test func projectsAndNewProject() throws {
        let h = try Harness(workingDirectory: "/tmp/troy-tests/repo")
        let created = h.ok("troy_new_project", ["name": "Atlas", "summary": "Maps", "path": "/tmp/troy-tests/repo"])
        #expect(created.hasPrefix("Created project #1 \"Atlas\", linked to /tmp/troy-tests/repo."))
        let list = h.ok("troy_projects")
        #expect(list.contains("1 project:"))
        #expect(list.contains("#1 Atlas — 0 records"))
        #expect(list.contains("← this folder"))
        #expect(list.contains("folders: /tmp/troy-tests/repo"))
        let duplicate = h.call("troy_new_project", ["name": "atlas"])
        #expect(duplicate.isError)
        #expect(duplicate.text.contains("already exists"))
        let archivedOnly = h.ok("troy_projects", ["include_archived": true])
        #expect(archivedOnly.contains("Atlas"))
    }

    @Test func newProjectDefaultsToTheGitRoot() throws {
        let root = NSTemporaryDirectory() + "troy-git-\(UUID().uuidString)"
        let nested = root + "/Sources/Deep"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let h = try Harness(workingDirectory: nested)
        let text = h.ok("troy_new_project", ["name": "Rooted"])
        let expected = try PathCheck.standard(root)
        #expect(text.contains("linked to \(expected)."), "\(text) / \(expected)")
        // Without a .git above, the folder itself is linked.
        let plain = NSTemporaryDirectory() + "troy-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        let other = try Harness(store: h.store, workingDirectory: plain)
        #expect(other.ok("troy_new_project", ["name": "Plain"]).contains("linked to \(try PathCheck.standard(plain))."))
    }

    @Test func saveReadAndContext() throws {
        let h = try Harness()
        let project = h.newProject("Core")
        let parent = h.save(project, "task", "Rewrite the store")
        let saved = h.ok("troy_save", [
            "project": .int(project), "kind": "task", "title": "Add the export command", "body": "Write Markdown.",
            "tags": ["cli", "export"], "paths": ["Sources/TroyCLI"], "parent": .int(parent),
        ])
        #expect(saved.contains("Saved #2 [task/open] \"Add the export command\" in project #1 Core."))
        #expect(saved.contains("Linked: part of #1."))

        let read = h.ok("troy_read", ["ids": [2]])
        #expect(read.hasPrefix("#2 [task/open] Add the export command\n"))
        #expect(read.contains("project #1 Core · tags: cli, export · paths: Sources/TroyCLI · created "))
        #expect(read.contains("Write Markdown."))
        #expect(read.contains("Links:\n- part of #1 [task/open] Rewrite the store"))

        let context = h.ok("troy_context", ["project": .int(project)])
        #expect(context.hasPrefix("Project #1 \"Core\"\n2 records · 2 open tasks · 0 in progress · last activity "))
        #expect(context.contains("READY\n#1 Rewrite the store\n#2 Add the export command · part of #1"))
        #expect(!context.contains("IN PROGRESS"))
        #expect(!context.contains("BLOCKED"))
        #expect(context.hasSuffix("Keep this current without being asked: troy_save {\"project\":1,…} each decision, finding and finished piece of work as it happens, and claim a task with troy_update before working on it. Read bodies with troy_read {\"ids\":[…]}."))
    }

    @Test func decisionsAndRecentAppearInContext() throws {
        let h = try Harness()
        let project = h.newProject("Core")
        h.save(project, "decision", "All Swift, no dependencies")
        h.save(project, "note", "Trigram misses two-character Korean words")
        let context = h.ok("troy_context", ["project": .int(project)])
        #expect(context.contains("DECISIONS IN EFFECT\n#1 All Swift, no dependencies ("))
        #expect(context.contains("RECENT\n#2 [note/open] Trigram misses two-character Korean words · 0m"))
    }

    // MARK: Project resolution

    @Test func saveRequiresAProject() throws {
        let h = try Harness(workingDirectory: "/tmp/troy-tests/linked")
        h.newProject("Alpha", path: "/tmp/troy-tests/linked")
        h.newProject("Beta")
        let result = h.call("troy_save", ["kind": "note", "title": "No project"])
        #expect(result.isError)
        #expect(result.text.contains("\"project\" is required"))
        #expect(result.text.contains("#1 Alpha"))
        #expect(result.text.contains("#2 Beta"))
        #expect(result.text.contains("troy_context"))
        // The linked working folder does not count for writes.
        #expect(try h.store.list(RecordQuery()).isEmpty)

        let empty = try Harness()
        let none = empty.call("troy_save", ["kind": "note", "title": "x"])
        #expect(none.text.contains("no projects yet"))
        #expect(none.text.contains("troy_new_project"))
    }

    @Test func projectFallbackOrder() throws {
        let store = try Store(path: ":memory:")
        let base = try Harness(store: store, workingDirectory: "/tmp/troy-tests/a/sub")
        base.newProject("Alpha", path: "/tmp/troy-tests/a")
        base.newProject("Beta", path: "/tmp/troy-tests/b")

        // Working directory: the project whose folder contains it.
        #expect(base.ok("troy_context").hasPrefix("Project #1 \"Alpha\""))
        // Environment beats the working directory.
        let env = try Harness(store: store, environment: ["TROY_PROJECT": "Beta"], workingDirectory: "/tmp/troy-tests/a/sub")
        #expect(env.ok("troy_context").hasPrefix("Project #2 \"Beta\""))
        // The argument beats the environment.
        #expect(env.ok("troy_context", ["project": "Alpha"]).hasPrefix("Project #1 \"Alpha\""))
        #expect(env.ok("troy_context", ["project": 1]).hasPrefix("Project #1 \"Alpha\""))
        #expect(env.ok("troy_context", ["project": "#1"]).hasPrefix("Project #1 \"Alpha\""))
        // Writes use the environment too.
        #expect(env.ok("troy_save", ["kind": "note", "title": "From env"]).contains("in project #2 Beta"))
        // Nothing matches: the error lists the projects.
        let lost = try Harness(store: store, workingDirectory: "/tmp/elsewhere")
        let miss = lost.call("troy_context")
        #expect(miss.isError)
        #expect(miss.text.contains("Alpha"))
        #expect(miss.text.contains("Pass \"project\""))
        let unknown = lost.call("troy_context", ["project": "Nope"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("No project matches"))
    }

    @Test func searchFallsBackToEveryProjectWhenNoneMatchesTheFolder() throws {
        let h = try Harness(workingDirectory: "/tmp/elsewhere")
        let one = h.newProject("One")
        h.save(one, "note", "Export notes")
        let text = h.ok("troy_search", ["query": "export"])
        #expect(text.contains("1 result for \"export\" in all projects:"))
    }

    // MARK: Leniency

    @Test func idsAndListsAreForgiving() throws {
        let h = try Harness()
        let project = h.newProject("Lenient")
        let a = h.save(project, "task", "First")
        let b = h.save(project, "task", "Second")
        let c = h.save(project, "task", "Third")
        #expect(h.ok("troy_read", ["ids": ["#\(a)"]]).hasPrefix("#\(a) "))
        #expect(h.ok("troy_read", ["ids": .double(Double(a))]).hasPrefix("#\(a) "))
        #expect(h.ok("troy_read", ["ids": "\(a), #\(b)"]).contains("\n---\n"))
        #expect(h.ok("troy_read", ["id": .string(" \(c) ")]).hasPrefix("#\(c) "))
        // Update with a string id, a float id and comma-separated tags.
        let update = h.ok("troy_update", ["id": "#\(a)", "tags": "x, y ,x"])
        #expect(update.contains("tags: x, y"))
        #expect(h.ok("troy_update", ["id": .double(Double(b)), "title": "Second!"]).contains("title changed"))
        // Link with a list of targets, with a string target in it.
        let link = h.ok("troy_link", ["from": .int(a), "to": [.int(b), .string("#\(c)")], "relation": "depends_on"])
        #expect(link.contains("Linked #\(a) depends on #\(b)"))
        #expect(link.contains("Linked #\(a) depends on #\(c)"))
        #expect(try h.store.links(of: a).count == 2)
        // A single target given as an id string, and a relation written with a space.
        #expect(h.ok("troy_link", ["from": .int(b), "to": "#\(c)", "relation": "relates to"]).contains("Linked #\(b) relates to #\(c)"))
        // The links shorthand: relation names as keys.
        let linked = h.ok("troy_save", ["project": "Lenient", "kind": "note", "title": "Shorthand", "links": [["depends_on": [.int(a), .int(b)]]]])
        #expect(linked.contains("Linked: depends on #\(a), depends on #\(b)."))
    }

    @Test func badArgumentsNameTheArgumentAndShowAnExample() throws {
        let h = try Harness()
        let project = h.newProject("Strict")
        let id = h.call("troy_update", ["id": "abc", "status": "done"])
        #expect(id.isError)
        #expect(id.text.contains("\"id\""))
        #expect(id.text.contains("#42"))
        let fraction = h.call("troy_read", ["ids": [.double(1.5)]])
        #expect(fraction.isError && fraction.text.contains("\"ids\""))
        let kind = h.call("troy_save", ["project": .int(project), "kind": "idea", "title": "x"])
        #expect(kind.isError)
        #expect(kind.text.contains("\"kind\"") && kind.text.contains("task, decision, note, result, prompt"))
        let status = h.call("troy_save", ["project": .int(project), "kind": "note", "title": "x", "status": "superseded"])
        #expect(status.isError && status.text.contains("supersedes"))
        let missing = h.call("troy_save", ["project": .int(project), "kind": "note"])
        #expect(missing.isError && missing.text.contains("\"title\" is required"))
        let unknown = h.call("troy_save", ["project": .int(project), "kind": "note", "title": "x", "description": "oops"])
        #expect(unknown.isError)
        #expect(unknown.text.contains("\"description\"") && unknown.text.contains("body"))
        let empty = h.call("troy_update", ["id": 1])
        #expect(empty.isError && empty.text.contains("Nothing to change"))
        let relation = h.call("troy_link", ["from": 1, "to": 2, "relation": "blocks"])
        #expect(relation.isError && relation.text.contains("part_of"))
        let tooMany = h.call("troy_read", ["ids": .array((1...21).map { .int($0) })])
        #expect(tooMany.isError && tooMany.text.contains("at most 20"))
        let blank = h.call("troy_search", ["query": "  "])
        #expect(blank.isError && blank.text.contains("\"query\""))
    }

    // MARK: Claims

    @Test func claimIsRefusedAndTakeoverSucceeds() throws {
        let store = try Store(path: ":memory:")
        let first = try Harness(store: store, environment: ["TROY_AGENT": "codex/a1f"])
        let second = try Harness(store: store, environment: ["TROY_AGENT": "claude-code/9f2"])
        let project = first.newProject("Claims")
        let task = first.save(project, "task", "Contested")
        #expect(first.ok("troy_update", ["id": .int(task), "status": "doing"]).contains("[task/doing by codex/a1f, 0m]"))

        let refused = second.call("troy_update", ["id": .int(task), "status": "doing"])
        #expect(refused.isError)
        #expect(refused.text.contains("#\(task) is in progress by codex/a1f, claimed just now."))
        #expect(refused.text.contains("Pick other work, or pass \"takeover\": true if that session is gone."))
        #expect(try store.record(id: task).summary.assignee == "codex/a1f")

        let taken = second.ok("troy_update", ["id": .int(task), "status": "doing", "takeover": true])
        #expect(taken.contains("by claude-code/9f2"))
        #expect(taken.contains("took over from codex/a1f"))
        #expect(try store.record(id: task).summary.assignee == "claude-code/9f2")
    }

    @Test func successfulClaimListsAdvisories() throws {
        let store = try Store(path: ":memory:")
        let first = try Harness(store: store, environment: ["TROY_AGENT": "codex/a1f"])
        let second = try Harness(store: store, environment: ["TROY_AGENT": "claude-code/9f2"])
        let project = first.newProject("Overlap")
        let one = first.save(project, "task", "Rewrite export", ["paths": ["Sources/App"]])
        first.ok("troy_update", ["id": .int(one), "status": "doing"])
        let two = second.save(project, "task", "Polish the menu", ["paths": ["Sources/App/Menu.swift"]])
        let dependency = second.save(project, "task", "Needs the export", ["links": [["to": .int(one), "relation": "depends_on"]]])

        let claim = second.ok("troy_update", ["id": .int(two), "status": "doing"])
        #expect(claim.contains("Watch out:"))
        #expect(claim.contains("- #\(one) [task/doing by codex/a1f, 0m] touches the same paths: "))

        let blocked = second.ok("troy_update", ["id": .int(dependency), "status": "doing"])
        #expect(blocked.contains("- depends on #\(one) [task/doing by codex/a1f, 0m], which is not finished"))
    }

    @Test func doneAsksForAnOutcomeUnlessTextIsGiven() throws {
        let h = try Harness()
        let project = h.newProject("Done")
        let bare = h.save(project, "task", "Bare")
        let documented = h.save(project, "task", "Documented")
        let replaced = h.save(project, "task", "Replaced")
        let note = h.save(project, "note", "Not a task")

        let reminder = h.ok("troy_update", ["id": .int(bare), "status": "done"])
        #expect(reminder.contains("Updated #\(bare) [task/done] \"Bare\": status open → done."))
        #expect(reminder.contains("Add a one-line outcome"))
        #expect(reminder.contains("troy_update {\"id\":\(bare),\"append\":\"Outcome: …\"}"))

        let appended = h.ok("troy_update", ["id": .int(documented), "status": "done", "append": "Outcome: shipped."])
        #expect(!appended.contains("outcome"))
        #expect(appended.contains("appended 17 characters"))
        #expect(try h.store.record(id: documented).body.contains("Outcome: shipped."))

        #expect(!h.ok("troy_update", ["id": .int(replaced), "status": "done", "body": "All of it."]).contains("outcome"))
        #expect(!h.ok("troy_update", ["id": .int(note), "status": "done"]).contains("outcome"))
        // Nothing changes the second time.
        #expect(h.ok("troy_update", ["id": .int(bare), "status": "done"]).hasPrefix("No change to #\(bare)"))
    }

    // MARK: Saving

    @Test func identicalSaveIsDeduplicated() throws {
        let h = try Harness()
        let project = h.newProject("Dedupe")
        let first = h.ok("troy_save", ["project": .int(project), "kind": "note", "title": "Same thing", "body": "Same body."])
        #expect(first.hasPrefix("Saved #1"))
        let second = h.ok("troy_save", ["project": .int(project), "kind": "note", "title": "Same thing", "body": "Same body."])
        #expect(second.hasPrefix("No second record was stored"))
        #expect(second.contains("#1 [note/open] \"Same thing\""))
        #expect(try h.store.list(RecordQuery()).count == 1)
    }

    @Test func saveShowsSimilarRecordsLinksAndAdvisories() throws {
        let store = try Store(path: ":memory:")
        let a = try Harness(store: store, environment: ["TROY_AGENT": "codex/a1f"])
        let b = try Harness(store: store, environment: ["TROY_AGENT": "claude-code/9f2"])
        let project = a.newProject("Similar")
        let epic = a.save(project, "task", "Native rewrite")
        let busy = a.save(project, "task", "Graph view", ["paths": ["Sources/TroyApp"], "status": "doing"])
        let existing = a.save(project, "task", "Add the export command", ["body": "First version."])
        let other = a.save(project, "decision", "Export format is Markdown", ["tags": ["export"]])

        let text = b.ok("troy_save", [
            "project": .int(project), "kind": "task", "title": "Add the export command", "body": "Second take.",
            "paths": ["Sources/TroyApp/Export.swift"], "parent": .int(epic),
            "links": [["to": .int(other), "relation": "relates_to", "note": "format"]],
        ])
        #expect(text.contains("Linked: part of #\(epic), relates to #\(other)."))
        #expect(text.contains("Similar records already exist. Link them with troy_link, or reuse one instead of duplicating:"))
        #expect(text.contains("- #\(existing) [task/open] Add the export command (100%, probably the same item)"))
        #expect(text.contains("- #\(other) [decision/open] Export format is Markdown ("))
        #expect(!text.contains("(\(100)%)"))
        #expect(text.contains("Watch out:\n- #\(busy) [task/doing by codex/a1f, 0m] touches the same paths: Sources/TroyApp/Export.swift"))
        // The record was written under the second server's label.
        let id = Int64(text.split(separator: " ")[1].dropFirst())!
        #expect(try store.record(id: id).summary.source == "claude-code/9f2")
    }

    @Test func saveCanClaimImmediately() throws {
        let h = try Harness(environment: ["TROY_AGENT": "codex/a1f"])
        let project = h.newProject("Now")
        let text = h.ok("troy_save", ["project": .int(project), "kind": "task", "title": "Start now", "status": "doing"])
        #expect(text.contains("[task/doing by codex/a1f, 0m]"))
    }

    // MARK: Context

    @Test func contextIsCutFromTheBottomAtASmallBudget() throws {
        let h = try Harness()
        let project = h.newProject("Big")
        h.save(project, "decision", "Decision that matters")
        for index in 1...40 {
            h.save(project, "task", "Ready task number \(index) with a reasonably long descriptive title to use space")
        }
        let full = h.ok("troy_context", ["project": .int(project), "max_chars": 20_000])
        #expect(full.contains("DECISIONS IN EFFECT"))
        #expect(!full.contains("not shown"))

        let small = h.ok("troy_context", ["project": .int(project), "max_chars": 1_000])
        #expect(small.count <= 1_000, "\(small.count)")
        #expect(small.contains("READY"))
        #expect(small.contains("more not shown"))
        #expect(small.contains("Left out to stay within max_chars: DECISIONS IN EFFECT (1)"))
        #expect(small.contains("troy_save {\"project\":\(project),…}"))
        #expect(small.hasSuffix("Read bodies with troy_read {\"ids\":[…]}."))
        // Below the minimum the budget is raised to 1,000.
        let clamped = h.ok("troy_context", ["project": .int(project), "max_chars": 10])
        #expect(clamped.count <= 1_000 && clamped.contains("READY"))
    }

    @Test func contextShowsInProgressBlockedAndCollisions() throws {
        let store = try Store(path: ":memory:")
        let a = try Harness(store: store, environment: ["TROY_AGENT": "codex/a1f"])
        let b = try Harness(store: store, environment: ["TROY_AGENT": "claude-code/9f2"])
        let project = a.newProject("Busy")
        let epic = a.save(project, "task", "Epic")
        let store1 = a.save(project, "task", "Rewrite the store", ["parent": .int(epic), "paths": ["Sources/TroyCore"]])
        let graph = b.save(project, "task", "Graph view", ["paths": ["Sources/TroyCore/Store.swift"]])
        let smoke = a.save(project, "task", "MCP smoke tests", ["links": [["to": .int(store1), "relation": "depends_on"]]])
        a.ok("troy_update", ["id": .int(store1), "status": "doing"])
        b.ok("troy_update", ["id": .int(graph), "status": "doing"])
        a.ok("troy_link", ["from": .int(store1), "to": .int(graph), "relation": "conflicts_with", "note": "both restructure Store"])

        let context = a.ok("troy_context", ["project": .int(project)])
        #expect(context.contains("IN PROGRESS\n#\(store1) Rewrite the store — codex/a1f, 0m · part of #\(epic) · paths: Sources/TroyCore"))
        #expect(context.contains("#\(graph) Graph view — claude-code/9f2, 0m"))
        #expect(context.contains("BLOCKED\n#\(smoke) MCP smoke tests — waits on #\(store1)"))
        #expect(context.contains("WATCH OUT"))
        #expect(context.contains("conflicts with"))
        #expect(context.contains("both restructure Store"))
        #expect(context.contains("are both in progress and touch Sources/TroyCore/Store.swift"))
    }

    // MARK: Read

    @Test func readCutsLongBodiesAndSeparatesRecords() throws {
        let h = try Harness()
        let project = h.newProject("Read")
        let long = h.save(project, "note", "Long", ["body": .string(String(repeating: "abcdefghij", count: 50))])
        let short = h.save(project, "note", "Short", ["body": "tiny"])
        let cut = h.ok("troy_read", ["ids": [.int(long)], "max_chars": 200])
        #expect(cut.contains(String(repeating: "abcdefghij", count: 20)))
        #expect(!cut.contains(String(repeating: "abcdefghij", count: 21)))
        #expect(cut.contains("[Body cut at 200 of 500 characters."))
        let both = h.ok("troy_read", ["ids": [.int(long), .int(short)]])
        #expect(both.contains("\n\n---\n\n#\(short) [note/open] Short"))
        #expect(!both.contains("Body cut"))
        let partial = h.ok("troy_read", ["ids": [.int(short), 999]])
        #expect(partial.contains("#999 does not exist."))
        let none = h.call("troy_read", ["ids": [999]])
        #expect(none.isError && none.text == "#999 does not exist.")
    }

    @Test func readShowsLinksFromBothSidesAndSupersession() throws {
        let h = try Harness()
        let project = h.newProject("Links")
        let epic = h.save(project, "task", "Epic")
        let child = h.save(project, "task", "Child", ["parent": .int(epic)])
        let old = h.save(project, "decision", "Old way")
        let new = h.save(project, "decision", "New way")
        let linked = h.ok("troy_link", ["from": .int(new), "to": .int(old), "relation": "supersedes", "note": "better"])
        #expect(linked.contains("Linked #\(new) supersedes #\(old) [decision/open] Old way."))
        #expect(linked.contains("now counts as superseded"))
        #expect(h.ok("troy_read", ["ids": [.int(epic)]]).contains("- contains #\(child) [task/open] Child"))
        let oldText = h.ok("troy_read", ["ids": [.int(old)]])
        #expect(oldText.contains("#\(old) [decision/open, superseded] Old way"))
        #expect(oldText.contains("- superseded by #\(new) [decision/open] New way — better"))
        // Removing a link restores what was there.
        #expect(h.ok("troy_link", ["from": .int(new), "to": .int(old), "relation": "supersedes", "remove": true]).hasPrefix("Removed:"))
        #expect(h.ok("troy_link", ["from": .int(new), "to": .int(old), "relation": "supersedes", "remove": true]).contains("nothing to remove"))
        #expect(h.ok("troy_read", ["ids": [.int(old)]]).contains("[decision/open] Old way"))
    }

    @Test func linkErrorsAreReportedPerTarget() throws {
        let h = try Harness()
        let project = h.newProject("Cycle")
        let a = h.save(project, "task", "A")
        let b = h.save(project, "task", "B")
        h.ok("troy_link", ["from": .int(a), "to": .int(b), "relation": "depends_on"])
        let cycle = h.call("troy_link", ["from": .int(b), "to": .int(a), "relation": "depends_on"])
        #expect(cycle.isError)
        #expect(cycle.text.contains("#\(b) depends on #\(a)"))
        let selfLink = h.call("troy_link", ["from": .int(a), "to": .int(a), "relation": "relates_to"])
        #expect(selfLink.isError)
        let mixed = h.ok("troy_link", ["from": .int(a), "to": [.int(b), 999], "relation": "relates_to"])
        #expect(mixed.contains("Linked #\(a) relates to #\(b)"))
        #expect(mixed.contains("#\(a) relates to #999:"))
    }

    // MARK: Search

    @Test func searchFindsRecordsAndSaysWhenThereMayBeMore() throws {
        let h = try Harness()
        let project = h.newProject("Find")
        h.save(project, "task", "Add the export command", ["body": "Writes every record as Markdown, links included."])
        h.save(project, "note", "Export is slow", ["tags": ["export"]])
        h.save(project, "note", "Unrelated")
        let other = h.newProject("Other")
        h.save(other, "note", "Export elsewhere")

        let text = h.ok("troy_search", ["query": "export", "project": .int(project)])
        #expect(text.hasPrefix("2 results for \"export\" in project #1 Find:"))
        #expect(text.contains("#1 [task/open] Add the export command · 0m"))
        #expect(text.contains("\n   Writes every record as Markdown, links included."))
        #expect(!text.contains("There may be more"))

        let limited = h.ok("troy_search", ["query": "export", "project": .int(project), "limit": 1])
        #expect(limited.hasPrefix("1 result for"))
        #expect(limited.contains("There may be more results."))
        let everywhere = h.ok("troy_search", ["query": "export", "all_projects": true])
        #expect(everywhere.hasPrefix("3 results for \"export\" in all projects:"))
        let filtered = h.ok("troy_search", ["query": "export", "project": .int(project), "kind": "note"])
        #expect(filtered.hasPrefix("1 result for"))
        let tagged = h.ok("troy_search", ["query": "export", "project": .int(project), "tag": "export"])
        #expect(tagged.contains("Export is slow") && !tagged.contains("Add the export command"))
    }

    @Test func searchWithNoResults() throws {
        let h = try Harness()
        let project = h.newProject("Empty")
        let text = h.ok("troy_search", ["query": "nothing here", "project": .int(project)])
        #expect(text.hasPrefix("No results for \"nothing here\" in project #1 Empty."))
        #expect(text.contains("all_projects"))
    }

    // MARK: Agent label

    @Test func agentLabelRules() {
        #expect(AgentLabel.make(clientName: "Claude Code", tag: "a3f") == "claude-code/a3f")
        #expect(AgentLabel.make(clientName: "codex-mcp-client", tag: "a3f") == "codex/a3f")
        #expect(AgentLabel.make(clientName: "Visual Studio Code", tag: "0b1") == "visual-studio-code/0b1")
        #expect(AgentLabel.make(clientName: "Cursor-MCP-Client", tag: "fff") == "cursor/fff")
        #expect(AgentLabel.make(clientName: nil, tag: "a3f") == "agent/a3f")
        #expect(AgentLabel.make(clientName: "  ", tag: "a3f") == "agent/a3f")
        #expect(AgentLabel.make(clientName: "weird/name!", tag: "a3f") == "weird-name/a3f")
        #expect(AgentLabel.make(clientName: "codex", tag: "a3f", override: "me/1") == "me/1")
        #expect(AgentLabel.make(clientName: "codex", tag: "a3f", override: "  ") == "codex/a3f")
        let tag = AgentLabel.randomTag()
        #expect(tag.count == 3 && tag.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func labelFollowsTheClientName() throws {
        let h = try Harness(tag: "9f2")
        #expect(h.server.agentLabel == "agent/9f2")
        let project = h.newProject("Label")
        let before = h.save(project, "note", "Before the handshake")
        #expect(try h.store.record(id: before).summary.source == "agent/9f2")
        h.rpc("initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code"]])
        #expect(h.server.agentLabel == "claude-code/9f2")
        #expect(h.store.agent == "claude-code/9f2")
        let after = h.save(project, "note", "After the handshake")
        #expect(try h.store.record(id: after).summary.source == "claude-code/9f2")

        let fixed = try Harness(environment: ["TROY_AGENT": "custom/1"], tag: "9f2")
        fixed.rpc("initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code"]])
        #expect(fixed.server.agentLabel == "custom/1")
    }
}

enum PathCheck {
    /// The path as the store records it: standardized, no trailing slash.
    static func standard(_ path: String) throws -> String {
        ("/" + path.split(separator: "/").joined(separator: "/"))
    }
}
