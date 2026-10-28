import AppKit
import SwiftUI

/// Row frames as the layout last placed them, kept out of view state so layout passes don't re-render the rows.
final class DiffRowFrames {
    var frames: [Int: CGRect] = [:]
    var codeWidth: CGFloat = 0
    /// The row at `y`, or the nearest end row when `y` is above or below them all.
    func row(at y: CGFloat) -> Int? {
        if let hit = frames.first(where: { $0.value.minY <= y && y < $0.value.maxY }) { return hit.key }
        guard let top = frames.min(by: { $0.value.minY < $1.value.minY }), let bottom = frames.max(by: { $0.value.minY < $1.value.minY })
        else { return nil }
        return y < top.value.minY ? top.key : bottom.key
    }
}

enum MarginPart: Equatable { case row(Int), note(Int), bracket(Int), tether(Int), paint }

struct MarginPartKey: LayoutValueKey { static let defaultValue = MarginPart.row(-1) }

/// Code rows down the left and notes in a margin on the right, each level with the rows it covers.
/// A bracket marks those rows; a tether ties the note back to them when the note above pushed it lower.
struct MarginLayout: Layout {
    /// Each note's rows, in the order the notes stack.
    let spans: [ClosedRange<Int>?]
    let lanes: [Int]
    let margin: ClosedRange<CGFloat>
    let lane: CGFloat
    let gutter: CGFloat
    let gap: CGFloat
    let tetherDrop: CGFloat
    /// Row heights are kept while this holds, so hovering a note doesn't measure every line again.
    let stamp: String
    var rowFrames: DiffRowFrames?

    struct Cache {
        var stamp = ""
        var codeWidth: CGFloat = -1
        var rowHeights: [Int: CGFloat] = [:]
        var width: CGFloat = -1
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.width = -1 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 900
        arrange(width, subviews, &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        arrange(bounds.width, subviews, &cache)
        for (i, view) in subviews.enumerated() where i < cache.frames.count {
            let f = cache.frames[i]
            view.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    func arrange(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) {
        guard cache.width != width || cache.frames.count != subviews.count else { return }
        let laneCount = spans.contains { $0 != nil } ? (lanes.max() ?? 0) + 1 : 0
        let noteWidth = min(max(width * 0.36, margin.lowerBound), margin.upperBound)
        let noteX = width - noteWidth
        let code = max(0, noteX - gutter - CGFloat(laneCount) * lane)
        if cache.stamp != stamp || cache.codeWidth != code {
            cache.stamp = stamp
            cache.codeWidth = code
            cache.rowHeights = [:]
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var top: [Int: CGFloat] = [:], bottom: [Int: CGFloat] = [:]
        var notes: [Int: Int] = [:], brackets: [Int: Int] = [:], tethers: [Int: Int] = [:]
        var paint: Int?
        var y: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            switch view[MarginPartKey.self] {
            case .row(let r):
                let h = cache.rowHeights[r] ?? view.sizeThatFits(ProposedViewSize(width: code, height: nil)).height
                cache.rowHeights[r] = h
                frames[i] = CGRect(x: 0, y: y, width: code, height: h)
                top[r] = y
                bottom[r] = y + h
                y += h
            case .note(let k): notes[k] = i
            case .bracket(let k): brackets[k] = i
            case .tether(let k): tethers[k] = i
            case .paint: paint = i
            }
        }
        if let paint { frames[paint] = CGRect(x: 0, y: 0, width: code, height: y) }
        let placed = spans.indices.filter { notes[$0] != nil }
        let heights = placed.map { subviews[notes[$0]!].sizeThatFits(ProposedViewSize(width: noteWidth, height: nil)).height }
        let anchors = placed.map { spans[$0].flatMap { top[$0.lowerBound] } ?? 0 }
        let tops = stackedTops(anchors: anchors, heights: heights, gap: gap)
        var end = y
        for (j, k) in placed.enumerated() {
            frames[notes[k]!] = CGRect(x: noteX, y: tops[j], width: noteWidth, height: heights[j])
            end = max(end, tops[j] + heights[j])
            guard let span = spans[k], let a = top[span.lowerBound], let b = bottom[span.upperBound] else { continue }
            let x = code + gutter * 0.25 + CGFloat(laneCount - 1 - lanes[k]) * lane
            let bracketWidth = lane * 0.7
            if let i = brackets[k] { frames[i] = CGRect(x: x, y: a, width: bracketWidth, height: b - a) }
            if let i = tethers[k] {
                let from = a + min(tetherDrop, (b - a) / 2)
                let to = from >= tops[j] + gap ? from : tops[j] + tetherDrop
                frames[i] = CGRect(x: x + bracketWidth, y: from, width: max(0, noteX - x - bracketWidth), height: max(1, to - from))
            }
        }
        cache.width = width
        cache.frames = frames
        cache.height = end
        if let rowFrames {
            rowFrames.codeWidth = code
            rowFrames.frames = [:]
            for (i, view) in subviews.enumerated() { if case .row(let r) = view[MarginPartKey.self] { rowFrames.frames[r] = frames[i] } }
        }
    }
}

/// A right square bracket on the code rows a note covers; its ticks point at the code.
struct CloseBracket: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: r.maxX - 0.5, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: r.maxX - 0.5, y: r.maxY - 0.5))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 0.5))
        return p
    }
}

/// From a bracket to its note: across, down beside the bracket, then across to the note.
struct Tether: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let bend = r.minX + min(r.width / 2, 5)
        p.move(to: CGPoint(x: r.minX, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: bend, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: bend, y: r.maxY - 0.5))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 0.5))
        return p
    }
}

/// A rounded card's outline with its top or bottom edge left open, so a header and its body draw as one card.
struct CardEdge: Shape {
    var top: Bool
    var bottom: Bool
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let rt = top ? radius : 0, rb = bottom ? radius : 0
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - rb))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rt))
        if top {
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rt, y: r.minY), radius: rt)
            p.addLine(to: CGPoint(x: r.maxX - rt, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rt), radius: rt)
        } else {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rb))
        if bottom {
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rb, y: r.maxY), radius: rb)
            p.addLine(to: CGPoint(x: r.minX + rb, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rb), radius: rb)
        }
        return p
    }
}

func severityColor(_ severity: String?) -> Color {
    switch severity {
    case "blocker": return T.red
    case "issue": return T.orange
    default: return T.text.opacity(0.6)
    }
}
