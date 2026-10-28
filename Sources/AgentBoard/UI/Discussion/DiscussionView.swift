import AppKit
import SwiftUI

/// A PR's review threads and conversation, read in place: each thread shows the code it is on,
/// then its comments with replies nested under the first.
struct DiscussionView: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    /// Set beside the diff: the view then has no header of its own, and a thread's line button scrolls that diff.
    var showLine: ((ReviewThread) -> Void)? = nil
    @State private var tab: Tab? = Tab(rawValue: ProcessInfo.processInfo.environment["BENCH_DISCUSSION_TAB"] ?? "")
    @State private var expanded: Set<String> = []
    /// Reply text by thread id, and `prComment` for a new PR comment. Kept here so it survives rows scrolling away.
    @State private var drafts: [String: String] = DiscussionView.benchDrafts
    @State private var focusTokens: [String: Int] = [:]
    static let prComment = "pr-comment"

    static var benchDrafts: [String: String] {
        guard let raw = ProcessInfo.processInfo.environment["BENCH_DISCUSSION_DRAFT"] else { return [:] }
        let bits = raw.split(separator: "|", maxSplits: 1).map(String.init)
        return bits.count == 2 ? [bits[0]: bits[1]] : [:]
    }

    enum Tab: String, Hashable { case comments, conversation }

    /// Authors switched off in the filter chips, shared by both tabs and kept across PRs.
    @AppStorage("hiddenCommentAuthors") private var hiddenRaw = ""
    @State private var openResolved: Set<String> = []

    var hiddenAuthors: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        let d = board.discussions[pr.key]
        let threads = d?.threads ?? []
        let talk = d?.conversation ?? []
        let current = tab ?? (threads.isEmpty && !talk.isEmpty ? .conversation : .comments)
        let hidden = hiddenAuthors
        let authors = current == .comments ? authorCounts(threads.compactMap { $0.comments.first?.author }) : authorCounts(talk.map(\.author))
        let shownThreads = threads.filter { !hidden.contains($0.comments.first?.author ?? "") }
        let shownTalk = talk.filter { !hidden.contains($0.author) }
        VStack(alignment: .leading, spacing: 0) {
            if showLine == nil { header }
            HStack(spacing: z(4)) {
                tabButton("Comments", threads.filter { !$0.resolved }.count, .comments, current)
                tabButton("Conversation", talk.count, .conversation, current)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, z(10)).padding(.top, showLine == nil ? 0 : z(8)).padding(.bottom, z(8))
            if authors.count > 1 {
                FlowLayout(spacing: z(4)) {
                    ForEach(authors, id: \.name) { a in
                        AuthorChip(login: a.name, count: a.count, on: !hidden.contains(a.name)) {
                            toggleAuthor(a.name, solo: NSEvent.modifierFlags.contains(.option), among: authors.map(\.name))
                        }
                    }
                }
                .padding(.horizontal, z(10)).padding(.bottom, z(8))
            }
            Rectangle().fill(T.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: z(12)) {
                    if d == nil {
                        if let error = board.discussionErrors[pr.key] {
                            note(error, retry: true)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, z(40))
                        }
                    } else {
                        switch current {
                        case .comments:
                            if threads.isEmpty { note("No review threads.") } else if shownThreads.isEmpty { note("Every author is filtered out.") }
                            ForEach(shownThreads) { t in
                                if t.resolved && !openResolved.contains(t.id) {
                                    ResolvedThreadRow(thread: t) { withAnimation(.snappy(duration: 0.15)) { _ = openResolved.insert(t.id) } }
                                } else {
                                    thread(t)
                                }
                            }
                        case .conversation:
                            if talk.isEmpty { note("No comments yet.") } else if shownTalk.isEmpty { note("Every author is filtered out.") }
                            ForEach(shownTalk) { conversationComment($0) }
                        }
                    }
                }
                .padding(.horizontal, z(10)).padding(.top, z(10)).padding(.bottom, z(current == .conversation ? 12 : 60))
            }
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.automatic)
            .id("\(current)|\(d != nil)")
            if d != nil && current == .conversation {
                Rectangle().fill(T.border).frame(height: 1)
                InlineComposer(text: draft(DiscussionView.prComment), placeholder: "Comment on #\(pr.number)…",
                               focusToken: focusTokens[DiscussionView.prComment] ?? 0) { body, _, done in
                    board.reply(pr, threadID: nil, body: body) { ok in
                        if ok { drafts[DiscussionView.prComment] = nil }
                        done(ok)
                    }
                }
                .padding(z(10))
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            board.openLink(url.absoluteString)
            return .handled
        })
        .onChange(of: drafts) {
            board.composing = drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        .onDisappear { board.composing = false }
    }

    var surface: String { board.discussion?.surface ?? "panel" }

    /// ⌥-click shows only that author, and ⌥-click on the only one shown brings everyone back.
    func toggleAuthor(_ name: String, solo: Bool, among names: [String]) {
        var hidden = hiddenAuthors
        if solo {
            let others = Set(names).subtracting([name])
            if others.isSubset(of: hidden) && !hidden.contains(name) { hidden.subtract(others) } else { hidden.formUnion(others); hidden.remove(name) }
        } else if hidden.contains(name) {
            hidden.remove(name)
        } else {
            hidden.insert(name)
        }
        withAnimation(.snappy(duration: 0.15)) { hiddenRaw = hidden.sorted().joined(separator: ",") }
    }

    func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0.isEmpty ? nil : $0 })
    }

    /// Starts a PR comment that quotes `c`, in the Conversation tab's composer.
    func quote(_ c: ThreadComment) {
        let existing = (drafts[DiscussionView.prComment] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[DiscussionView.prComment] = (existing.isEmpty ? "" : existing + "\n\n") + quoteOpening(c.body)
        withAnimation(.snappy(duration: 0.15)) { tab = .conversation }
        focusTokens[DiscussionView.prComment, default: 0] += 1
    }

    var header: some View {
        PRDrawerHeader(pr: pr, loading: board.discussionLoading.contains(pr.key), back: board.closeDiscussion,
                       reload: { board.loadDiscussion(pr, explicit: true) }) {
            DrawerIconButton(icon: "plusminus", help: "Show the diff") { board.openDiff(pr) }
            DrawerIconButton(icon: "arrow.up.forward.square", help: "Open on GitHub") { board.openLink(pr.threadURL) }
        }
    }

    func tabButton(_ title: String, _ count: Int, _ value: Tab, _ current: Tab) -> some View {
        DrawerTab(title: title, count: count, on: value == current) { withAnimation(.snappy(duration: 0.15)) { tab = value } }
    }

    func note(_ text: String, retry: Bool = false) -> some View {
        VStack(spacing: z(8)) {
            Text(text).font(ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center)
            if retry { QuietButton(title: "Try again", icon: "arrow.clockwise") { board.loadDiscussion(pr, explicit: true) } }
        }
        .frame(maxWidth: .infinity).padding(.top, z(40))
    }

    func thread(_ t: ReviewThread) -> some View {
        let file = (t.path as NSString).lastPathComponent
        let ctx = board.context(pr, thread: t)
        let actions = board.applicable(on: ctx, buttons: true)
        return VStack(alignment: .leading, spacing: z(12)) {
            HStack(spacing: z(5)) {
                Button { if let showLine { showLine(t) } else { board.openDiff(pr, path: t.path, line: t.line, thread: t.id) } } label: {
                    HStack(spacing: z(5)) {
                        Image(systemName: "doc.text").font(.system(size: z(10))).foregroundStyle(T.text3)
                        Text(file).font(mono(11)).foregroundStyle(T.text2).lineLimit(1)
                        if let line = t.line { Text(verbatim: ":\(line)").font(mono(11)).foregroundStyle(T.text3) }
                    }
                }
                .buttonStyle(HoverButtonStyle.link).pointerOnly()
                .help("\(t.path)\nShow this line in the diff")
                if t.outdated { Text("outdated").font(ui(10.5)).foregroundStyle(T.yellow.opacity(0.75)) }
                Spacer(minLength: z(4))
                if t.resolved {
                    Button { withAnimation(.snappy(duration: 0.15)) { _ = openResolved.remove(t.id) } } label: {
                        Text("Fold").font(ui(11)).foregroundStyle(T.text3)
                    }
                    .buttonStyle(HoverButtonStyle.link).pointerOnly()
                }
                ResolveButton(pr: pr, thread: t)
            }
            if !t.context.isEmpty { HunkView(lines: t.context, highlighted: t.highlighted) }
            VStack(alignment: .leading, spacing: z(14)) {
                if let first = t.comments.first { comment(first, avatar: 20) }
                let replies = Array(t.comments.dropFirst())
                if !replies.isEmpty {
                    VStack(alignment: .leading, spacing: z(14)) {
                        ForEach(replies) { comment($0, avatar: 18) }
                    }
                    .padding(.leading, z(13))
                    .overlay(alignment: .leading) { Rectangle().fill(T.text.opacity(0.12)).frame(width: 1) }
                    .padding(.leading, z(10))
                }
            }
            InlineComposer(text: draft(t.id), placeholder: "Reply…", resolves: !t.resolved, focusToken: focusTokens[t.id] ?? 0) { body, resolve, done in
                board.reply(pr, threadID: t.id, body: body) { ok in
                    if ok {
                        drafts[t.id] = nil
                        if resolve { board.setResolved(pr, t, true) }
                    }
                    done(ok)
                }
            }
            if !actions.isEmpty { QuickActionChips(context: ctx, items: actions) }
        }
        .padding(z(12))
        .rowSurface(interactive: false, resting: true)
        .opacity(t.resolved ? 0.75 : 1)
    }

    func conversationComment(_ c: ThreadComment) -> some View {
        let ctx = board.context(pr, comment: c)
        return VStack(alignment: .leading, spacing: z(10)) {
            comment(c, avatar: 20)
            FlowLayout(spacing: z(20)) {
                ActionChip(title: "Quote", key: "quote-\(c.id)") { quote(c) }
                ForEach(board.applicable(on: ctx, buttons: true)) { item in
                    ActionChip(title: item.action.title, key: board.actionKey(item.action, ctx)) {
                        board.run(item.action, ctx, targets: item.targets)
                    }
                }
            }
        }
        .padding(z(12))
        .rowSurface(interactive: false, resting: true)
    }

    /// Bot comments start folded to a few lines; a click unfolds them.
    func comment(_ c: ThreadComment, avatar: CGFloat) -> some View {
        let foldable = c.bot && (c.body.count > 160 || c.body.contains("```"))
        let folded = foldable && !expanded.contains(c.id)
        let mine = board.allPRs.first(where: \.mine)?.author == c.author
        return HStack(alignment: .top, spacing: z(9)) {
            Avatar(login: c.author, size: avatar)
            VStack(alignment: .leading, spacing: z(5)) {
                HStack(spacing: z(6)) {
                    Text(c.author).font(ui(12, .semibold)).foregroundStyle(mine ? T.blue : T.text2)
                    Ago(date: c.at)
                    if foldable {
                        Button { withAnimation(.snappy(duration: 0.15)) { if folded { expanded.insert(c.id) } else { expanded.remove(c.id) } } } label: {
                            Text(folded ? "Show all" : "Fold").font(ui(10.5)).foregroundStyle(T.text3)
                        }
                        .buttonStyle(HoverButtonStyle.link).pointerOnly()
                    }
                }
                CommentBody(text: c.body, dim: c.bot, preview: folded)
            }
        }
    }
}

