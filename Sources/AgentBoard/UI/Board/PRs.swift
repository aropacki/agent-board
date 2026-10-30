import AppKit
import SwiftUI

/// The same PR facts, in the same order, with the same links, everywhere a PR appears.
struct PRMeta: View, Zoomed {
    @Environment(\.zoom) var zoom
    let pr: PR
    var showAuthor = true
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface

    /// ⌘ keeps the GitHub page one click away.
    func showComments() {
        if NSEvent.modifierFlags.contains(.command) { board.openLink(pr.threadURL) } else { board.openDiscussion(pr, surface: surface) }
    }

    func showChecks() {
        if NSEvent.modifierFlags.contains(.command) { board.openLink(pr.checksURL) } else { board.openChecks(pr, surface: surface) }
    }

    var body: some View {
        FlowLayout(spacing: z(2)) {
            CIMeta(pr: pr) { showChecks() }
            Meta(text: "#\(pr.number)", color: T.text3, help: "Open PR #\(pr.number)") { board.openLink(pr.url) }
            if let newest = pr.unread.first {
                Meta(text: "\(pr.unread.count) new", color: T.red, icon: "bubble.left.fill",
                     help: "@\(newest.author): \(newest.excerpt)\nShow the comments; ⌘-click opens GitHub") { showComments() }
            }
            if pr.unresolved > 0 {
                Meta(text: "\(pr.unresolved)", color: T.text3, icon: "bubble.left",
                     help: "\(pr.unresolved) unresolved. Show the comments; ⌘-click opens GitHub") { showComments() }
            }
            if pr.review == "CHANGES_REQUESTED" {
                Meta(text: "changes", color: T.text2, icon: "hand.raised", tint: T.red,
                     help: "Changes requested. Show the comments; ⌘-click opens GitHub") { showComments() }
            }
            if pr.review == "APPROVED" { Meta(text: "approved", color: T.text3, icon: "checkmark", tint: T.green) }
            if let ticket = pr.ticket {
                if let link = Config.shared.issueTracker.link(ticket) {
                    Meta(text: ticket, color: T.text3, help: ticketHelp(ticket)) { board.openLink(link) }
                } else {
                    Meta(text: ticket, color: T.text3)
                }
            }
            if let repo = pr.shortRepo { Meta(text: repo, color: T.text3) }
            if !pr.mine && showAuthor { Meta(text: "@\(pr.author)", color: T.text3) }
        }
        .padding(.leading, -4)
    }
}

func prIconColor(_ pr: PR, ci: String) -> Color {
    if pr.mine && ci == "failing" { return T.red }
    if !pr.mine && (pr.agents ?? []).isEmpty { return T.purple }
    return T.text3
}

/// Its own view because its color follows CI, which changes whenever any PR's checks load.
struct PRGlyph: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR

    var body: some View {
        Image(systemName: "arrow.triangle.pull")
            .font(.system(size: z(12), weight: .regular))
            .foregroundStyle(pr.draft ? T.text3 : prIconColor(pr, ci: board.ci(pr)))
    }
}

/// Equatable on its PR: a state update decodes every PR afresh, and SwiftUI can't tell an unchanged one from new.
struct PRRow: View, Zoomed, Equatable {
    static func == (a: PRRow, b: PRRow) -> Bool { a.pr == b.pr && a.inStack == b.inStack }

    @Environment(\.zoom) var zoom
    let pr: PR
    var inStack = false
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    @State private var showAllAgents = false
    let visibleAgents = 2

    var body: some View {
        let agents = pr.agents ?? []
        let selecting = !board.selected.isEmpty
        let picked = board.isSelected(pr)
        VStack(alignment: .leading, spacing: z(5)) {
        HStack(alignment: .top, spacing: z(8)) {
            ZStack {
                if selecting {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: z(12), weight: .regular))
                        .foregroundStyle(picked ? T.blue : T.text3)
                } else {
                    PRGlyph(pr: pr)
                }
            }
            .frame(width: z(14), height: z(17))
            VStack(alignment: .leading, spacing: z(3)) {
                Text(pr.displayTitle).font(ui(13, .medium)).foregroundStyle(T.text).lineLimit(1).help(pr.displayTitle)
                PRMeta(pr: pr, showAuthor: !inStack)
            }
            Spacer(minLength: z(4))
            RowCorner(owner: "pr:\(pr.key)", time: pr.lastCommit, help: "Last commit")
        }
            if !agents.isEmpty { agentLines(agents) }
            RowActions(context: board.context(pr: pr), skipsStackButtons: inStack)
        }
        .padding(z(8))
        .background(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous).fill(picked ? T.blue.opacity(0.12) : .clear))
        .rowSurface(resting: !inStack)
        .onTapGesture {
            switch rowClick(NSEvent.modifierFlags, selecting: selecting) {
            case .select: board.toggleSelect(pr)
            case .diff: board.openDiff(pr)
            case .web: board.openLink(pr.url)
            }
        }
        .help(selecting ? "Click to select. ⌘-click opens the PR in the background" : "Click for the diff. ⇧-click to select several. ⌘-click opens the PR in the background")
        .opacity(pr.hidden == true ? 0.6 : 1)
        .menuTarget("pr:\(pr.key)")
    }

    /// Laid out like the PR lines inside an agent card, so the two read as mirrors.
    func agentLines(_ agents: [AgentRef]) -> some View {
        let shown = showAllAgents ? agents : Array(agents.prefix(visibleAgents))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { AgentLine(agent: $0).transition(.row) }
            if agents.count > visibleAgents {
                QuietButton(title: showAllAgents ? "Show fewer agents" : "Show \(agents.count - visibleAgents) more agents",
                            icon: showAllAgents ? "chevron.up" : "chevron.down") {
                    withAnimation(.snappy(duration: 0.2)) { showAllAgents.toggle() }
                }
                .padding(.leading, z(2))
            }
        }
        .padding(.leading, agents.count > 1 ? z(7) : 0)
        .overlay(alignment: .leading) {
            if agents.count > 1 { Bracket().stroke(T.bracket, lineWidth: 1).frame(width: z(4)) }
        }
        .padding(.leading, agents.count > 1 ? z(9) : z(16))
    }
}

