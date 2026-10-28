import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Neutral surfaces and text; color is reserved for status.
/// A design-size metric at the board's zoom, on the half-point grid.
func z(_ v: CGFloat) -> CGFloat { (v * T.zoom * 2).rounded() / 2 }

struct ZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = T.zoom
}

extension EnvironmentValues {
    var zoom: CGFloat {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
}

/// Views that size themselves from the environment's zoom, so the full window can run larger than the panel.
protocol Zoomed {
    var zoom: CGFloat { get }
}

extension Zoomed {
    func z(_ v: CGFloat) -> CGFloat { (v * zoom * 2).rounded() / 2 }
    func ui(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font { .system(size: size * zoom, weight: weight) }
    func mono(_ size: CGFloat = 11) -> Font { .system(size: size * zoom, design: .monospaced) }
    /// The UI face with fixed-width digits, so numbers and ages line up without a second typeface.
    func digits(_ size: CGFloat = 11.5) -> Font { .system(size: size * zoom).monospacedDigit() }
}

enum T {
    static let surface = Color(hex: 0x181818)
    static let raised = Color(hex: 0x212121)
    static let text = Color(hex: 0xdfdfdf)
    static let text2 = text.opacity(0.7)
    static let text3 = text.opacity(0.5)
    /// A status mark at rest: present, but quieter than any state that asks for something.
    static let idle = Color(white: 0.42)
    static let hover = text.opacity(0.025)
    static let separator = text.opacity(0.08)
    static let border = Color.white.opacity(0.08)
    static let bracket = text.opacity(0.12)

    static let blue = Color(hex: 0x339cff)
    static let green = Color(hex: 0x40c977)
    static let red = Color(hex: 0xff6764)
    static let orange = Color(hex: 0xff8549)
    static let yellow = Color(hex: 0xffd240)
    static let purple = Color(hex: 0xad7bf9)

    static func ui(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font { .system(size: size * zoom, weight: weight) }
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size * zoom, design: .monospaced) }
    static func digits(_ size: CGFloat = 11.5) -> Font { .system(size: size * zoom).monospacedDigit() }

    /// One scale for every font and metric. `defaults write <bundle id> zoom 0.85` changes it.
    static let zoom: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "zoom")
        return v >= 0.5 && v <= 1.5 ? v : 0.9375
    }()

    static let rowRadius: CGFloat = z(8)
    static let control = RoundedRectangle(cornerRadius: z(6), style: .continuous)
}

func ciColor(_ ci: String) -> Color {
    switch ci {
    case "passing": return T.green
    case "failing": return T.red
    case "running": return T.yellow
    default: return T.text3
    }
}

/// A left square bracket that groups the rows beside it.
struct Bracket: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: r.minX + 0.5, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: r.minX + 0.5, y: r.maxY - 0.5))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 0.5))
        return p
    }
}
