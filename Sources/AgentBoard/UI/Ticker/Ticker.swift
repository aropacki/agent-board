import AppKit
import SwiftUI

enum TickerSide { case status, notes }

@_silgen_name("_CGSDefaultConnection") private func CGSDefaultConnection() -> UInt32
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: UInt32, _ flag: Int, _ options: CFDictionary?) -> UInt64
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: UInt32, _ space: UInt64, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: UInt32, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: UInt32, _ spaces: CFArray)

/// A space that sits above every desktop, so its windows stay put while a swipe changes desktops.
/// Windows that only join all spaces are taken down for the swipe and come back when it settles.
final class OverlaySpace {
    private let cid = CGSDefaultConnection()
    private let id: UInt64

    init() {
        id = CGSSpaceCreate(cid, 1, nil)
        CGSSpaceSetAbsoluteLevel(cid, id, 100)
        CGSShowSpaces(cid, [NSNumber(value: id)] as CFArray)
    }

    func add(_ window: NSWindow) {
        CGSAddWindowsToSpaces(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: id)] as CFArray)
    }
}

extension AnyTransition {
    /// Enters from the top and leaves through the bottom.
    static var roll: AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .move(edge: .bottom).combined(with: .opacity))
    }
}

/// A strip's bottom edge, carried up through its rounded corners. The strip's shape minus the same
/// shape raised by `width`, so it is `width` thick along the bottom and thins to nothing where the
/// corners turn vertical.
struct BottomRim: Shape {
    let leading: CGFloat
    let trailing: CGFloat
    var width: CGFloat = 1
    func path(in r: CGRect) -> Path {
        func corners(_ rect: CGRect) -> Path {
            UnevenRoundedRectangle(bottomLeadingRadius: leading, bottomTrailingRadius: trailing, style: .circular).path(in: rect)
        }
        var raised = r
        raised.size.height -= width
        return corners(r).subtracting(corners(raised))
    }
}

/// The strips over the menu bar while the panel is closed: counts and one rolling agent left of
/// the notch, events right of it. They meet under the notch and never take clicks.
struct TickerBar: View {
    static let corner: CGFloat = 10
    let side: TickerSide
    @Environment(Board.self) private var board
    @State private var glow: Double = 0
    @State private var sweep: CGFloat = 0
    @State private var glowColor = T.blue

