import AppKit
import ServiceManagement
import SwiftUI
import TroyCore
import TroyMCP
import TroyUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, connections, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("General", ko: "일반")
        case .connections: L("Connections", ko: "연결")
        case .data: L("Data", ko: "데이터")
        case .about: L("About", ko: "정보")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connections: "cable.connector"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    static let width: CGFloat = 560

    /// Content height of the tab. The window grows or shrinks to it.
    var height: CGFloat {
        switch self {
        case .general: 310
        case .connections: 600
        case .data: 570
        case .about: 340
        }
    }
}

@Observable
final class SettingsState {
    var tab: SettingsTab = .general
}

// MARK: - Root

struct SettingsRoot: View {
    let model: AppModel
    let state: SettingsState
    let preferences: Preferences
    let launch: LaunchAtLogin
    let connections: ConnectionsModel

    var body: some View {
        Group {
            switch state.tab {
            case .general: GeneralPane(model: model, preferences: preferences, launch: launch)
            case .connections: ConnectionsPane(model: connections)
            case .data: DataPane(model: model)
            case .about: AboutPane()
            }
        }
        .frame(width: SettingsTab.width, height: state.tab.height)
        .id(model.languageRevision)
    }
}

// MARK: - General

/// Whether Troy opens at login, through `SMAppService`. Best effort: the real status and the system's error are shown.
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    var errorMessage: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    var statusText: String? {
        switch status {
        case .enabled: nil
        case .requiresApproval:
            L("Waiting for your approval in System Settings, Login Items.", ko: "시스템 설정의 로그인 항목에서 허용해야 합니다.")
        case .notFound:
            L("Available when Troy runs as an installed app.", ko: "설치된 앱으로 실행할 때 사용할 수 있습니다.")
        case .notRegistered: nil
        @unknown default: nil
        }
    }
}

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    let launch: LaunchAtLogin

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            Localization.language
        } set: { newValue in
            Localization.language = newValue
            model.languageRevision += 1
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Language", ko: "언어"), selection: languageBinding) {
                    Text(L("System", ko: "시스템 설정")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
            }
            Section {
                SettingToggle(
                    title: L("Open Troy at login", ko: "로그인할 때 Troy 열기"),
                    detail: launch.errorMessage ?? launch.statusText,
                    isError: launch.errorMessage != nil,
                    isOn: Binding { launch.isOn } set: { launch.set($0) })
                if launch.status == .requiresApproval {
                    Button(L("Open Login Items", ko: "로그인 항목 열기")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section {
                SettingToggle(
                    title: L("Shortcut to show the panel", ko: "패널 표시 단축키"),
                    detail: preferences.hotkeyEnabled && !preferences.hotkeyRegistered
                        ? L("\(HotKey.defaultDisplay) is already used by another app.", ko: "\(HotKey.defaultDisplay)는 다른 앱이 사용 중입니다.")
                        : L("Press \(HotKey.defaultDisplay) in any app to show or hide the panel.", ko: "어느 앱에서든 \(HotKey.defaultDisplay)로 패널을 열고 닫습니다."),
                    isError: preferences.hotkeyEnabled && !preferences.hotkeyRegistered,
                    isOn: $preferences.hotkeyEnabled)
                SettingToggle(
                    title: L("Show the in-progress count in the menu bar", ko: "메뉴 막대에 진행 중인 기록 수 표시"),
                    detail: L("A number beside the icon: records in progress in the selected project.", ko: "아이콘 옆에 선택한 프로젝트에서 진행 중인 기록 수를 표시합니다."),
                    isError: false,
                    isOn: $preferences.showsCount)
            }
        }
        .formStyle(.grouped)
        .onAppear { launch.refresh() }
    }
}

private struct SettingToggle: View {
    let title: String
    let detail: String?
    let isError: Bool
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isError ? Theme.danger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Connections

@Observable
final class ConnectionsModel {
    struct Row: Identifiable {
        var guide: MCPClientGuide
        /// `nil` while detection is running.
        var installed: Bool?
        var connected: Bool?
        var isBusy = false
        var message: Message?
        var id: String { guide.id }
    }

    struct Message {
        var text: String
        var isError: Bool
    }

    private(set) var rows: [Row]
    private(set) var binary = "troy"
    /// The id of the copy button that just worked, so it can say "Copied" for a moment.
    private(set) var copied: String?
    /// Render mode: detect from files only and never start another program.
    private let fileOnly: Bool

    init(fileOnly: Bool = false) {
        self.fileOnly = fileOnly
        rows = MCPClients.guides(binary: "troy").map { Row(guide: $0) }
    }

    nonisolated private struct Detected: Sendable {
        var guide: MCPClientGuide
        var installed: Bool
        var connected: Bool?
    }

    nonisolated private static func detect(fileOnly: Bool) -> (binary: String, rows: [Detected]) {
        // `defaultBinary` and `isInstalled` may ask the login shell, so this runs off the main actor.
        let binary = fileOnly ? "troy" : MCPClients.defaultBinary()
        let found = MCPClients.guides(binary: binary).map { guide in
            Detected(
                guide: guide,
                installed: fileOnly ? looksInstalled(guide) : MCPClients.isInstalled(guide),
                connected: MCPClients.isConnected(guide))
        }
        return (binary, found)
    }

    /// File-based detection for render mode.
    nonisolated private static func looksInstalled(_ guide: MCPClientGuide) -> Bool {
        let files = FileManager.default
        if let app = guide.appPath, files.fileExists(atPath: app) { return true }
        if case .command(let argv) = guide.method, let tool = argv.first {
            let home = NSHomeDirectory()
            let folders = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            if folders.contains(where: { files.isExecutableFile(atPath: "\($0)/\(tool)") }) { return true }
        }
        let folder = ((guide.statusFile as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
        return folder != home && files.fileExists(atPath: folder)
    }

    nonisolated private static var home: String { NSHomeDirectory() }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? MCPClients.Failure)?.description ?? error.localizedDescription
    }

    func refresh() async {
        let fileOnly = fileOnly
        let result = await Task.detached { Self.detect(fileOnly: fileOnly) }.value
        binary = result.binary
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = result.rows.map { detected in
            var row = previous[detected.guide.id] ?? Row(guide: detected.guide)
            row.guide = detected.guide
            row.installed = detected.installed
            row.connected = detected.connected
            return row
        }
    }

    func toggle(_ id: String) async {
        guard !fileOnly, let index = rows.firstIndex(where: { $0.id == id }), !rows[index].isBusy else { return }
        let guide = rows[index].guide
        let connect = rows[index].connected != true
        let binary = binary
        rows[index].isBusy = true
        rows[index].message = nil
        let outcome: Message = await Task.detached {
            do {
                let text = connect ? try MCPClients.connect(guide, binary: binary) : try MCPClients.disconnect(guide)
                return Message(text: text, isError: false)
            } catch {
                return Message(text: Self.describe(error), isError: true)
            }
        }.value
        let connected = await Task.detached { MCPClients.isConnected(guide) }.value
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].isBusy = false
            rows[index].message = outcome
            rows[index].connected = connected
        }
    }

    func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.copied == key { self?.copied = nil }
        }
    }
}

