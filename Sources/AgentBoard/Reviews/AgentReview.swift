import AppKit

/// Findings an agent writes for the diff viewer when its quick action emits them.
struct AgentReview: Codable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        var note: String?
    }

    struct Comment: Codable, Equatable, Identifiable {
        var id: String
        let path: String
        let line: Int
        var startLine: Int?
        var side: String?
        var startSide: String?
        var severity: String?
        var body: String
        /// posted or dropped; either takes it off the diff.
        var status: String?

        init(id: String = "", path: String, line: Int, startLine: Int? = nil, side: String? = nil, startSide: String? = nil,
             severity: String? = nil, body: String, status: String? = nil) {
            self.id = id
            self.path = path
            self.line = line
            self.startLine = startLine
            self.side = side
            self.startSide = startSide
            self.severity = severity
            self.body = body
            self.status = status
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            path = try c.decode(String.self, forKey: .path)
            line = try c.decode(Int.self, forKey: .line)
            startLine = try c.decodeIfPresent(Int.self, forKey: .startLine)
            side = try c.decodeIfPresent(String.self, forKey: .side)?.uppercased()
            startSide = try c.decodeIfPresent(String.self, forKey: .startSide)?.uppercased()
            severity = try c.decodeIfPresent(String.self, forKey: .severity)?.lowercased()
            body = try c.decode(String.self, forKey: .body)
            status = try c.decodeIfPresent(String.self, forKey: .status)
        }

        var open: Bool { status == nil }
    }

    var sha: String?
    var summary: String
    var files: [File]
    var comments: [Comment]

    init(sha: String? = nil, summary: String, files: [File] = [], comments: [Comment] = []) {
        self.sha = sha
        self.summary = summary
        self.files = files
        self.comments = comments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decodeIfPresent(String.self, forKey: .sha)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }
}

/// Clicking it in Activity opens the PR's diff with the agent's drafts.
func reviewReadyEvent(_ pr: PR) -> TickerEvent {
    TickerEvent(kind: .agentReview, text: "Agent review ready: #\(pr.number) \(pr.displayTitle)", target: "diff:\(pr.key)")
}

func reviewFileName(_ pr: PR) -> String { pr.repo.replacingOccurrences(of: "/", with: "-") + "-\(pr.number).json" }

func reviewURL(_ pr: PR) -> URL { reviewsDir.appendingPathComponent(reviewFileName(pr)) }

func parseReview(_ data: Data) -> AgentReview? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard var review = try? decoder.decode(AgentReview.self, from: data) else { return nil }
    for i in review.comments.indices where review.comments[i].id.isEmpty { review.comments[i].id = "c\(i)" }
    return review
}

func encodeReview(_ review: AgentReview) -> Data? {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(review)
}

/// What an action that emits findings adds to its prompt.
func reviewEmitSection(_ prs: [PR]) -> String {
    let files = prs.map { prs.count == 1 ? reviewURL($0).path : "#\($0.number): \(reviewURL($0).path)" }.joined(separator: "\n")
    return """
    Also write your findings for Agent Board as JSON\(prs.count == 1 ? ", to this file" : ", one file per PR"):
    \(files)
    Create the folder if it is missing and replace any older file. Use this shape:
    {
      "sha": "<the PR head commit you reviewed>",
      "summary": "<markdown: what the PR does and your verdict, a few short lines>",
      "files": [{"path": "<changed file>", "note": "<one line: what this file does in the change>"}],
      "comments": [{"path": "<changed file>", "line": 12, "start_line": 10, "side": "RIGHT", "severity": "blocker | issue | nit", "body": "<the comment as you would post it>"}]
    }
    List "files" in the order that best explains the change, starting where a reader should start. Put each comment on a line in the PR's diff: the new file's line number with side RIGHT, or the old file's number with side LEFT for a deleted line. "start_line" is optional and must be in the same hunk as "line". Do not post the comments; the board shows them as drafts.
    """
}

/// The files the review names come first, in its order; the rest keep their places after them.
func explainedOrder(_ files: [DiffFile], _ review: AgentReview?) -> [DiffFile] {
    guard let review, !review.files.isEmpty else { return files }
    var rank: [String: Int] = [:]
    for (i, f) in review.files.enumerated() where rank[f.path] == nil { rank[f.path] = i }
    return files.enumerated().sorted { a, b in
        switch (rank[a.element.path], rank[b.element.path]) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.offset < b.offset
        }
    }.map(\.element)
}
