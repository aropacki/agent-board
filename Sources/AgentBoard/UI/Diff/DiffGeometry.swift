import AppKit

/// The rows a comment covers, back from `line` to `startLine` inside one hunk; nil when the line is not in the diff.
func diffSpan(_ file: DiffFile, side: String, line: Int, startLine: Int?, startSide: String?) -> ClosedRange<Int>? {
    guard let end = file.lines.lastIndex(where: { $0.anchor?.side == side && $0.anchor?.line == line }) else { return nil }
    let startSide = startSide ?? side
    guard let startLine, startLine != line || startSide != side else { return end...end }
    let hunk = file.lines[end].hunk
    guard let start = file.lines[..<end].lastIndex(where: { $0.hunk == hunk && $0.anchor?.side == startSide && $0.anchor?.line == startLine })
    else { return end...end }
    return start...end
}

/// Nil when the draft's line is not in the diff, where GitHub can't take it inline.
func ghostSpan(_ c: AgentReview.Comment, in file: DiffFile) -> ClosedRange<Int>? {
    diffSpan(file, side: c.side ?? "RIGHT", line: c.line, startLine: c.startLine, startSide: c.startSide)
}

func threadSpan(_ t: ReviewThread, in file: DiffFile) -> ClosedRange<Int>? {
    t.line.flatMap { diffSpan(file, side: t.side ?? "RIGHT", line: $0, startLine: t.startLine, startSide: nil) }
}

/// Overlapping ranges get side-by-side brackets: each takes the first lane that is free where it starts.
func marginLanes(_ spans: [ClosedRange<Int>?]) -> [Int] {
    var laneEnds: [Int] = []
    var lanes = Array(repeating: 0, count: spans.count)
    let order = spans.indices.sorted { (spans[$0]?.lowerBound ?? -1, spans[$0]?.upperBound ?? -1) < (spans[$1]?.lowerBound ?? -1, spans[$1]?.upperBound ?? -1) }
    for i in order {
        guard let span = spans[i] else { continue }
        if let lane = laneEnds.firstIndex(where: { $0 < span.lowerBound }) {
            laneEnds[lane] = span.upperBound
            lanes[i] = lane
        } else {
            laneEnds.append(span.upperBound)
            lanes[i] = laneEnds.count - 1
        }
    }
    return lanes
}

/// Each note sits level with its lines unless the note above it runs past them; then it sits just under that note.
func stackedTops(anchors: [CGFloat], heights: [CGFloat], gap: CGFloat) -> [CGFloat] {
    var bottom = -CGFloat.infinity
    return zip(anchors, heights).map { anchor, height in
        let top = max(anchor, bottom + gap)
        bottom = top + height
        return top
    }
}

/// The diff measured in rows rather than points. The scroll view knows the height only of files it has drawn,
/// so a scrollbar in points jumps as files come into view; rows are known for every file up front.
struct DiffRowMap: Equatable {
    struct File: Equatable { let path: String; let start: Double; let rows: Int }
    /// What a file's header and the gap after it are worth in rows.
    static let header = 2.0, gap = 1.0
    let files: [File]
    let total: Double
    private let starts: [String: Double]

    init(_ files: [(path: String, rows: Int)]) {
        var at = 0.0
        self.files = files.map { f in
            defer { at += Self.header + Double(f.rows) + Self.gap }
            return File(path: f.path, start: at + Self.header, rows: f.rows)
        }
        total = at
        starts = Dictionary(self.files.map { ($0.path, $0.start) }) { a, _ in a }
    }

    func start(_ path: String) -> Double? { starts[path] }

    /// The file and row at position `p`; a position on a header or gap is the next file's first row.
    func locate(_ p: Double) -> (path: String, row: Int)? {
        guard let f = files.last(where: { $0.start - Self.header <= p }) ?? files.first else { return nil }
        let row = Int(p - f.start)
        if row >= f.rows, let next = files.first(where: { $0.start > f.start }) { return (next.path, 0) }
        return (f.path, min(max(0, row), max(0, f.rows - 1)))
    }
}

/// The row position of the viewport's top edge, read from the drawn piece that spans it, or else the one nearest it.
/// Frames are in the viewport's space, so a piece above the top has a negative `minY`.
func viewportRow(_ seen: [(start: Double, rows: Int, frame: CGRect)]) -> (row: Double, rowHeight: CGFloat)? {
    let drawn = seen.filter { $0.rows > 0 && $0.frame.height > 0 }
    guard let p = drawn.first(where: { $0.frame.minY <= 0 && $0.frame.maxY > 0 })
            ?? drawn.min(by: { abs($0.frame.minY) < abs($1.frame.minY) }) else { return nil }
    let rowHeight = p.frame.height / CGFloat(p.rows)
    return (p.start - Double(p.frame.minY / rowHeight), rowHeight)
}

/// A scrollbar thumb's top and height in a track of `track` points, for a viewport `visible` rows tall at row `top`.
func thumbFrame(top: Double, visible: Double, total: Double, track: CGFloat, minimum: CGFloat) -> (y: CGFloat, height: CGFloat) {
    let height = min(track, max(minimum, track * CGFloat(min(1, visible / max(1, total)))))
    let travel = max(0, total - visible)
    let f = travel > 0 ? min(1, max(0, top / travel)) : 0
    return (CGFloat(f) * (track - height), height)
}

/// The row a thumb dragged to `y` puts at the viewport's top.
func thumbRow(y: CGFloat, height: CGFloat, visible: Double, total: Double, track: CGFloat) -> Double {
    let span = track - height
    return span > 0 ? Double(min(1, max(0, y / span))) * max(0, total - visible) : 0
}

/// The function or block name GitHub puts after a hunk's line numbers.
func hunkContext(_ header: String) -> String {
    let parts = header.components(separatedBy: "@@")
    return parts.count > 2 ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces) : ""
}

func patchStamp(_ lines: [DiffLine]) -> String {
    var h: UInt64 = 5381
    for line in lines {
        h = h &* 33 &+ (line.kind == .add ? 1 : line.kind == .delete ? 2 : 3)
        for b in line.text.utf8 { h = h &* 33 &+ UInt64(b) }
    }
    return String(h, radix: 36) + "-\(lines.count)"
}

/// Row ranges a file draws as separate lazy pieces, so a long file builds only the rows on screen.
/// A piece runs at least `size` rows, ends at a hunk header when one is near, and never splits a note's rows.
func diffChunks(_ count: Int, hunkStarts: Set<Int>, spans: [ClosedRange<Int>], size: Int = 60) -> [Range<Int>] {
    guard count > 0 else { return [] }
    var covered = Array(repeating: false, count: count)
    for s in spans where s.lowerBound < s.upperBound {
        for i in (s.lowerBound + 1)...min(s.upperBound, count - 1) { covered[i] = true }
    }
    var out: [Range<Int>] = []
    var start = 0
    for i in 1..<count where !covered[i] {
        let length = i - start
        if length >= size && hunkStarts.contains(i) || length >= size * 2 {
            out.append(start..<i)
            start = i
        }
    }
    out.append(start..<count)
    return out
}

/// Unchanged lines GitHub leaves out above the hunk header at row `i`.
func hunkGap(_ lines: [DiffLine], at i: Int) -> Int {
    let nums = lines[i].text.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0 }
    guard nums.count > 1, nums[1] > 0 else { return 0 }
    let above = lines[..<i].last { $0.new != nil }?.new ?? 0
    return max(0, nums[1] - above - 1)
}