private struct ConnectionsPane: View {
    let model: ConnectionsModel

    var body: some View {
        Form {
            Section {
                Text(L(
                    "Connecting adds Troy to an AI client's list of tools, so the agents you run there can read and save to your project memory. Everything stays on this Mac: Troy has no account and sends nothing over the network.",
                    ko: "연결하면 AI 클라이언트의 도구 목록에 Troy가 추가되어, 그 클라이언트의 에이전트가 프로젝트 기억을 읽고 남길 수 있습니다. 모든 데이터는 이 Mac에만 있으며 Troy는 계정도 네트워크 전송도 없습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("AI clients", ko: "AI 클라이언트")) {
                ForEach(model.rows) { row in
                    ClientRow(row: row, model: model)
                }
            }
            Section(L("For your projects", ko: "프로젝트에 추가")) {
                CopyRow(
                    title: L("Copy agent instructions", ko: "에이전트 지침 복사"),
                    detail: L("Paste into AGENTS.md or CLAUDE.md so agents know when to use Troy.", ko: "AGENTS.md나 CLAUDE.md에 붙여 넣으면 에이전트가 Troy를 쓸 때를 알게 됩니다."),
                    key: "instructions", model: model, text: AgentGuide.projectSnippet)
                CopyRow(
                    title: L("Copy session-start hook", ko: "세션 시작 훅 복사"),
                    detail: L("A Claude Code hook that prints the project's state before the agent's first turn.", ko: "에이전트의 첫 응답 전에 프로젝트 현황을 보여 주는 Claude Code 훅입니다."),
                    key: "hook", model: model, text: AgentGuide.sessionStartHook(binary: model.binary))
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

private struct ClientRow: View {
    let row: ConnectionsModel.Row
    let model: ConnectionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(row.guide.name)
                    .frame(width: 112, alignment: .leading)
                status
                Spacer(minLength: 8)
                Button {
                    model.copy(row.guide.manual, key: row.id)
                } label: {
                    Text(model.copied == row.id ? L("Copied", ko: "복사됨") : L("Copy command", ko: "명령 복사"))
                }
                .controlSize(.small)
                .help(L("Copy the command to connect \(row.guide.name) by hand", ko: "\(Josa.attach(row.guide.name, "을", "를")) 직접 연결하는 명령 복사"))
                Button {
                    Task { await model.toggle(row.id) }
                } label: {
                    if row.isBusy {
                        ProgressView().controlSize(.small).frame(width: 52)
                    } else {
                        Text(row.connected == true ? L("Disconnect", ko: "연결 해제") : L("Connect", ko: "연결"))
                            .frame(minWidth: 52)
                    }
                }
                .controlSize(.small)
                .disabled(row.isBusy || row.installed == nil || (row.installed == false && row.connected != true))
            }
            if let message = row.message {
                Label {
                    Text(message.text)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? Theme.danger : Theme.color(RecordStatus.done))
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        if row.installed == nil {
            Text(L("Checking…", ko: "확인 중…")).font(.caption).foregroundStyle(.secondary)
        } else if row.connected == true {
            Label(L("Connected", ko: "연결됨"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.color(RecordStatus.done))
        } else if row.installed == false {
            Label(L("Not installed", ko: "설치되지 않음"), systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if row.connected == nil {
            Label(L("Settings file could not be read", ko: "설정 파일을 읽을 수 없음"), systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(L("Not connected", ko: "연결되지 않음"), systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CopyRow: View {
    let title: String
    let detail: String
    let key: String
    let model: ConnectionsModel
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                model.copy(text, key: key)
            } label: {
                Label(model.copied == key ? L("Copied", ko: "복사됨") : L("Copy", ko: "복사"),
                      systemImage: model.copied == key ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 56)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Data

private struct DataPane: View {
    let model: AppModel
    @State private var exportProjectID: Int64??
    @State private var message: ConnectionsModel.Message?
    @State private var isAddingDemo = false

    private var scope: Int64? { exportProjectID ?? model.selectedProjectID }

    private var projectCount: Int { model.projects.count }
    private var recordCount: Int { model.projects.reduce(0) { $0 + $1.stats.records } }

    var body: some View {
        Form {
            Section(L("Database", ko: "데이터베이스")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.client.path)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button(L("Show in Finder", ko: "Finder에서 보기")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.client.path)])
                        }
                        Button(L("Back Up…", ko: "백업…")) { Task { await backUp() } }
                    }
                    .controlSize(.small)
                    Text(L(
                        "Back Up writes one complete file, also while agents are working. A copy of the database file made by hand can miss the latest records.",
                        ko: "백업은 에이전트가 작업 중이어도 전체를 파일 하나로 만듭니다. 데이터베이스 파일을 직접 복사하면 최근 기록이 빠질 수 있습니다."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                LabeledContent(L("Projects", ko: "프로젝트"), value: "\(projectCount)")
                LabeledContent(L("Records", ko: "기록"), value: "\(recordCount)")
            }
            Section(L("Export", ko: "내보내기")) {
                HStack {
                    Picker(L("Project", ko: "프로젝트"), selection: Binding<Int64?>(
                        get: { scope }, set: { exportProjectID = .some($0) })
                    ) {
                        Text(L("All projects", ko: "모든 프로젝트")).tag(Int64?.none)
                        ForEach(model.projects) { Text($0.project.name).tag(Int64?.some($0.id)) }
                    }
                    Button(L("Export Markdown…", ko: "Markdown 내보내기…")) { Task { await export() } }
                        .controlSize(.small)
                        .disabled(model.projects.isEmpty)
                }
                Text(L("One Markdown file with every record and its links.", ko: "모든 기록과 연결을 담은 Markdown 파일 하나를 만듭니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("Examples", ko: "예시")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Add example project", ko: "예시 프로젝트 추가"))
                        Text(L("A small project that shows every kind of record. Delete it any time.", ko: "모든 종류의 기록을 보여 주는 작은 프로젝트입니다. 언제든 지울 수 있습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(L("Add", ko: "추가")) { Task { await addDemo() } }
                        .controlSize(.small)
                        .disabled(isAddingDemo)
                }
                if let message {
                    Label {
                        Text(message.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(message.isError ? Theme.danger : Theme.color(RecordStatus.done))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.viewAppeared() }
        .onDisappear { model.viewDisappeared() }
    }

    private func export() async {
        let projectID = scope
        guard let text = await model.exportMarkdown(projectID: projectID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let name = model.projects.first { $0.id == projectID }?.project.name ?? "Troy"
        panel.nameFieldStringValue = "\(name).md"
        panel.title = L("Export Markdown", ko: "Markdown 내보내기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            message = .init(text: L("Saved \(url.lastPathComponent).", ko: "\(Josa.attach(url.lastPathComponent, "을", "를")) 저장했습니다."), isError: false)
        } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func backUp() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.canCreateDirectories = true
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        panel.nameFieldStringValue = "Troy \(day).db"
        panel.title = L("Back Up Database", ko: "데이터베이스 백업")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        // Replace only what the panel asked about: a file that was there when it was chosen.
        // A name that was free and has been taken since is refused, not overwritten.
        let replacing = FileManager.default.fileExists(atPath: path)
        do {
            try await model.client.run { try $0.backup(to: path, replacing: replacing) }
            message = .init(text: L("Saved \(url.lastPathComponent).", ko: "\(Josa.attach(url.lastPathComponent, "을", "를")) 저장했습니다."), isError: false)
        } catch {
            message = .init(text: (error as? TroyError)?.message ?? error.localizedDescription, isError: true)
        }
    }

    private func addDemo() async {
        isAddingDemo = true
        defer { isAddingDemo = false }
        let language: DemoData.Language = Localization.usesKorean ? .korean : .english
        do {
            let project = try await model.client.run { try DemoData.seed(into: $0, language: language) }
            await model.refresh()
            model.selectedProjectID = project.id
            message = .init(text: L("Added “\(project.name)” and selected it.", ko: "\(Josa.attach("“\(project.name)”", "을", "를")) 추가하고 선택했습니다."), isError: false)
        } catch {
            message = .init(text: (error as? TroyError)?.message ?? error.localizedDescription, isError: true)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The app icon, or a stand-in when running the bare executable, which has none.
    @ViewBuilder private var icon: some View {
        if Bundle.main.bundleURL.pathExtension == "app" {
            Image(nsImage: NSApp.applicationIconImage).resizable()
        } else {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.accentColor)
                .overlay {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            icon
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("Troy").font(.title.weight(.semibold))
            Text(L("Version \(version)", ko: "버전 \(version)"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L(
                "Troy is a project memory for the AI agents you work with: tasks, decisions and notes they save as they go, kept in one file on this Mac.",
                ko: "Troy는 함께 일하는 AI 에이전트를 위한 프로젝트 기억입니다. 에이전트가 작업하며 남기는 할 일, 결정, 메모를 이 Mac의 파일 하나에 모아 둡니다."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
                .padding(.top, 6)
            Text(L("MIT License", ko: "MIT 라이선스"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
