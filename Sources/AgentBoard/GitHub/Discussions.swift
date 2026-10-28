import AppKit

struct ThreadComment: Identifiable, Equatable, Codable {
    let id: String
    let author: String
    let bot: Bool
    let body: String
    let at: Date
}

struct ReviewThread: Identifiable, Equatable, Codable {
    let id: String
    var resolved: Bool
    let outdated: Bool
    let path: String
    let line: Int?
    /// The end of the diff hunk, oldest line first; the last `highlighted` lines are what the comment is on.
    let context: [String]
    let highlighted: Int
    let comments: [ThreadComment]
    /// LEFT when the thread is on a deleted line, so `line` is the old file's number.
    var side: String? = nil
    var startLine: Int? = nil
    var url: String { comments.first?.id ?? "" }
    var bot: Bool { comments.first?.bot ?? false }
    var lastActivity: Date { comments.map(\.at).max() ?? .distantPast }
}

struct PRDiscussion: Equatable, Codable {
    var threads: [ReviewThread]
    let conversation: [ThreadComment]
}

let discussionQuery = """
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated path line startLine originalLine originalStartLine diffSide
          comments(first: 50) { nodes { author { login __typename } body createdAt url diffHunk } }
        }
      }
      comments(last: 50) { nodes { author { login __typename } body createdAt url } }
      reviews(last: 50) { nodes { author { login __typename } body submittedAt url } }
    }
  }
}
"""

private struct DiscussionResponse: Decodable {
    struct Nodes<Item: Decodable>: Decodable { let nodes: [Item] }
    struct Author: Decodable {
        let login: String
        let __typename: String?
    }
    struct Comment: Decodable {
        let author: Author?
        let body: String
        let createdAt: String?
        let submittedAt: String?
        let url: String
        let diffHunk: String?
    }
    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String
        let line: Int?
        let startLine: Int?
        let originalLine: Int?
        let originalStartLine: Int?
        let diffSide: String?
        let comments: Nodes<Comment>
    }
    struct PullRequest: Decodable {
        let reviewThreads: Nodes<Thread>
        let comments: Nodes<Comment>
        let reviews: Nodes<Comment>
    }
    struct Repository: Decodable { let pullRequest: PullRequest }
    struct Payload: Decodable { let repository: Repository }
    let data: Payload
}

/// Drops what GitHub renders but a reader does not: HTML comments, layout tags, extra blank lines.
/// Only named HTML tags go, so generics like `Array<String>` in code survive.
func cleanCommentBody(_ body: String) -> String {
    var s = body.replacingOccurrences(of: "\r\n", with: "\n")
    s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "</?(details|summary|div|span|p|img|a|sub|sup|b|i|strong|em|h[1-6]|table|tr|td|th|thead|tbody|ul|ol|li|picture|source|kbd|hr)\\b[^>]*>",
                               with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseDiscussion(_ data: Data) -> PRDiscussion? {
    guard let response = try? JSONDecoder().decode(DiscussionResponse.self, from: data) else { return nil }
    let pr = response.data.repository.pullRequest
    let iso = ISO8601DateFormatter()
    func comment(_ c: DiscussionResponse.Comment) -> ThreadComment {
        ThreadComment(id: c.url, author: c.author?.login ?? "ghost", bot: c.author?.__typename == "Bot",
                      body: cleanCommentBody(c.body), at: iso.date(from: c.createdAt ?? c.submittedAt ?? "") ?? .distantPast)
    }
    let threads: [ReviewThread] = pr.reviewThreads.nodes.compactMap { t in
        let comments = t.comments.nodes.map(comment)
        guard !comments.isEmpty else { return nil }
        let end = t.line ?? t.originalLine
        let start = t.line != nil ? t.startLine : t.originalStartLine
        let covered = min(10, max(1, (end ?? 0) - (start ?? end ?? 0) + 1))
        let hunk = (t.comments.nodes.first?.diffHunk ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.hasPrefix("@@") }
        let shown = Array(hunk.suffix(covered + 2))
        return ReviewThread(id: t.id, resolved: t.isResolved, outdated: t.isOutdated, path: t.path, line: end,
                            context: shown, highlighted: min(covered, shown.count), comments: comments, side: t.diffSide, startLine: start)
    }
    let conversation = (pr.comments.nodes + pr.reviews.nodes).map(comment).filter { !$0.body.isEmpty }.sorted { $0.at < $1.at }
    return PRDiscussion(threads: threads.sorted { $0.lastActivity < $1.lastActivity }, conversation: conversation)
}

/// Blocks; call off the main thread.
func fetchDiscussion(_ pr: PR) -> Result<PRDiscussion, DiscussionError> {
    let parts = pr.repo.split(separator: "/").map(String.init)
    guard parts.count == 2 else { return .failure(DiscussionError(message: "Unknown repo \(pr.repo).")) }
    let (status, output) = runTool(ghPath, ["api", "graphql", "-f", "query=\(discussionQuery)", "-f", "owner=\(parts[0])",
                                            "-f", "repo=\(parts[1])", "-F", "number=\(pr.number)"])
    guard status == 0, let discussion = parseDiscussion(Data(output.utf8)) else {
        return .failure(DiscussionError(message: withReason("Couldn't load the comments from GitHub.", status == 0 ? "" : output)))
    }
    return .success(discussion)
}

struct DiscussionError: Error { let message: String }

let replyMutation = """
mutation($id: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) { comment { url } }
}
"""

/// Blocks. Posts as the `gh` user: into a review thread when given its id, otherwise as a PR comment.
func postComment(_ pr: PR, threadID: String?, body: String) -> String? {
    let args = threadID.map { ["api", "graphql", "-f", "query=\(replyMutation)", "-f", "id=\($0)", "-f", "body=\(body)"] }
        ?? ["api", "repos/\(pr.repo)/issues/\(pr.number)/comments", "-f", "body=\(body)"]
    let (status, output) = runTool(ghPath, args)
    return status == 0 && !output.contains("\"errors\"") ? nil : "GitHub didn't take the reply."
}

let resolveMutation = """
mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) { thread { isResolved } }
}
"""

let unresolveMutation = """
mutation($id: ID!) {
  unresolveReviewThread(input: {threadId: $id}) { thread { isResolved } }
}
"""

/// Blocks. Resolves or reopens a review thread as the `gh` user.
func setThreadResolved(_ threadID: String, _ resolved: Bool) -> String? {
    let (status, output) = runTool(ghPath, ["api", "graphql", "-f", "query=\(resolved ? resolveMutation : unresolveMutation)",
                                            "-f", "id=\(threadID)"])
    guard status != 0 || output.contains("\"errors\"") else { return nil }
    return withReason(resolved ? "GitHub didn't resolve the thread." : "GitHub didn't reopen the thread.", output)
}

/// Each author once, most active first.
func authorCounts(_ authors: [String]) -> [(name: String, count: Int)] {
    var counts: [String: Int] = [:]
    for a in authors { counts[a, default: 0] += 1 }
    return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
}
