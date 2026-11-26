import SwiftUI
import TroyCore
import TroyUI

/// Links `record` to another record: pick the relation, find the other record, add an optional note.
public struct LinkEditorSheet: View {
    private let model: AppModel
    private let record: RecordSummary
    private let onDone: () -> Void

    @State private var relation: Relation
    /// True when `record` is the link's source ("this record <relation> the other").
    @State private var thisIsSource = true
    @State private var query = ""
    @State private var includesAllProjects = false
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var selected: RecordSummary?
    @State private var note = ""
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var searchFocused: Bool

    /// - Parameters:
    ///   - relation: the relation chosen when the sheet opens.
    ///   - onDone: called when the sheet should close, whether or not a link was made.
    public init(model: AppModel, record: RecordSummary, onDone: @escaping () -> Void) {
        self.model = model
        self.record = record
        self.onDone = onDone
        _relation = State(initialValue: .relatesTo)
    }

    /// For the preview executable, which needs a sheet that already shows a choice.
    package init(model: AppModel, record: RecordSummary, relation: Relation, query: String, selected: RecordSummary?, thisIsSource: Bool = true, onDone: @escaping () -> Void) {
        self.model = model
        self.record = record
        self.onDone = onDone
        _relation = State(initialValue: relation)
        _query = State(initialValue: query)
        _selected = State(initialValue: selected)
        _thisIsSource = State(initialValue: thisIsSource)
    }

    private var noteTooLong: Bool { note.count > Limits.linkNote }
    private var canAdd: Bool { selected != nil && !noteTooLong }

    private func name(of record: RecordSummary?) -> String {
        record.map { "#\($0.id) \($0.title)" } ?? L("the other record", ko: "선택한 기록")
    }

