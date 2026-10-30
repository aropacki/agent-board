import AppKit
import SwiftUI

extension Board {
    func loadOverview(_ pr: PR, explicit: Bool = false) {
        guard !overviewLoading.contains(pr.key) else { return }
        overviewLoading.insert(pr.key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchOverview(pr)
            if case .success(let overview) = result { warmMarkdown(document: overview.body) }
            DispatchQueue.main.async {
                self.overviewLoading.remove(pr.key)
                switch result {
                case .success(let o):
                    if self.overviews[pr.key] != o { withAnimation(.snappy(duration: 0.2)) { self.overviews[pr.key] = o } }
                    self.overviewErrors[pr.key] = nil
                    if self.unseenCommits(pr, o) { self.loadDiff(pr) }
                case .failure(let e):
                    self.overviewErrors[pr.key] = e.message
                    if explicit { self.show(.error, e.message) }
                }
            }
        }
    }

    func prCommandKey(_ pr: PR) -> String { "pr-command-\(pr.key)" }

    /// The loaded diff is older than the head GitHub has, so a merge now would land commits nobody looked at here.
    func unseenCommits(_ pr: PR, _ o: PROverview) -> Bool {
        guard let sha = diffs[pr.key]?.sha else { return false }
        return !o.headSha.isEmpty && sha != o.headSha
    }

    /// Refuses a merge while the diff on screen is older than the head, and loads the new one.
    private func refuseUnseen(_ pr: PR, _ o: PROverview) -> Bool {
        guard unseenCommits(pr, o) else { return false }
        show(.error, "#\(pr.number) has new commits. Look them over, then merge.")
        loadDiff(pr)
        return true
    }

    /// Runs a command against the head the overview read, then reads the PR again so the page shows where GitHub
    /// left it.
    func runPRCommand(_ pr: PR, _ command: PRCommand) {
        let key = prCommandKey(pr)
        guard let o = overviews[pr.key], !busy.contains(key) else { return }
        if case .merge = command, refuseUnseen(pr, o) { return }
        setBusy(key, true)
        let args = prCommandArgs(pr, command, headSha: o.headSha)
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, output) = runTool(ghPath, args)
            DispatchQueue.main.async {
                self.setBusy(key, false)
                if status == 0 {
                    self.show(.ok, command.done(pr, queued: o.queueEnabled))
                    self.collect(fresh: true)
                } else {
                    self.show(.error, withReason(command.failure, output))
                }
                self.loadOverview(pr)
                self.loadChecks(pr)
            }
        }
    }

    /// Merges a stacked PR and every open PR below it, then waits for GitHub to say how it went.
    func runStackMerge(_ pr: PR, _ method: MergeMethod?) {
        let key = prCommandKey(pr)
        guard let o = overviews[pr.key], let stack = o.stack, !busy.contains(key), !refuseUnseen(pr, o) else { return }
        setBusy(key, true)
        let args = stackMergeArgs(pr, method: method, headSha: o.headSha)
        DispatchQueue.global(qos: .userInitiated).async {
            var (_, output) = runTool(ghPath, args)
            var result = parseStackMerge(output)
            var polls = 0, misses = 0
            while result?.status == "pending", let uuid = result?.details.uuid, polls < 300, misses < 3 {
                Thread.sleep(forTimeInterval: 1)
                polls += 1
                (_, output) = runTool(ghPath, stackMergePollArgs(pr, uuid: uuid), timeout: readTimeout)
                if let next = parseStackMerge(output) { result = next; misses = 0 } else { misses += 1 }
            }
            DispatchQueue.main.async {
                self.setBusy(key, false)
                switch result?.status {
                case "merged": self.show(.ok, "Merged \(stack.list) into \(stack.base)")
                case "enqueued": self.show(.ok, "Sent \(stack.list) to the merge queue")
                case "pending": self.show(.error, "GitHub is still merging \(stack.list). Check the PRs on GitHub.")
                default:
                    let reason = result?.details.message ?? failureReason(
                        output.split(separator: "\n").filter { !$0.hasPrefix("{") }.joined(separator: "\n"))
                    self.show(.error, "GitHub didn't merge \(stack.list)" + (reason.map { " (\($0))" } ?? "."))
                }
                self.collect(fresh: true)
                self.loadOverview(pr)
                self.loadChecks(pr)
            }
        }
    }
}
