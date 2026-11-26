import SwiftUI
import TroyCore
import TroyUI

/// Creates a record (`editing == nil`) or edits one. Presented as a sheet over the main window.
public struct RecordEditorSheet: View {
    private let model: AppModel
    private let editing: Record?
    private let onDone: (Int64?) -> Void

    @State private var projectID: Int64
    @State private var kind: RecordKind
    @State private var status: RecordStatus
    @State private var title: String
    @State private var bodyText: String
    @State private var tags: [String]
    @State private var tagText = ""
    @State private var pathsText: String
    @State private var showsPreview: Bool
    @State private var similar: [SimilarRecord] = []
    @State private var error: String?
    @State private var isSaving = false
    @State private var asksToDiscard = false
    /// The revision the next save is based on. Moves forward only when the person chooses to save over a newer version.
    @State private var baseRev: Int
    @FocusState private var titleFocused: Bool

    /// - Parameters:
    ///   - editing: the record to change, with its full body; `nil` creates a new one.
    ///   - projectID: the project a new record goes into; `nil` lets the person choose.
    ///   - onDone: called with the saved record's id, or `nil` when the sheet was cancelled.
    public init(model: AppModel, editing: Record?, projectID: Int64?, onDone: @escaping (Int64?) -> Void) {
        self.init(model: model, editing: editing, projectID: projectID, initialTitle: nil, showsPreview: false, onDone: onDone)
    }

    /// For the preview executable: a sheet that already has a title typed, or opens on the Preview tab.
    package init(
        model: AppModel, editing: Record?, projectID: Int64?, initialTitle: String?, showsPreview: Bool,
        onDone: @escaping (Int64?) -> Void
    ) {
        self.model = model
        self.editing = editing
        self.onDone = onDone
        let firstActive = model.projects.first { $0.project.status == .active }?.id
        _projectID = State(initialValue: editing?.projectID ?? projectID ?? model.selectedProjectID ?? firstActive ?? 0)
        _kind = State(initialValue: editing?.kind ?? .task)
        _status = State(initialValue: editing?.status ?? .open)
        _title = State(initialValue: editing?.title ?? initialTitle ?? "")
        _showsPreview = State(initialValue: showsPreview)
        _bodyText = State(initialValue: editing?.body ?? "")
        _tags = State(initialValue: editing?.tags ?? [])
        _pathsText = State(initialValue: (editing?.paths ?? []).joined(separator: "\n"))
        _baseRev = State(initialValue: editing?.rev ?? 0)
    }

    private var isCreating: Bool { editing == nil }

    // MARK: Derived values

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The chips plus whatever is typed and not yet turned into a chip.
    private var allTags: [String] {
        Self.uniqueTags(tags + Self.splitTags(tagText))
    }

    private var paths: [String] {
        pathsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var projectChoices: [Project] {
        model.projects.map(\.project).filter { $0.status == .active || $0.id == projectID }
    }

    private var projectName: String {
        model.projects.first { $0.id == projectID }?.project.name ?? "#\(projectID)"
    }

    private var titleProblem: String? {
        trimmedTitle.count > Limits.title
            ? L("The title is limited to \(Limits.title) characters.", ko: "제목은 \(Limits.title)자까지 쓸 수 있습니다.") : nil
    }

    private var bodyProblem: String? {
        bodyText.count > Limits.body
            ? L("The body is limited to \(Limits.body.formatted()) characters.", ko: "본문은 \(Limits.body.formatted())자까지 쓸 수 있습니다.") : nil
    }

    private var tagProblem: String? {
        if allTags.count > Limits.tagCount {
            return L("At most \(Limits.tagCount) tags.", ko: "태그는 \(Limits.tagCount)개까지 붙일 수 있습니다.")
        }
        if allTags.contains(where: { $0.count > Limits.tagLength }) {
            return L("A tag is limited to \(Limits.tagLength) characters.", ko: "태그는 \(Limits.tagLength)자까지 쓸 수 있습니다.")
        }
        return nil
    }

    private var pathProblem: String? {
        if paths.count > Limits.recordPaths {
            return L("At most \(Limits.recordPaths) paths.", ko: "경로는 \(Limits.recordPaths)개까지 적을 수 있습니다.")
        }
        if paths.contains(where: { $0.count > Limits.recordPathLength }) {
            return L("A path is limited to \(Limits.recordPathLength) characters.", ko: "경로 하나는 \(Limits.recordPathLength)자까지 쓸 수 있습니다.")
        }
        return nil
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && projectID != 0 && titleProblem == nil && bodyProblem == nil
            && tagProblem == nil && pathProblem == nil && !bodyText.contains("\0") && !title.contains("\0")
    }

    private var patch: RecordPatch? {
        guard let editing else { return nil }
        var patch = RecordPatch(expectedRev: baseRev)
        if trimmedTitle != editing.title { patch.title = trimmedTitle }
        if bodyText != editing.body { patch.body = bodyText }
        if kind != editing.kind { patch.kind = kind }
        if status != editing.status { patch.status = status }
        if allTags != editing.tags { patch.tags = allTags }
        if paths != editing.paths { patch.paths = paths }
        return patch
    }

    private var hasChanges: Bool {
        guard let patch else { return !trimmedTitle.isEmpty || !bodyText.isEmpty || !allTags.isEmpty || !paths.isEmpty }
        return patch.title != nil || patch.body != nil || patch.kind != nil || patch.status != nil
            || patch.tags != nil || patch.paths != nil
    }

    private var canSave: Bool { isValid && hasChanges }

    // MARK: Body

    public var body: some View {
        SheetScaffold(
            title: isCreating ? L("New Record", ko: "새 기록") : L("Edit Record", ko: "기록 편집"),
            subtitle: editing.map { "#\($0.id) \($0.title)" },
            error: error,
            confirmTitle: isCreating ? L("Create", ko: "만들기") : L("Save", ko: "저장"),
            canConfirm: canSave,
            isWorking: isSaving,
            onCancel: cancel,
            onConfirm: save
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mainGroup
                    bodyGroup
                    detailsGroup
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 640, height: 620)
        .confirmationDialog(
            L("Discard your changes?", ko: "변경 사항을 버릴까요?"), isPresented: $asksToDiscard, titleVisibility: .visible
        ) {
            Button(L("Discard Changes", ko: "변경 사항 버리기"), role: .destructive) { onDone(nil) }
            Button(L("Keep Editing", ko: "계속 편집"), role: .cancel) {}
        }
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            titleFocused = true
        }
        .task(id: SimilarKey(title: trimmedTitle, tags: allTags, projectID: projectID)) { await findSimilar() }
    }

