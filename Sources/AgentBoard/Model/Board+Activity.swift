import AppKit
import SwiftUI

extension Board {
    func markActivitySeen() {
        activitySeenAt = Date()
        UserDefaults.standard.set(activitySeenAt, forKey: "activitySeenAt")
    }

    func openActivity(_ event: TickerEvent, surface: String = "panel") {
        guard let target = event.target else { return }
        if target.hasPrefix("card:") {
            open(id: String(target.dropFirst(5)))
        } else if target.hasPrefix("comments:"), let pr = pr(key: String(target.dropFirst(9))) {
            openDiscussion(pr, surface: surface)
        } else if target.hasPrefix("checks:"), let pr = pr(key: String(target.dropFirst(7))) {
            openChecks(pr, surface: surface)
        } else if target.hasPrefix("diff:"), let pr = pr(key: String(target.dropFirst(5))) {
            openDiff(pr)
        } else if target.hasPrefix("comments:") || target.hasPrefix("checks:") || target.hasPrefix("diff:") {
            show(.error, "That PR is no longer on the board.")
        } else {
            openLink(target)
        }
    }

    /// Each event holds the ticker for a few seconds; a burst keeps only its newest few.
    func pushTicker(_ events: [TickerEvent], log: Bool = true) {
        guard !events.isEmpty else { return }
        if log {
            activity = trimActivity(activity + events, now: Date())
            saveActivity(activity)
        }
        tickerQueue = Array((tickerQueue + events).suffix(6))
        if tickerNote == nil { advanceTicker() }
    }

    func advanceTicker() {
        guard !tickerQueue.isEmpty else {
            withAnimation(.easeInOut(duration: 0.8)) { tickerNote = nil }
            return
        }
        let next = tickerQueue.removeFirst()
        withAnimation(.easeInOut(duration: 0.8)) {
            tickerNote = next
            tickerLast = next
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.advanceTicker() }
    }
}
