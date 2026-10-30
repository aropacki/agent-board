import AppKit
import SwiftUI
import UserNotifications

/// System banners for what another person is waiting on you for, the way a chat app shows a direct message.
/// Everything else stays in the ticker.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let alerting: Set<TickerEvent.Kind> = [.comments, .changes, .review]
    let board: Board
    let center = UNUserNotificationCenter.current()
    private var pictures: [TickerEvent.Kind: Data] = [:]

    init(board: Board) {
        self.board = board
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ events: [TickerEvent]) {
        for event in events where Notifier.alerting.contains(event.kind) {
            let content = UNMutableNotificationContent()
            content.title = event.label
            content.body = event.subject
            content.sound = .default
            content.threadIdentifier = event.target ?? event.kind.rawValue
            content.userInfo = ["target": event.target ?? "", "kind": event.kind.rawValue]
            if let picture = picture(event) { content.attachments = [picture] }
            center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        }
    }

    /// The event's symbol on a tile in its color, so the kind reads before the words do. The system moves an
    /// attachment's file into its own store, so each banner gets a fresh copy.
    func picture(_ event: TickerEvent) -> UNNotificationAttachment? {
        guard let png = pictures[event.kind] ?? drawPicture(event) else { return nil }
        pictures[event.kind] = png
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "picture", url: url)
    }

    func drawPicture(_ event: TickerEvent) -> Data? {
        let side = 240, tint = NSColor(event.color)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 54, yRadius: 54)
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1),
                            NSColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)])?.draw(in: tile, angle: -90)
        NSGradient(colors: [tint.withAlphaComponent(0.45), tint.withAlphaComponent(0)])?
            .draw(fromCenter: CGPoint(x: tile.midX, y: tile.midY), radius: 0,
                  toCenter: CGPoint(x: tile.midX, y: tile.midY), radius: CGFloat(side) * 0.62, options: [])
        let config = NSImage.SymbolConfiguration(pointSize: 104, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, tint, tint]))
        if let symbol = NSImage(systemSymbolName: event.icon, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let target = info["target"] as? String ?? ""
        let kind = (info["kind"] as? String).flatMap(TickerEvent.Kind.init(rawValue:)) ?? .comments
        DispatchQueue.main.async { [board] in
            board.openBoard()
            board.openActivity(TickerEvent(kind: kind, text: "", target: target), surface: "window")
        }
        completionHandler()
    }
}