    private var mainGroup: some View {
        EditorGroup {
            FieldRow(label: L("Project", ko: "프로젝트")) {
                if isCreating, projectChoices.count > 1 {
                    Picker("", selection: $projectID) {
                        ForEach(projectChoices) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if projectChoices.isEmpty && isCreating {
                    Text(L("Create a project first.", ko: "먼저 프로젝트를 만드세요."))
                        .foregroundStyle(Theme.danger)
                } else {
                    Label(projectName, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
            }
            FieldRow(label: L("Kind", ko: "종류")) {
                OptionBar(
                    options: RecordKind.allCases.map {
                        .init(value: $0, name: Theme.name($0), symbol: Theme.symbol($0), tint: Theme.color($0))
                    },
                    selection: $kind)
            }
            FieldRow(label: L("Title", ko: "제목"), top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("", text: $title, prompt: Text(L("What is this record about?", ko: "무엇에 관한 기록인가요?")))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($titleFocused)
                            .accessibilityLabel(L("Title", ko: "제목"))
                        LimitCounter(count: trimmedTitle.count, limit: Limits.title)
                    }
                    if let titleProblem { FieldCaption(titleProblem, isError: true) }
                    if isCreating, !similar.isEmpty { similarList }
                }
            }
            FieldRow(label: L("Status", ko: "상태")) {
                OptionBar(
                    options: RecordStatus.allCases.map {
                        .init(value: $0, name: Theme.name($0), symbol: Theme.symbol($0), tint: $0 == .open ? Color.secondary : Theme.color($0))
                    },
                    selection: $status)
            }
        }
    }

    private var similarList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Similar records", ko: "비슷한 기록"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(similar.prefix(4), id: \.record.id) { match in
                let probablySame = match.score >= Limits.duplicateThreshold
                HStack(spacing: 8) {
                    KindIcon(match.record.kind, size: 18)
                    Text(match.record.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("#\(match.record.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    if probablySame {
                        Label(L("Probably the same", ko: "같은 기록일 수 있음"), systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                    }
                    Text("\(Int((match.score * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
            FieldCaption(L("A hint only. You can still save.", ko: "참고용입니다. 그대로 저장해도 됩니다."))
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var bodyGroup: some View {
        EditorGroup(
            title: L("Body", ko: "본문"),
            trailing: AnyView(
                Picker("", selection: $showsPreview) {
                    Text(L("Edit", ko: "편집")).tag(false)
                    Text(L("Preview", ko: "미리보기")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if showsPreview {
                    ScrollView {
                        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L("Nothing to preview.", ko: "미리 볼 내용이 없습니다."))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownText(bodyText)
                        }
                    }
                    .padding(10)
                    .frame(height: 190)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                } else {
                    TextArea(text: $bodyText, minHeight: 190)
                        .frame(height: 190)
                        .accessibilityLabel(L("Body", ko: "본문"))
                }
                HStack(alignment: .firstTextBaseline) {
                    FieldCaption(L("Markdown works: headings, lists, - [ ] tasks, tables, code.", ko: "마크다운을 쓸 수 있습니다: 제목, 목록, - [ ] 할 일, 표, 코드."))
                    Spacer()
                    LimitCounter(count: bodyText.count, limit: Limits.body)
                }
                if let bodyProblem { FieldCaption(bodyProblem, isError: true) }
            }
        }
    }

    private var detailsGroup: some View {
        EditorGroup {
            FieldRow(label: L("Tags", ko: "태그"), top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    tagsField
                    FieldCaption(tagProblem ?? L("Separate with a comma or Return.", ko: "쉼표나 Return으로 구분합니다."), isError: tagProblem != nil)
                }
            }
            FieldRow(label: L("Paths", ko: "경로"), top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    TextArea(text: $pathsText, minHeight: 56, monospaced: true)
                        .frame(height: 64)
                        .accessibilityLabel(L("Paths", ko: "경로"))
                    FieldCaption(pathProblem ?? L(
                        "One per line. The files or folders this work touches. Troy warns when two agents' work overlaps.",
                        ko: "한 줄에 하나씩. 이 작업이 건드리는 파일이나 폴더입니다. 두 에이전트의 작업이 겹치면 Troy가 알려 줍니다."),
                        isError: pathProblem != nil)
                }
            }
        }
    }

    private var tagsField: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag).font(.caption).lineLimit(1)
                    IconButton(symbol: "xmark", label: L("Remove tag \(tag)", ko: "태그 \(tag) 삭제")) {
                        tags.removeAll { $0 == tag }
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: Capsule())
            }
            TextField("", text: $tagText, prompt: Text(tags.isEmpty ? L("Add a tag", ko: "태그 추가") : ""))
                .textFieldStyle(.plain)
                .labelsHidden()
                .accessibilityLabel(L("Add a tag", ko: "태그 추가"))
                .frame(width: tags.isEmpty ? 160 : 90)
                .onSubmit { commitTagText() }
                .onChange(of: tagText) { _, text in
                    if text.contains(",") || text.contains("，") { commitTagText(keepLast: true) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }

    // MARK: Actions

    /// Turns typed text into chips. With `keepLast`, the text after the last comma stays in the field.
    private func commitTagText(keepLast: Bool = false) {
        var text = tagText
        var remainder = ""
        if keepLast, let last = text.lastIndex(where: { $0 == "," || $0 == "，" }) {
            remainder = String(text[text.index(after: last)...])
            text = String(text[...last])
        }
        tags = Self.uniqueTags(tags + Self.splitTags(text))
        tagText = remainder
    }

    private func cancel() {
        if hasChanges { asksToDiscard = true } else { onDone(nil) }
    }

    private func findSimilar() async {
        guard isCreating, trimmedTitle.count >= 2, projectID != 0 else {
            similar = []
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let found = await model.similar(title: trimmedTitle, tags: allTags, projectID: projectID)
        guard !Task.isCancelled else { return }
        similar = found
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        error = nil
        commitTagText()
        Task {
            if let editing {
                var changes = patch ?? RecordPatch()
                changes.expectedRev = baseRev
                if let result = await model.updateRecord(editing.id, changes) {
                    isSaving = false
                    onDone(result.record.id)
                    return
                }
                await showFailure(recordID: editing.id)
            } else {
                let draft = RecordDraft(
                    projectID: projectID, kind: kind, title: trimmedTitle, body: bodyText,
                    tags: allTags, paths: paths, status: status)
                if let result = await model.createRecord(draft) {
                    isSaving = false
                    onDone(result.record.id)
                    return
                }
                await showFailure(recordID: nil)
            }
            isSaving = false
        }
    }

    /// Moves the model's error into the sheet. A stale revision also fetches the newest revision, so
    /// pressing Save again applies only the fields changed here on top of it.
    private func showFailure(recordID: Int64?) async {
        let message = model.errorMessage ?? L("The record could not be saved.", ko: "기록을 저장하지 못했습니다.")
        var isConflict = false
        if case .conflict = model.lastError { isConflict = true }
        model.errorMessage = nil
        // The only conflict an edit from the app can meet is a stale revision.
        if isConflict, let recordID, let latest = await model.record(recordID) {
            baseRev = latest.rev
            error = L("This record changed while you were editing.", ko: "편집하는 동안 이 기록이 바뀌었습니다.")
                + " \(message)\n"
                + L("Save again to apply only your changes on top of the newest version.",
                    ko: "다시 저장하면 바꾼 항목만 최신 버전에 적용합니다.")
        } else {
            error = message
        }
    }

    // MARK: Tag helpers

    static func splitTags(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased()).inserted }
    }
}

private struct SimilarKey: Equatable {
    var title: String
    var tags: [String]
    var projectID: Int64
}
