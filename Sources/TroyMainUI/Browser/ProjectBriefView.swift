import AppKit
import SwiftUI
import TroyCore
import TroyUI

/// A project's state as an editorial brief: what is moving, who owns it, what is ready or stuck,
/// where work collides and which decisions are in effect. In the all-projects scope it lists the
/// projects instead, so a project can be picked from here.
struct ProjectBriefView: View {
    @Bindable var model: AppModel
    @Environment(BrowserUI.self) private var ui

    @State private var expanded: Set<String> = []
    @State private var summaryExpanded = false
    @State private var copied = false
    @State private var copyTick = 0
    @ScaledMetric(relativeTo: .title) private var nameSize: CGFloat = 26
    @ScaledMetric(relativeTo: .headline) private var sectionSize: CGFloat = 16

    private static let initialCount = 5
    private static let maxWidth: CGFloat = 1040
    private static let twoColumnWidth: CGFloat = 860

    // MARK: Body

    var body: some View {
        Group {
            if !model.isLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = model.selectedProjectID {
                // The overview of the previous project is cleared on switching; never show it under a new name.
                if let overview = model.overview, overview.project.id == id {
                    brief(overview)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                allProjects
            }
        }
        .task(id: copyTick) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
        .onChange(of: model.selectedProjectID) {
            expanded = []
            summaryExpanded = false
            copied = false
        }
    }

    // MARK: One project

    private func brief(_ o: ProjectOverview) -> some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.twoColumnWidth
            let work = !(o.doing.isEmpty && o.ready.isEmpty && o.blocked.isEmpty && o.collisions.isEmpty)
            let hasLeft = !o.doing.isEmpty || !o.ready.isEmpty || hasDecisions(o)
            let hasRight = !o.blocked.isEmpty || !o.collisions.isEmpty || !o.recent.isEmpty
            ScrollView {
                VStack(spacing: 0) {
                    header(o)
                    VStack(alignment: .leading, spacing: 24) {
                        if o.stats.records == 0 {
                            EmptyState(
                                symbol: "tray",
                                title: L("No records yet", ko: "아직 기록이 없습니다"),
                                message: L("Agents save tasks, decisions and notes here as they work. You can also add one yourself.",
                                           ko: "에이전트가 일하면서 할 일, 결정, 메모를 여기에 남깁니다. 직접 추가할 수도 있습니다.")
                            ) {
                                Button(L("New record", ko: "새 기록")) { ui.newRecord() }
                            }
                            .frame(minHeight: 220)
                        } else if wide && hasLeft && hasRight {
                            if !work { quietLine }
                            HStack(alignment: .top, spacing: 40) {
                                VStack(alignment: .leading, spacing: 24) {
                                    doing(o)
                                    ready(o)
                                    decisions(o)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                VStack(alignment: .leading, spacing: 24) {
                                    blocked(o)
                                    collisions(o)
                                    recent(o)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            if !work { quietLine }
                            doing(o)
                            blocked(o)
                            ready(o)
                            collisions(o)
                            decisions(o)
                            recent(o)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: Self.maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func hasDecisions(_ o: ProjectOverview) -> Bool {
        !o.decisions.isEmpty || (o.kindCounts[.decision] ?? 0) > 0
    }

    /// One calm line when nothing is moving, instead of a column of empty sections.
    private var quietLine: some View {
        Label(L("Nothing is in progress, ready or blocked.", ko: "진행 중이거나 시작 대기, 막힌 작업이 없습니다."),
              systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func header(_ o: ProjectOverview) -> some View {
        let summary = o.project.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let longSummary = summary.count > 140 || summary.contains(where: \.isNewline)
        let records = o.stats.records == 1
            ? L("1 record", ko: "기록 1개")
            : L("\(o.stats.records) records", ko: "기록 \(o.stats.records)개")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(o.project.name)
                    .font(.system(size: nameSize, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if o.project.status == .archived {
                    Text(L("Archived", ko: "보관됨")).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Spacer(minLength: 8)
                copyButton(o)
            }
            if !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(summaryExpanded || !longSummary ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if longSummary {
                        Button(summaryExpanded ? L("Show less", ko: "접기") : L("Show more", ko: "더 보기")) {
                            summaryExpanded.toggle()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 6) {
                Text(records).fixedSize()
                if let last = o.stats.lastActivity {
                    Text("·")
                    Text(L("Updated \(Theme.age(last))", ko: "\(Theme.age(last)) 수정"))
                        .fixedSize()
                        .help(Theme.timestamp(last))
                }
                if let path = o.project.paths.first {
                    let more = o.project.paths.count - 1
                    Text("·")
                    Label(more > 0 ? "\(path)  +\(more)" : path, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(o.project.paths.joined(separator: "\n"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            distribution(o)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(Theme.workspaceSurface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func copyButton(_ o: ProjectOverview) -> some View {
        Button {
            ui.copy(briefText(o))
            copied = true
            copyTick += 1
            AccessibilityNotification.Announcement(L("Session brief copied", ko: "인계 메모를 복사했습니다")).post()
        } label: {
            Label(copied ? L("Copied", ko: "복사됨") : L("Copy session brief", ko: "인계 메모 복사"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(copied ? Theme.workspaceInk : nil)
        .help(L("Copy this project's state as text to hand to an AI session", ko: "AI 세션에 넘길 수 있도록 이 프로젝트의 현재 상태를 텍스트로 복사합니다"))
    }

    /// The kinds as one thin band, each as wide as its share of the records, with a compact legend.
    @ViewBuilder private func distribution(_ o: ProjectOverview) -> some View {
        let parts = RecordKind.allCases.map { ($0, o.kindCounts[$0] ?? 0) }.filter { $0.1 > 0 }
        let total = parts.reduce(0) { $0 + $1.1 }
        if total > 0 {
            let spoken = parts.map { "\(Theme.pluralName($0.0)) \($0.1)" }.joined(separator: ", ")
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let gap: CGFloat = 1
                    let usable = max(0, geo.size.width - gap * CGFloat(parts.count - 1))
                    HStack(spacing: gap) {
                        ForEach(parts, id: \.0) { kind, count in
                            Rectangle()
                                .fill(Theme.color(kind))
                                .frame(width: usable * CGFloat(count) / CGFloat(total))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Record kinds: \(spoken)", ko: "기록 종류: \(spoken)"))
                FlowLayout(spacing: 6, lineSpacing: 2) {
                    ForEach(parts, id: \.0) { kind, count in
                        let title = L("Show all \(Theme.pluralName(kind)) in the record list",
                                      ko: "기록 목록에서 \(Theme.pluralName(kind)) 모두 보기")
                        Button {
                            var filter = RecordFilter()
                            filter.scope = .all
                            filter.kinds = [kind]
                            filter.tag = nil
                            filter.hideSuperseded = false
                            model.filter = filter
                            model.searchText = ""
                            model.selectedRecordID = nil
                            model.browserMode = .list
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.color(kind)).frame(width: 6, height: 6)
                                Text(Theme.pluralName(kind)).lineLimit(1)
                                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(title)
                        .accessibilityLabel(title)
                        .accessibilityValue("\(count)")
                    }
                }
            }
        }
    }

    // MARK: Sections

    private func doing(_ o: ProjectOverview) -> some View {
        section("doing", L("In progress", ko: "진행 중"),
                symbol: Theme.symbol(RecordStatus.doing), tint: Theme.color(RecordStatus.doing),
                hint: L("Work being done now, and by whom.", ko: "지금 누가 무엇을 하고 있는지 보여줍니다."),
                items: o.doing, limit: Limits.overviewDoing, total: o.stats.doing) { r in
            let stale = Theme.isStale(claimedAt: r.claimedAt)
            let owner = r.assignee ?? L("No owner", ko: "담당 미지정")
            recordRow(r, note: stale ? L("\(owner) · claimed long ago", ko: "\(owner) · 오래전에 맡음") : owner,
                      noteColor: stale ? .secondary : Theme.attention)
        }
    }

    private func ready(_ o: ProjectOverview) -> some View {
        section("ready", L("Ready to start", ko: "바로 시작"),
                symbol: Theme.symbol(RecordStatus.open), tint: Theme.color(RecordStatus.open),
                hint: L("Open tasks that wait on nothing.", ko: "기다리는 선행 작업이 없는 대기 중인 할 일입니다."),
                items: o.ready, limit: Limits.overviewReady) { r in
            recordRow(r)
        }
    }

    private func blocked(_ o: ProjectOverview) -> some View {
        section("blocked", L("Blocked", ko: "막힘"),
                symbol: "hourglass", tint: Theme.attention,
                hint: L("These wait for the records listed under them to finish.", ko: "아래 적힌 선행 기록이 끝나야 진행할 수 있습니다."),
                items: o.blocked, limit: Limits.overviewBlocked) { b in
            VStack(alignment: .leading, spacing: 0) {
                recordRow(b.record, note: b.record.status == .doing ? b.record.assignee : nil, noteColor: Theme.attention)
                ForEach(b.waitingOn) { dep in
                    BriefRow(
                        label: L("Waits on \(dep.title), #\(dep.id), \(Theme.name(dep.status))",
                                 ko: "선행 작업 \(dep.title), #\(dep.id), \(Theme.name(dep.status))"),
                        hint: L("Opens the record in the list", ko: "목록에서 기록 열기"), action: { model.revealInList(dep) }
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                            Text(L("Waits on", ko: "선행")).font(.caption).foregroundStyle(.secondary).fixedSize()
                            Text("#\(dep.id)").font(Theme.referenceFont).foregroundStyle(.secondary).fixedSize()
                            Text(dep.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            StatusBadge(dep.status, isSuperseded: dep.isSuperseded)
                        }
                    }
                    .padding(.leading, 32)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func collisions(_ o: ProjectOverview) -> some View {
        let conflict = o.collisions.contains { $0.kind == .conflict }
        return section("collisions", L("Collisions", ko: "겹침"),
                       symbol: "exclamationmark.triangle.fill", tint: conflict ? Theme.danger : Theme.attention,
                       hint: L("Unfinished records that may get in each other's way.", ko: "끝나지 않은 기록끼리 서로 방해할 수 있는 경우입니다."),
                       items: o.collisions, limit: Limits.overviewCollisions) { c in
            VStack(alignment: .leading, spacing: 0) {
                Label(collisionName(c.kind), systemImage: c.kind == .conflict ? "exclamationmark.triangle.fill" : "arrow.triangle.merge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(c.kind == .conflict ? Theme.danger : Theme.attention)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                recordRow(c.first, note: c.first.assignee, noteColor: Theme.attention)
                recordRow(c.second, note: c.second.assignee, noteColor: Theme.attention)
                if !c.detail.isEmpty {
                    Text(c.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func decisions(_ o: ProjectOverview) -> some View {
        let past = o.kindCounts[.decision] ?? 0
        return section("decisions", L("Decisions in effect", ko: "유효한 결정"),
                       symbol: Theme.symbol(RecordKind.decision), tint: Theme.color(RecordKind.decision),
                       hint: L("Not dropped and not replaced, newest first.", ko: "중단되거나 대체되지 않은 결정입니다. 최신순입니다."),
                       items: o.decisions, limit: Limits.overviewDecisions,
                       empty: past > 0 ? L("None in effect; \(past) replaced or dropped.", ko: "유효한 결정이 없습니다. \(past)개는 대체되었거나 중단되었습니다.") : nil) { r in
            recordRow(r)
        }
    }

    private func recent(_ o: ProjectOverview) -> some View {
        section("recent", L("Recently changed", ko: "최근 변경"),
                symbol: "clock", tint: .secondary,
                hint: L("Latest records not listed elsewhere here.", ko: "여기 다른 곳에 나오지 않은 최근 기록입니다."),
                items: o.recent, limit: Limits.overviewRecent) { r in
            recordRow(r, showStatus: true)
        }
    }

    /// The count to show for a bounded list: exact when known, "N+" when the query stopped at its limit.
    private func bound(_ shown: Int, limit: Int, total: Int?) -> (label: String, spoken: String, note: String?) {
        if let total {
            let note = total > shown ? L("Showing \(shown) of \(total)", ko: "\(total)개 중 \(shown)개 표시") : nil
            return ("\(total)", "\(total)", note)
        }
        if shown >= limit {
            return ("\(shown)+", L("\(shown) or more", ko: "\(shown)개 이상"),
                    L("Showing \(shown); there may be more", ko: "\(shown)개 표시 · 더 있을 수 있음"))
        }
        return ("\(shown)", "\(shown)", nil)
    }

    /// A readable heading with a status symbol and count, a hairline, the first few rows and a disclosure for the rest.
    /// Without rows and without an `empty` line it draws nothing.
    @ViewBuilder
    private func section<Item, Row: View>(
        _ id: String, _ title: String, symbol: String, tint: Color, hint: String,
        items: [Item], limit: Int, total: Int? = nil, empty: String? = nil,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !items.isEmpty || empty != nil {
            let open = expanded.contains(id)
            let shown = open ? items : Array(items.prefix(Self.initialCount))
            let count = bound(items.count, limit: limit, total: total)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.callout).foregroundStyle(tint).frame(width: 18)
                    Text(title).font(.system(size: sectionSize, weight: .semibold)).lineLimit(1)
                    Text(count.label).font(.callout).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                }
                .help(hint)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(count.spoken)")
                .accessibilityAddTraits(.isHeader)
                Divider().padding(.vertical, 6)
                if items.isEmpty, let empty {
                    Text(empty).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in row(item) }
                    if let note = count.note, open || items.count <= Self.initialCount {
                        Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4)
                    }
                    if items.count > Self.initialCount {
                        Button(open ? L("Show fewer", ko: "접기") : L("Show \(items.count - Self.initialCount) more", ko: "\(items.count - Self.initialCount)개 더 보기")) {
                            if open { expanded.remove(id) } else { expanded.insert(id) }
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .accessibilityLabel(open ? L("Show fewer \(title)", ko: "\(title) 접기") : L("Show all \(items.count) in \(title)", ko: "\(title) \(items.count)개 모두 보기"))
                    }
                }
            }
        }
    }

    /// A record you can open, in columns: kind, title with an optional note such as its owner, status, id, age.
    private func recordRow(_ r: RecordSummary, note: String? = nil, noteColor: Color = .secondary, showStatus: Bool = false) -> some View {
        let status = r.isSuperseded ? Theme.supersededName : Theme.name(r.status)
        var spoken = "\(Theme.name(r.kind)), \(r.title), #\(r.id), \(status)"
        if let note { spoken += ", \(note)" }
        return BriefRow(label: spoken, hint: L("Opens the record in the list", ko: "목록에서 기록 열기"), action: { model.revealInList(r) }) {
            HStack(alignment: .top, spacing: 10) {
                KindIcon(r.kind, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(noteColor).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if showStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(.top, 2)
                }
                Text("#\(r.id)")
                    .font(Theme.referenceFont).foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing).padding(.top, 2)
                Text(Theme.age(r.updatedAt))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing).padding(.top, 2)
                    .help(Theme.timestamp(r.updatedAt))
            }
        }
    }

    private func collisionName(_ kind: AdvisoryKind) -> String {
        switch kind {
        case .conflict: L("Conflict", ko: "충돌")
        case .pathOverlap: L("Touching the same files", ko: "같은 파일을 건드림")
        case .unfinishedDependency: L("Unfinished dependency", ko: "끝나지 않은 선행 작업")
        }
    }

    // MARK: All projects

    private var allProjects: some View {
        let projects = model.projects
        let records = projects.reduce(0) { $0 + $1.stats.records }
        let projectCount = projects.count == 1 ? L("1 project", ko: "프로젝트 1개") : L("\(projects.count) projects", ko: "프로젝트 \(projects.count)개")
        let recordCount = records == 1 ? L("1 record", ko: "기록 1개") : L("\(records) records", ko: "기록 \(records)개")
        return ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("All projects", ko: "모든 프로젝트"))
                        .font(.system(size: nameSize, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !projects.isEmpty {
                        Text("\(projectCount) · \(recordCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background(Theme.workspaceSurface)
                .overlay(alignment: .bottom) { Divider() }

                VStack(alignment: .leading, spacing: 4) {
                    if projects.isEmpty {
                        EmptyState(
                            symbol: "tray",
                            title: L("No projects yet", ko: "아직 프로젝트가 없습니다"),
                            message: L("Start a project, or let a connected AI client create one.", ko: "프로젝트를 만들거나, 연결된 AI 클라이언트가 만들도록 두세요.")
                        ) {
                            Button(L("New project", ko: "새 프로젝트")) { ui.newProject() }
                        }
                        .frame(minHeight: 220)
                    } else {
                        ForEach(projects) { summary in projectRow(summary) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func projectRow(_ s: ProjectSummary) -> some View {
        let p = s.project
        let summary = p.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts = [L("\(s.stats.records) records", ko: "기록 \(s.stats.records)개"),
                     L("\(s.stats.openTasks) open tasks", ko: "대기 중인 할 일 \(s.stats.openTasks)개")]
        if s.stats.doing > 0 { facts.append(L("\(s.stats.doing) in progress", ko: "진행 중 \(s.stats.doing)개")) }
        if let last = s.stats.lastActivity { facts.append(L("active \(Theme.age(last))", ko: "최근 활동 \(Theme.age(last))")) }
        let line = facts.joined(separator: " · ")
        return BriefRow(
            label: "\(p.name)\(p.status == .archived ? ", " + L("archived", ko: "보관됨") : ""), \(line)",
            hint: L("Opens this project's brief", ko: "이 프로젝트의 브리프 열기"), action: { model.selectedProjectID = p.id }
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder")
                    .font(.title3)
                    .foregroundStyle(Theme.workspaceInk)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(p.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if p.status == .archived {
                            Text(L("Archived", ko: "보관됨")).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    if !summary.isEmpty {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .opacity(p.status == .archived ? 0.7 : 1)
        }
    }

    // MARK: Copy

    /// The brief as Markdown for another AI session. Lists the overview query capped say so.
    private func briefText(_ o: ProjectOverview) -> String {
        func ref(_ r: RecordSummary) -> String { "#\(r.id) \(r.title)" }
        func suffix(_ shown: Int, limit: Int, total: Int? = nil) -> String {
            guard let note = bound(shown, limit: limit, total: total).note else { return "" }
            return " (\(note))"
        }
        let p = o.project
        var lines = ["# " + L("Session brief: \(p.name)", ko: "인계 메모: \(p.name)"), ""]
        lines.append(L("Project: \(p.name) (project #\(p.id))", ko: "프로젝트: \(p.name) (프로젝트 #\(p.id))"))
        let summary = p.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines.append(L("Summary: \(summary)", ko: "요약: \(summary)")) }
        if !p.paths.isEmpty { lines.append(L("Folders: ", ko: "폴더: ") + p.paths.joined(separator: ", ")) }
        let kinds = RecordKind.allCases.compactMap { kind in o.kindCounts[kind].flatMap { $0 > 0 ? "\($0) \(kind.rawValue)" : nil } }
        lines.append(L("Records: \(o.stats.records)", ko: "기록: \(o.stats.records)개") + (kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"))
        if let last = o.stats.lastActivity { lines.append(L("Last activity: ", ko: "최근 활동: ") + Theme.timestamp(last)) }
        lines.append(L("Records are cited as #id. Read full text with troy_read.", ko: "기록은 #id로 인용합니다. 본문은 troy_read로 읽습니다."))

        if !o.doing.isEmpty {
            lines += ["", "## " + L("In progress", ko: "진행 중") + suffix(o.doing.count, limit: Limits.overviewDoing, total: o.stats.doing)]
            for r in o.doing {
                var line = "- \(ref(r)) — " + L("owner: ", ko: "담당: ") + (r.assignee ?? L("none", ko: "없음"))
                if Theme.isStale(claimedAt: r.claimedAt) { line += L(" (claimed over \(Limits.staleClaimHours)h ago)", ko: " (\(Limits.staleClaimHours)시간 넘게 전에 맡음)") }
                if !r.paths.isEmpty { line += L("; files: ", ko: "; 파일: ") + r.paths.joined(separator: ", ") }
                lines.append(line)
            }
        }

        if !o.ready.isEmpty {
            lines += ["", "## " + L("Ready to start", ko: "바로 시작") + suffix(o.ready.count, limit: Limits.overviewReady)]
            lines += o.ready.map { "- \(ref($0))" }
        }

        if !o.blocked.isEmpty {
            lines += ["", "## " + L("Blocked", ko: "막힘") + suffix(o.blocked.count, limit: Limits.overviewBlocked)]
            for b in o.blocked {
                let owner = b.record.assignee.map { L(" (owner: \($0))", ko: " (담당: \($0))") } ?? ""
                let waits = b.waitingOn.map { "\(ref($0)) [\(Theme.name($0.status))]" }.joined(separator: ", ")
                lines.append("- \(ref(b.record))\(owner) — " + L("waits on: ", ko: "선행: ") + waits)
            }
        }

        if !o.collisions.isEmpty {
            lines += ["", "## " + L("Collisions", ko: "겹침") + suffix(o.collisions.count, limit: Limits.overviewCollisions)]
            for c in o.collisions {
                var line = "- \(ref(c.first)) ↔ \(ref(c.second)) — \(collisionName(c.kind))"
                if !c.detail.isEmpty { line += ": \(c.detail)" }
                lines.append(line)
            }
        }

        if o.doing.isEmpty && o.ready.isEmpty && o.blocked.isEmpty && o.collisions.isEmpty {
            lines += ["", "## " + L("Work", ko: "작업"),
                      "- " + L("Nothing is in progress, ready or blocked.", ko: "진행 중이거나 시작 대기, 막힌 작업이 없습니다.")]
        }

        if hasDecisions(o) {
            lines += ["", "## " + L("Decisions in effect", ko: "유효한 결정") + suffix(o.decisions.count, limit: Limits.overviewDecisions)]
            if o.decisions.isEmpty {
                let past = o.kindCounts[.decision] ?? 0
                lines.append("- " + L("none in effect; \(past) replaced or dropped", ko: "유효한 결정 없음; \(past)개는 대체되었거나 중단됨"))
            }
            for r in o.decisions {
                lines.append("- \(ref(r))")
                if !r.preview.isEmpty { lines.append("  \(r.preview)") }
            }
        }

        if !o.recent.isEmpty {
            lines += ["", "## " + L("Recently changed", ko: "최근 변경") + suffix(o.recent.count, limit: Limits.overviewRecent)]
            for r in o.recent {
                let status = r.isSuperseded ? "superseded" : r.status.rawValue
                lines.append("- \(ref(r)) [\(r.kind.rawValue), \(status)] — " + Theme.age(r.updatedAt))
                if !r.preview.isEmpty { lines.append("  \(r.preview)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A full-width row that opens something: hover tint, whole row clickable, one spoken label.
private struct BriefRow<Content: View>: View {
    let label: String
    let hint: String
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(hovering ? Theme.workspaceSurface : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}