    /// Both outer ends are rounded; the strips meet flush under a notch.
    var radii: (leading: CGFloat, trailing: CGFloat) {
        let r = TickerBar.corner
        let split = board.tickerNotchInset > 0 ? 0 : r
        return side == .status ? (r, split) : (split, r)
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: radii.leading, bottomTrailingRadius: radii.trailing, style: .circular)
    }

    static let glow = LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.25),
                                             .init(color: .white.opacity(0.055), location: 0.7),
                                             .init(color: .white.opacity(0.12), location: 1)],
                                     startPoint: .top, endPoint: .bottom)

    /// The glow continued past the rounded corners, so only the rim marks the curve instead of the
    /// black menu bar showing through. The strip covers it everywhere else.
    var halo: some View { TickerBar.glow }

    /// Black with a glow that rises from the lit bottom edge. Glow and rim fade out before a flush
    /// end, reaching black at the notch's visible edge so the strip meets the notch without a seam.
    var surface: some View {
        let fade: CGFloat = 48
        let hidden = board.tickerNotchInset
        let (leading, trailing) = radii
        return ZStack {
            Color.black
            ZStack {
                TickerBar.glow
                BottomRim(leading: leading, trailing: trailing)
                    .fill(Color.white.opacity(0.17))
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
            }
            .mask {
                HStack(spacing: 0) {
                    if leading == 0 {
                        Color.clear.frame(width: hidden)
                        LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                    }
                    Color.white
                    if trailing == 0 {
                        LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                        Color.clear.frame(width: hidden)
                    }
                }
            }
        }
    }

    var body: some View {
        Group {
            switch side {
            case .status: statusSide
            case .notes: notesSide
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ZStack { surface; if side == .notes { arrivalWash } } }
        .clipShape(shape)
        .background { halo }
        .preferredColorScheme(.dark)
        .onChange(of: board.tickerNote?.id) { _, id in
            guard side == .notes, id != nil, let note = board.tickerNote else { return }
            arrive(note.color)
        }
    }

    /// A band of the event's color crosses the strip toward the text, then the tint settles out.
    var arrivalWash: some View {
        GeometryReader { geo in
            let band = max(geo.size.width * 0.5, 160)
            ZStack(alignment: .leading) {
                glowColor.opacity(0.10)
                LinearGradient(colors: [glowColor.opacity(0), glowColor.opacity(0.38), glowColor.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + sweep * (geo.size.width + band))
            }
        }
        .opacity(glow)
        .allowsHitTesting(false)
    }

    func arrive(_ color: Color) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            glowColor = color
            sweep = 0
            glow = 1
        }
        withAnimation(.easeInOut(duration: 1.4)) { sweep = 1 }
        withAnimation(.easeOut(duration: 2.4).delay(1.2)) { glow = 0 }
    }

    var statusSide: some View {
        let l = BoardLists(board.state)
        let running = l.running.map { TickerItem(id: $0.id, icon: nil, color: T.blue, title: $0.title) }
        let needs = l.needs.map { TickerItem(id: $0.id, icon: nil, color: T.orange, title: $0.title) }
        var unread: [PR] = []
        for pr in (board.state?.prs?.mine ?? []) + (board.state?.allCards ?? []).flatMap(\.prs)
        where !pr.unread.isEmpty && !unread.contains(where: { $0.key == pr.key }) { unread.append(pr) }
        let comments = unread.map { pr in
            TickerItem(id: pr.key, icon: nil, color: T.red, title: "@\(pr.unread[0].author) on #\(pr.number)")
        }
        return HStack(spacing: 22) {
            if !comments.isEmpty { commentsGroup(comments) }
            group(T.blue, running, moving: true, startDelay: 0)
            group(T.orange, needs, startDelay: TickerRoller.hold / 2)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, board.tickerNotchInset + 8)
    }

    /// A live event and the resting line it becomes share one identity, so settling only dims it.
    var notesSide: some View {
        let live = board.tickerNote
        return ZStack(alignment: .trailing) {
            if let shown = live ?? board.tickerLast {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    noteLine(shown, age: live == nil ? shortAge(from: shown.at, to: context.date) : nil)
                }
                .opacity(live == nil ? 0.55 : 1)
                .id(shown.id)
                .transition(.roll)
            } else {
                Text("No new activity").font(.system(size: 11.5)).foregroundStyle(T.text3).transition(.roll)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
        .padding(.leading, board.tickerNotchInset + 8)
        .padding(.trailing, 30)
    }

    /// The age sits left of the icon, so it appears without moving the right-aligned text.
    func noteLine(_ note: TickerEvent, age: String?) -> some View {
        HStack(spacing: 7) {
            if let age { Text(age).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(T.text3).transition(.opacity) }
            NoteIcon(note: note, live: age == nil)
            Text(note.text).font(.system(size: 12, weight: .medium)).foregroundStyle(T.text).lineLimit(1)
        }
    }

    /// Leads the strip and stays until the comments are read, like an unread badge.
    func commentsGroup(_ items: [TickerItem]) -> some View {
        HStack(spacing: 6) {
            PulsingSymbol(name: "bubble.left.fill", color: T.red, size: 10, weight: .regular, pulsing: board.animating)
                .frame(width: 12, height: 12)
            Text(verbatim: "\(items.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(T.red)
            TickerRoller(items: items).padding(.leading, 3)
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background {
            Capsule().fill(HoverBody.edges(T.red.opacity(0.16), middle: 0.7))
                .overlay(HoverBody.cornerStroke(Capsule(), T.red.opacity(0.6)))
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    func group(_ color: Color, _ items: [TickerItem], moving: Bool = false, startDelay: Double) -> some View {
        HStack(spacing: 7) {
            Orb(color: color, size: 7, moving: moving && !items.isEmpty)
            Text(verbatim: "\(items.count)").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(T.text)
            if !items.isEmpty { TickerRoller(items: items, startDelay: startDelay).padding(.leading, 3) }
        }
    }
}

/// Bounces once as a live event finishes rolling in.
struct NoteIcon: View {
    let note: TickerEvent
    let live: Bool
    @State private var bounce = 0

    var body: some View {
        Image(systemName: note.icon).font(.system(size: 11)).foregroundStyle(note.color)
            .symbolEffect(.bounce, value: bounce)
            .task(id: note.id) {
                guard live else { return }
                try? await Task.sleep(for: .seconds(0.6))
                bounce += 1
            }
    }
}

struct TickerItem: Identifiable {
    let id: String
    let icon: String?
    let color: Color
    let title: String
}

/// Shows one item at a time and rolls to the next every few seconds.
struct TickerRoller: View {
    static let hold: Double = 8
    let items: [TickerItem]
    var startDelay: Double = 0
    @State private var index = 0

    /// The hidden copies size the slot to the longest title, so rolling never shifts what follows.
    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(items) { line($0).hidden() }
            if !items.isEmpty {
                let item = items[index % items.count]
                line(item)
                    .id("\(index)-\(item.id)")
                    .transition(.roll)
            }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .clipped()
        .task(id: items.count) {
            guard items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(startDelay))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TickerRoller.hold))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.8)) { index += 1 }
            }
        }
    }

    func line(_ item: TickerItem) -> some View {
        HStack(spacing: 5) {
            if let icon = item.icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(item.color) }
            Text(item.title).font(.system(size: 11.5)).foregroundStyle(T.text2).lineLimit(1)
        }
    }
}
