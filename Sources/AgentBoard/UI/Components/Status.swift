import AppKit
import SwiftUI

/// A symbol whose pulse runs as a Core Animation layer animation. SwiftUI's repeating
/// symbol effects rebuild layers every frame, which held a full core whenever the board was in front.
final class PulseImageView: NSImageView {
    var pulsing = false { didSet { if pulsing != oldValue { applyPulse() } } }
    /// What the current image was drawn from; building a symbol image is slow enough to skip when nothing changed.
    var drawn: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulse()
    }

    func applyPulse() {
        wantsLayer = true
        guard let layer else { return }
        if pulsing && window != nil {
            guard layer.animation(forKey: "pulse") == nil else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 0.85
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "pulse")
        } else {
            layer.removeAnimation(forKey: "pulse")
        }
    }
}

struct PulsingSymbol: NSViewRepresentable {
    let name: String
    let color: Color
    let size: CGFloat
    var weight: NSFont.Weight = .bold
    let pulsing: Bool

    func makeNSView(context: Context) -> PulseImageView {
        let view = PulseImageView()
        view.imageScaling = .scaleNone
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: PulseImageView, context: Context) {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color)"
        if view.drawn != key {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            view.drawn = key
        }
        view.pulsing = pulsing
    }
}

/// A glass status mark. Color carries the state; a sweep of light and a soft halo mark one that is still moving.
struct Orb: View {
    let color: Color
    let size: CGFloat
    var moving = false
    @Environment(Board.self) private var board

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.4), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: size * 0.6))
            Circle().fill(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.3)], startPoint: .center, endPoint: .bottom))
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.56, height: size * 0.36)
                .offset(y: -size * 0.2)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .background { if moving { OrbMotion(kind: .glow, color: color, on: board.animating) } }
        .overlay { if moving { OrbMotion(kind: .sheen, color: color, on: board.animating) } }
    }
}

/// The moving part of an `Orb`, run by Core Animation so a board full of running marks costs no SwiftUI frames.
/// Every orb shares one clock, so their sweeps land together.
final class OrbMotionView: NSView {
    enum Kind { case glow, sheen }
    static let period: CFTimeInterval = 2.4
    var kind = Kind.sheen
    var color = NSColor.white { didSet { if color != oldValue { needsLayout = true } } }
    var on = false { didSet { if on != oldValue { apply() } } }
    private let shape = CAShapeLayer()
    private let band = CAGradientLayer()
    private var moving: CALayer { kind == .glow ? shape : band }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let layer, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = bounds
        shape.path = CGPath(ellipseIn: r, transform: nil)
        switch kind {
        case .glow:
            shape.fillColor = color.cgColor
            shape.shadowColor = color.cgColor
            shape.shadowOffset = .zero
            shape.shadowRadius = r.width * 0.4
            shape.shadowOpacity = 0
            if shape.superlayer == nil { layer.addSublayer(shape) }
        case .sheen:
            shape.fillColor = NSColor.black.cgColor
            layer.mask = shape
            band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.6).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.bounds = CGRect(x: 0, y: 0, width: r.width * 0.55, height: r.height * 1.6)
            band.position = CGPoint(x: -r.width, y: r.midY)
            band.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 9))
            if band.superlayer == nil { layer.addSublayer(band) }
        }
        CATransaction.commit()
        moving.removeAnimation(forKey: "motion")
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard on, window != nil, bounds.width > 0 else { moving.removeAnimation(forKey: "motion"); return }
        guard moving.animation(forKey: "motion") == nil else { return }
        let animation: CAAnimation
        switch kind {
        case .glow:
            let breathe = CABasicAnimation(keyPath: "shadowOpacity")
            breathe.fromValue = 0.15
            breathe.toValue = 0.8
            breathe.duration = Self.period / 2
            breathe.autoreverses = true
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation = breathe
        case .sheen:
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -bounds.width * 0.5
            sweep.toValue = bounds.width * 1.5
            sweep.duration = 0.9
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let group = CAAnimationGroup()
            group.animations = [sweep]
            group.duration = Self.period
            animation = group
        }
        animation.repeatCount = .infinity
        let now = CACurrentMediaTime()
        animation.beginTime = moving.convertTime(now - now.truncatingRemainder(dividingBy: Self.period), from: nil)
        moving.add(animation, forKey: "motion")
    }
}

struct OrbMotion: NSViewRepresentable {
    let kind: OrbMotionView.Kind
    let color: Color
    let on: Bool

    func makeNSView(context: Context) -> OrbMotionView {
        let view = OrbMotionView()
        view.kind = kind
        return view
    }

    func updateNSView(_ view: OrbMotionView, context: Context) {
        view.color = NSColor(color)
        view.on = on
    }
}

/// The leading status mark shared by cards and agent chips.
struct StatusDot: View, Zoomed {
    @Environment(\.zoom) var zoom
    let status: String

    var body: some View {
        switch status {
        case "needs": Orb(color: T.orange, size: z(9))
        case "running": Orb(color: T.blue, size: z(9), moving: true)
        case "error", "aborted": Orb(color: T.red, size: z(9))
        default: Orb(color: T.idle, size: z(9))
        }
    }
}

struct CIDot: View, Zoomed {
    @Environment(\.zoom) var zoom
    let ci: String
    var body: some View { Orb(color: ciColor(ci), size: z(7), moving: ci == "running") }
}
