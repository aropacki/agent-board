import AppKit
import SwiftUI

/// The ⌥Space popup over whatever is on screen: the board, with the diff viewer above it.
struct PopupRoot: View {
    @Environment(Board.self) private var board
    var zoom: CGFloat { T.zoom * 1.15 }

    var body: some View {
        GeometryReader { geo in
            let safe = board.popupSafe
            let w = geo.size.width - safe.leading - safe.trailing, h = geo.size.height - safe.top - safe.bottom
            let card = CGSize(width: w - 2 * max(32, w * 0.05), height: h - 2 * max(24, h * 0.05))
            let shape = RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous)
            let presented = board.popupPresented
            ZStack {
                Color.black.opacity(0.32).opacity(presented ? 1 : 0)
                    .contentShape(Rectangle()).onTapGesture { board.dismissPopup() }
                FullBoardView()
                    .equatable()
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(T.border))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                    .opacity(board.boardOpen ? 1 : 0)
                    .allowsHitTesting(board.boardOpen)
                    .overlay { DiffLayer(shape: shape, zoom: zoom) }
                .frame(width: max(0, card.width), height: max(0, card.height))
                .modifier(BoardOverlays(barWidth: 520))
                .scaleEffect(presented || Motion.reduced ? 1 : 0.98)
                .opacity(presented ? 1 : 0)
                .position(x: safe.leading + w / 2, y: safe.top + h / 2)
            }
        }
        .allowsHitTesting(board.popupPresented)
        .ignoresSafeArea()
        .environment(\.boardSurface, "window")
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .key)
    }
}

/// Its own view so that opening and closing a diff re-renders only this layer, not the board under it.
struct DiffLayer: View {
    @Environment(Board.self) private var board
    let shape: RoundedRectangle
    let zoom: CGFloat

    var body: some View {
        if board.diffOpen != nil {
            ZStack {
                if board.boardOpen {
                    shape.fill(Color.black.opacity(0.35)).contentShape(shape).onTapGesture { board.closeDiff() }
                }
                DiffPopup().padding(board.boardOpen ? 28 * zoom : 0)
            }
            .environment(\.zoom, zoom)
            .transition(.pop(from: .center))
        }
    }
}
