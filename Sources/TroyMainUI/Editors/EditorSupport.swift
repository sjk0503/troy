import SwiftUI
import TroyCore
import TroyUI

// Pieces the four editor sheets share: the sheet frame, grouped sections with aligned labels,
// the error line, a limit counter, a chip picker and a wrapping layout for tags.

/// Width of the label column in every editor, so labels line up across sections.
let editorLabelWidth: CGFloat = 84

/// Title, scrolling content, optional error, and the Cancel / action buttons in the usual places.
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var error: String?
    let confirmTitle: String
    let canConfirm: Bool
    var isWorking = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            content

            VStack(spacing: 10) {
                if let error { ErrorLine(text: error) }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(L("Cancel", ko: "취소"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(action: onConfirm) {
                        HStack(spacing: 6) {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(confirmTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canConfirm || isWorking)
                    .help("\(confirmTitle)  ⌘↩")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(alignment: .top) { Divider() }
        }
        .interactiveDismissDisabled()
    }
}

/// A failure shown inside the sheet that caused it.
struct ErrorLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A rounded group of rows, like a section of a grouped form.
struct EditorGroup<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// A label in the aligned column and its control. `top` aligns the label with the first line of tall controls.
struct FieldRow<Content: View>: View {
    let label: String
    var top = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: top ? .firstTextBaseline : .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: editorLabelWidth, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "182 / 240", shown only when a field is close to its limit.
struct LimitCounter: View {
    let count: Int
    let limit: Int

    var body: some View {
        if Double(count) >= Double(limit) * 0.8 {
            Text("\(count) / \(limit)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(count > limit ? Theme.danger : Color.secondary)
        }
    }
}

/// A caption under a control.
struct FieldCaption: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Theme.danger : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of labeled choices with an icon each, for kinds and statuses.
struct OptionBar<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let name: String
        let symbol: String
        let tint: Color
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(option.tint)
                        Text(option.name)
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        selected ? option.tint.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? option.tint.opacity(0.5) : Color.primary.opacity(0.10)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width, width.isFinite { size.width = width }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), frames)
    }
}

/// A multi-line text box that looks like a field: used for the body, paths and summary.
struct TextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 80
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.callout, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}

/// A small icon button with an accessibility label.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
