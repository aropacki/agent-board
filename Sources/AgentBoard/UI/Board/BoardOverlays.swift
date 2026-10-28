import AppKit
import SwiftUI

/// Toast, selection, cleanup confirmation, and the dropdown, shared by the panel and the full window.
struct BoardOverlays: ViewModifier {
    var barWidth: CGFloat? = nil
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: z(6)) {
                    toastView
                    if board.pendingAction != nil { confirmBar } else { selectionBar }
                }
            }
            .overlay { menuLayer }
            .overlay { peekLayer }
    }

    var peekLayer: some View {
        GeometryReader { geo in
            if let peek = board.checksPeek, peek.surface == surface, board.menu == nil {
                let bounds = geo.frame(in: .global)
                let checks = board.checks[peek.key]
                let size = ChecksPeekList.size(checks)
                let origin = Dropdown.origin(anchor: peek.anchor, size: size, bounds: bounds)
                let placed = CGPoint(x: origin.x - bounds.minX, y: origin.y - bounds.minY)
                ChecksPeekList(pr: board.pr(key: peek.key), checks: checks, error: board.checksErrors[peek.key])
                    .padding(.leading, placed.x).padding(.top, placed.y)
                    .transition(.pop(from: Dropdown.placed(Dropdown.growth(anchor: peek.anchor, origin: origin, size: size),
                                                           at: placed, size: size)))
                    .id(peek.key)
            }
        }
    }

    var menuLayer: some View {
        GeometryReader { geo in
            if let menu = board.menu, menu.surface == surface {
                let bounds = geo.frame(in: .global)
                let size = Dropdown.size(menu.actions)
                let origin = Dropdown.origin(anchor: menu.anchor, size: size, bounds: bounds)
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { board.closeMenu() }
                let placed = CGPoint(x: origin.x - bounds.minX, y: origin.y - bounds.minY)
                DropdownMenu(menu: menu)
                    .padding(.leading, placed.x).padding(.top, placed.y)
                    .transition(.pop(from: Dropdown.placed(Dropdown.growth(anchor: menu.anchor, origin: origin, size: size),
                                                           at: placed, size: size)))
                    .id(menu.id)
            }
        }
    }

    @ViewBuilder var selectionBar: some View {
        let picked = board.selectedPRs
        if !picked.isEmpty {
            let ctx = board.selectionContext
            let items = board.applicable(on: ctx, buttons: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: z(4)) {
                    selectionCount(picked.count)
                    Spacer(minLength: z(4))
                    HStack(spacing: z(20)) { selectionChips(picked, ctx, items) }.padding(.horizontal, z(7))
                    clearSelectionButton
                }
                VStack(alignment: .leading, spacing: z(6)) {
                    HStack(spacing: z(4)) {
                        selectionCount(picked.count)
                        Spacer(minLength: z(4))
                        clearSelectionButton
                    }
                    FlowLayout(spacing: z(20)) { selectionChips(picked, ctx, items) }.padding(.horizontal, z(11))
                }
            }
            .padding(z(6))
            .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T.rowRadius + 2, style: .continuous).strokeBorder(T.border))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .frame(maxWidth: barWidth)
            .padding(.horizontal, z(8)).padding(.bottom, z(8))
            .transition(.slide(.bottom))
        }
    }

    func selectionCount(_ n: Int) -> some View {
        Text("\(n) selected").font(T.ui(12, .medium)).foregroundStyle(T.text)
            .contentTransition(.numericText())
            .padding(.leading, z(4))
    }

    @ViewBuilder func selectionChips(_ picked: [PR], _ ctx: ActionContext, _ items: [ActionItem]) -> some View {
        ForEach(items) { item in
            ActionChip(title: item.action.title, key: board.actionKey(item.action, ctx)) {
                board.run(item.action, ctx, targets: item.targets)
            }
        }
        if picked.count > 1 {
            ActionChip(title: "Tab group", key: "group-selected") {
                board.openTabGroup(reviewOrder(picked), title: "\(picked.count) PRs")
            }
            .help("Open as one Chrome tab group. ⌘-click keeps Chrome behind")
        }
        ActionChip(title: "Copy", key: "copy-selected") { board.copyLinks(reviewOrder(picked)) }
            .help("Copy each PR's link and title, one per line")
        ActionChip(title: "Hide", key: "hide-selected") { board.hide(picked) }
    }

    var clearSelectionButton: some View {
        Button { board.clearSelection() } label: {
            Image(systemName: "xmark").font(.system(size: z(10.5), weight: .semibold)).foregroundStyle(T.text2)
                .frame(width: z(16), height: z(16))
        }
        .buttonStyle(HoverButtonStyle.icon).pointerOnly()
        .help("Clear selection")
    }

    @ViewBuilder var confirmBar: some View {
        if let p = board.pendingAction {
            VStack(alignment: .leading, spacing: z(6)) {
                Text(p.question).font(T.ui(12, .medium)).foregroundStyle(T.text)
                Text(p.preview)
                    .font(T.ui(11.5)).foregroundStyle(T.text2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = p.hiddenNote { Text(note).font(T.ui(11.5)).foregroundStyle(T.text3) }
                HStack(spacing: z(20)) {
                    Spacer()
                    ActionChip(title: "Cancel", color: T.text3, key: "cancel-action") { board.cancelAction() }
                    ActionChip(title: p.action.title, color: T.text, key: board.actionKey(p.action, p.context)) { board.confirmAction() }
                }
                .padding(.trailing, z(7))
            }
            .padding(z(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T.rowRadius + 2, style: .continuous).strokeBorder(T.border))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .frame(maxWidth: barWidth)
            .padding(.horizontal, z(8)).padding(.bottom, z(8))
            .transition(.slide(.bottom))
        }
    }

    @ViewBuilder var toastView: some View {
        if let toast = board.toast {
            HStack(spacing: z(8)) {
                Image(systemName: toast.kind == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: z(11)))
                    .foregroundStyle(toast.kind == .ok ? T.green : T.orange)
                Text(toast.text).font(T.ui(12)).foregroundStyle(T.text).lineLimit(3)
            }
            .padding(.horizontal, z(12)).padding(.vertical, z(8))
            .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous).strokeBorder(T.border))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .frame(maxWidth: barWidth)
            .padding(.horizontal, z(12)).padding(.bottom, z(12))
            .transition(.slide(.bottom))
            .id(toast.id)
        }
    }
}
