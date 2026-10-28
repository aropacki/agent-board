import AppKit
import UserNotifications

/// System banners for what another person is waiting on you for, the way a chat app shows a direct message.
/// Everything else stays in the ticker.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let alerting: Set<TickerEvent.Kind> = [.comments, .changes, .review]
    let board: Board
    let center = UNUserNotificationCenter.current()

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
            center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        }
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
