import AppKit
import SwiftUI

/// An agent under a PR row: the same facts as an agent card, one level quieter.
struct AgentLine: View, Zoomed {
    @Environment(\.zoom) var zoom
    let agent: AgentRef
    @Environment(Board.self) private var board

    var body: some View {
        let key = "open-\(agent.id)"
        HStack(spacing: z(6)) {
                ZStack {
                    if board.busy.contains(key) {
                        ProgressView().controlSize(.mini)
                    } else if board.succeeded.contains(key) {
                        Image(systemName: "checkmark").font(.system(size: z(9), weight: .bold)).foregroundStyle(T.green)
                    } else {
                        StatusDot(status: board.state?.status(of: agent) ?? agent.status)
                    }
                }
                .frame(width: z(10), height: z(10))
                HStack(alignment: .firstTextBaseline, spacing: z(4)) {
                    Text(agent.title).font(ui(12)).foregroundStyle(T.text2).lineLimit(1)
                    Spacer(minLength: 0)
                    Ago(date: Date(timeIntervalSince1970: agent.updatedAt), short: false)
                }
        }
        .padding(.horizontal, z(6)).padding(.vertical, z(4))
        .rowSurface(radius: 6)
        .padding(.trailing, -z(6))
        .onTapGesture { board.open(agent) }
        .help("Open “\(agent.title)”")
        .menuTarget("card:\(agent.id)")
    }
}

/// A chat's side chats and subagents, folded to one line that shows how many there are and the most urgent state.
struct ChildChatsHeader: View, Zoomed {
    @Environment(\.zoom) var zoom
    let chats: [Card]
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let dots = chats.map(\.dotStatus)
        let urgent = ["needs", "running", "error", "aborted"].first(where: dots.contains) ?? "done"
        let sides = chats.filter { $0.kind == "side" }.count, subs = chats.count - sides
        let summary = [sides > 0 ? "\(sides) side chat\(sides == 1 ? "" : "s")" : nil,
                       subs > 0 ? "\(subs) subagent\(subs == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: z(6)) {
            StatusDot(status: urgent).frame(width: z(10), height: z(10))
            Text(summary).font(ui(12)).foregroundStyle(T.text3).lineLimit(1)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.system(size: z(9), weight: .semibold)).foregroundStyle(T.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, z(6)).padding(.vertical, z(4))
        .rowSurface(radius: 6)
        .padding(.trailing, -z(6))
        .onTapGesture(perform: toggle)
        .help(open ? "Hide these chats" : "Show these chats")
    }
}

/// Equatable on its card: a state update decodes every card afresh, and SwiftUI can't tell an unchanged one from new.
struct CardView: View, Zoomed, Equatable {
    static func == (a: CardView, b: CardView) -> Bool { a.card == b.card }

    @Environment(\.zoom) var zoom
    let card: Card
    @Environment(Board.self) private var board
    @Environment(\.sectionName) private var sectionName
    @State private var showAllPRs = false
    @State private var showChats = false
    @State private var probeID = UUID()
    @Environment(\.boardSurface) private var surface
    let visiblePRs = 2

    var body: some View {
        let openKey = "open-\(card.id)"
        let shown = showAllPRs ? card.prs : Array(card.prs.prefix(visiblePRs))
        let _ = Probe.on ? Probe.rows[probeID] = (card.id, sectionName, card.dotStatus, card.needsYou) : ()
        VStack(alignment: .leading, spacing: z(5)) {
            HStack(alignment: .top, spacing: z(8)) {
                StatusDot(status: card.dotStatus).frame(width: z(14), height: z(17))
                VStack(alignment: .leading, spacing: z(2)) {
                    Text(card.title).font(ui(13, .medium)).foregroundStyle(sectionName == "Recent" ? T.text2 : T.text).lineLimit(1)
                        .help(card.title)
                    if let slot = card.slot { slotLine(slot) }
                }
                Spacer(minLength: z(4))
                RowCorner(owner: "card:\(card.id)", busyKey: openKey, time: card.updatedAt)
            }

            let reasons = card.needsYou.filter { $0 != "finished" }
            if !reasons.isEmpty {
                FlowLayout(spacing: z(2)) { ForEach(reasons, id: \.self) { needsLink($0) } }
                    .padding(.leading, z(18))
            }

            if !card.prs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { CardPRLine(pr: $0).transition(.row) }
                    if card.prs.count > visiblePRs {
                        QuietButton(title: showAllPRs ? "Show fewer PRs" : "Show \(card.prs.count - visiblePRs) more PRs",
                                    icon: showAllPRs ? "chevron.up" : "chevron.down") {
                            withAnimation(.snappy(duration: 0.2)) { showAllPRs.toggle() }
                        }
                        .padding(.leading, z(2))
                    }
                }
                .padding(.leading, card.prs.count > 1 ? z(7) : 0)
                .overlay(alignment: .leading) {
                    if card.prs.count > 1 { Bracket().stroke(T.bracket, lineWidth: 1).frame(width: z(4)) }
                }
                .padding(.leading, card.prs.count > 1 ? z(9) : z(16))
            }

