import AppKit
import SwiftUI

/// A faint line that fades out at both ends, drawn under a row to keep neighbors apart.
struct Separator: View, Zoomed {
    @Environment(\.zoom) var zoom
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: T.separator, location: 0.12),
                               .init(color: T.separator, location: 0.88), .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .offset(y: z(1.5))
            .allowsHitTesting(false)
    }
}

/// Flat row: no fill at rest, a faint fill on hover.
/// `resting` draws a faint line under a top-level row so neighbors stay apart without hovering.
struct RowSurface: ViewModifier, Zoomed {
    @Environment(\.zoom) var zoom
    var interactive = true
    var radius = T.rowRadius
    var resting = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.rowHovered, hovering)
            .background(shape.fill(hovering ? T.hover : .clear).animation(Motion.fill(hovering: hovering), value: hovering))
            .overlay(alignment: .bottom) { if resting { Separator() } }
            .contentShape(shape)
            .trackHover { hovering = interactive && $0 }
    }
}

/// Hover read from every pointer move, not only from enter and exit. A quick move off and back on can
/// drop one of those edges, and an edge-only hover then stays wrong until the pointer leaves; here the next
/// move corrects it. `action` still runs only when the state changes.
struct TrackHover: ViewModifier {
    let action: (Bool) -> Void
    @State private var inside = false

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            let now: Bool
            switch phase {
            case .active: now = true
            case .ended: now = false
            }
            guard now != inside else { return }
            inside = now
            action(now)
        }
    }
}

extension View {
    func trackHover(_ action: @escaping (Bool) -> Void) -> some View { modifier(TrackHover(action: action)) }
}

struct RowHoveredKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by the nearest row surface. Read it in a small subview: a row that reads it re-renders whole on every hover.
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

/// A row's top-right corner: busy, done, the ⋯ button while hovered or open, otherwise the age.
struct RowCorner: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(\.rowHovered) private var hovered
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    let owner: String
    var busyKey: String? = nil
    let time: Double?
    var help: String? = nil

    var body: some View {
        ZStack(alignment: .trailing) {
            if let busyKey, board.busy.contains(busyKey) {
                ProgressView().controlSize(.mini)
            } else if let busyKey, board.succeeded.contains(busyKey) {
                Image(systemName: "checkmark").font(.system(size: z(10), weight: .bold)).foregroundStyle(T.green)
            } else if hovered || board.menuOpen(owner, surface) {
                MoreButton(owner: owner)
            } else if let time, let help {
                age(time).help(help)
            } else if let time {
                age(time)
            }
        }
        .frame(minWidth: z(26), minHeight: z(17), alignment: .trailing)
    }

    func age(_ time: Double) -> some View {
        OnTitleBaseline(text: relativeTime(time, board.now), titleFont: ui(13, .medium), font: digits(11.5))
            .frame(height: z(17), alignment: .top)
    }
}

/// Right-column text on the row title's first baseline. The empty strut carries the title's font,
/// so a smaller font still lines up when both are top-aligned in the row.
struct OnTitleBaseline: View {
    let text: String
    let titleFont: Font
    let font: Font
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "\u{200B}").font(titleFont)
            Text(verbatim: text).font(font).foregroundStyle(T.text3)
        }
    }
}

/// A relative time on the board's clock. Its own view, so a clock tick re-renders this label and nothing around it.
struct Ago: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let date: Date
    var short = true
    var size: CGFloat = 11.5
    var prefix = ""

    var body: some View {
        let text = short ? shortAge(from: date, to: board.now) : relativeTime(date.timeIntervalSince1970, board.now)
        Text(verbatim: prefix + text).font(digits(size)).foregroundStyle(T.text3)
    }
}

/// When the collector last wrote the board. It changes on every collect, so only this label observes it.
struct UpdatedStamp: View {
    @Environment(Board.self) private var board
    var prefix = ""

    var body: some View {
        if let t = board.generatedAt {
            Ago(date: Date(timeIntervalSince1970: t), short: false, prefix: prefix).help("Last updated")
        }
    }
}

/// Runs the collector now. `refreshing` flips twice per collect, so only this button observes it.
struct RefreshButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board

    var body: some View {
        Button { board.collect(fresh: true) } label: {
            ZStack {
                if board.refreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
            .font(.system(size: z(11.5), weight: .medium))
            .foregroundStyle(T.text2)
            .frame(width: z(16), height: z(16))
        }
        .buttonStyle(HoverButtonStyle.icon).pointerOnly()
        .help("Refresh now")
    }
}

extension View {
    func rowSurface(interactive: Bool = true, radius: CGFloat = T.rowRadius, resting: Bool = false) -> some View {
        modifier(RowSurface(interactive: interactive, radius: radius, resting: resting))
    }
}
