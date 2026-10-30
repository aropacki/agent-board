import AppKit
import SwiftUI

/// The same board laid out in columns for a large or full-screen window.
struct FullBoardView: View, SectionHost, Zoomed {
    var zoom: CGFloat { T.zoom * 1.15 }
    @Environment(Board.self) private var board
    @AppStorage("fullCollapsedSections") var collapsedRaw = ""
    @State var folding: String?
    @State private var showActivity = ProcessInfo.processInfo.environment["BENCH_ACTIVITY"] != nil

    var body: some View {
        let l = BoardLists(board.state)
        VStack(spacing: 0) {
            topBar(l)
            Rectangle().fill(T.border).frame(height: 1)
            if board.showActions {
                ActionsEditor()
            } else {
                columns(l).overlay(alignment: .trailing) {
                    if let open = board.discussion, open.surface == "window", let pr = board.pr(key: open.key) {
                        drawer(width: 600) { DiscussionView(pr: pr) }
                            .menuViewport("cover-discussion")
                            .transition(.push)
                    } else if let open = board.checksOpen, open.surface == "window", let pr = board.pr(key: open.key) {
                        drawer(width: 600) { ChecksView(pr: pr) }
                            .menuViewport("cover-checks")
                            .transition(.push)
                    } else if showActivity {
                        activityDrawer.transition(.push)
                    }
                }
            }
        }
        .environment(\.zoom, zoom)
        .background(T.surface)
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .key)
    }

    func columns(_ l: BoardLists) -> some View {
                HStack(alignment: .top, spacing: 0) {
                    column("Agents", count: l.cards.count + l.loose.count) {
                        if !board.trusted { PermissionCard() }
                        section("Running", l.running, persistent: true) { CardView(card: $0) }
                        section("Needs you", l.needs, persistent: true) { CardView(card: $0) }
                        section("Recent", l.recent) { CardView(card: $0) }
                        section("Slots without a chat", l.loose) { LooseSlotView(slot: $0) }
                        if board.state != nil && l.cards.isEmpty && l.loose.isEmpty { empty("No chats in the last two days.") }
                    }
                    divider
                    column("Review requested", count: l.freshReview.count) {
                        ForEach(prUnits(l.freshReview)) { prUnitView($0).transition(.row).id("review|\($0.id)") }
                        if board.state != nil && l.freshReview.isEmpty { empty("Nothing waiting on you.") }
                    }
                    divider
                    column("My PRs", count: l.freshMine.count) {
                        ForEach(prUnits(l.freshMine)) { prUnitView($0).transition(.row).id("mine|\($0.id)") }
                        if board.state != nil && l.freshMine.isEmpty { empty("No open PRs.") }
                    }
                }
    }

    var divider: some View { Rectangle().fill(T.border).frame(width: 1) }

    /// Slides over the last column; the board stays visible beside it.
    func drawer<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: z(width))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(T.raised)
            .overlay(alignment: .leading) { Rectangle().fill(T.border).frame(width: 1) }
            .shadow(color: .black.opacity(0.35), radius: 18, x: -6)
    }

    var activityDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: z(6)) {
                Text("Activity").font(ui(13, .semibold)).foregroundStyle(T.text)
                Spacer()
                Button { withAnimation(.snappy(duration: 0.2)) { showActivity = false } } label: {
                    Image(systemName: "xmark").font(.system(size: z(10), weight: .semibold)).foregroundStyle(T.text2)
                        .frame(width: z(16), height: z(16))
                }
                .buttonStyle(HoverButtonStyle.icon).pointerOnly()
                .help("Close")
            }
            .padding(.horizontal, z(16)).frame(height: z(38))
            ScrollView { ActivityList().padding(.horizontal, z(8)).padding(.bottom, z(60)) }
                .scrollIndicators(.automatic)
        }
        .frame(width: z(440))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.raised)
        .overlay(alignment: .leading) { Rectangle().fill(T.border).frame(width: 1) }
        .shadow(color: .black.opacity(0.35), radius: 18, x: -6)
        .menuViewport("cover")
    }

    func empty(_ text: String) -> some View {
        Text(text).font(ui(12)).foregroundStyle(T.text3).frame(maxWidth: .infinity).padding(.top, z(40))
    }

    func column<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: z(6)) {
                Text(title).font(ui(13, .semibold)).foregroundStyle(T.text)
                Text(verbatim: "\(count)").font(digits(11.5)).foregroundStyle(T.text3).contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, z(16)).frame(height: z(38))
            ScrollView {
                // A lazy stack guesses the height of cards it has not drawn, and cards vary enough that the guess ran
                // hundreds of points long, so the column scrolled past its end. A column holds few enough cards to draw.
                VStack(alignment: .leading, spacing: z(2)) { content() }
                    .padding(.horizontal, z(8))
                    .padding(.bottom, z(80))
            }
            .scrollIndicators(.automatic)
            .holdsRefreshWhileScrolling()
            .menuViewport(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func topBar(_ l: BoardLists) -> some View {
        HStack(spacing: z(14)) {
            SummaryRow(lists: l)
            Spacer()
            if !board.showActions { ActivityButton(showing: showActivity, label: true) { showActivity.toggle() } }
            Button { withAnimation(.snappy(duration: 0.2)) { board.showActions.toggle() } } label: {
                Text(board.showActions ? "Board" : "Quick actions").font(ui(12, .medium)).foregroundStyle(T.text2)
            }
            .buttonStyle(HoverButtonStyle.header).pointerOnly()
            .help(board.showActions ? "Back to the board" : "Edit the quick actions and where they show")
            NewAgentButton(label: true)
            UpdatedStamp(prefix: "Updated ")
            RefreshButton()
            MoreButton(owner: "header-window", size: CGSize(width: z(24), height: z(24)))
        }
        .padding(.horizontal, z(16)).frame(height: z(40))
        .contentShape(Rectangle())
        .menuTarget("header-window")
        .menuViewport("header-window")
    }
}
