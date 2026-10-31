import AppKit
import SwiftUI

/// Banners for what another person is waiting on you for, the way a chat app shows a direct message.
/// Everything else stays in the ticker. The board draws them itself, because a system banner can't be styled.
final class Notifier {
    static let alerting: Set<TickerEvent.Kind> = [.comments, .changes, .review, .issue]
    let board: Board
    let banners = Banners()
    let window: NSPanel
    private var size: CGSize = .zero
    private var shrink: DispatchWorkItem?

    init(board: Board, space: OverlaySpace) {
        self.board = board
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        let host = FirstClickHostingView(rootView: BannerStack(banners: banners, open: { [weak self] in self?.open($0) },
                                                               close: { [weak self] in self?.dismiss($0) },
                                                               resized: { [weak self] in self?.resize($0) }))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        space.add(window)
    }

    func post(_ events: [TickerEvent]) {
        let fresh = events.filter { Notifier.alerting.contains($0.kind) }
        guard !fresh.isEmpty else { return }
        NSSound.beep()
        window.ignoresMouseEvents = false
        banners.add(fresh)
    }

    func dismiss(_ id: UUID) {
        banners.remove(id)
        if banners.items.isEmpty { window.ignoresMouseEvents = true }
    }

    func open(_ event: TickerEvent) {
        dismiss(event.id)
        board.openBoard()
        board.openActivity(event, surface: "window")
    }

    /// Grows at once so an arriving banner is never clipped, and shrinks after a removal has faded out.
    func resize(_ wanted: CGSize) {
        shrink?.cancel()
        if wanted.height >= size.height && wanted.width >= size.width {
            place(wanted)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.place(wanted) }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// The card's corner sits just inside the screen's top right, under the menu bar.
    func place(_ wanted: CGSize) {
        size = wanted
        guard let screen = NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        let reach = BannerStack.pad - 8
        window.setFrame(NSRect(x: v.maxX - wanted.width + reach, y: v.maxY - wanted.height + reach,
                               width: wanted.width, height: wanted.height), display: true)
    }
}
