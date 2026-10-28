import AppKit
import SwiftUI

struct HoverButtonStyle: ButtonStyle {
    var padH: CGFloat
    var padV: CGFloat
    var rest = 0.0
    var hover = 0.07
    var press = 0.12
    var radius: CGFloat = z(5)
    var bordered = false
    /// Fill and outline are strongest at the corners and ease off toward the middle of each edge.
    var faded = false

    static let link = HoverButtonStyle(padH: z(4), padV: z(1.5), hover: 0.045, press: 0.08, radius: z(4))
    static let chip = HoverButtonStyle(padH: z(6), padV: z(3), rest: 0.05, hover: 0.065, press: 0.11)
    /// A labeled control in a header: the action buttons' faded surface at header size.
    static let header = HoverButtonStyle(padH: z(8), padV: z(3), rest: 0.03, hover: 0.06, press: 0.1, radius: z(5), faded: true)
    static let action = HoverButtonStyle(padH: z(7), padV: z(2.5), rest: 0.03, hover: 0.06, press: 0.1, radius: z(5), faded: true)
    static let icon = HoverButtonStyle(padH: z(4), padV: z(4), hover: 0.06, press: 0.1, radius: z(6))

    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, style: self) }
}

struct HoverBody: View {
    let configuration: ButtonStyle.Configuration
    let style: HoverButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.zoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let scale = zoom / T.zoom
        let shape = RoundedRectangle(cornerRadius: style.radius * scale, style: .continuous)
        let level = !isEnabled ? style.rest / 2 : configuration.isPressed ? style.press : hovering ? style.hover : style.rest
        configuration.label
            .padding(.horizontal, style.padH * scale).padding(.vertical, style.padV * scale)
            .background {
                Group {
                    if style.faded {
                        shape.fill(Self.edges(T.text.opacity(level), middle: 0.7))
                            .overlay(Self.cornerStroke(shape, T.text.opacity(level * 6)))
                    } else {
                        shape.fill(T.text.opacity(level))
                    }
                }
                .animation(Motion.fill(hovering: hovering, pressed: configuration.isPressed), value: level)
            }
            .overlay { if style.bordered { shape.strokeBorder(T.border) } }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .trackHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }

    /// `color` at both ends, falling off quickly from them to `middle` of itself at the center.
    static func edges(_ color: Color, middle: Double, vertical: Bool = false) -> LinearGradient {
        let near = color.opacity(middle + (1 - middle) * 0.35)
        return LinearGradient(stops: [.init(color: color, location: 0), .init(color: near, location: 0.22),
                                      .init(color: color.opacity(middle), location: 0.5),
                                      .init(color: near, location: 0.78), .init(color: color, location: 1)],
                              startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
    }

    /// A hairline at full `color` in the corners. The two falloffs multiply, so the long edges fade further
    /// toward their middles than the short ones.
    static func cornerStroke<S: InsettableShape>(_ shape: S, _ color: Color) -> some View {
        shape.strokeBorder(edges(color, middle: 0.1), lineWidth: 0.5)
            .mask(edges(.white, middle: 0.3, vertical: true))
    }
}

/// A tap target for views drawn many times at once, like list rows and file headers. A `Button` brings focus,
/// accessibility, and tooltip machinery that costs per instance every time the view appears; this keeps only the tap,
/// the hover fill, and the pointer.
struct TapTarget<Label: View>: View, Zoomed {
    @Environment(\.zoom) var zoom
    var padH: CGFloat = 8
    var padV: CGFloat = 4
    var hover = 0.05
    var radius: CGFloat = 5
    /// Spans the row, so the whole width takes the tap.
    var wide = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: z(radius), style: .continuous)
        label
            .padding(.horizontal, z(padH)).padding(.vertical, z(padV))
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            .background(shape.fill(T.text.opacity(hovering ? hover : 0)).animation(Motion.fill(hovering: hovering), value: hovering))
            .contentShape(shape)
            .onTapGesture(perform: action)
            .trackHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

/// One PR or card fact. With an action it is a link; without, plain text at the same metrics.
struct Meta: View, Zoomed {
    @Environment(\.zoom) var zoom
    let text: String
    var color: Color = T.text2
    var icon: String? = nil
    /// The icon's color when it differs from the text's: the mark carries the state, the word stays quiet.
    var tint: Color? = nil
    var ci: String? = nil
    var help: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: text.isEmpty ? 0 : z(4)) {
            if let ci { CIDot(ci: ci) }
            if let icon { Image(systemName: icon).font(.system(size: z(9.5), weight: .semibold)).foregroundStyle(tint ?? color) }
            // A bare mark keeps the line's height, so it sits on the same baseline as its neighbors.
            Text(verbatim: text.isEmpty ? "\u{200B}" : text).font(digits(11.5))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        if let action {
            Button(action: action) { label }
                .buttonStyle(HoverButtonStyle.link).pointerOnly()
                .help(help ?? text)
        } else {
            label.padding(.horizontal, z(4)).padding(.vertical, z(1.5)).help(help ?? text)
        }
    }
}

struct QuietButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: z(4)) {
                Image(systemName: icon).font(.system(size: z(9), weight: .semibold))
                Text(title).font(ui(11.5))
            }
            .foregroundStyle(T.text3)
        }
        .buttonStyle(HoverButtonStyle.link).pointerOnly()
    }
}

/// A text button whose surface overhangs its text: the text lines up with the text around it and the
/// surface's ends sit in the gutter, so rows of them need wide spacing.
struct ActionChip: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    var color: Color = T.text2
    let key: String
    var disabledReason: String? = nil
    let action: () -> Void
    @Environment(Board.self) private var board

    var body: some View {
        let busy = board.busy.contains(key)
        let done = board.succeeded.contains(key)
        Button(action: action) {
            Text(title)
                .font(ui(11.5, .medium))
                .foregroundStyle(done ? T.green : color)
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.mini) } }
        }
        .buttonStyle(HoverButtonStyle.action).pointerOnly()
        .padding(.horizontal, -z(7))
        .disabled(busy || disabledReason != nil)
        .help(disabledReason ?? title)
    }
}
