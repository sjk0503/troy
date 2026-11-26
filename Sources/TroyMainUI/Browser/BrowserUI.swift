import AppKit
import Observation
import SwiftUI
import TroyCore
import TroyGraph
import TroyUI

/// The sheets the main window can present.
enum BrowserSheet: Identifiable {
    case newRecord(projectID: Int64?)
    case editRecord(Record)
    case newProject
    case editProject(Project)
    case addLink(RecordSummary)

    var id: String {
        switch self {
        case .newRecord: "new-record"
        case .editRecord(let record): "edit-record-\(record.id)"
        case .newProject: "new-project"
        case .editProject(let project): "edit-project-\(project.id)"
        case .addLink(let record): "add-link-\(record.id)"
        }
    }
}

/// A link the person asked to remove, waiting for confirmation.
struct PendingLinkRemoval {
    var link: LinkedRecord
    /// The record the link is being viewed from.
    var from: RecordSummary
}

/// Window-local state that is not part of `AppModel`: which sheet or confirmation is up, the
/// graph's local view filters, and the helpers every part of the browser shares.
@Observable
final class BrowserUI {
    let model: AppModel

    var sheet: BrowserSheet?
    var recordToDelete: RecordSummary?
    var projectToDelete: ProjectSummary?
    var linkToRemove: PendingLinkRemoval?
    /// Increases when the search field should take focus.
    var searchFocusTick = 0
    /// Set when the search field has to take focus once the list is on screen (⌘F from the overview).
    var wantsSearchFocus = false

    // Graph view filters. They never change what the list shows.
    var graphHidesFinished = false
    var graphHiddenRelations: Set<Relation> = []
    /// True while the graph shows only the selected record's direct links. Reset when leaving the graph.
    /// Leaving the local graph also drops `showsLocalInspector`, so the next local graph starts full width.
    var showsLocalGraph = false {
        didSet { if !showsLocalGraph { showsLocalInspector = false } }
    }
    /// True when the user asked for the record detail beside the local graph. Off by default, so the local
    /// graph is full width. `open(_:)` leaves it alone, so the choice survives opening another record.
    var showsLocalInspector = false

    init(model: AppModel, showsLocalGraph: Bool = false) {
        self.model = model
        self.showsLocalGraph = showsLocalGraph
    }

    // MARK: Presenting

    func newRecord() {
        let hasActiveProject = model.projects.contains { $0.project.status == .active }
        if model.isLoaded, !hasActiveProject {
            sheet = .newProject
            return
        }
        let selected = model.selectedProject
        sheet = .newRecord(projectID: selected?.status == .active ? selected?.id : nil)
    }

    func newProject() { sheet = .newProject }

    func edit(_ project: Project) { sheet = .editProject(project) }

    func addLink(to record: RecordSummary) { sheet = .addLink(record) }

    /// Opens the editor with the record's full text.
    func edit(recordID id: Int64) {
        if let record = model.detail?.record, record.id == id {
            sheet = .editRecord(record)
            return
        }
        Task {
            if let record = await model.record(id) { sheet = .editRecord(record) }
        }
    }

    /// After a record was created: make sure it is visible, then select it.
    func select(created id: Int64) async {
        guard let record = await model.record(id) else {
            model.selectedRecordID = id
            return
        }
        // A new record from the overview or the list is revealed in the list; the graph stays the graph.
        if model.browserMode == .graph {
            open(record.summary)
        } else {
            model.revealInList(record.summary)
        }
    }

    /// The selected record's direct links as a graph.
    func openLocalGraph(for record: RecordSummary) {
        open(record)
        showsLocalGraph = true
        model.browserMode = .graph
    }

    // MARK: Navigation

    /// Selects a record from a link or an advisory, switching project when it lives in another one.
    func open(_ record: RecordSummary) {
        if let current = model.selectedProjectID, current != record.projectID {
            model.selectedProjectID = record.projectID
        }
        model.selectedRecordID = record.id
    }

    // MARK: Actions

    func setStatus(_ id: Int64, _ status: RecordStatus) {
        Task { await model.updateRecord(id, RecordPatch(status: status)) }
    }

    func setArchived(_ project: Project, _ archived: Bool) {
        Task { await model.updateProject(project.id, status: archived ? .archived : .active) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func projectName(_ id: Int64) -> String? {
        model.projects.first { $0.id == id }?.project.name
    }

    /// The record and its links as Markdown, for pasting into a prompt or a note.
    func markdown(_ detail: RecordDetail) -> String {
        let summary = detail.record.summary
        var lines = ["# \(summary.title)", ""]
        var meta = "#\(summary.id) · \(summary.kind.rawValue) · \(summary.status.rawValue)"
        if !summary.tags.isEmpty { meta += " · " + summary.tags.map { "#\($0)" }.joined(separator: " ") }
        lines.append(meta)
        if !detail.record.body.isEmpty { lines += ["", detail.record.body] }
        if !summary.paths.isEmpty { lines += ["", "Paths:"] + summary.paths.map { "- `\($0)`" } }
        if !detail.links.isEmpty {
            lines += ["", "Links:"]
            for item in detail.links {
                var line = "- \(item.phrase) #\(item.other.id) \(item.other.title)"
                if !item.link.note.isEmpty { line += " — \(item.link.note)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Relation look

/// How each relation is drawn, in the graph and in its legend. One place so they cannot disagree.
struct RelationStyle {
    var width: Double
    var stroke: GraphStroke
    var hasArrow: Bool
    /// 0...1, how hard the edge pulls its two ends together in the layout.
    var strength: Double

    static func of(_ relation: Relation) -> RelationStyle {
        switch relation {
        case .partOf: RelationStyle(width: 2.6, stroke: .solid, hasArrow: true, strength: 0.95)
        case .dependsOn: RelationStyle(width: 1.7, stroke: .solid, hasArrow: true, strength: 0.6)
        case .derivedFrom: RelationStyle(width: 1.1, stroke: .dashed, hasArrow: true, strength: 0.45)
        case .supersedes: RelationStyle(width: 1.1, stroke: .dashed, hasArrow: true, strength: 0.3)
        case .relatesTo: RelationStyle(width: 1.3, stroke: .dotted, hasArrow: false, strength: 0.12)
        case .conflictsWith: RelationStyle(width: 1.5, stroke: .dashed, hasArrow: false, strength: 0.08)
        }
    }
}

/// Colors made once. A dynamic `Color` compares by identity, and the graph canvas re-lays out
/// whenever its inputs compare unequal, so fresh colors on every redraw would restart the layout.
enum Paint {
    static let kinds: [RecordKind: Color] = Dictionary(uniqueKeysWithValues: RecordKind.allCases.map { ($0, Theme.color($0)) })
    static let relations: [Relation: Color] = Dictionary(uniqueKeysWithValues: Relation.allCases.map { ($0, Theme.color($0)) })
}
