import AppKit
import SwiftUI

extension Board {
    func openDiff(_ pr: PR, path: String? = nil, line: Int? = nil, thread: String? = nil) {
        closeMenu()
        diffSelection = nil
        let target = DiffTarget(key: pr.key, path: path, line: line, thread: thread)
        if popupPresented {
            withAnimation(Motion.content) { diffOpen = target }
            popupChanged?()
        } else {
            diffOpen = target
            presentPopup()
        }
        if diffs[pr.key] == nil { loadDiff(pr) }
        loadDiscussion(pr)
        loadOverview(pr)
    }

    func isReviewed(_ pr: PR, _ f: DiffFile) -> Bool { reviewedFiles[pr.key]?[f.path] == f.stamp }

    func setReviewed(_ pr: PR, _ f: DiffFile, _ on: Bool) {
        reviewedFiles[pr.key, default: [:]][f.path] = on ? f.stamp : nil
        let live = Set(allPRs.map(\.key))
        reviewedFiles = reviewedFiles.filter { live.contains($0.key) && !$0.value.isEmpty }
        if !isBench { UserDefaults.standard.set(reviewedFiles, forKey: "diffReviewed") }
    }

    func closeDiff() {
        diffSelection = nil
        diffOpenNotes = []
        if boardOpen {
            withAnimation(Motion.content) { diffOpen = nil }
            popupChanged?()
        } else {
            dismissPopupWindow()
        }
    }

    /// Escape clears a picked range first, then closes the popup.
    func escapeDiff() -> Bool {
        guard diffOpen != nil else { return false }
        if diffSelection != nil { diffSelection = nil } else { closeDiff() }
        return true
    }

    func loadDiff(_ pr: PR, explicit: Bool = false) {
        guard !diffLoading.contains(pr.key) else { return }
        diffLoading.insert(pr.key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchDiff(pr)
            DispatchQueue.main.async {
                self.diffLoading.remove(pr.key)
                switch result {
                case .success(let d):
                    self.diffs[pr.key] = d
                    self.diffErrors[pr.key] = nil
                case .failure(let e):
                    self.diffErrors[pr.key] = e.message
                    if explicit { self.show(.error, e.message) }
                }
            }
        }
        if discussions[pr.key] == nil { loadDiscussion(pr) }
    }

    func commentOnDiff(_ pr: PR, file: DiffFile, lines: [DiffLine], body: String, done: @escaping (Bool) -> Void) {
        guard let sha = diffs[pr.key]?.sha,
              let args = reviewCommentArgs(pr, sha: sha, path: file.path, lines: lines, body: body) else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = postReviewComment(args)
            DispatchQueue.main.async {
                if let failure { self.show(.error, failure) } else {
                    self.show(.ok, "Commented on \((file.path as NSString).lastPathComponent)")
                    self.diffSelection = nil
                    self.diffDraft = ""
                    self.loadDiscussion(pr)
                }
                done(failure == nil)
            }
        }
    }

    // MARK: Popup
}
