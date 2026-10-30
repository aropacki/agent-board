import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let board = Board()
    var panel: EdgePanel!
    var statusTicker: NSPanel!
    let tickerSpace = OverlaySpace()
    var notesTicker: NSPanel!
    var statusShown = false
    var notesShown = false
    var popup: PopupPanel?
    var popupHost: NSView?
    var popupHolds = 0
    var popupReturnTo: NSRunningApplication?
    var hotKey: GlobalHotKey?
    var notifier: Notifier?
    var inFront = false
    var hideTimer: Timer?
    var frontActivity: NSObjectProtocol?
    let width: CGFloat = 372
    let inset: CGFloat = 8
    /// Above desktop icons and widgets (icons + 2), still below every app window.
    let behindLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = EdgePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = behindLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = FirstClickHostingView(rootView: BoardView().environment(board))
        host.sizingOptions = []
        panel.contentView = panelContainer(host)
        place(frontX: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.place(frontX: false)
            self?.placeTickers()
        }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.pointerMoved() }
        NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        installMenuMonitor(board)
        board.popupChanged = { [weak self] in self?.syncPopup() }
        board.holdPopup = { [weak self] in self?.holdPopup($0) }
        let notifier = Notifier(board: board)
        self.notifier = notifier
        board.alert = { notifier.post($0) }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.togglePopup() }
        if hotKey == nil { board.show(.error, "Another app holds ⌥Space, so the board shortcut is off.") }
        makeTickers()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.board.decayNeeds(step: 60) }
    }

    func togglePopup() {
        if board.boardOpen && popup?.isVisible == true { board.closePopup() } else { board.openBoard() }
    }

    func syncPopup() {
        if board.boardOpen || board.diffOpen != nil { showPopup() } else { hidePopup() }
    }

    /// An ordered-out window still runs layout, so the popup's view tree would keep re-rendering on every
    /// state change. Detached, it does no work until shown again, then catches up once.
    func hidePopup() {
        guard let popup else { return }
        let hadKeyboard = popup.isKeyWindow
        popup.orderOut(nil)
        popup.contentView = NSView()
        if NSApp.isActive, let app = popupReturnTo, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else if hadKeyboard {
            returnKeyboard()
        }
        popupReturnTo = nil
        syncActivity()
    }

    /// The board's windows never activate the app, so the app in front keeps its caret even while a board window
    /// holds the keyboard. Activating that app again sends typing back to it.
    func returnKeyboard() {
        guard let front = NSWorkspace.shared.frontmostApplication, front != .current else { return }
        front.activate()
    }

    /// Covers the screen under the pointer, over every app and full-screen Space. The app activates while the popup
    /// is up: an inactive app's panel loses the keyboard whenever the front app takes it back, and an inactive app
    /// runs at background priority. The app that was in front gets activation back when the popup goes.
    func showPopup() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        if popup == nil {
            let p = PopupPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .modalPanel
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isMovable = false
            p.appearance = NSAppearance(named: .darkAqua)
            p.delegate = self
            let host = FirstClickHostingView(rootView: PopupRoot().environment(board))
            host.sizingOptions = []
            popupHost = host
            popup = p
        }
        guard let popup else { return }
        if popup.contentView !== popupHost { popup.contentView = popupHost }
        if !popup.isVisible {
            let f = screen.frame, v = screen.visibleFrame
            board.popupSafe = EdgeInsets(top: f.maxY - v.maxY, leading: v.minX - f.minX, bottom: v.minY - f.minY, trailing: f.maxX - v.maxX)
            popup.setFrame(f, display: false)
            if let front = NSWorkspace.shared.frontmostApplication, front != .current { popupReturnTo = front }
        }
        popup.orderFrontRegardless()
        NSApp.activate()
        popup.makeKey()
        syncActivity()
    }

    /// Clicking into another app, or another of the board's windows, closes the popup. While the app is still
    /// active and no other window took the keyboard, the loss is transient, so the popup takes it back.
    func windowDidResignKey(_ notification: Notification) {
        guard let popup, (notification.object as? NSWindow) === popup, popupHolds == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popupHolds == 0, popup.isVisible, !popup.isKeyWindow else { return }
            if NSApp.isActive && NSApp.keyWindow == nil {
                popup.makeKey()
                return
            }
            self.board.closePopup()
        }
    }

    /// Clicks pass through to the tool's window while an action types into it, since it may click its prompt field.
    func holdPopup(_ on: Bool) {
        popupHolds = max(0, popupHolds + (on ? 1 : -1))
        guard let popup else { return }
        popup.ignoresMouseEvents = popupHolds > 0
        if popupHolds == 0 && popup.isVisible && board.popupPresented { popup.makeKey() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        board.openBoard()
        return false
    }

    func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let tile = rect.insetBy(dx: 24, dy: 24)
            NSColor(red: 0x21 / 255, green: 0x21 / 255, blue: 0x21 / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 46, yRadius: 46).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0x33 / 255, green: 0x9c / 255, blue: 1, alpha: 1)]))
            if let symbol = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    var menuBarHeight: CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : max(screen.safeAreaInsets.top, 24)
    }

    /// The whole menu bar, split at the notch so the strips meet behind it, covering the menu bar
    /// icons; the strips step aside on hover to reveal them.
    func tickerFrames() -> (status: NSRect, notes: NSRect, notchInset: CGFloat) {
        let f = screen.frame
        let notch = screen.auxiliaryTopLeftArea.flatMap { l in screen.auxiliaryTopRightArea.map { (l, $0) } }
            .flatMap { $0.0.width > 0 && $0.1.width > 0 ? $0 : nil }
        let h = menuBarHeight
        let y = f.maxY - h
        let half = (f.width * 0.45).rounded()
        var left = NSRect(x: f.minX, y: y, width: half, height: h)
        var right = NSRect(x: f.maxX - half, y: y, width: half, height: h)
        var inset: CGFloat = 0
        if let (l, r) = notch {
            let split = ((l.maxX + r.minX) / 2).rounded()
            inset = split - l.maxX
            left = NSRect(x: f.minX, y: y, width: split - f.minX, height: h)
            right = NSRect(x: split, y: y, width: f.maxX - split, height: h)
        }
        right.size.width = f.maxX - right.minX
        return (left, right, inset)
    }

    func placeTickers() {
        let frames = tickerFrames()
        if board.tickerNotchInset != frames.notchInset { board.tickerNotchInset = frames.notchInset }
        if statusTicker?.frame != frames.status { statusTicker?.setFrame(frames.status, display: true) }
        if notesTicker?.frame != frames.notes { notesTicker?.setFrame(frames.notes, display: true) }
    }

    func makeTicker(_ side: TickerSide, frame: NSRect) -> NSPanel {
        let ticker = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ticker.level = .statusBar
        ticker.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ticker.isOpaque = false
        ticker.backgroundColor = .clear
        ticker.hasShadow = false
        ticker.ignoresMouseEvents = true
        ticker.hidesOnDeactivate = false
        ticker.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: TickerBar(side: side).environment(board))
        host.sizingOptions = []
        ticker.contentView = host
        ticker.alphaValue = 0
        ticker.orderFrontRegardless()
        tickerSpace.add(ticker)
        return ticker
    }

    func makeTickers() {
        let frames = tickerFrames()
        board.tickerNotchInset = frames.notchInset
        statusTicker = makeTicker(.status, frame: frames.status)
        notesTicker = makeTicker(.notes, frame: frames.notes)
        updateTicker()
    }

    var pointerInMenuBar: Bool {
        let p = NSEvent.mouseLocation
        let f = screen.frame
        return p.x >= f.minX && p.x <= f.maxX && p.y >= f.maxY - menuBarHeight - 4
    }

    /// Out of the way while the panel is open; each strip also steps aside while the pointer is
    /// over its side of the menu bar.
    func updateTicker() {
        guard let statusTicker, let notesTicker else { return }
        let hovering = pointerInMenuBar
        let x = NSEvent.mouseLocation.x
        let showStatus = !inFront && !(hovering && x <= statusTicker.frame.maxX + 40)
        let showNotes = !inFront && !(hovering && x >= notesTicker.frame.minX - 40)
        if showStatus != statusShown {
            statusShown = showStatus
            fade(statusTicker, in: showStatus)
        }
        if showNotes != notesShown {
            notesShown = showNotes
            if showNotes { notesTicker.setFrame(tickerFrames().notes, display: true) }
            fade(notesTicker, in: showNotes)
        }
    }

    func fade(_ ticker: NSPanel, in show: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = show ? 0.2 : 0.1
            ticker.animator().alphaValue = show ? 1 : 0
        }
    }

    func targetFrame(offset: CGFloat = 0) -> NSRect {
        let f = screen.visibleFrame
        return NSRect(x: f.minX + inset + offset, y: f.minY + inset, width: width, height: f.height - inset * 2)
    }

    func place(frontX: Bool) { panel.setFrame(targetFrame(), display: true) }

    var pointerAtEdge: Bool {
        let p = NSEvent.mouseLocation
        let full = screen.frame
        return p.x <= full.minX + 1 && p.y >= full.minY && p.y <= full.maxY
    }

    var pointerNearPanel: Bool { panel.frame.insetBy(dx: -18, dy: -18).contains(NSEvent.mouseLocation) || pointerAtEdge }

    func pointerMoved() {
        updateTicker()
        if !inFront {
            if pointerAtEdge { bringFront() }
            return
        }
        if pointerNearPanel {
            hideTimer?.invalidate()
            hideTimer = nil
        } else if hideTimer == nil {
            // Default run loop mode only: the timer waits while a context menu is tracking.
            let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.hideIfAway() }
            RunLoop.main.add(timer, forMode: .default)
            hideTimer = timer
        }
    }

    func hideIfAway() {
        hideTimer = nil
        guard inFront, !pointerNearPanel, !board.composing, NSApp.modalWindow == nil, panel.childWindows?.isEmpty != false else { return }
        sendBehind()
    }

    func bringFront() {
        inFront = true
        updateTicker()
        hideTimer?.invalidate()
        hideTimer = nil
        panel.setFrame(targetFrame(offset: -10), display: false)
        panel.level = .floating
        panel.orderFrontRegardless()
        board.isFront = true
        syncActivity()
        board.reload()
        board.collectIfStale()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(targetFrame(), display: false)
            panel.animator().alphaValue = 1
        }
    }

    /// Asks the scheduler for interactive latency while the board is in front or the popup is up.
    func syncActivity() {
        let wanted = inFront || popup?.isVisible == true
        if wanted, frontActivity == nil {
            frontActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                  reason: "Agent Board is in front")
        } else if !wanted, let activity = frontActivity {
            ProcessInfo.processInfo.endActivity(activity)
            frontActivity = nil
        }
    }

    func sendBehind() {
        inFront = false
        updateTicker()
        board.isFront = false
        board.closeMenu(surface: "panel")
        syncActivity()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.inFront else { return }
            if self.panel.isKeyWindow {
                self.panel.orderOut(nil)
                self.returnKeyboard()
            }
            self.panel.level = self.behindLevel
            self.panel.setFrame(self.targetFrame(), display: false)
            self.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                self.panel.animator().alphaValue = 1
            }
        })
    }
}