    public var body: some View {
        SheetScaffold(
            title: L("Add Link", ko: "연결 추가"),
            subtitle: "#\(record.id) \(record.title)",
            error: error,
            confirmTitle: L("Add Link", ko: "연결 추가"),
            canConfirm: canAdd,
            isWorking: isSaving,
            onCancel: onDone,
            onConfirm: add
        ) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        relationGroup
                        if !relation.isSymmetric { directionGroup }
                        searchGroup
                        noteGroup
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .padding(.bottom, 14)
                }
                previewBar
            }
        }
        .frame(width: 600, height: 700)
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            searchFocused = true
        }
        .task(id: SearchKey(query: query, all: includesAllProjects)) { await runSearch() }
    }

    // MARK: Relation

    private var relationGroup: some View {
        EditorGroup(title: L("Relation", ko: "관계")) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Relation.allCases, id: \.self) { item in
                    let isSelected = item == relation
                    Button { relation = item } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Theme.color(item)).frame(width: 9, height: 9)
                            Text(Theme.name(item)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? Theme.color(item).opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isSelected ? Theme.color(item).opacity(0.6) : Color.primary.opacity(0.10)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            FieldCaption(Theme.explanation(relation))
        }
    }

    // MARK: Direction

    private var directionGroup: some View {
        EditorGroup(title: L("Direction", ko: "방향")) {
            directionOption(thisSource: true)
            directionOption(thisSource: false)
        }
    }

    private func directionOption(thisSource: Bool) -> some View {
        let isSelected = thisIsSource == thisSource
        let this = name(of: record)
        let other = name(of: selected)
        return Button { thisIsSource = thisSource } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Self.sentence(
                    source: thisSource ? this : other, target: thisSource ? other : this, relation: relation,
                    placeholderSide: selected == nil ? (thisSource ? .target : .source) : nil)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Search

    private var searchGroup: some View {
        EditorGroup(title: L("Other record", ko: "연결할 기록")) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("", text: $query, prompt: Text(L("Search by title, tag or text", ko: "제목, 태그, 내용으로 검색")))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .focused($searchFocused)
                        .accessibilityLabel(L("Search records", ko: "기록 검색"))
                    if !query.isEmpty {
                        IconButton(symbol: "xmark.circle.fill", label: L("Clear search", ko: "검색어 지우기")) { query = "" }
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))

                Toggle(L("All projects", ko: "모든 프로젝트"), isOn: $includesAllProjects)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            results
        }
    }

    @ViewBuilder private var results: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selected, trimmed.isEmpty {
            selectedCard(selected)
        } else if trimmed.isEmpty {
            hint(L("Type to find the record to link.", ko: "연결할 기록을 검색하세요."))
        } else if hits.isEmpty {
            hint(isSearching || !hasSearched ? L("Searching…", ko: "검색 중…") : L("No matching records.", ko: "일치하는 기록이 없습니다."))
        } else {
            VStack(spacing: 2) {
                ForEach(hits) { hit in resultRow(hit.record, snippet: nil) }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 56)
    }

    private func selectedCard(_ record: RecordSummary) -> some View {
        resultRow(record, snippet: nil)
    }

    private func resultRow(_ summary: RecordSummary, snippet: String?) -> some View {
        let isSelected = selected?.id == summary.id
        return Button { selected = summary } label: {
            HStack(spacing: 8) {
                RecordRow(summary, projectName: includesAllProjects ? projectName(summary.projectID) : nil)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func projectName(_ id: Int64) -> String? {
        model.projects.first { $0.id == id }?.project.name
    }

    // MARK: Note and preview

    private var noteGroup: some View {
        EditorGroup(title: L("Note (optional)", ko: "메모 (선택)")) {
            HStack(spacing: 8) {
                TextField("", text: $note, prompt: Text(L("Why are these linked?", ko: "왜 연결하나요?")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel(L("Note", ko: "메모"))
                LimitCounter(count: note.count, limit: Limits.linkNote)
            }
            if noteTooLong {
                FieldCaption(L("The note is limited to \(Limits.linkNote) characters.", ko: "메모는 \(Limits.linkNote)자까지 쓸 수 있습니다."), isError: true)
            }
        }
    }

    private var previewBar: some View {
        let this = name(of: record)
        let other = name(of: selected)
        let source = relation.isSymmetric || thisIsSource ? this : other
        let target = relation.isSymmetric || thisIsSource ? other : this
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("Will be saved", ko: "저장될 내용"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Self.sentence(source: source, target: target, relation: relation, placeholderSide: nil, dimmed: selected == nil)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color(relation).opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    // MARK: Sentence

    enum Side { case source, target }

    /// "#12 Sync engine  is part of  #3 Ship offline mode", with the titles emphasized and the relation in its color.
    static func sentence(source: String, target: String, relation: Relation, placeholderSide: Side?, dimmed: Bool = false) -> Text {
        func subject(_ text: String, _ side: Side) -> Text {
            let isPlaceholder = placeholderSide == side
            return Text(text).fontWeight(isPlaceholder ? .regular : .semibold)
                .foregroundStyle(isPlaceholder || dimmed ? Color.secondary : Color.primary)
        }
        func connector(_ text: String) -> Text {
            Text(text).foregroundStyle(Theme.color(relation))
        }
        if Localization.usesKorean {
            // The particle follows the sound the title ends in.
            func particle(_ word: String, _ afterConsonant: String, _ afterVowel: String) -> Text {
                Text(Josa.pick(word, afterConsonant, afterVowel) + " ")
            }
            let topic = subject(source, .source) + particle(source, "은", "는")
            let pair = subject(source, .source) + particle(source, "과", "와") + subject(target, .target) + particle(target, "은", "는")
            switch relation {
            case .partOf: return topic + subject(target, .target) + Text("의 ") + connector("일부입니다")
            case .dependsOn: return topic + subject(target, .target) + particle(target, "이", "가") + connector("끝나야 진행할 수 있습니다")
            case .derivedFrom: return topic + subject(target, .target) + Text("에서 ") + connector("나왔습니다")
            case .supersedes: return topic + subject(target, .target) + particle(target, "을", "를") + connector("대체합니다")
            case .relatesTo: return pair + connector("관련이 있습니다")
            case .conflictsWith: return pair + connector("서로 충돌합니다")
            }
        }
        let verb: String = switch relation {
        case .partOf: "is part of"
        case .dependsOn: "depends on"
        case .derivedFrom: "is derived from"
        case .supersedes: "supersedes"
        case .relatesTo: "relates to"
        case .conflictsWith: "conflicts with"
        }
        return subject(source, .source) + Text("  ") + connector(verb) + Text("  ") + subject(target, .target)
    }

    // MARK: Actions

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            isSearching = false
            hasSearched = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let found = await model.search(trimmed, projectID: includesAllProjects ? nil : record.projectID, limit: 20)
        guard !Task.isCancelled else { return }
        hits = found.filter { $0.record.id != record.id }
        hasSearched = true
        isSearching = false
    }

    private func add() {
        guard let selected, canAdd, !isSaving else { return }
        isSaving = true
        error = nil
        let (from, to) = relation.isSymmetric || thisIsSource ? (record.id, selected.id) : (selected.id, record.id)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await model.link(from: from, to: to, relation: relation, note: text)
            isSaving = false
            if ok {
                onDone()
            } else {
                error = model.errorMessage ?? L("The link could not be added.", ko: "연결을 추가하지 못했습니다.")
                model.errorMessage = nil
            }
        }
    }
}

private struct SearchKey: Equatable {
    var query: String
    var all: Bool
}
