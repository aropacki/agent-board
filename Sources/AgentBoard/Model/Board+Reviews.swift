import AppKit
import SwiftUI

extension Board {
    func review(for pr: PR) -> AgentReview? { reviews[reviewFileName(pr)] }

    /// Picks up review files as agents write them; the first pass after launch is quiet.
    func loadReviews() {
        let fm = FileManager.default
        let names = Set(((try? fm.contentsOfDirectory(atPath: reviewsDir.path)) ?? []).filter { $0.hasSuffix(".json") })
        for gone in Set(reviews.keys).subtracting(names) {
            reviews[gone] = nil
            reviewStamps[gone] = nil
        }
        for name in names {
            let url = reviewsDir.appendingPathComponent(name)
            guard let stamp = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, stamp != reviewStamps[name],
                  let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            reviewStamps[name] = stamp
            guard let review = parseReview(data) else {
                reviewErrors[name] = "The agent's review file isn't in the shape the board reads."
                continue
            }
            let fresh = reviews[name].map { $0.sha != review.sha || $0.summary != review.summary } ?? true
            reviews[name] = review
            reviewErrors[name] = nil
            if fresh && reviewsLoaded, let pr = allPRs.first(where: { reviewFileName($0) == name }) {
                pushTicker([reviewReadyEvent(pr)])
            }
        }
        reviewsLoaded = true
    }

    func saveReview(_ pr: PR, _ change: (inout AgentReview) -> Void) {
        let name = reviewFileName(pr)
        guard var review = reviews[name] else { return }
        change(&review)
        reviews[name] = review
        guard !isBench, let data = encodeReview(review) else { return }
        let url = reviewURL(pr)
        do {
            try data.write(to: url, options: .atomic)
            reviewStamps[name] = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        } catch {
            show(.error, "Couldn't save the review file.")
        }
    }

    func editGhost(_ pr: PR, _ id: String, body: String) {
        saveReview(pr) { r in if let i = r.comments.firstIndex(where: { $0.id == id }) { r.comments[i].body = body } }
    }

    func dropGhost(_ pr: PR, _ id: String) {
        withAnimation(.snappy(duration: 0.15)) {
            saveReview(pr) { r in if let i = r.comments.firstIndex(where: { $0.id == id }) { r.comments[i].status = "dropped" } }
        }
    }

    func restoreGhosts(_ pr: PR) {
        withAnimation(.snappy(duration: 0.15)) {
            saveReview(pr) { r in for i in r.comments.indices where r.comments[i].status == "dropped" { r.comments[i].status = nil } }
        }
    }

    /// Posts a draft at the commit the agent reviewed, so its line numbers still match.
    func postGhost(_ pr: PR, _ id: String, body: String, done: @escaping (Bool) -> Void) {
        guard let review = review(for: pr), let c = review.comments.first(where: { $0.id == id }), let diff = diffs[pr.key],
              let file = diff.files.first(where: { $0.path == c.path }), let span = ghostSpan(c, in: file) else {
            show(.error, "That line isn't in the diff, so GitHub can't take the comment inline.")
            done(false)
            return
        }
        let sha = review.sha.flatMap { $0.count == 40 ? $0 : nil } ?? diff.sha
        guard let args = reviewCommentArgs(pr, sha: sha, path: c.path, lines: file.lines[span].filter { $0.kind != .hunk }, body: body) else {
            done(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = postReviewComment(args)
            DispatchQueue.main.async {
                if let failure { self.show(.error, failure) } else {
                    self.saveReview(pr) { r in
                        if let i = r.comments.firstIndex(where: { $0.id == id }) {
                            r.comments[i].body = body
                            r.comments[i].status = "posted"
                        }
                    }
                    self.show(.ok, "Posted on \((c.path as NSString).lastPathComponent)")
                    self.loadDiscussion(pr)
                }
                done(failure == nil)
            }
        }
    }

    /// The quick actions on this PR that write findings for the diff viewer.
    func reviewActions(_ pr: PR) -> [ActionItem] { applicable(on: context(pr: pr)).filter(\.action.emitsReview) }
}
