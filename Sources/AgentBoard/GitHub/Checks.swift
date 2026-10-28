import AppKit

struct CICheck: Identifiable, Equatable, Codable {
    let name: String
    let workflow: String?
    /// pass, fail, pending, skipping, or cancel, as `gh pr checks` buckets them.
    let bucket: String
    let link: String?
    let started: Date?
    let completed: Date?
    var id: String { (workflow ?? "") + "|" + name }
}

/// GitHub reports a time that has not happened yet as year 1.
func checkDate(_ s: String?) -> Date? {
    guard let s, let d = ISO8601DateFormatter().date(from: s), d.timeIntervalSince1970 > 0 else { return nil }
    return d
}

/// A check run's status and conclusion, or a commit status's state, bucketed the way `gh pr checks` does.
func checkBucket(status: String?, conclusion: String?, state: String?) -> String {
    if let state {
        switch state {
        case "SUCCESS": return "pass"
        case "FAILURE", "ERROR": return "fail"
        default: return "pending"
        }
    }
    guard status == "COMPLETED" else { return "pending" }
    switch conclusion {
    case "SUCCESS", "NEUTRAL": return "pass"
    case "SKIPPED": return "skipping"
    case "CANCELLED": return "cancel"
    default: return "fail"
    }
}

/// A cancelled run was stopped, usually by a newer push, so it says nothing about the code.
func checkSkipped(_ c: CICheck) -> Bool { c.bucket == "skipping" || c.bucket == "cancel" }

/// Failures first, then passes, then what is still running, then skipped and cancelled.
func sortedChecks(_ checks: [CICheck]) -> [CICheck] {
    func rank(_ c: CICheck) -> Int {
        if checkSkipped(c) { return 3 }
        switch c.bucket {
        case "fail": return 1
        case "pass": return 2
        default: return 0
        }
    }
    return checks.sorted { (rank($0), $0.workflow ?? "", $0.name) < (rank($1), $1.workflow ?? "", $1.name) }
}

let checksFragment = """
commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
  __typename
  ... on CheckRun { name status conclusion startedAt completedAt detailsUrl checkSuite { workflowRun { workflow { name } } } }
  ... on StatusContext { context state targetUrl }
} } } } } }
"""

/// One query for many PRs, each under the alias `p<index>`.
func checksQuery(_ prs: [PR]) -> String {
    let parts = prs.enumerated().compactMap { i, pr -> String? in
        let repo = pr.repo.split(separator: "/")
        guard repo.count == 2 else { return nil }
        return "p\(i): repository(owner: \"\(repo[0])\", name: \"\(repo[1])\") { pullRequest(number: \(pr.number)) { \(checksFragment) } }"
    }
    return "query { " + parts.joined(separator: " ") + " }"
}

/// The checks under each alias, by index. A PR GitHub did not return is left out; a PR without CI has
/// no checks. A re-run job keeps only its latest run.
func parseCheckRollups(_ output: String) -> [Int: [CICheck]]? {
    guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"),
          let root = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
          let payload = root["data"] as? [String: Any] else { return nil }
    func dig(_ value: Any?, _ keys: String...) -> Any? {
        keys.reduce(value) { ($0 as? [String: Any])?[$1] }
    }
    var out: [Int: [CICheck]] = [:]
    for (alias, value) in payload {
        guard alias.hasPrefix("p"), let i = Int(alias.dropFirst()),
              let pr = dig(value, "pullRequest") as? [String: Any] else { continue }
        let commit = (dig(pr, "commits", "nodes") as? [[String: Any]])?.last?["commit"]
        let nodes = dig(commit, "statusCheckRollup", "contexts", "nodes") as? [[String: Any]] ?? []
        var latest: [String: CICheck] = [:]
        for n in nodes {
            let check = n["__typename"] as? String == "StatusContext"
                ? CICheck(name: n["context"] as? String ?? "", workflow: nil,
                          bucket: checkBucket(status: nil, conclusion: nil, state: n["state"] as? String),
                          link: n["targetUrl"] as? String, started: nil, completed: nil)
                : CICheck(name: n["name"] as? String ?? "", workflow: dig(n, "checkSuite", "workflowRun", "workflow", "name") as? String,
                          bucket: checkBucket(status: n["status"] as? String, conclusion: n["conclusion"] as? String, state: nil),
                          link: n["detailsUrl"] as? String, started: checkDate(n["startedAt"] as? String),
                          completed: checkDate(n["completedAt"] as? String))
            if let seen = latest[check.id], (seen.started ?? .distantPast) >= (check.started ?? .distantPast) { continue }
            latest[check.id] = check
        }
        // A stable order lets an unchanged refetch compare equal, which skips the view update and the cache write.
        out[i] = latest.values.sorted { $0.id < $1.id }
    }
    return out
}

/// Blocks. Checks for many PRs in one request, by PR key.
func fetchChecks(_ prs: [PR]) -> Result<[String: [CICheck]], DiscussionError> {
    let (_, output) = runTool(ghPath, ["api", "graphql", "-f", "query=\(checksQuery(prs))"])
    guard let rollups = parseCheckRollups(output) else {
        return .failure(DiscussionError(message: withReason("Couldn't load CI checks from GitHub.", output)))
    }
    return .success(Dictionary(rollups.compactMap { i, c in i < prs.count ? (prs[i].key, c) : nil }, uniquingKeysWith: { a, _ in a }))
}