/// The top of a PR drawer: back, the PR's title and facts, reload, then the drawer's own buttons.
struct PRDrawerHeader<Trailing: View>: View, Zoomed {
    @Environment(\.zoom) var zoom
    let pr: PR
    let loading: Bool
    let back: () -> Void
    let reload: () -> Void
    let trailing: Trailing

    init(pr: PR, loading: Bool, back: @escaping () -> Void, reload: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.pr = pr
        self.loading = loading
        self.back = back
        self.reload = reload
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: z(8)) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: z(11), weight: .semibold)).foregroundStyle(T.text2)
                    .frame(width: z(16), height: z(16))
            }
            .buttonStyle(HoverButtonStyle.icon).pointerOnly()
            .help("Back")
            VStack(alignment: .leading, spacing: z(2)) {
                Text(pr.displayTitle).font(ui(12.5, .semibold)).foregroundStyle(T.text).lineLimit(2)
                PRMeta(pr: pr)
            }
            Spacer(minLength: z(4))
            Button(action: reload) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .font(.system(size: z(11), weight: .medium)).foregroundStyle(T.text2).frame(width: z(16), height: z(16))
            }
            .buttonStyle(HoverButtonStyle.icon).pointerOnly()
            .help("Reload")
            trailing
        }
        .padding(.horizontal, z(10)).padding(.top, z(10)).padding(.bottom, z(8))
    }
}

struct DrawerIconButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: z(11.5), weight: .medium)).foregroundStyle(T.text2)
                .frame(width: z(16), height: z(16))
        }
        .buttonStyle(HoverButtonStyle.icon).pointerOnly()
        .help(help)
    }
}

struct DrawerTab: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: z(4)) {
                Text(title).font(ui(11.5, on ? .medium : .regular))
                Text(verbatim: "\(count)").font(mono(10.5)).foregroundStyle(T.text3)
            }
            .foregroundStyle(on ? T.text : T.text3)
        }
        .buttonStyle(HoverButtonStyle(padH: z(7), padV: z(3), rest: on ? 0.07 : 0, hover: on ? 0.07 : 0.04, press: 0.09)).pointerOnly()
    }
}
