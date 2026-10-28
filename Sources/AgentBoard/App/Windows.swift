import AppKit
import SwiftUI

/// Opaque, flat container: no glass sampling behind the panel.
func panelContainer(_ content: NSView) -> NSView {
    let box = NSView()
    box.wantsLayer = true
    box.layer?.backgroundColor = NSColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255, alpha: 1).cgColor
    box.layer?.cornerRadius = 12
    box.layer?.cornerCurve = .continuous
    box.layer?.masksToBounds = true
    box.layer?.borderWidth = 1
    box.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    content.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        content.topAnchor.constraint(equalTo: box.topAnchor),
        content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
    return box
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel never activates the app, so without this the first click only focuses the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Right-click and control-click open the board's dropdown for the row under the pointer.
func installMenuMonitor(_ board: Board) {
    NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .scrollWheel, .keyDown]) { event in
        switch event.type {
        case .scrollWheel:
            // A two-finger click on a trackpad also sends small scroll events; only a real scroll closes the menu.
            let distance = abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY)
            if distance >= 2 && Date().timeIntervalSince(board.menuOpenedAt) > 0.3 { board.closeMenu() }
            return event
        case .keyDown:
            guard event.keyCode == 53 else { return event }
            if board.menu != nil { board.closeMenu(); return nil }
            return board.escapePopup() ? nil : event
        case .leftMouseDown where !event.modifierFlags.contains(.control):
            return event
        default:
            guard let root = event.window?.contentView else { return event }
            let p = root.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: p.x, y: root.isFlipped ? p.y : root.bounds.height - p.y)
            let surface = event.window is EdgePanel ? "panel" : "window"
            guard let owner = board.menuOwner(at: point, surface: surface) else { board.closeMenu(); return event }
            board.showMenu(owner: owner, anchor: CGRect(origin: point, size: .zero), surface: surface)
            return nil
        }
    }
}
