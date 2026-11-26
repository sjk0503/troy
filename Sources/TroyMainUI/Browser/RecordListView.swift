import SwiftUI
import TroyCore
import TroyUI

/// The records of the selected project, grouped so the most actionable come first, or search results.
struct RecordListView: View {
    @Bindable var model: AppModel
    @Environment(BrowserUI.self) private var ui

    private struct RecordGroup: Identifiable {
        let id: String
        let title: String?
        let records: [RecordSummary]
    }

    private var showsProject: Bool { model.selectedProjectID == nil }

    var body: some View {
        if let hits = model.searchHits {
            if hits.isEmpty { noResults } else { results(hits) }
        } else if model.records.isEmpty {
            noRecords
        } else {
            grouped
        }
    }

    // MARK: Lists

    private var grouped: some View {
        let names = projectNames
        return List(selection: $model.selectedRecordID) {
            ForEach(groups()) { group in
                Section {
                    ForEach(group.records) { record in
                        row(record, projectName: showsProject ? names[record.projectID] : nil)
                    }
                } header: {
                    if let title = group.title { SectionHeading(title, count: group.records.count) }
                }
            }
        }
        .listStyle(.inset)
        .listRowSeparator(.hidden)
        .alternatingRowBackgrounds(.disabled)
    }

    private func results(_ hits: [SearchHit]) -> some View {
        let names = projectNames
        return List(selection: $model.selectedRecordID) {
            Section {
                ForEach(hits) { hit in
                    row(hit.record, projectName: showsProject ? names[hit.record.projectID] : nil, subtitle: hit.snippet)
                }
            } header: {
                SectionHeading(L("Results", ko: "검색 결과"), count: hits.count)
            }
            if hits.count >= Limits.searchLimit {
                Text(L("Showing the first \(Limits.searchLimit) results. Add a word to narrow them down.",
                       ko: "처음 \(Limits.searchLimit)개만 보입니다. 단어를 더 넣어 좁혀 보세요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .listRowSeparator(.hidden)
        .alternatingRowBackgrounds(.disabled)
    }

    private func row(_ record: RecordSummary, projectName: String?, subtitle: String? = nil) -> some View {
        RecordRow(record, projectName: projectName, subtitle: subtitle)
            .tag(record.id)
            .listRowSeparator(.hidden)
            .contextMenu { menu(for: record) }
    }

    private var projectNames: [Int64: String] {
        Dictionary(model.projects.map { ($0.id, $0.project.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Grouping

    private func groups() -> [RecordGroup] {
        let records = model.records
        if model.filter.scope == .finished {
            return [RecordGroup(id: "finished", title: nil, records: records)]
        }
        var result: [RecordGroup] = []
        func add(_ id: String, _ title: String, _ items: [RecordSummary]) {
            guard !items.isEmpty else { return }
            result.append(RecordGroup(id: id, title: title, records: items.sorted { $0.updatedAt > $1.updatedAt }))
        }
        let unfinished = records.filter { !$0.status.isFinished }
        add("doing", Theme.name(.doing), unfinished.filter { $0.status == .doing })
        let open = unfinished.filter { $0.status == .open }
        add("tasks", L("Open tasks", ko: "대기 중인 할 일"), open.filter { $0.kind == .task })
        for kind in [RecordKind.decision, .note, .result, .prompt] {
            add(kind.rawValue, Theme.pluralName(kind), open.filter { $0.kind == kind })
        }
        if model.filter.scope == .all {
            add("finished", ContentHeader.name(.finished), records.filter { $0.status.isFinished })
        }
        return result
    }

    // MARK: Context menu

    @ViewBuilder private func menu(for record: RecordSummary) -> some View {
        ForEach(RecordStatus.allCases.filter { $0 != record.status }, id: \.self) { status in
            Button { ui.setStatus(record.id, status) } label: {
                Label(Self.markAs(status), systemImage: Theme.symbol(status))
            }
        }
        Divider()
        Button(L("Edit…", ko: "편집…")) { ui.edit(recordID: record.id) }
        Button(L("Add link…", ko: "연결 추가…")) { ui.addLink(to: record) }
        Button(L("Copy “#\(record.id)”", ko: "“#\(record.id)” 복사")) { ui.copy("#\(record.id)") }
        Divider()
        Button(L("Delete…", ko: "삭제…"), role: .destructive) { ui.recordToDelete = record }
    }

    private static func markAs(_ status: RecordStatus) -> String {
        switch status {
        case .open: L("Mark as open", ko: "대기로 표시")
        case .doing: L("Mark as in progress", ko: "진행 중으로 표시")
        case .done: L("Mark as done", ko: "완료로 표시")
        case .dropped: L("Mark as dropped", ko: "중단으로 표시")
        }
    }

    // MARK: Empty states

    private var hasNarrowingFilter: Bool { !model.filter.kinds.isEmpty || model.filter.tag != nil }

    @ViewBuilder private var noRecords: some View {
        if hasNarrowingFilter {
            EmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: L("No matching records", ko: "조건에 맞는 기록이 없습니다"),
                message: L("Nothing here matches the kind or tag you picked in the sidebar.",
                           ko: "사이드바에서 고른 종류나 태그에 맞는 기록이 없습니다.")
            ) {
                Button(L("Clear filters", ko: "필터 해제")) {
                    model.filter.kinds = []
                    model.filter.tag = nil
                }
            }
        } else if model.filter.scope == .active, (model.overview?.stats.records ?? 0) > 0 {
            EmptyState(
                symbol: "checkmark.circle",
                title: L("Nothing open", ko: "열려 있는 기록이 없습니다"),
                message: L("Everything in this project is finished. Switch to “All” to see it.",
                           ko: "이 프로젝트의 기록은 모두 끝났습니다. 보려면 “전체”로 바꾸세요.")
            ) {
                Button(L("Show all", ko: "전체 보기")) { model.filter.scope = .all }
            }
        } else {
            EmptyState(
                symbol: "tray",
                title: L("No records yet", ko: "아직 기록이 없습니다"),
                message: L("Agents save tasks, decisions and notes here as they work. You can also add one yourself.",
                           ko: "에이전트가 일하면서 할 일, 결정, 메모를 여기에 남깁니다. 직접 추가할 수도 있습니다.")
            ) {
                Button(L("New record", ko: "새 기록")) { ui.newRecord() }
            }
        }
    }

    private var noResults: some View {
        EmptyState(
            symbol: "magnifyingglass",
            title: L("No results for “\(model.searchText.trimmingCharacters(in: .whitespaces))”",
                     ko: "“\(model.searchText.trimmingCharacters(in: .whitespaces))” 검색 결과가 없습니다"),
            message: L("Search matches every word as a substring of the title, tags or text, so each word you type has to appear somewhere in a record.",
                       ko: "검색은 입력한 모든 단어가 제목, 태그, 본문 어딘가에 부분 문자열로 들어 있는 기록을 찾습니다.")
        ) {
            if model.filter.scope != .all || model.selectedProjectID != nil {
                Button(L("Search everywhere", ko: "전체에서 검색")) {
                    model.filter.scope = .all
                    model.filter.kinds = []
                    model.filter.tag = nil
                    model.selectedProjectID = nil
                }
            }
        }
    }
}
