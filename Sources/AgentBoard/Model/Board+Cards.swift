import AppKit
import SwiftUI

extension Board {
    func hide(_ pr: PR) { hide([pr]) }

    func unhide(_ prs: [PR]) {
        let urls = Set(prs.map(\.url))
        let kept = ((try? String(contentsOf: hiddenPRsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !urls.contains($0) }
        try? (kept.map { $0 + "\n" }.joined()).write(to: hiddenPRsURL, atomically: true, encoding: .utf8)
        show(.ok, prs.count == 1 ? "Unhid #\(prs[0].number)" : "Unhid \(prs.count) PRs")
        collect()
    }

    func editHiddenChats(_ change: (inout [String: Double]) -> Void) {
        var map = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: hiddenChatsURL))) ?? [:]
        change(&map)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: hiddenChatsURL, options: .atomic) }
    }

    func hide(_ card: Card, quiet: Bool = false) {
        editHiddenChats { $0[card.id] = Date().timeIntervalSince1970 }
        if !quiet { show(.ok, "Hid “\(card.title)”") }
        collect()
    }

    func decayNeeds(step: Double) {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let due = needsClock.tick(needs: BoardLists(state).needs, step: step, idle: idle)
        UserDefaults.standard.set(needsClock.waited, forKey: "needsActiveSeconds")
        for card in due { moveToRecent(card, quiet: true) }
        let unread = due.flatMap(\.minePRs).filter { !$0.unread.isEmpty }
        alert?(unread.map { pr in
            TickerEvent(kind: .comments, text: commentText(pr.unread.count, pr.unread[0], "#\(pr.number) \(pr.displayTitle)"),
                        target: "comments:\(pr.key)")
        })
    }

    /// Quiets the card's current reasons; a reason that clears and comes back shows again. Unread comments are the
    /// exception: waiting never quiets them, and moving the card yourself reads them.
    func moveToRecent(_ card: Card, quiet: Bool = false) {
        markSeen(card.id)
        if !quiet { readComments(card.minePRs) }
        let reasons = card.needsYou.filter { $0 != "finished" && $0 != "new comments" }
        if !reasons.isEmpty {
            var map = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dismissedURL))) as? [String: [String]] ?? [:]
            map[card.id] = Array(Set((map[card.id] ?? []) + reasons)).sorted()
            if let data = try? JSONSerialization.data(withJSONObject: map) { try? data.write(to: dismissedURL, options: .atomic) }
        }
        if !quiet { show(.ok, "Moved “\(card.title)” to Recent") }
        collect()
    }

    func unhide(_ card: Card) {
        editHiddenChats { $0[card.id] = nil }
        show(.ok, "Unhid “\(card.title)”")
        collect()
    }

    func hide(_ prs: [PR]) {
        guard !prs.isEmpty else { return }
        let existing = (try? String(contentsOf: hiddenPRsURL, encoding: .utf8)) ?? ""
        try? FileManager.default.createDirectory(at: hiddenPRsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let added = prs.map { $0.url + "\n" }.joined()
        try? (existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + added).write(to: hiddenPRsURL, atomically: true, encoding: .utf8)
        show(.ok, prs.count == 1 ? "Hid #\(prs[0].number)" : "Hid \(prs.count) PRs")
        selected.removeAll { key in prs.contains { $0.key == key } }
        collect()
    }

    // MARK: Selection

    func isSelected(_ pr: PR) -> Bool { selected.contains(pr.key) }

    func toggleSelect(_ pr: PR) {
        withAnimation(.snappy(duration: 0.15)) {
            if let i = selected.firstIndex(of: pr.key) { selected.remove(at: i) } else { selected.append(pr.key) }
        }
    }

    func clearSelection() { withAnimation(.snappy(duration: 0.15)) { selected.removeAll() } }

    func tapReturn(_ slot: Slot) {
        guard confirmReturn == slot.path else {
            withAnimation(.snappy) { confirmReturn = slot.path }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.confirmReturn == slot.path { withAnimation(.snappy) { self?.confirmReturn = nil } }
            }
            return
        }
        withAnimation(.snappy) { confirmReturn = nil }
        let key = "return-\(slot.path)"
        setBusy(key, true)
        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = runTool("/bin/bash", [actScript, "return", slot.path])
            DispatchQueue.main.async {
                self.setBusy(key, false)
                if code == 0 { self.show(.ok, "Returned \(slot.label)") } else { self.show(.error, out.isEmpty ? "Return failed" : out) }
                self.collect()
            }
        }
    }
}
