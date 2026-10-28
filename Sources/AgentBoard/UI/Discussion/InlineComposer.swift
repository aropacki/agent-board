import AppKit
import SwiftUI

/// The first line of a comment as a quote, so a PR comment reads as a reply to it.
func quoteOpening(_ body: String) -> String {
    let first = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    guard !first.isEmpty else { return "" }
    return "> " + (first.count > 140 ? String(first.prefix(139)) + "…" : first) + "\n\n"
}

/// A reply field in the thread it answers. It starts as one line and grows as you type.
/// Return sends, ⌥Return adds a line, and ⌘Return also resolves the thread when `resolves` is set.
struct InlineComposer: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Binding var text: String
    let placeholder: String
    var resolves = false
    /// Changing it puts the cursor in the field, as Quote does.
    var focusToken = 0
    let send: (_ body: String, _ resolve: Bool, _ done: @escaping (Bool) -> Void) -> Void
    @State private var active = false
    @State private var sending: Bool? = nil
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let live = active || !text.isEmpty
        VStack(alignment: .leading, spacing: z(4)) {
            HStack(alignment: .bottom, spacing: z(4)) {
                Group {
                    if live {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...8)
                            .focused($focused)
                            .onSubmit { submit(resolve: false) }
                            .disabled(sending != nil)
                    } else {
                        Text(placeholder).foregroundStyle(T.text3)
                    }
                }
                .font(ui(12)).foregroundStyle(T.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, z(6))
                if !empty || sending != nil {
                    if resolves { sendButton(resolve: true) }
                    sendButton(resolve: false)
                }
            }
            .padding(.leading, z(10)).padding(.trailing, z(4))
            .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(T.text.opacity(focused ? 0.08 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: z(8), style: .continuous))
            .simultaneousGesture(TapGesture().onEnded { activate() }, including: live ? .none : .all)
            .pointerStyle(live ? nil : .link)
            if focused {
                Text(resolves ? "↩ sends · ⌘↩ sends and resolves · ⌥↩ new line" : "↩ sends · ⌥↩ new line")
                    .font(ui(11.5)).foregroundStyle(T.text3).padding(.leading, z(10))
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: focused)
        .onChange(of: focusToken) { activate() }
        .onChange(of: focused) { if !focused && text.isEmpty { active = false } }
    }

    func sendButton(resolve: Bool) -> some View {
        Button { submit(resolve: resolve) } label: {
            ZStack {
                if sending == resolve {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: resolve ? "checkmark" : "arrow.up").font(.system(size: z(10), weight: .bold))
                }
            }
            .foregroundStyle(resolve ? T.text2 : Color.white)
            .frame(width: z(22), height: z(20))
            .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(resolve ? T.text.opacity(0.08) : T.blue))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .pointerStyle(.link)
        .disabled(sending != nil)
        .keyboardShortcut(resolve && focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .help(resolve ? "Send and resolve the thread (⌘↩)" : "Send (↩)")
        .padding(.bottom, z(4))
    }

    func activate() {
        active = true
        DispatchQueue.main.async { focused = true }
    }

    func submit(resolve: Bool) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, sending == nil else { return }
        sending = resolve
        send(body, resolve) { ok in
            sending = nil
            if ok {
                focused = false
                active = false
            }
        }
    }
}

/// The actions that are buttons on a row, in the user's order.
struct QuickActionChips: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let context: ActionContext
    let items: [ActionItem]

    var body: some View {
        FlowLayout(spacing: z(20)) {
            ForEach(items) { item in
                ActionChip(title: item.action.title, key: board.actionKey(item.action, context)) {
                    board.run(item.action, context, targets: item.targets)
                }
            }
        }
    }
}

/// An on/off choice drawn as a chip.
struct ToggleChip: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    var icon: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: z(4)) {
                if let icon { Image(systemName: icon).font(.system(size: z(9.5), weight: .medium)) }
                Text(title).font(ui(11.5))
            }
            .foregroundStyle(on ? T.text : T.text3)
        }
        .buttonStyle(HoverButtonStyle(padH: z(7), padV: z(3), rest: on ? 0.1 : 0.03, hover: on ? 0.12 : 0.06, press: 0.14)).pointerOnly()
    }
}
