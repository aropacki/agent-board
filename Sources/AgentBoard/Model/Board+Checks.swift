import AppKit
import SwiftUI

extension Board {
    func openChecks(_ pr: PR, surface: String) {
        closeChecksPeek()
        withAnimation(.snappy(duration: 0.2)) { discussion = nil; checksOpen = (pr.key, surface) }
        loadChecksIfStale(pr)
    }

    func closeChecks() { withAnimation(.snappy(duration: 0.2)) { checksOpen = nil } }

    func loadChecks(_ pr: PR, explicit: Bool = false) { loadChecks([pr], explicit: explicit) }

    /// Small batches run in parallel and each shows as it lands: GitHub answers six PRs far sooner than
    /// twenty-five, at the same rate-limit cost. Keeps what is already shown when a fetch fails.
    func loadChecks(_ prs: [PR], explicit: Bool = false) {
        let wanted = prs.filter { !checksLoading.contains($0.key) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { checksLoading.insert($0.key) }
        let size = 6
        let group = DispatchGroup()
        var failure: DiscussionError?
        for start in stride(from: 0, to: wanted.count, by: size) {
            let batch = Array(wanted[start..<min(start + size, wanted.count)])
            group.enter()
            DispatchQueue.global(qos: explicit ? .userInitiated : .utility).async {
                let result = fetchChecks(batch)
                DispatchQueue.main.async {
                    let got = try? result.get()
                    for pr in batch {
                        self.checksLoading.remove(pr.key)
                        if let checks = got?[pr.key] {
                            if self.checks[pr.key] != checks { self.checks[pr.key] = checks }
                            self.checksErrors[pr.key] = nil
                            self.checksFetchedAt[pr.key] = Date()
                        } else if self.checks[pr.key] == nil {
                            self.checksErrors[pr.key] = "Could not load the checks from GitHub."
                        }
                    }
                    if case .failure(let e) = result { failure = failure ?? e }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if let failure { self.refreshFailed("checks", failure.message, explicit: explicit) } else { self.refreshSucceeded("checks") }
            self.saveFetchCache()
        }
    }

    func hoverChecksFact(_ pr: PR, surface: String, anchor: CGRect, inside: Bool) {
        if inside {
            peekFact = ChecksPeek(key: pr.key, surface: surface, anchor: anchor)
            loadChecksIfStale(pr)
        } else if peekFact?.key == pr.key {
            peekFact = nil
        }
        settlePeek()
    }

    func hoverChecksList(_ inside: Bool) {
        peekOverList = inside
        settlePeek()
    }

    func closeChecksPeek() {
        peekWork?.cancel()
        peekFact = nil
        peekOverList = false
        if checksPeek != nil { withAnimation(.easeOut(duration: 0.08)) { checksPeek = nil } }
    }

    /// A short wait before showing, so passing over the fact does nothing, and before hiding, so the
    /// pointer can cross into the list.
    func settlePeek() {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let fact = self.peekFact {
                if self.checksPeek != fact, self.menu == nil { withAnimation(.easeOut(duration: 0.1)) { self.checksPeek = fact } }
            } else if !self.peekOverList, self.checksPeek != nil {
                withAnimation(.easeOut(duration: 0.08)) { self.checksPeek = nil }
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (peekFact != nil && checksPeek == nil ? 0.35 : 0.2), execute: work)
    }

    /// A PR's CI as every surface shows it: from whichever is newer, the checks this app loaded or the
    /// collector's PR data, which can trail a rerun by a few minutes.
    func ci(_ pr: PR) -> String {
        guard let loaded = checks[pr.key], let at = checksFetchedAt[pr.key],
              at.timeIntervalSince1970 > prsFetchedAt ?? 0 else { return pr.ci }
        return ciVerdict(loaded, required: pr.requiredChecks ?? [])
    }

    func loadChecksIfStale(_ pr: PR, age: TimeInterval = 20) {
        if Date().timeIntervalSince(checksFetchedAt[pr.key] ?? .distantPast) > age { loadChecks(pr) }
    }
}
