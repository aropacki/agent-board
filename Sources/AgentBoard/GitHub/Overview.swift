import AppKit

enum MergeMethod: String, CaseIterable, Equatable {
    case squash = "SQUASH", merge = "MERGE", rebase = "REBASE"

    var flag: String { "--" + rawValue.lowercased() }
    var title: String {
        switch self {
        case .squash: return "Squash and merge"
        case .merge: return "Merge"
        case .rebase: return "Rebase and merge"
        }
    }
    var short: String {
        switch self {
        case .squash: return "Squash"
        case .merge: return "Merge commit"
        case .rebase: return "Rebase"
        }
    }
}

/// What a PR's page says beyond its diff: the description, where it stands, and what the repo lets you do with it.
struct PROverview: Equatable {
    struct Reviewer: Equatable, Identifiable {
        let login: String
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or REQUESTED for a review not given yet.
        let state: String
        let team: Bool
        var id: String { login }
    }
    struct Label: Equatable, Identifiable {
        let name: String
        let color: String
        var id: String { name }
    }

    let body: String
    /// OPEN, CLOSED, or MERGED.
    let state: String
    let draft: Bool
    let author: String
    let createdAt: Date
    let base: String
    let head: String
    let headSha: String
    let additions: Int
    let deletions: Int
    let files: Int
    let commits: Int
    /// MERGEABLE, CONFLICTING, or UNKNOWN while GitHub works it out.
    let mergeable: String
    /// CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS, DRAFT, or UNKNOWN.
    let mergeState: String
    let decision: String?
    let queueEnabled: Bool
    let queued: Bool
    let queuePosition: Int?
    let autoMerge: MergeMethod?
    let autoMergeBy: String?
    let canUpdateBranch: Bool
    let labels: [Label]
    let reviewers: [Reviewer]
    let methods: [MergeMethod]
    let defaultMethod: MergeMethod?
    let autoMergeAllowed: Bool

    var open: Bool { state == "OPEN" }
}

let overviewQuery = """
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed autoMergeAllowed viewerDefaultMergeMethod
    pullRequest(number: $number) {
      body state isDraft createdAt
      author { login }
      baseRefName headRefName headRefOid
      additions deletions changedFiles
      commits { totalCount }
      mergeable mergeStateStatus reviewDecision
      isMergeQueueEnabled isInMergeQueue mergeQueueEntry { position }
      autoMergeRequest { mergeMethod enabledBy { login } }
      viewerCanUpdateBranch
      labels(first: 20) { nodes { name color } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } ... on Bot { login } } } }
      latestOpinionatedReviews(first: 20, writersOnly: true) { nodes { author { login } state } }
    }
  }
}
"""

private struct OverviewResponse: Decodable {
    struct Nodes<Item: Decodable>: Decodable { let nodes: [Item] }
    struct Login: Decodable { let login: String }
    struct Count: Decodable { let totalCount: Int }
    struct Requested: Decodable {
        let __typename: String
        let login: String?
        let name: String?
    }
    struct Request: Decodable { let requestedReviewer: Requested? }
    struct Review: Decodable {
        let author: Login?
        let state: String
    }
    struct Label: Decodable {
        let name: String
        let color: String
    }
    struct Queue: Decodable { let position: Int? }
    struct AutoMerge: Decodable {
        let mergeMethod: String
        let enabledBy: Login?
    }
    struct PullRequest: Decodable {
        let body: String
        let state: String
        let isDraft: Bool
        let createdAt: String
        let author: Login?
        let baseRefName: String
        let headRefName: String
        let headRefOid: String
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let commits: Count
        let mergeable: String
        let mergeStateStatus: String
        let reviewDecision: String?
        let isMergeQueueEnabled: Bool
        let isInMergeQueue: Bool
        let mergeQueueEntry: Queue?
        let autoMergeRequest: AutoMerge?
        let viewerCanUpdateBranch: Bool
        let labels: Nodes<Label>
        let reviewRequests: Nodes<Request>
        let latestOpinionatedReviews: Nodes<Review>
    }
    struct Repository: Decodable {
        let squashMergeAllowed: Bool
        let mergeCommitAllowed: Bool
        let rebaseMergeAllowed: Bool
        let autoMergeAllowed: Bool
        let viewerDefaultMergeMethod: String?
        let pullRequest: PullRequest
    }
    struct Payload: Decodable { let repository: Repository }
    let data: Payload
}

