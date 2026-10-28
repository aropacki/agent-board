import AppKit
import SwiftUI

struct TickerEvent: Equatable, Identifiable, Codable {
    enum Kind: String, Codable { case finished, needsYou, review, ciFailed, ciPassed, approved, changes, comments, agentReview }
    let kind: Kind
    let text: String
    var id = UUID()
    var at = Date()
    /// `card:<chat id>`, `comments:`, `checks:`, or `diff:` and a PR key, or a URL: what the activity log opens.
    var target: String? = nil

    /// "Finished: Title" splits into the label and the subject.
    var label: String { text.range(of: ": ").map { String(text[..<$0.lowerBound]) } ?? "" }
    var subject: String { text.range(of: ": ").map { String(text[$0.upperBound...]) } ?? text }
    static func == (a: TickerEvent, b: TickerEvent) -> Bool { a.kind == b.kind && a.text == b.text }

    var icon: String {
        switch kind {
        case .finished: return "checkmark.circle.fill"
        case .needsYou: return "bell.fill"
        case .review: return "eye.fill"
        case .ciFailed: return "xmark.circle.fill"
        case .ciPassed: return "checkmark.seal.fill"
        case .approved: return "hand.thumbsup.fill"
        case .changes: return "exclamationmark.bubble.fill"
        case .comments: return "text.bubble.fill"
        case .agentReview: return "sparkles"
        }
    }
    var color: Color {
        switch kind {
        case .comments, .agentReview: return T.blue
        case .finished, .ciPassed, .approved: return T.green
        case .needsYou, .changes: return T.orange
        case .review: return T.purple
        case .ciFailed: return T.red
        }
    }
}

/// What changed between two collects, worth a glance. Hidden chats and PRs say nothing.
/// Counts only the minutes you are at the Mac, so walking away never shuffles Needs you.
struct NeedsClock {
    static let limit: Double = 3600
    static let awayAfter: Double = 120
    var waited: [String: Double] = [:]

    /// Returns the agents that have waited through `limit` active seconds.
    mutating func tick(needs: [Card], step: Double, idle: Double) -> [Card] {
        let ids = Set(needs.map(\.id))
        waited = waited.filter { ids.contains($0.key) }
        guard idle < NeedsClock.awayAfter else { return [] }
        var due: [Card] = []
        for card in needs {
            let total = (waited[card.id] ?? 0) + step
            if total >= NeedsClock.limit {
                waited[card.id] = nil
                due.append(card)
            } else {
                waited[card.id] = total
            }
        }
        return due
    }
}

func tickerEvents(from old: BoardState, to new: BoardState) -> [TickerEvent] {
    var out: [TickerEvent] = []
    let oldCards = Dictionary(old.allCards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for card in new.allCards where card.hidden != true && card.kind != "subagent" {
        let before = oldCards[card.id]
        let wasRunning = before?.status == "running"
        if wasRunning && card.status != "running" {
            out.append(TickerEvent(kind: .finished, text: "Finished: \(card.title)", target: "card:\(card.id)"))
        }
        let added = card.needsYou.filter { !(before?.needsYou ?? []).contains($0) && $0 != "finished" }
        if !added.isEmpty {
            out.append(TickerEvent(kind: .needsYou, text: "Needs you: \(card.title) · \(added.joined(separator: ", "))",
                                   target: "card:\(card.id)"))
        }
    }
    let oldReview = Set((old.prs?.review ?? []).map(\.key))
    for pr in new.prs?.review ?? [] where !oldReview.contains(pr.key) && pr.hidden != true && !pr.stale {
        out.append(TickerEvent(kind: .review, text: "Review requested: #\(pr.number) \(pr.displayTitle) · @\(pr.author)",
                               target: pr.url))
    }
    let oldMine = Dictionary((old.prs?.mine ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    for pr in new.prs?.mine ?? [] where pr.hidden != true {
        guard let before = oldMine[pr.key] else { continue }
        let name = "#\(pr.number) \(pr.displayTitle)"
        if pr.ci == "failing" && before.ci != "failing" {
            out.append(TickerEvent(kind: .ciFailed, text: "CI failing: \(name)", target: "checks:\(pr.key)"))
        }
        if pr.ci == "passing" && (before.ci == "failing" || before.ci == "running") {
            out.append(TickerEvent(kind: .ciPassed, text: "CI passed: \(name)", target: pr.url))
        }
        if pr.review != before.review {
            if pr.review == "APPROVED" { out.append(TickerEvent(kind: .approved, text: "Approved: \(name)", target: pr.url)) }
            if pr.review == "CHANGES_REQUESTED" {
                out.append(TickerEvent(kind: .changes, text: "Changes requested: \(name)", target: "comments:\(pr.key)"))
            }
        }
        let seen = Set(before.unread.map(\.url))
        let added = pr.unread.filter { !seen.contains($0.url) }
        if let newest = added.first {
            out.append(TickerEvent(kind: .comments, text: commentText(added.count, newest, name), target: "comments:\(pr.key)"))
        }
    }
    return out
}

func commentText(_ count: Int, _ newest: PRComment, _ name: String) -> String {
    let who = count == 1 ? "Comment from @\(newest.author)" : "\(count) new comments"
    return newest.excerpt.isEmpty ? "\(who): \(name)" : "\(who): \(name) · “\(newest.excerpt)”"
}

/// The log keeps a week, capped so the file stays small.
func trimActivity(_ log: [TickerEvent], now: Date, keep: Int = 300, days: Double = 7) -> [TickerEvent] {
    Array(log.filter { now.timeIntervalSince($0.at) < days * 86400 }.suffix(keep))
}

func loadActivity() -> [TickerEvent] {
    guard let data = try? Data(contentsOf: activityURL) else { return [] }
    return trimActivity((try? JSONDecoder().decode([TickerEvent].self, from: data)) ?? [], now: Date())
}

func saveActivity(_ log: [TickerEvent]) {
    guard let data = try? JSONEncoder().encode(log) else { return }
    DispatchQueue.global(qos: .utility).async { try? data.write(to: activityURL, options: .atomic) }
}
