import SwiftUI
import TroyCore
import TroyUI

/// The always-visible "How to use Troy" button and the small reading popover it opens.
struct UsageHelpButton: View {
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Label(L("How to use", ko: "사용법"), systemImage: "questionmark.circle")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .help(L("How to use Troy", ko: "Troy 사용법"))
        .accessibilityLabel(L("How to use Troy", ko: "Troy 사용법"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            UsageHelpView { isShown = false }
        }
    }
}

/// Short, readable guidance. Steps are numbered because their order matters.
struct UsageHelpView: View {
    @Environment(\.appActions) private var appActions
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("How to use Troy", ko: "Troy 사용법"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                step(1, L(
                    "In Settings > Connections, link your AI client, then start a new session in it.",
                    ko: "설정 > 연결에서 AI 클라이언트를 연결한 뒤, 클라이언트에서 새 세션을 시작하세요."))
                step(2, L(
                    "Ask the AI to save decisions and results. The first save in a git repository creates its project.",
                    ko: "AI에게 결정과 결과를 저장해 달라고 요청하세요. git 저장소에서 처음 저장하면 프로젝트가 만들어집니다."))
                step(3, L(
                    "In the overview, see what to do next and what is blocked. In a record's local graph, follow what it depends on, and paste the session brief into a new AI session.",
                    ko: "작업 개요에서 다음 할 일과 막힌 이유를 확인하세요. 기록의 로컬 그래프에서 선행 작업을 따라가고, 새 AI 세션에는 인계 메모를 붙여 넣으세요."))
            }

            Text(L(
                "Searching, filtering and selecting only change what you see. When you edit a record, change its status, or update its links, your AI client can see those changes.",
                ko: "검색·필터·선택은 보이는 화면만 바꿉니다. 상태를 바꾸거나 기록과 연결을 편집하면 AI도 그 변경을 볼 수 있습니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    dismiss()
                    appActions.showConnections()
                } label: {
                    Label(L("Connect an AI client", ko: "AI 클라이언트 연결"), systemImage: "link")
                }
                Button {
                    dismiss()
                    appActions.openGuide()
                } label: {
                    Label(L("User guide PDF (Korean)", ko: "사용 가이드 PDF (한국어)"), systemImage: "doc.richtext")
                }
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Step \(number): \(text)", ko: "\(number)단계: \(text)"))
    }
}
