import SwiftUI

/// Where the diff's viewport is, in rows. Only the scrollbar reads it, so a scroll redraws the bar and nothing else.
@Observable
final class DiffScroll {
    private(set) var row: Double = 0
    private(set) var visible: Double = 1
    /// -1 at the top, 1 at the bottom: the row estimate drifts by a few rows there, and the thumb must still touch the end.
    var edge = -1
    @ObservationIgnored var viewport: CGFloat = 0
    @ObservationIgnored private(set) var seen: [String: (start: Double, rows: Int, frame: CGRect)] = [:]

    func saw(_ id: String, start: Double, rows: Int, frame: CGRect?) {
        seen[id] = frame.map { (start, rows, $0) }
        guard let at = viewportRow(Array(seen.values)) else { return }
        let visible = Double(viewport / at.rowHeight)
        if abs(at.row - row) > 0.01 { row = at.row }
        if abs(visible - self.visible) > 0.01 { self.visible = visible }
    }
}

struct DiffScrollbar: View, Zoomed {
    @Environment(\.zoom) var zoom
    let scroll: DiffScroll
    let total: Double
    /// Puts row `p` at the viewport's top.
    let seek: (Double) -> Void
    @State private var hovering = false
    /// Where in the thumb the drag took hold, so the thumb stays under the pointer while the diff catches up.
    @State private var grip: CGFloat?
    @State private var dragged: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let row = scroll.edge == 1 ? total : scroll.edge == -1 ? 0 : scroll.row
            let measured = thumbFrame(top: row, visible: scroll.visible, total: total, track: g.size.height, minimum: z(28))
            let y = grip == nil ? measured.y : min(max(0, dragged), g.size.height - measured.height)
            let wide = hovering || grip != nil
            Capsule()
                .fill(T.text.opacity(wide ? 0.42 : 0.22))
                .frame(width: wide ? z(7) : z(4), height: measured.height)
                .offset(y: y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let hold = grip ?? (v.startLocation.y >= measured.y && v.startLocation.y <= measured.y + measured.height
                            ? v.startLocation.y - measured.y : measured.height / 2)
                        grip = hold
                        dragged = v.location.y - hold
                        seek(thumbRow(y: dragged, height: measured.height, visible: scroll.visible, total: total, track: g.size.height))
                    }
                    .onEnded { _ in grip = nil })
        }
        .frame(width: z(11))
        .padding(.vertical, z(4))
        .trackHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .opacity(total > scroll.visible ? 1 : 0)
    }
}