func parseOverview(_ data: Data) -> PROverview? {
    guard let response = try? JSONDecoder().decode(OverviewResponse.self, from: data) else { return nil }
    let repo = response.data.repository, pr = repo.pullRequest
    let reviewed = pr.latestOpinionatedReviews.nodes.compactMap { r in
        r.author.map { PROverview.Reviewer(login: $0.login, state: r.state, team: false) }
    }
    let given = Set(reviewed.map(\.login))
    let requested = pr.reviewRequests.nodes.compactMap(\.requestedReviewer).compactMap { r -> PROverview.Reviewer? in
        guard let name = r.login ?? r.name, !given.contains(name) else { return nil }
        return PROverview.Reviewer(login: name, state: "REQUESTED", team: r.__typename == "Team")
    }
    let allowed: [(Bool, MergeMethod)] = [(repo.squashMergeAllowed, .squash), (repo.mergeCommitAllowed, .merge),
                                          (repo.rebaseMergeAllowed, .rebase)]
    return PROverview(
        body: cleanCommentBody(pr.body), state: pr.state, draft: pr.isDraft, author: pr.author?.login ?? "ghost",
        createdAt: ISO8601DateFormatter().date(from: pr.createdAt) ?? .distantPast,
        base: pr.baseRefName, head: pr.headRefName, headSha: pr.headRefOid,
        additions: pr.additions, deletions: pr.deletions, files: pr.changedFiles, commits: pr.commits.totalCount,
        mergeable: pr.mergeable, mergeState: pr.mergeStateStatus, decision: pr.reviewDecision,
        queueEnabled: pr.isMergeQueueEnabled, queued: pr.isInMergeQueue, queuePosition: pr.mergeQueueEntry?.position,
        autoMerge: pr.autoMergeRequest.flatMap { MergeMethod(rawValue: $0.mergeMethod) },
        autoMergeBy: pr.autoMergeRequest?.enabledBy?.login,
        canUpdateBranch: pr.viewerCanUpdateBranch,
        labels: pr.labels.nodes.map { PROverview.Label(name: $0.name, color: $0.color) },
        reviewers: reviewed + requested,
        methods: allowed.filter(\.0).map(\.1),
        defaultMethod: repo.viewerDefaultMergeMethod.flatMap(MergeMethod.init(rawValue:)),
        autoMergeAllowed: repo.autoMergeAllowed)
}

/// Blocks; call off the main thread.
func fetchOverview(_ pr: PR) -> Result<PROverview, DiscussionError> {
    let parts = pr.repo.split(separator: "/").map(String.init)
    guard parts.count == 2 else { return .failure(DiscussionError(message: "Unknown repo \(pr.repo).")) }
    let (status, output) = runTool(ghPath, ["api", "graphql", "-f", "query=\(overviewQuery)", "-f", "owner=\(parts[0])",
                                            "-f", "repo=\(parts[1])", "-F", "number=\(pr.number)"])
    guard status == 0, let overview = parseOverview(Data(output.utf8)) else {
        return .failure(DiscussionError(message: withReason("Couldn't load the PR from GitHub.", status == 0 ? "" : output)))
    }
    return .success(overview)
}

enum PRCommand: Equatable {
    /// No method lets a merge queue pick its own. `auto` merges once the requirements pass.
    case merge(MergeMethod?, auto: Bool)
    case disableAuto
    case ready
    case draft
    case updateBranch

    var failure: String {
        switch self {
        case .merge(_, let auto): return auto ? "GitHub didn't turn on auto-merge." : "GitHub didn't merge the PR."
        case .disableAuto: return "GitHub didn't turn off auto-merge."
        case .ready: return "GitHub didn't mark the PR ready."
        case .draft: return "GitHub didn't convert the PR to a draft."
        case .updateBranch: return "GitHub didn't update the branch."
        }
    }

    func done(_ pr: PR, queued: Bool) -> String {
        switch self {
        case .merge(_, let auto):
            return auto ? "Auto-merge is on for #\(pr.number)" : queued ? "Sent #\(pr.number) to the merge queue" : "Merged #\(pr.number)"
        case .disableAuto: return "Auto-merge is off for #\(pr.number)"
        case .ready: return "#\(pr.number) is ready for review"
        case .draft: return "#\(pr.number) is a draft"
        case .updateBranch: return "Updated the branch of #\(pr.number)"
        }
    }
}

/// The `gh` arguments for a command on a PR. A merge names the head commit the user saw, so GitHub refuses it if
/// someone pushed since.
func prCommandArgs(_ pr: PR, _ command: PRCommand, headSha: String) -> [String] {
    let target = [String(pr.number), "--repo", pr.repo]
    switch command {
    case .merge(let method, let auto):
        return ["pr", "merge"] + target + (method.map { [$0.flag] } ?? []) + (auto ? ["--auto"] : [])
            + ["--match-head-commit", headSha]
    case .disableAuto: return ["pr", "merge"] + target + ["--disable-auto"]
    case .ready: return ["pr", "ready"] + target
    case .draft: return ["pr", "ready"] + target + ["--undo"]
    case .updateBranch: return ["pr", "update-branch"] + target
    }
}