/// A run of PRs where each one's base is the previous one's branch, shown base first.
struct StackGroup: View, Zoomed {
    @Environment(\.zoom) var zoom
    let prs: [PR]
    @Environment(Board.self) private var board
    @State private var showAll = false
    let visible = 4

    var body: some View {
        let authors = Set(prs.map(\.author))
        let ctx = board.context(stack: prs)
        let owner = "stack:\(prs[0].stackId ?? prs[0].key)"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: z(6)) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: z(11), weight: .regular))
                    .foregroundStyle(T.text3)
                    .frame(width: z(14))
                Text("Stack of \(prs.count)").font(ui(11.5, .medium)).foregroundStyle(T.text2)
                if !prs[0].mine, authors.count == 1 { Text("@\(prs[0].author)").font(ui(11.5)).foregroundStyle(T.text3) }
                Spacer(minLength: z(4))
                HStack(spacing: z(20)) {
                    ForEach(board.applicable(on: ctx, buttons: true)) { item in
                        ActionChip(title: item.action.title, key: board.actionKey(item.action, ctx)) {
                            board.run(item.action, ctx, targets: item.targets)
                        }
                    }
                }
                .padding(.trailing, z(7))
                MoreButton(owner: owner)
            }
            .padding(.horizontal, z(8)).padding(.vertical, z(6))
            .contentShape(Rectangle())
            .menuTarget(owner)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? prs : Array(prs.prefix(visible))) { PRRow(pr: $0, inStack: true).transition(.row) }
                if prs.count > visible {
                    QuietButton(title: showAll ? "Show fewer" : "Show \(prs.count - visible) more in this stack",
                                icon: showAll ? "chevron.up" : "chevron.down") {
                        withAnimation(.snappy(duration: 0.2)) { showAll.toggle() }
                    }
                    .padding(.leading, z(26)).padding(.bottom, z(4))
                }
            }
            .padding(.leading, z(7))
            .overlay(alignment: .leading) { Bracket().stroke(T.bracket, lineWidth: 1).frame(width: z(4)) }
            .padding(.leading, z(12))
        }
        .padding(.bottom, z(4))
        .rowSurface(interactive: false, resting: true)
    }
}

enum PRUnit: Identifiable {
    case single(PR)
    case stack(String, [PR])
    var id: String {
        switch self {
        case .single(let pr): return pr.key
        case .stack(let id, _): return "stack:" + id
        }
    }
}

/// Groups stack members that share a section, at the position of the most recent member.
func prUnits(_ prs: [PR]) -> [PRUnit] {
    let groups = Dictionary(grouping: prs.filter { $0.stackId != nil }, by: { $0.stackId! })
    var emitted = Set<String>()
    var out: [PRUnit] = []
    for pr in prs {
        if let sid = pr.stackId, let members = groups[sid], members.count > 1 {
            if emitted.insert(sid).inserted { out.append(.stack(sid, members.sorted { ($0.stackPos ?? 0) < ($1.stackPos ?? 0) })) }
        } else {
            out.append(.single(pr))
        }
    }
    return out
}

@ViewBuilder func prUnitView(_ unit: PRUnit) -> some View {
    switch unit {
    case .single(let pr): PRRow(pr: pr)
    case .stack(_, let prs): StackGroup(prs: prs)
    }
}

/// A PR inside an agent card: the same facts as a PR row, one level quieter.
struct CardPRLine: View, Zoomed {
    @Environment(\.zoom) var zoom
    let pr: PR
    @Environment(Board.self) private var board

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pr.displayTitle).font(ui(12)).foregroundStyle(T.text2).lineLimit(1)
            PRMeta(pr: pr)
        }
        .padding(.horizontal, z(6)).padding(.vertical, z(4))
        .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(board.isSelected(pr) ? T.blue.opacity(0.12) : .clear))
        .rowSurface(radius: 6)
        .onTapGesture {
            switch rowClick(NSEvent.modifierFlags, selecting: !board.selected.isEmpty) {
            case .select: board.toggleSelect(pr)
            case .diff: board.openDiff(pr)
            case .web: board.openLink(pr.url)
            }
        }
        .help("Click for the diff. ⇧-click to select. ⌘-click opens the PR in the background")
        .menuTarget("pr:\(pr.key)")
    }
}
