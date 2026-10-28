import AppKit
import SwiftUI

enum Dropdown {
    static let width: CGFloat = z(224)
    static let rowHeight: CGFloat = z(26)
    static let dividerHeight: CGFloat = z(9)
    static let pad: CGFloat = z(4)

    static func size(_ actions: [MenuAction]) -> CGSize {
        CGSize(width: width, height: pad * 2 + CGFloat(actions.count) * rowHeight + CGFloat(actions.filter(\.divider).count) * dividerHeight)
    }

    /// Below the anchor, flipped above when it would run off the bottom, always inside the bounds.
    static func origin(anchor: CGRect, size: CGSize, bounds: CGRect, margin: CGFloat = 8) -> CGPoint {
        let fromPoint = anchor.width == 0 && anchor.height == 0
        var x = fromPoint ? anchor.minX : anchor.maxX - size.width
        var y = anchor.maxY + (fromPoint ? 2 : 4)
        if y + size.height > bounds.maxY - margin { y = anchor.minY - size.height - (fromPoint ? 2 : 4) }
        x = min(max(x, bounds.minX + margin), bounds.maxX - margin - size.width)
        y = min(max(y, bounds.minY + margin), bounds.maxY - margin - size.height)
        return CGPoint(x: x, y: y)
    }

    /// The point of a dropdown placed at `origin` nearest its anchor, in the dropdown's own unit space.
    static func growth(anchor: CGRect, origin: CGPoint, size: CGSize) -> UnitPoint {
        let x = size.width > 0 ? min(max((anchor.midX - origin.x) / size.width, 0), 1) : 0.5
        return UnitPoint(x: x, y: origin.y >= anchor.midY ? 0 : 1)
    }

    /// `unit` of a dropdown padded out to `at` inside its layer, in the unit space of the padded frame.
    /// A transition scales the whole placed view, padding included.
    static func placed(_ unit: UnitPoint, at: CGPoint, size: CGSize) -> UnitPoint {
        let w = at.x + size.width, h = at.y + size.height
        return UnitPoint(x: w > 0 ? (at.x + unit.x * size.width) / w : 0.5,
                         y: h > 0 ? (at.y + unit.y * size.height) / h : 0.5)
    }
}

/// The ⋯ button. It opens the board's own dropdown, drawn inside the panel.
struct MoreButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    let owner: String
    var size: CGSize? = nil
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        let open = board.menuOpen(owner, surface)
        Button { board.toggleMenu(owner: owner, anchor: frame, surface: surface) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: z(11), weight: .semibold))
                .foregroundStyle(open || hovering ? T.text : T.text2)
                .frame(width: (size ?? CGSize(width: z(22), height: z(17))).width,
                       height: (size ?? CGSize(width: z(22), height: z(17))).height)
                .background(T.control.fill(T.text.opacity(open ? 0.1 : hovering ? 0.06 : 0)))
                .contentShape(T.control)
        }
        .buttonStyle(.plain).pointerOnly()
        .trackHover { hovering = $0 }
        .pointerStyle(.link)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .help("More actions")
    }
}

/// Registers a row for right-click. One event monitor reads these frames.
struct MenuTarget: ViewModifier {
    let owner: String
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    @Environment(\.menuViewport) private var viewport
    @State private var token = UUID()
    @State private var last = LastFrame()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                last.frame = $0
                board.menuTargets[token] = (surface, owner, $0, "\(surface)|\(viewport)")
            }
            .onAppear { if let f = last.frame { board.menuTargets[token] = (surface, owner, f, "\(surface)|\(viewport)") } }
            .onDisappear { board.menuTargets[token] = nil }
    }
}

/// A view's frame as of its last move. A view that comes back unmoved, as when the popup shows its view tree
/// again, reports no geometry change, so it registers from here.
final class LastFrame { var frame: CGRect? }

/// A scroll area rows can be right-clicked in. Rows scrolled under a header stay out of reach.
struct MenuViewport: ViewModifier {
    let name: String
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    @State private var last = LastFrame()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                last.frame = $0
                board.menuViewports["\(surface)|\(name)"] = (surface, $0)
            }
            .onAppear { if let f = last.frame { board.menuViewports["\(surface)|\(name)"] = (surface, f) } }
            .onDisappear { board.menuViewports["\(surface)|\(name)"] = nil }
            .environment(\.menuViewport, name)
    }
}

struct HoldsRefreshWhileScrolling: ViewModifier {
    @Environment(Board.self) private var board
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in board.scrollMoved(token, moving: phase != .idle) }
            .onDisappear { board.scrollMoved(token, moving: false) }
    }
}

extension View {
    func menuTarget(_ owner: String) -> some View { modifier(MenuTarget(owner: owner)) }
    func menuViewport(_ name: String) -> some View { modifier(MenuViewport(name: name)) }
    func holdsRefreshWhileScrolling() -> some View { modifier(HoldsRefreshWhileScrolling()) }
}

struct DropdownRow: View {
    let action: MenuAction
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: z(8)) {
            Image(systemName: action.icon).font(.system(size: z(11), weight: .regular)).frame(width: z(15))
                .foregroundStyle(action.destructive ? T.red : T.text2)
            Text(action.title).font(T.ui(12)).lineLimit(1)
                .foregroundStyle(action.destructive ? T.red : T.text)
            Spacer(minLength: z(0))
            if let shortcut = action.shortcut { Text(shortcut).font(T.ui(11.5)).foregroundStyle(T.text3) }
        }
        .padding(.horizontal, z(8))
        .frame(height: Dropdown.rowHeight)
        .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(hovering ? T.text.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: run)
        .trackHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

struct DropdownMenu: View {
    let menu: RowMenu
    @Environment(Board.self) private var board

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(menu.actions) { action in
                if action.divider {
                    Rectangle().fill(T.border).frame(height: 1)
                        .padding(.vertical, (Dropdown.dividerHeight - 1) / 2).padding(.horizontal, z(4))
                }
                DropdownRow(action: action) {
                    board.closeMenu()
                    action.run()
                }
            }
        }
        .padding(Dropdown.pad)
        .frame(width: Dropdown.width)
        .background(Color(hex: 0x262626), in: RoundedRectangle(cornerRadius: z(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(9), style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}

/// Every button is the same shape: a rounded rect whose fill steps up on hover and press.
extension View {
    /// Keeps a button out of the key-view loop and drops its focus ring. Each focusable view that
    /// appears or disappears makes the hosting view rebuild that loop over the whole tree, and each
    /// focus ring is a hidden NSView that every display-list update repositions.
    func pointerOnly() -> some View { focusable(false).focusEffectDisabled() }
}
