import AppKit
import SwiftUI

/// A PR's changed files over the page it was opened from. Escape or a click outside closes it.
struct DiffPopup: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    @AppStorage("diffShowGenerated") private var showGenerated = false
    @AppStorage("diffCommentsOpen") private var showComments = true
    @State private var toggled: Set<String> = []
    /// Bumped by each line button in the comments pane, so a second click on one thread scrolls back to it.
    @State private var revealed = 0
    /// The comments pane costs a few frames to build, so it waits out the popup's opening animation.
    @State private var paneReady = false
    @State private var width: CGFloat = 0
    @State private var jump: String?
    @State private var query = ""
    @State private var scroll = DiffScroll()

    var body: some View {
        if let target = board.diffOpen, let pr = board.pr(key: target.key) {
            card(pr, target)
                .onChange(of: board.diffDraft) { board.composing = !board.diffDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .onDisappear { board.composing = false }
                .task {
                    guard (try? await Task.sleep(for: .milliseconds(260))) != nil else { return }
                    withAnimation(Motion.content) { paneReady = true }
                }
        }
    }

    var draft: Binding<String> { Binding(get: { board.diffDraft }, set: { board.diffDraft = $0 }) }

    /// Generated and reviewed files start folded; others start open.
    func folded(_ f: DiffFile, _ pr: PR) -> Bool { toggled.contains(f.path) != (f.generated || board.isReviewed(pr, f)) }

    func toggle(_ f: DiffFile) {
        withAnimation(.snappy(duration: 0.15)) { if toggled.contains(f.path) { toggled.remove(f.path) } else { toggled.insert(f.path) } }
    }

    func setAllFolded(_ fold: Bool, _ files: [DiffFile], _ pr: PR) {
        withAnimation(.snappy(duration: 0.15)) { toggled = Set(files.filter { ($0.generated || board.isReviewed(pr, $0)) != fold }.map(\.path)) }
    }

    /// Folds a file as it is marked reviewed and brings the next one up under it.
    func markReviewed(_ pr: PR, _ f: DiffFile, _ on: Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            board.setReviewed(pr, f, on)
            toggled.remove(f.path)
        }
        if on { jump = f.path }
    }

    struct Piece: Identifiable {
        let id: String
        let rows: Range<Int>
        let last: Bool
        let threads: [ReviewThread]
        let ghosts: [AgentReview.Comment]
    }

    /// A file's lazy chunks, each with the notes that start on its rows; notes off the diff go in the first.
    /// The pick being dragged is left out, so a drag does not re-cut the file under the pointer.
    func pieces(_ f: DiffFile, threads: [ReviewThread], ghosts: [AgentReview.Comment]) -> [Piece] {
        let fileGhosts = ghosts.filter { $0.path == f.path }
        let threadSpans = threads.map { threadSpan($0, in: f) }, ghostSpans = fileGhosts.map { ghostSpan($0, in: f) }
        let picked = board.diffDragging ? nil : board.diffSelection.flatMap { $0.path == f.path ? $0.range : nil }
        let hunks = Set(f.lines.indices.filter { f.lines[$0].kind == .hunk })
        let chunks = diffChunks(f.lines.count, hunkStarts: hunks, spans: (threadSpans + ghostSpans).compactMap { $0 } + [picked].compactMap { $0 })
        func owner(_ span: ClosedRange<Int>?) -> Int { span.flatMap { s in chunks.firstIndex { $0.contains(s.lowerBound) } } ?? 0 }
        let threadOwners = threadSpans.map(owner), ghostOwners = ghostSpans.map(owner)
        return chunks.enumerated().map { k, rows in
            Piece(id: "\(f.path)#c\(rows.lowerBound)", rows: rows, last: k == chunks.count - 1,
                  threads: threads.indices.filter { threadOwners[$0] == k }.map { threads[$0] },
                  ghosts: fileGhosts.indices.filter { ghostOwners[$0] == k }.map { fileGhosts[$0] })
        }
    }

    /// A piece that is not drawn yet has no row ids to scroll to, so the first move lands on the piece and later ones on the row.
    func seek(_ p: Double, _ map: DiffRowMap, _ shown: [DiffFile], _ pr: PR, threads: [ReviewThread], ghosts: [AgentReview.Comment],
              _ proxy: ScrollViewProxy) {
        guard let (path, row) = map.locate(p), let f = shown.first(where: { $0.path == path }) else { return }
        guard row > 0, !folded(f, pr), !f.lines.isEmpty else { proxy.scrollTo(path, anchor: .top); return }
        guard let piece = pieces(f, threads: threads.filter { $0.path == path }, ghosts: ghosts).first(where: { $0.rows.contains(row) })
        else { return }
        guard scroll.seen[piece.id] != nil else { proxy.scrollTo(piece.id, anchor: .top); return }
        proxy.scrollTo(f.lines[row].new.map { "\(path)#\($0)" } ?? "\(path)@\(row)", anchor: .top)
    }

    /// A target on screen or near it glides there; a far one cuts, since a lazy stack can only glide to rows it has drawn.
    /// The row lands a third of the way down, so the note level with it shows under the pinned file header.
    func reveal(_ target: DiffTarget, _ shown: [DiffFile], _ pr: PR, threads: [ReviewThread], ghosts: [AgentReview.Comment],
                _ proxy: ScrollViewProxy) async {
        guard let path = target.path, let f = shown.first(where: { $0.path == path }) else { return }
        let thread = target.thread.flatMap { id in threads.first { $0.id == id } }
        let row = thread.flatMap { threadSpan($0, in: f)?.lowerBound } ?? target.line.flatMap { l in f.lines.firstIndex { $0.new == l } }
        if row != nil && folded(f, pr) {
            if toggled.contains(f.path) { toggled.remove(f.path) } else { toggled.insert(f.path) }
        }
        guard (try? await Task.sleep(for: .milliseconds(60))) != nil else { return }
        guard let row, let piece = pieces(f, threads: threads.filter { $0.path == path }, ghosts: ghosts).first(where: { $0.rows.contains(row) })
        else { withAnimation(Motion.content) { proxy.scrollTo(path, anchor: .top) }; return }
        let id = f.lines[row].new.map { "\(path)#\($0)" } ?? "\(path)@\(row)"
        let spot = UnitPoint(x: 0, y: 0.3)
        if let drawn = scroll.seen[piece.id]?.frame, drawn.maxY > -scroll.viewport, drawn.minY < 2 * scroll.viewport {
            withAnimation(Motion.content) { proxy.scrollTo(id, anchor: spot) }
        } else {
            proxy.scrollTo(piece.id, anchor: .top)
            guard (try? await Task.sleep(for: .milliseconds(30))) != nil else { return }
            proxy.scrollTo(id, anchor: spot)
        }
        guard let thread else { return }
        let flash = "t-" + thread.id
        board.diffFlash = flash
        guard (try? await Task.sleep(for: .milliseconds(1200))) != nil else { return }
        if board.diffFlash == flash { withAnimation(.easeOut(duration: 0.4)) { board.diffFlash = nil } }
    }

    func lineNumberWidth(_ f: DiffFile) -> CGFloat {
        z(7) * CGFloat(max(2, String(f.lines.compactMap { $0.new ?? $0.old }.max() ?? 0).count))
    }

    func card(_ pr: PR, _ target: DiffTarget) -> some View {
        let diff = board.diffs[pr.key]
        let review = board.review(for: pr)
        let files = explainedOrder(diff?.files ?? [], review)
        let unfiltered = showGenerated ? files : files.filter { !$0.generated }
        let shown = unfiltered.filter { matchesFileQuery($0.path, query) }
        let threads = (board.discussions[pr.key]?.threads ?? []).filter { !$0.outdated }
        let ghosts = (review?.comments ?? []).filter(\.open)
        let notes = Dictionary((review?.files ?? []).enumerated().map { ($1.path, (step: $0 + 1, note: $1.note)) }) { a, _ in a }
        let map = DiffRowMap(shown.map { (path: $0.path, rows: folded($0, pr) ? 0 : max(1, $0.lines.count)) })
        return VStack(spacing: 0) {
            header(pr, files, shown: shown, counted: unfiltered)
            Rectangle().fill(T.border).frame(height: 1)
            if diff == nil {
                VStack(spacing: z(8)) {
                    if let error = board.diffErrors[pr.key] {
                        Text(error).font(ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center)
                        QuietButton(title: "Try again", icon: "arrow.clockwise") { board.loadDiff(pr, explicit: true) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if width > z(760) + (showComments ? z(380) : 0) {
                        fileList(pr, shown, notes: notes, threads: threads, ghosts: ghosts) { jump = $0 }
                        Rectangle().fill(T.border).frame(width: 1)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                if let review {
                                    ReviewSummaryCard(pr: pr, review: review, headSha: diff?.sha).padding(.bottom, z(10))
                                } else if let error = board.reviewErrors[reviewFileName(pr)] {
                                    Text(error).font(ui(11.5)).foregroundStyle(T.text3).padding(.bottom, z(10))
                                }
                                if shown.isEmpty {
                                    Text(files.isEmpty ? "No changed files." : !query.isEmpty ? "No file matches “\(query)”." : "Only generated files changed.")
                                        .font(ui(12)).foregroundStyle(T.text3).frame(maxWidth: .infinity).padding(.top, z(40))
                                }
                                ForEach(shown) { f in
                                    let fileThreads = threads.filter { $0.path == f.path }
                                    Section {
                                        if !folded(f, pr) {
                                            if f.lines.isEmpty {
                                                NoPatch()
                                            } else {
                                                let stamp = f.stamp, numWidth = lineNumberWidth(f), start = map.start(f.path) ?? 0
                                                ForEach(pieces(f, threads: fileThreads, ghosts: ghosts)) { piece in
                                                    DiffChunkView(pr: pr, file: f, rows: piece.rows, last: piece.last, stamp: stamp, numWidth: numWidth,
                                                                  threads: piece.threads, ghosts: piece.ghosts, draft: draft)
                                                        .equatable()
                                                        .id(piece.id)
                                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: {
                                                            scroll.saw(piece.id, start: start + Double(piece.rows.lowerBound), rows: piece.rows.count, frame: $0)
                                                        }
                                                        .onDisappear { scroll.saw(piece.id, start: 0, rows: 0, frame: nil) }
                                                }
                                            }
                                        }
                                    } header: {
                                        DiffFileHeader(file: f, step: notes[f.path], threads: fileThreads.count, folded: folded(f, pr),
                                                       reviewed: board.isReviewed(pr, f), toggle: { toggle(f) },
                                                       markReviewed: { markReviewed(pr, f, $0) })
                                            .id(f.path)
                                    } footer: {
                                        Color.clear.frame(height: z(10))
                                    }
                                }
                            }
                            .padding(z(10)).padding(.bottom, z(40))
                        }
                        .scrollIndicators(.never)
                        .onScrollGeometryChange(for: Int.self) { g in
                            g.visibleRect.minY <= 1 ? -1 : g.visibleRect.maxY >= g.contentSize.height - 1 ? 1 : 0
                        } action: { _, edge in scroll.edge = edge }
                        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, h in scroll.viewport = h }
                        .overlay(alignment: .trailing) {
                            DiffScrollbar(scroll: scroll, total: map.total) { row in
                                seek(row, map, shown, pr, threads: threads, ghosts: ghosts, proxy)
                            }
                        }
                        .onChange(of: jump) { _, path in
                            guard let path else { return }
                            proxy.scrollTo(path, anchor: .top)
                            jump = nil
                        }
                        .task(id: "\(target.path ?? "")|\(target.line ?? 0)|\(target.thread ?? "")|\(diff != nil)|\(revealed)") {
                            await reveal(target, shown, pr, threads: threads, ghosts: ghosts, proxy)
                        }
                    }
                    if showComments {
                        HStack(spacing: 0) {
                            Rectangle().fill(T.border).frame(width: 1)
                            ZStack {
                                if paneReady {
                                    DiscussionView(pr: pr) { t in
                                        board.diffOpen = DiffTarget(key: pr.key, path: t.path, line: t.line, thread: t.id)
                                        revealed += 1
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .frame(width: z(380))
                            .frame(maxHeight: .infinity)
                        }
                        .transition(.slide(.trailing))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.raised)
        .clipShape(RoundedRectangle(cornerRadius: z(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(12), style: .continuous).strokeBorder(T.border))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .menuViewport("cover-diff")
    }

    func header(_ pr: PR, _ files: [DiffFile], shown: [DiffFile], counted: [DiffFile]) -> some View {
        let generated = files.filter(\.generated).count
        let added = files.reduce(0) { $0 + $1.additions }, removed = files.reduce(0) { $0 + $1.deletions }
        let allFolded = !shown.isEmpty && shown.allSatisfy { folded($0, pr) }
        let reviewed = counted.filter { board.isReviewed(pr, $0) }.count
        return HStack(alignment: .center, spacing: z(8)) {
            VStack(alignment: .leading, spacing: z(2)) {
                Text(pr.displayTitle).font(ui(12.5, .semibold)).foregroundStyle(T.text).lineLimit(1)
                HStack(spacing: z(6)) {
                    Text(verbatim: "#\(pr.number)").font(mono(10.5)).foregroundStyle(T.text3)
                    if !files.isEmpty {
                        Text("\(files.count) files").font(ui(11)).foregroundStyle(T.text3)
                        Text(verbatim: "+\(added)").font(mono(10.5)).foregroundStyle(T.green.opacity(0.85))
                        Text(verbatim: "−\(removed)").font(mono(10.5)).foregroundStyle(T.red.opacity(0.85))
                    }
                    if reviewed > 0 {
                        Text(verbatim: "\(reviewed)/\(counted.count) reviewed").font(ui(11))
                            .foregroundStyle(reviewed == counted.count ? T.green.opacity(0.9) : T.text3)
                    }
                    if width > z(900) { Text("Drag across lines to comment").font(ui(11)).foregroundStyle(T.text3.opacity(0.8)) }
                }
            }
            Spacer(minLength: z(6))
            if board.review(for: pr) == nil, let item = board.reviewActions(pr).first {
                QuietButton(title: item.action.title, icon: "sparkles") { board.run(item.action, board.context(pr: pr), targets: item.targets) }
                    .help("Run “\(item.action.title)”; its findings show here as drafts")
            }
            let open = (board.discussions[pr.key]?.threads ?? []).filter { !$0.resolved }.count
            ToggleChip(title: open > 0 ? "Comments \(open)" : "Comments", icon: "text.bubble", on: showComments) {
                withAnimation(Motion.content) { showComments.toggle() }
            }
            .help(showComments ? "Hide the comments" : "Read the comments beside the diff")
            if generated > 0 {
                ToggleChip(title: "Generated \(generated)", icon: showGenerated ? "eye" : "eye.slash", on: showGenerated) {
                    withAnimation(.snappy(duration: 0.15)) { showGenerated.toggle() }
                }
                .help(showGenerated ? "Hide lockfiles, codegen output, and snapshots" : "Show lockfiles, codegen output, and snapshots")
            }
            DrawerIconButton(icon: allFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                             help: allFolded ? "Expand all files" : "Collapse all files") { setAllFolded(!allFolded, files, pr) }
            Button { board.loadDiff(pr, explicit: true) } label: {
                ZStack {
                    if board.diffLoading.contains(pr.key) { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .font(.system(size: z(11), weight: .medium)).foregroundStyle(T.text2).frame(width: z(16), height: z(16))
            }
            .buttonStyle(HoverButtonStyle.icon).pointerOnly()
            .help("Reload")
            DrawerIconButton(icon: "arrow.up.forward.square", help: "Open Files changed on GitHub") { board.openLink(pr.url + "/files") }
            DrawerIconButton(icon: "xmark", help: "Close (Esc)") { board.closeDiff() }
        }
        .padding(.horizontal, z(12)).padding(.vertical, z(9))
    }

    func fileList(_ pr: PR, _ files: [DiffFile], notes: [String: (step: Int, note: String?)], threads: [ReviewThread],
                  ghosts: [AgentReview.Comment], jump: @escaping (String) -> Void) -> some View {
        let talk = Dictionary(grouping: threads, by: \.path)
        return VStack(spacing: 0) {
            HStack(spacing: z(5)) {
                Image(systemName: "magnifyingglass").font(.system(size: z(10))).foregroundStyle(T.text3)
                TextField("Find a file", text: $query).textFieldStyle(.plain).font(ui(11.5)).foregroundStyle(T.text)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: z(10))).foregroundStyle(T.text3) }
                        .buttonStyle(.plain).pointerOnly()
                }
            }
            .padding(.horizontal, z(8)).padding(.vertical, z(5))
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: z(6), style: .continuous))
            .padding([.horizontal, .top], z(8)).padding(.bottom, z(2))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: z(1)) {
                ForEach(files) { f in
                    let drafts = ghosts.filter { $0.path == f.path }.count
                    let reviewed = board.isReviewed(pr, f)
                    TapTarget(action: { jump(f.path) }) {
                        HStack(alignment: .top, spacing: z(6)) {
                            if let step = notes[f.path]?.step {
                                Text(verbatim: "\(step)").font(mono(10)).foregroundStyle(T.blue.opacity(0.9)).frame(minWidth: z(12), alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: z(1)) {
                                HStack(spacing: z(4)) {
                                    Text((f.path as NSString).lastPathComponent).font(ui(11.5)).foregroundStyle(f.generated || reviewed ? T.text3 : T.text2).lineLimit(1)
                                    if reviewed { Image(systemName: "checkmark").font(.system(size: z(8.5), weight: .bold)).foregroundStyle(T.green.opacity(0.8)) }
                                }
                                Text((f.path as NSString).deletingLastPathComponent).font(ui(10)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: z(4))
                            VStack(alignment: .trailing, spacing: z(2)) {
                                DiffCounts(file: f)
                                if let fileThreads = talk[f.path] {
                                    let open = fileThreads.filter { !$0.resolved }.count
                                    HStack(spacing: z(2)) {
                                        Image(systemName: "text.bubble").font(.system(size: z(8)))
                                        Text(verbatim: "\(fileThreads.count)").font(mono(9.5))
                                    }
                                    .foregroundStyle(open > 0 ? T.text2 : T.text3.opacity(0.7))
                                    .help("\(fileThreads.count) threads, \(open) unresolved")
                                }
                                if drafts > 0 {
                                    HStack(spacing: z(2)) {
                                        Image(systemName: "sparkles").font(.system(size: z(8)))
                                        Text(verbatim: "\(drafts)").font(mono(9.5))
                                    }
                                    .foregroundStyle(T.text3)
                                }
                            }
                        }
                    }
                }
            }
            .padding(z(6))
        }
        .scrollIndicators(.never)
        }
        .frame(width: z(250))
    }
}

/// Every space-separated term appears in the path, case-insensitively.
func matchesFileQuery(_ path: String, _ query: String) -> Bool {
    let terms = query.lowercased().split(separator: " ")
    let p = path.lowercased()
    return terms.allSatisfy { p.contains($0) }
}

/// A file GitHub sends no patch for, like a binary or a very large diff.
struct NoPatch: View, Zoomed {
    @Environment(\.zoom) var zoom
    var body: some View {
        Text("GitHub shows no diff for this file.").font(ui(11.5)).foregroundStyle(T.text3).padding(z(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.18))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: z(8), bottomTrailingRadius: z(8), style: .continuous))
            .overlay(CardEdge(top: false, bottom: true, radius: z(8)).stroke(T.border))
    }
}
