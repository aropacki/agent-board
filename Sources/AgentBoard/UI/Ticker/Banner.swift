import AppKit
import SwiftUI

@Observable
final class Banners {
    static let shown = 3
    var items: [TickerEvent] = []

    func add(_ events: [TickerEvent]) {
        withAnimation(Motion.reduced ? nil : .smooth(duration: 0.35)) {
            items = Array((events.reversed() + items).prefix(Banners.shown))
        }
    }

    func remove(_ id: UUID) {
        withAnimation(Motion.reduced ? nil : .easeIn(duration: 0.2)) { items.removeAll { $0.id == id } }
    }
}

/// The event's symbol on a tile in its color, so the kind reads before the words do.
struct EventTile: View {
    let event: TickerEvent
    let side: CGFloat
    var bounce = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.18, blue: 0.21), Color(red: 0.08, green: 0.08, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [event.color.opacity(0.45), event.color.opacity(0)], center: .center,
                           startRadius: 0, endRadius: side * 0.62)
            // White first, so the inner mark of a multi-layer symbol stays visible on its tinted body.
            Image(systemName: event.icon)
                .font(.system(size: side * 0.43, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, event.color, event.color)
                .symbolEffect(.bounce, value: bounce)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Newest on top, under the menu bar's right end, where the ticker's events land.
struct BannerStack: View {
    let banners: Banners
    let open: (TickerEvent) -> Void
    let close: (UUID) -> Void
    let resized: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: z(8)) {
            ForEach(banners.items) { event in
                BannerCard(event: event, open: { open(event) }, close: { close(event.id) })
                    // A short drop stays inside the window's padding, so nothing is clipped on the way in or out.
                    .transition(Motion.reduced ? .opacity : .offset(y: -z(10)).combined(with: .opacity)
                        .combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(BannerStack.pad)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .preferredColorScheme(.dark)
    }

    /// Room for the shadow and the close button, which sits over the card's corner.
    static let pad: CGFloat = 16
}

struct BannerCard: View, Zoomed {
    @Environment(\.zoom) var zoom
    let event: TickerEvent
    let open: () -> Void
    let close: () -> Void
    static let life: Double = 8
    @State private var hovering = false
    @State private var left: CGFloat = 1
    @State private var sweep: CGFloat = 0
    @State private var wash: Double = 1
    @State private var bounce = 0

    /// "#123 Title · detail" or "ABC-12 Title · detail" splits into the number, the title, and what follows.
    var parts: (number: String?, title: String, detail: String?) {
        let pieces = event.subject.components(separatedBy: " · ")
        let head = pieces[0]
        let detail = pieces.count > 1 ? pieces.dropFirst().joined(separator: " · ") : nil
        guard let id = head.prefixMatch(of: #/(#\d+|[A-Z][A-Z0-9]*-\d+) /#) else { return (nil, head, detail) }
        return (String(id.1), String(head[id.range.upperBound...]), detail)
    }

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: z(14), style: .continuous) }

    /// Capitals for the kind; the person in it keeps their case.
    var heading: Text {
        let label = event.label
        let person = (label.range(of: " from ") ?? label.range(of: " by ")).map { label.index(before: $0.upperBound) }
        let split = person ?? label.range(of: " @")?.lowerBound ?? label.endIndex
        let kind = Text(label[..<split].uppercased()).font(ui(10, .bold)).tracking(0.7)
        let who = Text(label[split...]).font(ui(11, .semibold))
        return Text("\(kind)\(who)").foregroundStyle(event.color)
    }

    var body: some View {
        let (number, title, detail) = parts
        HStack(alignment: .top, spacing: z(12)) {
            EventTile(event: event, side: z(46), bounce: bounce)
            VStack(alignment: .leading, spacing: z(3)) {
                HStack(spacing: z(6)) {
                    heading
                    Spacer(minLength: z(8))
                    Text("now").font(digits(10.5)).foregroundStyle(T.text3)
                }
                let pr = Text(number.map { $0 + " " } ?? "").font(mono(11.5).weight(.medium)).foregroundStyle(T.text3)
                Text("\(pr)\(Text(title).font(ui(13, .semibold)).foregroundStyle(T.text))")
                if let detail {
                    Text(detail).font(ui(11.5)).foregroundStyle(T.text2).lineLimit(2)
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, z(12)).padding(.top, z(12)).padding(.bottom, z(13))
        .frame(width: z(352))
        .background { surface }
        .clipShape(shape)
        .overlay { shape.strokeBorder(T.border) }
        .overlay { HoverBody.cornerStroke(shape, event.color.opacity(0.7)) }
        .overlay(alignment: .bottom) { countdown }
        .overlay(alignment: .topLeading) { if hovering { closeButton } }
        .shadow(color: .black.opacity(0.45), radius: z(12), y: z(4))
        .contentShape(shape)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .onAppear(perform: arrive)
        .onChange(of: hovering) { _, on in run(paused: on) }
        // Hovering holds the banner; leaving restarts the full count.
        .task(id: hovering) {
            guard !hovering else { return }
            try? await Task.sleep(for: .seconds(BannerCard.life))
            if !Task.isCancelled { close() }
        }
    }

    var surface: some View {
        GeometryReader { geo in
            let band = max(geo.size.width * 0.6, 180)
            ZStack(alignment: .leading) {
                T.surface
                LinearGradient(colors: [event.color.opacity(0.16), event.color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [event.color.opacity(0), event.color.opacity(0.32), event.color.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: -band + sweep * (geo.size.width + band))
                    .animation(.easeInOut(duration: 1.2), value: sweep)
                    .opacity(wash)
                    .animation(.easeOut(duration: 1.6).delay(1.0), value: wash)
                if hovering { Color.white.opacity(0.03) }
            }
        }
    }

    /// How long the banner stays, drawn as a bar that empties from the right.
    var countdown: some View {
        Capsule().fill(event.color.opacity(0.75))
            .frame(height: z(2))
            .scaleEffect(x: left, anchor: .leading)
            .animation(hovering ? .easeOut(duration: 0.25) : .linear(duration: BannerCard.life), value: left)
            .padding(.horizontal, z(14)).padding(.bottom, z(4))
            .allowsHitTesting(false)
    }

    var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: z(8), weight: .bold)).foregroundStyle(T.text)
                .frame(width: z(18), height: z(18))
                .background(Circle().fill(T.raised))
                .overlay(Circle().strokeBorder(T.border))
        }
        .buttonStyle(.plain)
        .offset(x: -z(6), y: -z(6))
        .transition(.opacity)
    }

    /// Each animation is scoped to the view it moves, so a long one never carries the card's own position.
    func arrive() {
        run(paused: false)
        guard !Motion.reduced else { wash = 0; return }
        sweep = 1
        wash = 0
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            bounce += 1
        }
    }

    func run(paused: Bool) { left = paused ? 1 : 0 }
}
