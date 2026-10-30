import AppKit
import SwiftUI

/// Three speeds: fills on hover and press, content and layout, and whole windows.
enum Motion {
    /// Read on each use, so turning Reduce Motion on applies without a restart.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let hoverIn = Animation.easeOut(duration: 0.12)
    static let hoverOut = Animation.easeOut(duration: 0.2)
    static let press = Animation.easeOut(duration: 0.06)
    static let content = Animation.snappy(duration: 0.2)
    static let window = Animation.snappy(duration: 0.24)

    static func fill(hovering: Bool, pressed: Bool = false) -> Animation { pressed ? press : hovering ? hoverIn : hoverOut }
}

extension AnyTransition {
    /// In from `edge` and back out toward it. A crossfade under Reduce Motion.
    static func slide(_ edge: Edge) -> AnyTransition {
        Motion.reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// A view one level deeper: in from the trailing edge, back out to it.
    static var push: AnyTransition { slide(.trailing) }

    /// A list row: settles in from just above, and fades as it leaves.
    static var row: AnyTransition {
        .asymmetric(insertion: Motion.reduced ? .opacity : .offset(y: -z(4)).combined(with: .opacity), removal: .opacity)
    }

    /// A menu or popover growing from `anchor`, the point of its frame nearest what opened it.
    static func pop(from anchor: UnitPoint) -> AnyTransition {
        Motion.reduced ? .opacity : .scale(scale: 0.97, anchor: anchor).combined(with: .opacity)
    }
}
