import AppKit
import SwiftUI

/// The header control that opens the log, with a dot while anything is unread.
struct NewAgentButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    var label = false

    var body: some View {
        Button { board.newAgent() } label: {
            Group {
                if label {
                    Text("New agent").font(ui(12, .medium))
                        .opacity(board.busy.contains("new-agent") ? 0 : 1)
                        .overlay { if board.busy.contains("new-agent") { ProgressView().controlSize(.mini) } }
                } else {
                    ZStack {
                        if board.busy.contains("new-agent") { ProgressView().controlSize(.mini) } else { Image(systemName: "plus") }
                    }
                    .font(.system(size: z(11.5), weight: .medium))
                    .frame(width: z(16), height: z(16))
                }
            }
            .foregroundStyle(T.text2)
        }
        .buttonStyle(label ? HoverButtonStyle.header : HoverButtonStyle.icon).pointerOnly()
        .help("New agent in Cursor")
    }
}

struct ActivityButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let showing: Bool
    var label = false
    let toggle: () -> Void

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { toggle() } } label: {
            HStack(spacing: z(5)) {
                if !label {
                    Image(systemName: showing ? "rectangle.split.3x1" : "clock.arrow.circlepath")
                        .font(.system(size: z(11.5), weight: .medium))
                        .overlay(alignment: .topTrailing) {
                            if board.unreadActivity > 0 && !showing {
                                Orb(color: T.orange, size: z(6)).offset(x: z(3), y: -z(2))
                            }
                        }
                }
                if label { Text(showing ? "Board" : "Activity").font(ui(12, .medium)) }
                if label && board.unreadActivity > 0 && !showing {
                    Text(verbatim: "\(board.unreadActivity)").font(digits(11.5)).foregroundStyle(T.orange)
                }
            }
            .foregroundStyle(T.text2)
            .frame(minWidth: label ? nil : z(16), minHeight: z(16))
        }
        .buttonStyle(label ? HoverButtonStyle.header : HoverButtonStyle.icon).pointerOnly()
        .help(showing ? "Back to the board" : "Activity")
    }
}
