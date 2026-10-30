import AppKit
import SwiftUI

struct BoardView: View, SectionHost, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    @AppStorage("collapsedSections") var collapsedRaw = "Stale PRs"
    @State private var showAllRecent = false
    @State private var showActivity = ProcessInfo.processInfo.environment["BENCH_ACTIVITY"] != nil
    @Namespace private var rows
    @State var folding: String?
    let recentLimit = 6

    var body: some View {
        let l = BoardLists(board.state)
        let cards = l.cards, needs = l.needs, running = l.running, recent = l.recent, loose = l.loose
        let shownRecent = showAllRecent ? recent : Array(recent.prefix(recentLimit))
        let stalePRs = l.stale

        VStack(spacing: 0) {
            header(l)
            Rectangle().fill(T.border).frame(height: 1)

            let discussionPR = board.discussion.flatMap { $0.surface == "panel" ? board.pr(key: $0.key) : nil }
            let checksPR = board.checksOpen.flatMap { $0.surface == "panel" ? board.pr(key: $0.key) : nil }
            let covered = discussionPR != nil || checksPR != nil || showActivity
            ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: z(2)) {
                    if !board.trusted { PermissionCard() }
                    section("Running", running, persistent: true) { CardView(card: $0) }
                    section("Needs you", needs, persistent: true) { CardView(card: $0) }
                    section("Recent", shownRecent, count: recent.count) { CardView(card: $0) }
                    if recent.count > recentLimit && !collapsed.contains("Recent") { showMoreRecent(recent.count) }
                    let freshReview = l.freshReview, freshMine = l.freshMine
                    section("Review requested", prUnits(freshReview), count: freshReview.count) { prUnitView($0) }
                    section("My PRs", prUnits(freshMine), count: freshMine.count) { prUnitView($0) }
                    section("Stale PRs", prUnits(stalePRs), count: stalePRs.count) { prUnitView($0) }
                    section("Slots without a chat", loose) { LooseSlotView(slot: $0) }
                    section("Hidden", l.hidden) { hiddenRow($0) }
                    if board.state != nil && cards.isEmpty && loose.isEmpty { emptyState }
                    if board.state == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, z(40))
                    }
                }
                .padding(.horizontal, z(6))
                .padding(.bottom, z(60))
                .environment(\.rowNamespace, rows)
            }
            .scrollIndicators(.never)
            .holdsRefreshWhileScrolling()
            .menuViewport("main")
            .offset(x: covered && !Motion.reduced ? -z(24) : 0)
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)

            if let pr = discussionPR {
                DiscussionView(pr: pr).menuViewport("discussion").transition(.push)
            } else if let pr = checksPR {
                ChecksView(pr: pr).menuViewport("checks").transition(.push)
            } else if showActivity {
                ScrollView { ActivityList().padding(.horizontal, z(6)).padding(.bottom, z(60)) }
                    .scrollIndicators(.never)
                    .menuViewport("activity")
                    .transition(.push)
            }
            }
        }
        .background(T.surface)
        .modifier(BoardOverlays())
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .key)
    }

    func showMoreRecent(_ total: Int) -> some View {
        QuietButton(title: showAllRecent ? "Show fewer" : "Show \(total - recentLimit) more",
                    icon: showAllRecent ? "chevron.up" : "chevron.down") {
            withAnimation(.snappy(duration: 0.2)) { showAllRecent.toggle() }
        }
        .padding(.leading, z(26))
    }

    func header(_ l: BoardLists) -> some View {
        VStack(alignment: .leading, spacing: z(8)) {
            HStack(spacing: z(2)) {
                Text(showActivity ? "Activity" : "Agents").font(ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
                NewAgentButton()
                RefreshButton()
                ActivityButton(showing: showActivity) { showActivity.toggle() }
                MoreButton(owner: "header", size: CGSize(width: z(24), height: z(24)))
            }
            HStack(spacing: z(12)) {
                SummaryRow(lists: l)
                Spacer()
                UpdatedStamp()
            }
        }
        .padding(.horizontal, z(14)).padding(.top, z(12)).padding(.bottom, z(10))
        .contentShape(Rectangle())
        .menuTarget("header")
        .menuViewport("header")
    }

    var emptyState: some View {
        VStack(spacing: z(4)) {
            Text("All quiet").font(ui(13, .medium)).foregroundStyle(T.text2)
            Text("No chats in the last two days.").font(ui(12)).foregroundStyle(T.text3)
        }
        .frame(maxWidth: .infinity).padding(.top, z(60))
    }

}
