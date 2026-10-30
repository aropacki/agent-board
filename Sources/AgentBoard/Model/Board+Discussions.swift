import AppKit
import SwiftUI

extension Board {
    func openDiscussion(_ pr: PR, surface: String) {
        withAnimation(.snappy(duration: 0.2)) { checksOpen = nil; discussion = (pr.key, surface) }
        loadDiscussion(pr)
        readComments([pr])
    }

    /// Comments stay new until you open them here or write on the PR yourself.
    func readComments(_ prs: [PR]) {
        let unread = prs.filter { !$0.unread.isEmpty }
        guard !unread.isEmpty else { return }
        unread.forEach { markSeen($0.key) }
        collect()
    }

    func closeDiscussion() { withAnimation(.snappy(duration: 0.2)) { discussion = nil } }

    func reply(_ pr: PR, threadID: String?, body: String, done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = postComment(pr, threadID: threadID, body: body)
            DispatchQueue.main.async {
                if let failure { self.show(.error, failure) } else {
                    self.show(.ok, "Replied on #\(pr.number)")
                    self.loadDiscussion(pr)
                }
                done(failure == nil)
            }
        }
    }

    /// `explicit` is the user asking, which starts a fetch even with one in flight: the one in flight may be the
    /// reason they asked.
    func loadDiscussion(_ pr: PR, explicit: Bool = false) {
        guard explicit || !discussionLoading.contains(pr.key) else { return }
        discussionLoading.insert(pr.key)
        let request = (discussionRequests[pr.key] ?? 0) + 1
        discussionRequests[pr.key] = request
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchDiscussion(pr)
            DispatchQueue.main.async {
                guard self.discussionRequests[pr.key] == request else { return }
                self.discussionLoading.remove(pr.key)
                switch result {
                case .success(let d):
                    if self.discussions[pr.key] != d { withAnimation(.snappy(duration: 0.2)) { self.discussions[pr.key] = d } }
                    self.discussionErrors[pr.key] = nil
                    self.discussionsFetchedAt[pr.key] = Date()
                    self.discussionsUnresolved[pr.key] = pr.unresolved
                    self.refreshSucceeded("discussion")
                    self.saveFetchCache()
                case .failure(let e):
                    self.discussionErrors[pr.key] = e.message
                    self.refreshFailed("discussion", e.message, explicit: explicit)
                }
            }
        }
    }

    /// Shows the change at once and puts it back when GitHub refuses it.
    func setResolved(_ pr: PR, _ t: ReviewThread, _ resolved: Bool) {
        let key = "resolve-\(t.id)"
        guard !busy.contains(key) else { return }
        markResolved(pr, t.id, resolved)
        setBusy(key, true)
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = setThreadResolved(t.id, resolved)
            DispatchQueue.main.async {
                self.setBusy(key, false)
                if let failure {
                    self.markResolved(pr, t.id, !resolved)
                    self.show(.error, failure)
                    return
                }
                self.show(.ok, resolved ? "Resolved the thread on #\(pr.number)" : "Reopened the thread on #\(pr.number)")
                self.loadDiscussion(pr)
                self.collect()
            }
        }
    }

    func markResolved(_ pr: PR, _ threadID: String, _ resolved: Bool) {
        guard var d = discussions[pr.key], let i = d.threads.firstIndex(where: { $0.id == threadID }) else { return }
        d.threads[i].resolved = resolved
        withAnimation(.snappy(duration: 0.2)) { discussions[pr.key] = d }
    }
}
