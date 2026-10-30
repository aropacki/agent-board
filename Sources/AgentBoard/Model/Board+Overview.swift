import AppKit
import SwiftUI

extension Board {
    func loadOverview(_ pr: PR, explicit: Bool = false) {
        guard !overviewLoading.contains(pr.key) else { return }
        overviewLoading.insert(pr.key)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = fetchOverview(pr)
            DispatchQueue.main.async {
                self.overviewLoading.remove(pr.key)
                switch result {
                case .success(let o):
                    if self.overviews[pr.key] != o { withAnimation(.snappy(duration: 0.2)) { self.overviews[pr.key] = o } }
                    self.overviewErrors[pr.key] = nil
                case .failure(let e):
                    self.overviewErrors[pr.key] = e.message
                    if explicit { self.show(.error, e.message) }
                }
            }
        }
    }

    func prCommandKey(_ pr: PR) -> String { "pr-command-\(pr.key)" }

    /// Runs a command against the head whose diff is loaded, or else the one the overview read, then reads the PR
    /// again so the page shows where GitHub left it.
    func runPRCommand(_ pr: PR, _ command: PRCommand) {
        let key = prCommandKey(pr)
        guard let o = overviews[pr.key], !busy.contains(key) else { return }
        setBusy(key, true)
        let args = prCommandArgs(pr, command, headSha: diffs[pr.key]?.sha ?? o.headSha)
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
}
