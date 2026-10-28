import AppKit
import SwiftUI

struct SectionTitle: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: z(6)) {
                Text(title).font(ui(11.5, .medium))
                Text(verbatim: "\(count)").font(digits(11.5)).foregroundStyle(T.text3)
                    .contentTransition(.numericText())
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: z(9), weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .opacity(hovering ? 1 : 0.6)
            }
            .foregroundStyle(hovering ? T.text2 : T.text3)
            .padding(.horizontal, z(8))
            .frame(height: z(26))
            .background(T.control.fill(hovering ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .trackHover { hovering = $0 }
        .pointerStyle(.link)
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
        .overlay(alignment: .bottom) { if collapsed { Separator() } }
        .padding(.top, z(4))
    }
}

struct SummaryItem: View, Zoomed {
    @Environment(\.zoom) var zoom
    let count: Int
    let label: String
    let color: Color
    var moving = false
    var body: some View {
        HStack(spacing: z(5)) {
            Orb(color: color, size: z(7), moving: moving && count > 0)
            Text(verbatim: "\(count)").font(digits(11.5)).foregroundStyle(T.text).contentTransition(.numericText())
            Text(label).font(ui(11.5)).foregroundStyle(T.text3)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The board's counts in section order, each named and counted like its section.
struct SummaryRow: View, Zoomed {
    @Environment(\.zoom) var zoom
    let lists: BoardLists
    var body: some View {
        HStack(spacing: z(12)) {
            SummaryItem(count: lists.running.count, label: "running", color: T.blue, moving: true)
            SummaryItem(count: lists.needs.count, label: "needs you", color: T.orange)
        }
    }
}

enum HiddenItem: Identifiable {
    case card(Card)
    case pr(PR)
    var id: String {
        switch self {
        case .card(let c): return "card:" + c.id
        case .pr(let p): return "pr:" + p.key
        }
    }
}

/// Collapsible sections with section-scoped row identity. Both layouts keep their own collapse state.
protocol SectionHost: Zoomed {
    var collapsedRaw: String { get nonmutating set }
    /// The section opening or closing right now.
    var folding: String? { get nonmutating set }
}

extension SectionHost {
    var collapsedTokens: Set<String> { Set(collapsedRaw.split(separator: "|").map(String.init)) }
    static var closedByDefault: Set<String> { ["Hidden"] }

    var collapsed: Set<String> {
        let tokens = collapsedTokens
        return tokens.union(Self.closedByDefault.filter { !tokens.contains("open:" + $0) })
    }

    func toggle(_ name: String) {
        var c = collapsedTokens
        let token = Self.closedByDefault.contains(name) ? "open:" + name : name
        if c.contains(token) { c.remove(token) } else { c.insert(token) }
        folding = name
        collapsedRaw = c.sorted().joined(separator: "|")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if folding == name { folding = nil } }
    }

    @ViewBuilder
    func section<Item: Identifiable, Row: View>(_ name: String, _ items: [Item], count: Int? = nil, persistent: Bool = false,
                                                @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        if !items.isEmpty || persistent {
            let isCollapsed = collapsed.contains(name)
            VStack(alignment: .leading, spacing: z(2)) {
                SectionTitle(title: name, count: count ?? items.count, collapsed: isCollapsed) { toggle(name) }
                if !isCollapsed {
                    ForEach(items, id: \.id) { item in
                        row(item).modifier(SectionMove(id: item.id)).transition(.row)
                    }
                    .environment(\.sectionName, name)
                }
            }
            .clipShape(FoldClip(on: folding == name))
        }
    }

}

/// Clips to the section's frame only while it folds, so its rows are cut at the moving edge instead of showing
/// under the section below. Cards sliding in from another section stay whole the rest of the time.
struct FoldClip: Shape {
    var on: Bool
    func path(in rect: CGRect) -> Path { Path(on ? rect : rect.insetBy(dx: -10_000, dy: -10_000)) }
}

/// Only the position is matched: a row's height can differ between sections, and its new layout takes over at once.
struct SectionMove<ID: Hashable>: ViewModifier {
    let id: ID
    @Environment(\.rowNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace, properties: .position) } else { content }
    }
}

/// What each section shows, computed once per render.
struct BoardLists {
    let cards, needs, running, recent: [Card]
    let loose: [Slot]
    let review, mine, freshReview, freshMine, stale: [PR]
    let hidden: [HiddenItem]

    init(_ state: BoardState?) {
        cards = state?.cards ?? []
        running = cards.filter { $0.section == "running" }
        needs = cards.filter { $0.section == "needs" }
        recent = cards.filter { $0.section == "recent" }
        loose = state?.looseSlots ?? []
        review = state?.prs?.review ?? []
        mine = state?.prs?.mine ?? []
        freshReview = review.filter { !$0.stale }
        freshMine = mine.filter { !$0.stale }
        stale = (review + mine).filter { $0.stale }
        hidden = (state?.hiddenCards ?? []).map(HiddenItem.card) + (state?.prs?.hidden ?? []).map(HiddenItem.pr)
    }
}

@ViewBuilder func hiddenRow(_ item: HiddenItem) -> some View {
    switch item {
    case .card(let c): CardView(card: c)
    case .pr(let p): PRRow(pr: p)
    }
}