            if let chats = card.children, !chats.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ChildChatsHeader(chats: chats, open: showChats) {
                        withAnimation(.snappy(duration: 0.2)) { showChats.toggle() }
                    }
                    if showChats {
                        ForEach(chats) { chat in
                            AgentLine(agent: AgentRef(id: chat.id, title: chat.title, status: chat.dotStatus, updatedAt: chat.updatedAt))
                                .transition(.row)
                        }
                    }
                }
                .padding(.leading, showChats ? z(7) : 0)
                .overlay(alignment: .leading) {
                    if showChats { Bracket().stroke(T.bracket, lineWidth: 1).frame(width: z(4)) }
                }
                .padding(.leading, showChats ? z(9) : z(16))
            }

            RowActions(context: board.context(card: card))
        }
        .padding(z(8))
        .rowSurface(resting: true)
        .onDisappear { if Probe.on { Probe.rows[probeID] = nil } }
        .onTapGesture { board.open(card) }
        .opacity(card.hidden == true ? 0.6 : 1)
        .menuTarget("card:\(card.id)")
    }

    /// Each reason links to what explains it: the chat or the review.
    func needsLink(_ reason: String) -> some View {
        let changes = card.prs.first { $0.mine && $0.review == "CHANGES_REQUESTED" }
        switch reason {
        case "changes requested" where changes != nil:
            return Meta(text: reason, color: T.orange, help: "Show the comments; ⌘-click opens GitHub") {
                if NSEvent.modifierFlags.contains(.command) { board.openLink(changes!.threadURL) } else { board.openDiscussion(changes!, surface: surface) }
            }
        default:
            return Meta(text: reason, color: T.orange, help: "Open the chat") { board.open(card) }
        }
    }

    func slotLine(_ slot: Slot) -> some View {
        HStack(spacing: z(6)) {
            Text("\(slot.label) · \(slot.branch ?? "detached")")
                .foregroundStyle(T.text3)
                .lineLimit(1).truncationMode(.middle)
            if slot.dirty == true { Text("dirty").foregroundStyle(T.orange) }
            if let ahead = slot.ahead, ahead > 0 { Text("↑\(ahead)").foregroundStyle(T.orange) }
            else if slot.branch != nil && slot.pushed == false { Text("unpushed").foregroundStyle(T.orange) }
        }
        .font(ui(11.5))
    }

}

struct ReturnChip: View {
    let slot: Slot
    @Environment(Board.self) private var board
    var body: some View {
        let confirming = board.confirmReturn == slot.path
        ActionChip(title: confirming ? "Confirm return" : "Return",
                   color: confirming ? T.orange : T.text2,
                   key: "return-\(slot.path)",
                   disabledReason: slot.blockerText) { board.tapReturn(slot) }
    }
}

struct LooseSlotView: View, Zoomed {
    @Environment(\.zoom) var zoom
    let slot: Slot
    var body: some View {
        HStack(spacing: z(8)) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: z(10.5), weight: .medium))
                .foregroundStyle(T.text3)
                .frame(width: z(14))
            VStack(alignment: .leading, spacing: z(2)) {
                Text(slot.label).font(ui(13, .medium)).foregroundStyle(T.text)
                Text("\(slot.branch ?? "detached") · \(slot.leaseHolder ?? "no holder")")
                    .font(ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer()
            if slot.leased { ReturnChip(slot: slot) }
        }
        .padding(z(8))
        .rowSurface(interactive: false, resting: true)
        .menuTarget("slot:\(slot.path)")
    }
}

struct PermissionCard: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    var body: some View {
        VStack(alignment: .leading, spacing: z(6)) {
            HStack(spacing: z(6)) {
                Image(systemName: "hand.raised").font(.system(size: z(11), weight: .medium)).foregroundStyle(T.orange)
                Text("Let Agent Board type into Cursor").font(ui(13, .medium)).foregroundStyle(T.text)
            }
            Text("Quick actions type into Cursor, so they need Accessibility access. Turn on Agent Board in the list that opens.")
                .font(ui(12)).foregroundStyle(T.text2)
            Button { board.requestTrust() } label: {
                Text("Open Accessibility settings").font(ui(12, .medium)).foregroundStyle(T.text)
            }
            .buttonStyle(HoverButtonStyle.action).pointerOnly()
            .padding(.top, z(2))
        }
        .padding(z(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.raised, in: RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous).strokeBorder(T.border))
        .padding(.top, z(8))
        .transition(.opacity)
    }
}
