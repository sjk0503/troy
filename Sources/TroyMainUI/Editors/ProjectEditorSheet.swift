import AppKit
import SwiftUI
import TroyCore
import TroyUI

/// Creates a project (`editing == nil`) or changes its name, summary, linked folders and archive state.
public struct ProjectEditorSheet: View {
    private let model: AppModel
    private let editing: Project?
    private let onDone: (Int64?) -> Void

    @State private var name: String
    @State private var summary: String
    @State private var paths: [String]
    @State private var isArchived: Bool
    @State private var error: String?
    @State private var isSaving = false
    @State private var asksToDiscard = false
    @State private var asksToDelete = false
    @FocusState private var nameFocused: Bool

    /// - Parameter onDone: called with the saved project's id, or `nil` when cancelled or when the project was deleted.
    public init(model: AppModel, editing: Project?, onDone: @escaping (Int64?) -> Void) {
        self.model = model
        self.editing = editing
        self.onDone = onDone
        _name = State(initialValue: editing?.name ?? "")
        _summary = State(initialValue: editing?.summary ?? "")
        _paths = State(initialValue: editing?.paths ?? [])
        _isArchived = State(initialValue: editing?.status == .archived)
    }

    private var isCreating: Bool { editing == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameProblem: String? {
        trimmedName.count > Limits.projectName
            ? L("The name is limited to \(Limits.projectName) characters.", ko: "이름은 \(Limits.projectName)자까지 쓸 수 있습니다.") : nil
    }

    private var summaryProblem: String? {
        trimmedSummary.count > Limits.projectSummary
            ? L("The summary is limited to \(Limits.projectSummary.formatted()) characters.", ko: "요약은 \(Limits.projectSummary.formatted())자까지 쓸 수 있습니다.") : nil
    }

    private var isValid: Bool { !trimmedName.isEmpty && nameProblem == nil && summaryProblem == nil }

    private var hasChanges: Bool {
        guard let editing else { return !trimmedName.isEmpty || !trimmedSummary.isEmpty || !paths.isEmpty }
        return trimmedName != editing.name || trimmedSummary != editing.summary || paths != editing.paths
            || isArchived != (editing.status == .archived)
    }

    private var recordCount: Int {
        editing.flatMap { project in model.projects.first { $0.id == project.id }?.stats.records } ?? 0
    }

    public var body: some View {
        SheetScaffold(
            title: isCreating ? L("New Project", ko: "새 프로젝트") : L("Edit Project", ko: "프로젝트 편집"),
            subtitle: editing?.name,
            error: error,
            confirmTitle: isCreating ? L("Create", ko: "만들기") : L("Save", ko: "저장"),
            canConfirm: isValid && (isCreating || hasChanges),
            isWorking: isSaving,
            onCancel: cancel,
            onConfirm: save
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EditorGroup {
                        FieldRow(label: L("Name", ko: "이름"), top: true) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    TextField("", text: $name, prompt: Text(L("Project name", ko: "프로젝트 이름")))
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                        .focused($nameFocused)
                                        .accessibilityLabel(L("Name", ko: "이름"))
                                    LimitCounter(count: trimmedName.count, limit: Limits.projectName)
                                }
                                if let nameProblem { FieldCaption(nameProblem, isError: true) }
                            }
                        }
                        FieldRow(label: L("Summary", ko: "요약"), top: true) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextArea(text: $summary, minHeight: 72)
                                    .frame(height: 80)
                                    .accessibilityLabel(L("Summary", ko: "요약"))
                                HStack(alignment: .firstTextBaseline) {
                                    FieldCaption(summaryProblem ?? L("What the project is, in a sentence or two. Agents read this.", ko: "프로젝트가 무엇인지 한두 문장으로. 에이전트도 읽습니다."), isError: summaryProblem != nil)
                                    Spacer()
                                    LimitCounter(count: trimmedSummary.count, limit: Limits.projectSummary)
                                }
                            }
                        }
                    }
                    foldersGroup
                    if let editing { manageGroup(editing) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 540, height: isCreating ? 520 : 720)
        .confirmationDialog(
            L("Discard your changes?", ko: "변경 사항을 버릴까요?"), isPresented: $asksToDiscard, titleVisibility: .visible
        ) {
            Button(L("Discard Changes", ko: "변경 사항 버리기"), role: .destructive) { onDone(nil) }
            Button(L("Keep Editing", ko: "계속 편집"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Delete “\(editing?.name ?? "")”?", ko: "“\(editing?.name ?? "")” 프로젝트를 삭제할까요?"),
            isPresented: $asksToDelete, titleVisibility: .visible
        ) {
            Button(L("Delete Project", ko: "프로젝트 삭제"), role: .destructive) { delete() }
            Button(L("Cancel", ko: "취소"), role: .cancel) {}
        } message: {
            Text(L(
                "Its \(recordCount) records and all their links are deleted with it. This cannot be undone.",
                ko: "기록 \(recordCount)개와 모든 연결이 함께 삭제됩니다. 되돌릴 수 없습니다."))
        }
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            nameFocused = true
        }
    }

    // MARK: Folders

    private var foldersGroup: some View {
        EditorGroup(title: L("Linked folders", ko: "연결된 폴더")) {
            if paths.isEmpty {
                Text(L("No folders linked.", ko: "연결된 폴더가 없습니다."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                        if index > 0 { Divider() }
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(Self.display(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer(minLength: 8)
                            IconButton(symbol: "minus.circle", label: L("Remove folder \(Self.display(path))", ko: "폴더 \(Self.display(path)) 제거")) {
                                paths.removeAll { $0 == path }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            HStack {
                Button { addFolders() } label: {
                    Label(L("Add Folder…", ko: "폴더 추가…"), systemImage: "plus")
                }
                .disabled(paths.count >= Limits.projectPaths)
                Spacer()
            }
            FieldCaption(L(
                "Agents working inside these folders are matched to this project.",
                ko: "이 폴더 안에서 일하는 에이전트는 이 프로젝트로 연결됩니다."))
        }
    }

    // MARK: Archive and delete

    private func manageGroup(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorGroup(title: L("Archive", ko: "보관")) {
                Toggle(isOn: $isArchived) {
                    Text(isArchived ? L("Archived", ko: "보관됨") : L("Archive this project", ko: "이 프로젝트 보관"))
                }
                .toggleStyle(.switch)
                FieldCaption(L(
                    "Archived projects leave the sidebar. Nothing is deleted, and you can restore it any time.",
                    ko: "보관한 프로젝트는 사이드바에서 사라집니다. 아무것도 삭제되지 않으며 언제든 되돌릴 수 있습니다."))
            }
            EditorGroup(title: L("Delete", ko: "삭제")) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    FieldCaption(L(
                        "Deleting the project also deletes its records and links.",
                        ko: "프로젝트를 삭제하면 기록과 연결도 함께 삭제됩니다."))
                    Spacer(minLength: 8)
                    Button(role: .destructive) { asksToDelete = true } label: {
                        Text(L("Delete Project…", ko: "프로젝트 삭제…"))
                    }
                    .foregroundStyle(Theme.danger)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Actions

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = L("Add", ko: "추가")
        panel.message = L("Choose the folders this project works in.", ko: "이 프로젝트가 일하는 폴더를 고르세요.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !paths.contains(path), paths.count < Limits.projectPaths { paths.append(path) }
        }
    }

    private func cancel() {
        if hasChanges { asksToDiscard = true } else { onDone(nil) }
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            if let editing {
                var mergedPaths: [String]?
                if paths != editing.paths {
                    // Apply what was added and removed here to the list as it is stored now, so a folder
                    // another process linked while this sheet was open is not dropped.
                    let stored = (await model.project(editing.id))?.paths ?? editing.paths
                    let removed = Set(editing.paths).subtracting(paths)
                    let added = paths.filter { !editing.paths.contains($0) }
                    mergedPaths = stored.filter { !removed.contains($0) } + added.filter { !stored.contains($0) }
                }
                let ok = await model.updateProject(
                    editing.id,
                    name: trimmedName != editing.name ? trimmedName : nil,
                    summary: trimmedSummary != editing.summary ? trimmedSummary : nil,
                    status: isArchived != (editing.status == .archived) ? (isArchived ? .archived : .active) : nil,
                    paths: mergedPaths)
                isSaving = false
                if ok { onDone(editing.id) } else { showFailure() }
            } else {
                let project = await model.createProject(name: trimmedName, summary: trimmedSummary, paths: paths)
                isSaving = false
                if let project { onDone(project.id) } else { showFailure() }
            }
        }
    }

    private func delete() {
        guard let editing, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            let ok = await model.deleteProject(editing.id)
            isSaving = false
            if ok { onDone(nil) } else { showFailure() }
        }
    }

    private func showFailure() {
        error = model.errorMessage ?? L("The project could not be saved.", ko: "프로젝트를 저장하지 못했습니다.")
        model.errorMessage = nil
    }

    private static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
