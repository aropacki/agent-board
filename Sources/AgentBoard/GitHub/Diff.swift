import AppKit

struct DiffLine: Equatable {
    enum Kind { case hunk, context, add, delete }
    let kind: Kind
    let text: String
    let old: Int?
    let new: Int?
    /// Which `@@` hunk the line is in; a comment range has to stay inside one.
    let hunk: Int

    /// Where GitHub anchors a comment on this line: deleted lines by their old number, the rest by their new one.
    var anchor: (side: String, line: Int)? {
        switch kind {
        case .hunk: return nil
        case .delete: return old.map { ("LEFT", $0) }
        case .add, .context: return new.map { ("RIGHT", $0) }
        }
    }
}

struct DiffFile: Identifiable, Equatable {
    let path: String
    let previousPath: String?
    let status: String
    let additions: Int
    let deletions: Int
    /// Empty when GitHub sends no patch: binary files and very large diffs.
    let lines: [DiffLine]
    let generated: Bool
    /// Changes whenever the file's diff does, so a file marked reviewed comes back when new commits touch it.
    let stamp: String
    var id: String { path }

    init(path: String, previousPath: String?, status: String, additions: Int, deletions: Int, lines: [DiffLine], generated: Bool) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.lines = lines
        self.generated = generated
        stamp = patchStamp(lines)
    }
}

struct PRDiff: Equatable {
    let sha: String
    let files: [DiffFile]
}

func parsePatch(_ patch: String) -> [DiffLine] {
    var out: [DiffLine] = []
    var old = 0, new = 0, hunk = -1
    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("@@") {
            let nums = line.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0 }
            old = nums.first ?? 0
            new = nums.count > 1 ? nums[1] : 0
            hunk += 1
            out.append(DiffLine(kind: .hunk, text: line, old: nil, new: nil, hunk: hunk))
        } else if hunk < 0 || line.hasPrefix("\\") {
            continue
        } else if line.hasPrefix("+") {
            out.append(DiffLine(kind: .add, text: String(line.dropFirst()), old: nil, new: new, hunk: hunk))
            new += 1
        } else if line.hasPrefix("-") {
            out.append(DiffLine(kind: .delete, text: String(line.dropFirst()), old: old, new: nil, hunk: hunk))
            old += 1
        } else {
            out.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: old, new: new, hunk: hunk))
            old += 1
            new += 1
        }
    }
    if out.last?.kind == .context && out.last?.text.isEmpty == true && patch.hasSuffix("\n") { out.removeLast() }
    return out
}

/// Lockfiles, codegen output, and snapshots, by path or by a do-not-edit banner near the top.
func isGeneratedFile(_ path: String, _ lines: [DiffLine]) -> Bool {
    let name = (path as NSString).lastPathComponent
    let dirs = path.split(separator: "/").dropLast().map { $0.lowercased() }
    let lockfiles: Set<String> = ["pnpm-lock.yaml", "package-lock.json", "yarn.lock", "gemfile.lock", "poetry.lock",
                                  "go.sum", "cargo.lock", "composer.lock", "uv.lock", "podfile.lock"]
    let suffixes = [".pb.go", "_pb2.py", "_pb2.pyi", "_pb2_grpc.py", "_pb.ts", "_pb.js", ".pb.ts", ".pb.swift",
                    ".generated.ts", ".generated.go", ".gen.go", ".gen.ts", "_gen.go", ".min.js", ".snap"]
    if lockfiles.contains(name.lowercased()) || suffixes.contains(where: { name.lowercased().hasSuffix($0) }) { return true }
    if dirs.contains(where: { ["__generated__", "generated", "__snapshots__", "entgen"].contains($0) }) { return true }
    let head = lines.lazy.filter { $0.kind != .hunk && $0.kind != .delete }.prefix(12).map(\.text).joined(separator: "\n")
    return head.contains("DO NOT EDIT") || head.contains("@generated") || head.contains("Code generated")
}

/// `gh api --jq` output for a PR's files: one JSON object per line.
func parsePRFiles(_ ndjson: String) -> [DiffFile] {
    struct Row: Decodable {
        let filename: String
        let status: String
        let additions: Int
        let deletions: Int
        let patch: String?
        let previous_filename: String?
    }
    return ndjson.split(separator: "\n").compactMap { line in
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
        let lines = parsePatch(row.patch ?? "")
        return DiffFile(path: row.filename, previousPath: row.previous_filename, status: row.status, additions: row.additions,
                        deletions: row.deletions, lines: lines, generated: isGeneratedFile(row.filename, lines))
    }
}

/// Blocks. The PR's changed files and the head commit a new comment is pinned to.
func fetchDiff(_ pr: PR) -> Result<PRDiff, DiscussionError> {
    let (filesStatus, files) = runTool(ghPath, ["api", "--paginate", "repos/\(pr.repo)/pulls/\(pr.number)/files?per_page=100",
                                                "--jq", ".[] | {filename, status, additions, deletions, patch, previous_filename}"],
                                       timeout: readTimeout * 3)
    let (shaStatus, sha) = runTool(ghPath, ["api", "repos/\(pr.repo)/pulls/\(pr.number)", "--jq", ".head.sha"], timeout: readTimeout)
    let head = sha.trimmingCharacters(in: .whitespacesAndNewlines)
    guard filesStatus == 0, shaStatus == 0, !head.isEmpty else {
        return .failure(DiscussionError(message: withReason("Couldn't load the diff from GitHub.", filesStatus == 0 ? sha : files)))
    }
    return .success(PRDiff(sha: head, files: parsePRFiles(files)))
}

/// The `gh api` arguments that post one review comment on `lines`, which run oldest first inside one hunk.
func reviewCommentArgs(_ pr: PR, sha: String, path: String, lines: [DiffLine], body: String) -> [String]? {
    guard let end = lines.last?.anchor, let start = lines.first?.anchor else { return nil }
    var args = ["api", "repos/\(pr.repo)/pulls/\(pr.number)/comments", "-f", "body=\(body)", "-f", "commit_id=\(sha)",
                "-f", "path=\(path)", "-F", "line=\(end.line)", "-f", "side=\(end.side)"]
    if lines.count > 1 { args += ["-F", "start_line=\(start.line)", "-f", "start_side=\(start.side)"] }
    return args
}

/// Blocks. Posts a review comment as the `gh` user.
func postReviewComment(_ args: [String]) -> String? {
    let (status, output) = runTool(ghPath, args)
    return status == 0 && !output.contains("\"errors\"") ? nil : withReason("GitHub didn't take the comment.", output)
}

/// A run of diff lines picked for a comment: `anchor` is where the pick started, `head` where it ends now.
struct DiffSelection: Equatable {
    let path: String
    var anchor: Int
    var head: Int
    var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
}

/// The diff viewer's PR, and the file and line to scroll to.
struct DiffTarget: Equatable {
    let key: String
    var path: String?
    var line: Int?
    /// A review thread to land on; its own span picks the row, since `line` alone does not say which side.
    var thread: String? = nil
}
