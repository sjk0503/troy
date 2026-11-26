import Foundation

/// A small, believable project for trying Troy out: `troy demo` adds it, and the app's
/// screenshots are rendered from it. It exercises every feature once: sub-tasks, a blocked
/// task, two agents whose work overlaps, a superseded decision and a pair of conflicting ones.
public enum DemoData {
    public enum Language: Sendable { case english, korean }

    /// The name the demo project gets in the given language.
    public static func projectName(_ language: Language) -> String {
        language == .korean ? "망고 노트 (예시)" : "Mango Notes (demo)"
    }

    /// Adds the demo project and returns it. Calling it again returns the project that is already there.
    @discardableResult
    public static func seed(into store: Store, language: Language = .english) throws -> Project {
        let name = projectName(language)
        if let existing = try? store.resolveProject(reference: name, directory: nil) { return existing }

        func t(_ english: String, _ korean: String) -> String { language == .korean ? korean : english }
        let original = store.agent
        defer { store.agent = original }

        let project = try store.createProject(
            name: name,
            summary: t(
                "A note-taking app getting an offline mode. Example data: edit or delete it freely.",
                "오프라인 모드를 만드는 노트 앱. 예시 데이터이니 자유롭게 고치거나 지우세요."))
        let projectID = project.id

        func add(
            _ kind: RecordKind, _ title: String, _ body: String = "", tags: [String] = [], paths: [String] = [],
            status: RecordStatus = .open, by agent: String = "claude-code/a3f", parent: Int64? = nil, links: [LinkDraft] = []
        ) throws -> Int64 {
            store.agent = agent
            let draft = RecordDraft(
                projectID: projectID, kind: kind, title: title, body: body, tags: tags, paths: paths,
                status: status, parent: parent, links: links)
            return try store.create(draft).record.id
        }

        let offline = try add(
            .task, t("Ship offline mode", "오프라인 모드 출시"),
            t("Notes must stay editable with no network and sync when it returns.\n\nDone when a note edited on a plane shows up on the laptop after landing, with nothing lost.",
              "네트워크가 없어도 노트를 고칠 수 있고, 연결되면 동기화되어야 한다.\n\n완료 조건: 비행기에서 고친 노트가 착륙 뒤 노트북에 빠짐없이 나타난다."),
            tags: ["offline", "v2"])

        let benchmark = try add(
            .note, t("Benchmark: SQLite against one file per note", "벤치마크: SQLite 대 노트별 파일"),
            t("10,000 notes on an iPhone 13.\n\n| | open app | search |\n|---|---|---|\n| SQLite (WAL) | 180 ms | 12 ms |\n| JSON files | 2.4 s | 900 ms |",
              "iPhone 13, 노트 10,000개.\n\n| | 앱 열기 | 검색 |\n|---|---|---|\n| SQLite (WAL) | 180 ms | 12 ms |\n| JSON 파일 | 2.4초 | 900 ms |"),
            tags: ["storage", "benchmark"], by: "codex/7c1")

        let jsonFiles = try add(
            .decision, t("Store each note as a JSON file", "노트마다 JSON 파일로 저장"),
            t("Simple to inspect and to back up.", "들여다보기 쉽고 백업도 쉽다."),
            tags: ["storage"], by: "app")

        let sqlite = try add(
            .decision, t("Use SQLite with WAL for local storage", "로컬 저장소는 SQLite WAL 사용"),
            t("One file, atomic writes, and full-text search for free. The benchmark settled it: opening the app is 13 times faster.",
              "파일 하나, 원자적 쓰기, 전문 검색까지 덤으로 얻는다. 벤치마크가 결론을 냈다: 앱 열기가 13배 빠르다."),
            tags: ["storage"],
            links: [LinkDraft(to: benchmark, relation: .derivedFrom), LinkDraft(to: jsonFiles, relation: .supersedes, note: t("too slow at 10,000 notes", "노트 10,000개에서 너무 느림"))])

        let pickDatabase = try add(
            .task, t("Pick the local database", "로컬 데이터베이스 선정"),
            t("Outcome: SQLite with WAL. See the decision and the benchmark.", "결과: SQLite WAL. 결정과 벤치마크 참고."),
            tags: ["storage"], status: .done, by: "codex/7c1", parent: offline,
            links: [LinkDraft(to: sqlite, relation: .relatesTo)])

        let sync = try add(
            .task, t("Local-first sync engine", "로컬 우선 동기화 엔진"),
            t("Every device writes to its own database first and exchanges changes later.\n\n- [x] change log table\n- [ ] push and pull\n- [ ] retry with backoff",
              "기기마다 자기 데이터베이스에 먼저 쓰고 변경분을 나중에 주고받는다.\n\n- [x] 변경 기록 테이블\n- [ ] 올리기와 내려받기\n- [ ] 간격을 늘려 가며 재시도"),
            tags: ["sync"], paths: ["App/Sync"], status: .doing, by: "claude-code/a3f", parent: offline,
            links: [LinkDraft(to: pickDatabase, relation: .dependsOn)])

        let fieldWins = try add(
            .decision, t("Last writer wins per field, not per note", "노트 단위가 아니라 필드 단위로 마지막 쓰기 우선"),
            t("Two devices changing different fields of one note must both keep their change.",
              "두 기기가 한 노트의 서로 다른 필드를 고쳤다면 둘 다 살아남아야 한다."),
            tags: ["sync", "conflicts"])

        let askUser = try add(
            .decision, t("Keep both versions and ask the user", "두 버전을 모두 남기고 사용자에게 묻기"),
            t("Never drop text silently; show a merge sheet.", "글을 말없이 버리지 않는다. 병합 화면을 띄운다."),
            tags: ["sync", "conflicts"], by: "codex/7c1",
            links: [LinkDraft(to: fieldWins, relation: .conflictsWith, note: t("pick one before the resolver is written", "충돌 해결기를 쓰기 전에 하나로 정해야 함"))])

        let observation = try add(
            .note, t("People edit the same note on phone and laptop within minutes", "사용자는 몇 분 간격으로 휴대폰과 노트북에서 같은 노트를 고친다"),
            t("From 12 support threads in October. Conflicts are the normal case, not an edge case.",
              "10월 고객 문의 12건에서 확인. 충돌은 예외가 아니라 일상이다."),
            tags: ["research"], by: "app", links: [LinkDraft(to: fieldWins, relation: .relatesTo)])

        let resolver = try add(
            .task, t("Resolve edits made offline on two devices", "두 기기에서 오프라인으로 고친 내용 병합"),
            t("Needs the change log from the sync engine.", "동기화 엔진의 변경 기록이 필요하다."),
            tags: ["sync", "conflicts"], paths: ["App/Sync/ConflictResolver.swift"], status: .doing, by: "codex/7c1",
            parent: offline,
            links: [LinkDraft(to: sync, relation: .dependsOn), LinkDraft(to: askUser, relation: .derivedFrom), LinkDraft(to: observation, relation: .relatesTo)])

        _ = try add(
            .task, t("Queue writes while offline", "오프라인 중 쓰기 대기열"),
            tags: ["sync"], paths: ["App/Sync/WriteQueue.swift"], parent: offline,
            links: [LinkDraft(to: sync, relation: .dependsOn)])

        _ = try add(
            .task, t("Offline indicator in the toolbar", "툴바에 오프라인 표시"),
            t("A small cloud with a slash; tapping it explains what will sync.", "빗금 친 작은 구름. 누르면 무엇이 동기화될지 알려 준다."),
            tags: ["ui"], paths: ["App/Toolbar"], parent: offline)

        _ = try add(
            .result, t("Sync protocol draft v1", "동기화 프로토콜 초안 v1"),
            t("```\nPUSH  since=<cursor>  changes=[…]\nPULL  since=<cursor>  -> changes, cursor\n```\nOpen question: how long does the server keep tombstones?",
              "```\nPUSH  since=<cursor>  changes=[…]\nPULL  since=<cursor>  -> changes, cursor\n```\n남은 질문: 서버는 삭제 표식을 얼마나 오래 보관하는가?"),
            tags: ["sync"], links: [LinkDraft(to: sync, relation: .derivedFrom)])

        let search = try add(
            .task, t("Search across all notes", "노트 전체 검색"), tags: ["search"])

        let fts = try add(
            .task, t("Index note bodies with FTS5", "FTS5로 노트 본문 색인"),
            tags: ["search", "storage"], paths: ["App/Search"], parent: search,
            links: [LinkDraft(to: pickDatabase, relation: .dependsOn)])

        _ = try add(
            .note, t("The trigram index misses two-character Korean words", "trigram 색인은 두 글자 한글 낱말을 놓친다"),
            t("결제, 검색 and 토큰 are all two characters. Fall back to LIKE for short terms.",
              "결제, 검색, 토큰은 모두 두 글자다. 짧은 검색어는 LIKE로 처리한다."),
            tags: ["search"], by: "codex/7c1", links: [LinkDraft(to: fts, relation: .relatesTo)])

        _ = try add(
            .prompt, t("Review a sync change for data loss", "동기화 변경의 데이터 손실 점검"),
            t("Read the diff and list every path where a write made on one device can be lost or applied twice. For each, name the test that would catch it.",
              "변경 내용을 읽고, 한 기기의 쓰기가 사라지거나 두 번 적용될 수 있는 경로를 모두 적어 줘. 경로마다 그것을 잡아낼 테스트를 알려 줘."),
            tags: ["review"], by: "app", links: [LinkDraft(to: resolver, relation: .relatesTo)])

        _ = try add(
            .task, t("Sync through iCloud Drive", "iCloud Drive로 동기화"),
            t("Dropped: no way to merge two edits of the same file.", "중단: 같은 파일을 두 번 고친 것을 합칠 방법이 없다."),
            tags: ["sync"], status: .dropped, by: "app", links: [LinkDraft(to: sync, relation: .relatesTo)])

        _ = try add(
            .task, t("Set up CI", "CI 구성"),
            t("Outcome: build and tests run on every push.", "결과: 푸시할 때마다 빌드와 테스트가 돈다."),
            tags: ["infra"], status: .done, by: "codex/7c1")

        return try store.project(id: projectID)
    }
}
