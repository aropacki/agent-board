import AppKit
import SwiftUI

/// The file's name bar. It stays pinned while its lines scroll under it.
struct DiffFileHeader: View, Zoomed {
    @Environment(\.zoom) var zoom
    let file: DiffFile
    /// Where the agent's review puts this file in its explanation.
    let step: (step: Int, note: String?)?
    let threads: Int
    let folded: Bool
    let reviewed: Bool
    let toggle: () -> Void
    let markReviewed: (Bool) -> Void

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: z(8), bottomLeadingRadius: folded ? z(8) : 0,
                                           bottomTrailingRadius: folded ? z(8) : 0, topTrailingRadius: z(8), style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: z(3)) {
                HStack(spacing: z(6)) {
                    Image(systemName: "chevron.right").font(.system(size: z(9), weight: .semibold)).foregroundStyle(T.text3)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    if let step { Text(verbatim: "\(step.step)").font(mono(10.5)).foregroundStyle(T.blue.opacity(0.9)) }
                    HStack(spacing: 0) {
                        let dir = (file.path as NSString).deletingLastPathComponent
                        if !dir.isEmpty { Text(dir + "/").foregroundStyle(T.text3) }
                        Text((file.path as NSString).lastPathComponent).foregroundStyle(reviewed ? T.text2 : T.text)
                    }
                    .font(mono(11)).lineLimit(1).truncationMode(.head)
                    if file.status != "modified" { Text(file.status).font(ui(10.5)).foregroundStyle(T.text3) }
                    if let previous = file.previousPath {
                        Text("from " + previous).font(ui(10.5)).foregroundStyle(T.text3).lineLimit(1).truncationMode(.head)
                    }
                    if file.generated { Text("generated").font(ui(10.5)).foregroundStyle(T.text3) }
                    if threads > 0 {
                        HStack(spacing: z(3)) {
                            Image(systemName: "bubble.left").font(.system(size: z(9)))
                            Text(verbatim: "\(threads)").font(mono(10))
                        }
                        .foregroundStyle(T.text3)
                    }
                    Spacer(minLength: z(6))
                    DiffCounts(file: file)
                }
                if let note = step?.note, !note.isEmpty, !reviewed {
                    Text(note).font(ui(11.5)).foregroundStyle(T.text3).padding(.leading, z(15)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, z(10)).padding(.trailing, z(8)).padding(.vertical, z(7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .pointerStyle(.link)
            TapTarget(padH: 4, padV: 1.5, hover: 0.045, radius: 4, wide: false, action: { markReviewed(!reviewed) }) {
                HStack(spacing: z(4)) {
                    Image(systemName: reviewed ? "checkmark.circle.fill" : "circle").font(.system(size: z(11)))
                        .foregroundStyle(reviewed ? T.green : T.text3)
                    Text("Reviewed").font(ui(11)).foregroundStyle(reviewed ? T.text2 : T.text3)
                }
            }
            .padding(.top, z(5)).padding(.trailing, z(6))
        }
        .background { shape.fill(T.raised); shape.fill(Color.black.opacity(0.18)) }
        .overlay(CardEdge(top: true, bottom: folded, radius: z(8)).stroke(T.border))
        .overlay(alignment: .bottom) { if !folded { Rectangle().fill(T.border).frame(height: 1) } }
    }
}

/// A run of one file's lines with their notes in the margin; a file draws as several, so only the ones on screen exist.
/// A drag across line rows picks lines for a comment; ⇧-click extends the pick.
/// Equatable on its data, so a board update that leaves these lines alone skips them.
/// Board state it reads, like the selection, still updates it through observation.
struct DiffChunkView: View, Zoomed, Equatable {
    static func == (a: DiffChunkView, b: DiffChunkView) -> Bool {
        a.rows == b.rows && a.last == b.last && a.stamp == b.stamp && a.numWidth == b.numWidth && a.pr == b.pr
            && a.threads == b.threads && a.ghosts == b.ghosts
    }

    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let file: DiffFile
    let rows: Range<Int>
    let last: Bool
    /// Changes with the file's diff; row heights are measured again when it does.
    let stamp: String
    let numWidth: CGFloat
    let threads: [ReviewThread]
    let ghosts: [AgentReview.Comment]
    @Binding var draft: String
    @State private var frames = DiffRowFrames()
    /// This chunk's drag started on its code, so its moves extend the pick.
    @State private var picking = false
    /// The note under the pointer; its lines light up.
    @State private var lit: String?

    var space: String { "diff-\(file.path)#\(rows.lowerBound)" }

    enum Note {
        case thread(ReviewThread)
        case ghost(AgentReview.Comment)
        case composer(DiffSelection)
    }

    struct Placed: Identifiable {
        let id: String
        let note: Note
        let span: ClosedRange<Int>?
    }

    /// Notes in the order they stack: by their first row, the ones off the diff first.
    func notes(_ selection: DiffSelection?) -> [Placed] {
        var out = threads.map { Placed(id: "t-" + $0.id, note: .thread($0), span: threadSpan($0, in: file)) }
        out += ghosts.map { Placed(id: "g-" + $0.id, note: .ghost($0), span: ghostSpan($0, in: file)) }
        if let selection, !board.diffDragging, rows.contains(selection.range.lowerBound) {
            out.append(Placed(id: "compose", note: .composer(selection), span: selection.range))
        }
        return out.sorted { ($0.span?.lowerBound ?? -1, $0.span?.upperBound ?? -1, $0.id) < ($1.span?.lowerBound ?? -1, $1.span?.upperBound ?? -1, $1.id) }
    }

    func isOpen(_ id: String) -> Bool { board.diffOpenNotes.contains(file.path + "|" + id) }

    var body: some View {
        let selection = board.diffSelection?.path == file.path ? board.diffSelection : nil
        let placed = notes(selection)
        let spans = placed.map(\.span)
        let flash = board.diffFlash
        let lit = placed.first { $0.id == self.lit } ?? placed.first { $0.id == flash }
        var bands: [Int: Color] = [:]
        for p in placed where p.span != nil && !isSettled(p) { for i in p.span! { bands[i] = tint(p) } }
        let paints = rows.compactMap { i in
            paint(i, picked: selection?.range.contains(i) == true, lit: lit?.span?.contains(i) == true ? tint(lit!) : nil, band: bands[i])
        }
        let numbers = rows.compactMap { i -> RowPaint.Number? in
            let line = file.lines[i]
            guard line.kind != .hunk, let n = line.new ?? line.old else { return nil }
            return .init(row: i, text: String(n), color: line.kind == .delete ? T.red.opacity(0.5) : T.text3.opacity(0.55))
        }
        return MarginLayout(spans: spans, lanes: marginLanes(spans), margin: z(260)...z(380), lane: z(7), gutter: z(14),
                            gap: z(6), tetherDrop: z(14), stamp: stamp + "|\(zoom)", rowFrames: frames) {
            RowPaint(paints: paints, numbers: numbers, frames: frames, bar: z(2),
                     numberEdge: CGPoint(x: z(6) + numWidth, y: z(1.5)), numberFont: mono(10.5))
                .layoutValue(key: MarginPartKey.self, value: .paint)
            ForEach(rows, id: \.self) { i in
                let line = file.lines[i]
                if line.kind != .hunk || i > 0 || hunkGap(file.lines, at: i) > 0 {
                    row(i, line)
                        .layoutValue(key: MarginPartKey.self, value: .row(i))
                }
            }
            ForEach(Array(placed.enumerated()), id: \.element.id) { k, p in
                let on = self.lit == p.id || flash == p.id
                note(p)
                    .trackHover { inside in
                        if inside { self.lit = p.id } else if self.lit == p.id { self.lit = nil }
                    }
                    .layoutValue(key: MarginPartKey.self, value: .note(k))
                if p.span != nil {
                    CloseBracket().stroke(tint(p).opacity(on ? 1 : isSettled(p) ? 0.5 : 0.85), lineWidth: on ? 2 : 1.5)
                        .allowsHitTesting(false)
                        .layoutValue(key: MarginPartKey.self, value: .bracket(k))
                    Tether().stroke(tint(p).opacity(on ? 0.9 : 0.4), lineWidth: 1)
                        .allowsHitTesting(false)
                        .layoutValue(key: MarginPartKey.self, value: .tether(k))
                }
            }
        }
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { drag($0) }
                    .onEnded { _ in finishPick() })
        }
        .coordinateSpace(.named(space))
        .padding(.top, rows.lowerBound == 0 ? z(4) : 0).padding(.bottom, last ? z(4) : 0).padding(.trailing, z(10))
        .background(Color.black.opacity(0.18))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: last ? z(8) : 0, bottomTrailingRadius: last ? z(8) : 0, style: .continuous))
        .overlay(CardEdge(top: false, bottom: last, radius: z(8)).stroke(T.border))
    }

    /// Resolved threads keep their bracket but give up the band on their lines.
    func isSettled(_ p: Placed) -> Bool {
        if case .thread(let t) = p.note { return t.resolved }
        return false
    }

    func setOpen(_ id: String, _ open: Bool) {
        let key = file.path + "|" + id
        withAnimation(.snappy(duration: 0.15)) { if open { board.diffOpenNotes.insert(key) } else { board.diffOpenNotes.remove(key) } }
    }

    func tint(_ p: Placed) -> Color {
        switch p.note {
        case .thread(let t): return T.text.opacity(t.resolved ? 0.3 : 0.6)
        case .ghost(let g): return severityColor(g.severity)
        case .composer: return T.blue
        }
    }

    @ViewBuilder func note(_ p: Placed) -> some View {
        switch p.note {
        case .thread(let t): thread(t, open: isOpen(p.id)) { setOpen(p.id, $0) }
        case .ghost(let g): GhostComment(pr: pr, comment: g, placed: p.span != nil, folded: !isOpen(p.id)) { setOpen(p.id, !$0) }
        case .composer(let s): composer(s)
        }
    }

    func row(_ i: Int, _ line: DiffLine) -> some View {
        Group {
            if line.kind == .hunk {
                let gap = hunkGap(file.lines, at: i), context = hunkContext(line.text)
                HStack(spacing: z(10)) {
                    Text(verbatim: "⋯").frame(width: numWidth, alignment: .trailing)
                    if gap > 0 { Text(gap == 1 ? "1 unchanged line" : "\(gap) unchanged lines").font(ui(10.5)) }
                    if !context.isEmpty { Text(context).font(mono(10)).lineLimit(1).truncationMode(.tail) }
                }
                .font(mono(10.5))
                .foregroundStyle(T.text3.opacity(0.8))
                .padding(.vertical, z(5)).padding(.leading, z(6))
            } else {
                Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.kind == .context ? T.text2 : T.text)
                    .font(mono(10.5))
                    .lineSpacing(z(1.5))
                    .padding(EdgeInsets(top: z(1.5), leading: z(6) + numWidth + z(12), bottom: z(1.5), trailing: z(8)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .id(line.new.map { "\(file.path)#\($0)" } ?? "\(file.path)@\(i)")
    }

    /// The row's fill and edge mark, or nil when it draws neither.
    func paint(_ i: Int, picked: Bool, lit: Color?, band: Color?) -> RowPaint.Paint? {
        if picked { return .init(row: i, fill: T.blue.opacity(0.16), edge: T.blue.opacity(0.85)) }
        let kind = file.lines[i].kind
        let quiet = file.status == "added"
        let edge: Color? = quiet ? nil : kind == .add ? T.green.opacity(0.6) : kind == .delete ? T.red.opacity(0.6) : nil
        let fill: Color? = if let lit { lit.opacity(0.12) } else if let band { band.opacity(0.045) }
            else if quiet { nil } else if kind == .add { T.green.opacity(0.06) } else if kind == .delete { T.red.opacity(0.07) } else { nil }
        return fill == nil && edge == nil ? nil : .init(row: i, fill: fill, edge: edge)
    }

    /// Keeps the pick on comment-able lines in the hunk where it started.
    func clamp(_ i: Int, hunk: Int) -> Int? {
        let inHunk = file.lines.indices.filter { file.lines[$0].hunk == hunk && file.lines[$0].kind != .hunk }
        guard let first = inHunk.first, let last = inHunk.last else { return nil }
        return min(max(i, first), last)
    }

    /// The drag surface sits under the rows; a drag that starts in the margin is left to the notes.
    func drag(_ value: DragGesture.Value) {
        if !picking {
            guard value.startLocation.x <= frames.codeWidth, let start = frames.row(at: value.startLocation.y) else { return }
            picking = true
            board.diffDragging = true
            pick(from: start, to: nil)
        } else {
            pick(from: nil, to: frames.row(at: value.location.y))
        }
    }

    func pick(from start: Int?, to over: Int?) {
        if let start {
            let current = board.diffSelection
            if NSEvent.modifierFlags.contains(.shift), let current, current.path == file.path,
               let head = clamp(start, hunk: file.lines[current.anchor].hunk) {
                board.diffSelection?.head = head
            } else if let anchor = clamp(start, hunk: file.lines[start].hunk) {
                board.diffSelection = DiffSelection(path: file.path, anchor: anchor, head: anchor)
            }
            return
        }
        guard let over, let s = board.diffSelection, s.path == file.path,
              let head = clamp(over, hunk: file.lines[s.anchor].hunk), head != s.head else { return }
        board.diffSelection?.head = head
    }

    func finishPick() {
        guard picking else { return }
        picking = false
        board.diffDragging = false
        if board.diffSelection?.path == file.path { board.diffComposerFocus += 1 }
    }

    func composer(_ s: DiffSelection) -> some View {
        let picked = Array(file.lines[s.range]).filter { $0.kind != .hunk }
        let first = picked.first?.anchor?.line, last = picked.last?.anchor?.line
        let label = first == last ? "line \(last ?? 0)" : "lines \(first ?? 0)–\(last ?? 0)"
        return VStack(alignment: .leading, spacing: z(6)) {
            HStack(spacing: z(6)) {
                Text("Comment on \(label)").font(ui(11, .medium)).foregroundStyle(T.text2)
                Spacer(minLength: 0)
                Button { board.diffSelection = nil } label: {
                    Text("Cancel").font(ui(11)).foregroundStyle(T.text3)
                }
                .buttonStyle(HoverButtonStyle.link).pointerOnly()
            }
            InlineComposer(text: $draft, placeholder: "Comment on \(label)…", focusToken: board.diffComposerFocus) { body, _, done in
                board.commentOnDiff(pr, file: file, lines: picked, body: body) { ok in
                    if ok { draft = "" }
                    done(ok)
                }
            }
        }
        .padding(z(10))
        .background(T.raised, in: RoundedRectangle(cornerRadius: z(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(8), style: .continuous).strokeBorder(T.blue.opacity(0.5)))
    }

    /// Folded, a resolved thread is one line and an open one is its first comment's opening lines.
    func thread(_ t: ReviewThread, open: Bool, setOpen: @escaping (Bool) -> Void) -> some View {
        let card = RoundedRectangle(cornerRadius: z(8), style: .continuous)
        return Group {
            if t.resolved && !open {
                ResolvedThreadRow(thread: t, showFile: false) { setOpen(true) }
            } else if !open, let first = t.comments.first {
                Button { setOpen(true) } label: {
                    VStack(alignment: .leading, spacing: z(5)) {
                        author(first) {
                            if t.comments.count > 1 {
                                Text(t.comments.count == 2 ? "1 reply" : "\(t.comments.count - 1) replies").font(ui(11)).foregroundStyle(T.text3)
                            }
                        }
                        CommentBody(text: first.body, dim: first.bot, preview: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerOnly()
                .help("Show the whole thread")
                .padding(z(10))
                .background(T.raised, in: card)
                .overlay(card.strokeBorder(T.border))
            } else {
                VStack(alignment: .leading, spacing: z(10)) {
                    ForEach(t.comments) { c in
                        VStack(alignment: .leading, spacing: z(4)) {
                            author(c) {
                                if c.id == t.comments.first?.id {
                                    Button { setOpen(false) } label: { Text("Fold").font(ui(11)).foregroundStyle(T.text3) }
                                        .buttonStyle(HoverButtonStyle.link).pointerOnly()
                                }
                            }
                            CommentBody(text: c.body, dim: c.bot)
                        }
                    }
                    ThreadReplyBar(pr: pr, thread: t)
                }
                .padding(z(10))
                .background(T.raised, in: card)
                .overlay(card.strokeBorder(T.border))
            }
        }
    }

    func author<Trailing: View>(_ c: ThreadComment, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: z(6)) {
            Avatar(login: c.author, size: 16)
            Text(c.author).font(ui(11.5, .semibold)).foregroundStyle(T.text2).lineLimit(1)
            Ago(date: c.at, size: 10)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// Every row's fill and edge mark in one drawing behind the rows, so a row is only its text.
struct RowPaint: View {
    struct Paint: Equatable {
        let row: Int
        let fill: Color?
        let edge: Color?
    }

    struct Number {
        let row: Int
        let text: String
        let color: Color
    }

    let paints: [Paint]
    /// Drawn here rather than as a view per line, which costs as much again as the code beside it.
    let numbers: [Number]
    /// Read while drawing: layout has placed the rows by then.
    let frames: DiffRowFrames
    let bar: CGFloat
    /// Where a number's top right corner sits inside its row.
    let numberEdge: CGPoint
    let numberFont: Font

    var body: some View {
        Canvas { context, _ in
            for p in paints {
                guard let f = frames.frames[p.row] else { continue }
                if let fill = p.fill { context.fill(Path(f), with: .color(fill)) }
                if let edge = p.edge { context.fill(Path(CGRect(x: f.minX, y: f.minY, width: bar, height: f.height)), with: .color(edge)) }
            }
            for n in numbers {
                guard let f = frames.frames[n.row] else { continue }
                context.draw(Text(verbatim: n.text).font(numberFont).foregroundStyle(n.color),
                             at: CGPoint(x: f.minX + numberEdge.x, y: f.minY + numberEdge.y), anchor: .topTrailing)
            }
        }
        .allowsHitTesting(false)
    }
}
