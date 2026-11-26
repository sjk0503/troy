import SwiftUI
import TroyCore
import TroyUI

/// Projects, kinds and tags. Projects choose what the window shows; kinds and tags narrow it.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(BrowserUI.self) private var ui

    private static let shownTags = 12

    var body: some View {
        @Bindable var ui = ui
        List(selection: projectSelection) {
            Section {
                allProjectsRow
                ForEach(model.projects) { summary in
                    projectRow(summary)
                }
                Toggle(isOn: $model.showsArchivedProjects) {
                    Text(L("Show archived", ko: "보관된 프로젝트 보기"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            } header: {
                HStack {
                    Text(L("Projects", ko: "프로젝트"))
                    Spacer()
                    Button { ui.newProject() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(L("New project", ko: "새 프로젝트"))
                    .accessibilityLabel(L("New project", ko: "새 프로젝트"))
                }
            }

            Section(L("Kinds", ko: "종류")) {
                ForEach(RecordKind.allCases, id: \.self) { kind in
                    kindRow(kind)
                }
            }

            if !visibleTags.isEmpty {
                Section(L("Tags", ko: "태그")) {
                    ForEach(visibleTags, id: \.tag) { tag in
                        tagRow(tag)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            L("Delete this project?", ko: "이 프로젝트를 삭제할까요?"),
            isPresented: Binding(get: { ui.projectToDelete != nil }, set: { if !$0 { ui.projectToDelete = nil } }),
            titleVisibility: .visible, presenting: ui.projectToDelete
        ) { summary in
            Button(L("Delete", ko: "삭제"), role: .destructive) {
                Task { await model.deleteProject(summary.id) }
            }
            Button(L("Cancel", ko: "취소"), role: .cancel) {}
        } message: { summary in
            Text(L(
                "“\(summary.project.name)” and its \(summary.stats.records) records will be permanently deleted, with their links and history. This cannot be undone.",
                ko: "“\(summary.project.name)” 프로젝트와 기록 \(summary.stats.records)개가 연결과 변경 이력까지 모두 영구 삭제됩니다. 되돌릴 수 없습니다."))
        }
    }

    // MARK: Projects

    private var projectSelection: Binding<Int64?> {
        Binding(
            get: { model.selectedProjectID ?? 0 },
            set: { model.selectedProjectID = ($0 ?? 0) == 0 ? nil : $0 })
    }

    private var allProjectsRow: some View {
        let open = model.projects.filter { $0.project.status == .active }.reduce(0) { $0 + $1.stats.openTasks }
        return Label(L("All projects", ko: "모든 프로젝트"), systemImage: "tray.full")
            .badge(open)
            .tag(Int64(0))
    }

    private func projectRow(_ summary: ProjectSummary) -> some View {
        let archived = summary.project.status == .archived
        return HStack(spacing: 5) {
            Label {
                Text(summary.project.name).lineLimit(1)
            } icon: {
                Image(systemName: archived ? "archivebox" : "folder")
            }
            if summary.stats.doing > 0 {
                Circle()
                    .fill(Theme.attention)
                    .frame(width: 6, height: 6)
                    .help(L("\(summary.stats.doing) in progress", ko: "진행 중 \(summary.stats.doing)개"))
                    .accessibilityLabel(L("\(summary.stats.doing) in progress", ko: "진행 중 \(summary.stats.doing)개"))
            }
        }
        .opacity(archived ? 0.5 : 1)
        .badge(summary.stats.openTasks)
        .tag(summary.id)
        .contextMenu {
            Button(L("Edit…", ko: "편집…")) { ui.edit(summary.project) }
            Button(archived ? L("Unarchive", ko: "보관 해제") : L("Archive", ko: "보관")) {
                ui.setArchived(summary.project, !archived)
            }
            Divider()
            Button(L("Delete…", ko: "삭제…"), role: .destructive) { ui.projectToDelete = summary }
        }
    }

    // MARK: Kinds

    /// The overview has no kind or tag filters, so choosing one there shows the filtered list.
    /// The local graph ignores them too, so from there the filtered whole-project graph is shown.
    private func showFiltered() {
        if model.browserMode == .overview {
            model.browserMode = .list
        } else if model.browserMode == .graph {
            ui.showsLocalGraph = false
        }
    }

    private func kindRow(_ kind: RecordKind) -> some View {
        let isOn = model.filter.kinds.contains(kind)
        return Button {
            if isOn { model.filter.kinds.remove(kind) } else { model.filter.kinds.insert(kind) }
            showFiltered()
        } label: {
            HStack(spacing: 8) {
                KindIcon(kind, size: 18)
                Text(Theme.pluralName(kind))
                    .foregroundStyle(isOn ? Color.accentColor : .primary)
                    .fontWeight(isOn ? .semibold : .regular)
                Spacer(minLength: 4)
                if isOn {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn
              ? L("Showing only the checked kinds. Click to stop filtering by this kind.", ko: "선택한 종류만 보는 중입니다. 눌러서 이 종류의 필터를 끕니다.")
              : L("Show only this kind", ko: "이 종류만 보기"))
    }

    // MARK: Tags

    private var visibleTags: [TagCount] {
        let sorted = model.tags.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
        var shown = Array(sorted.prefix(Self.shownTags))
        if let selected = model.filter.tag, !shown.contains(where: { $0.tag == selected }) {
            shown.append(sorted.first { $0.tag == selected } ?? TagCount(tag: selected, count: 0))
        }
        return shown
    }

    private func tagRow(_ tag: TagCount) -> some View {
        let isOn = model.filter.tag == tag.tag
        return Button {
            model.filter.tag = isOn ? nil : tag.tag
            showFiltered()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.caption)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(tag.tag)
                    .lineLimit(1)
                    .foregroundStyle(isOn ? Color.accentColor : .primary)
                    .fontWeight(isOn ? .semibold : .regular)
                Spacer(minLength: 4)
                if isOn {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                } else {
                    Text("\(tag.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
