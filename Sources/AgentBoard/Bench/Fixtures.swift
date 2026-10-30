import Foundation

/// Seeded data for `make perf`, sized like a busy day. The same seed gives the same board, diff, and checks every run.
struct Fixtures {
    let state: BoardState
    /// `state` minus its first card, for scenarios that swap state back and forth.
    let trimmed: BoardState
    /// `state` decoded again a refresh later: the same content, a newer stamp.
    let restamped: BoardState
    let diffPR: PR
    let diff: PRDiff
    let discussion: PRDiscussion
    let overview: PROverview
    let review: AgentReview
    let checks: [CICheck]

    var allPRs: [PR] { (state.prs?.mine ?? []) + (state.prs?.review ?? []) }
    var bigFile: DiffFile { diff.files.first { !$0.generated && !$0.lines.isEmpty }! }
    var target: DiffTarget { DiffTarget(key: diffPR.key, path: nil, line: nil) }

    /// Fills the board and its fetch caches. The fetch times never go stale, so no prefetch starts during a run.
    func seed(_ board: Board) {
        board.state = state
        board.isFront = true
        let now = Date.distantFuture
        for (i, pr) in (allPRs + state.cards.flatMap(\.prs)).enumerated() {
            board.checks[pr.key] = [checks, checks.filter { $0.bucket != "fail" },
                                    checks.filter { $0.bucket != "fail" && $0.bucket != "pending" }][i % 3]
            board.checksFetchedAt[pr.key] = now
            board.discussionsFetchedAt[pr.key] = now
            board.discussionsUnresolved[pr.key] = pr.unresolved
        }
        board.diffs[diffPR.key] = diff
        board.discussions[diffPR.key] = discussion
        board.overviews[diffPR.key] = overview
        board.reviews[reviewFileName(diffPR)] = review
    }

    static func boardState(_ rng: inout Rng, now: Double, repo: String) -> BoardState {
            var prs: [PR] = []
            for i in 0..<14 {
                let mine = i < 8
                let number = 4100 + i * 7
                let stacked = mine && i < 3
                prs.append(PR(
                    key: "\(repo)#\(number)", number: number, title: "ABC-\(300 + i) " + rng.sentence(4...9),
                    url: "https://github.com/\(repo)/pull/\(number)", repo: i == 6 ? "acme/infra" : repo,
                    author: mine ? "me" : rng.pick(["dana", "lee", "sam", "ruth"]), draft: i == 5,
                    review: rng.pick([nil, "APPROVED", "CHANGES_REQUESTED", nil]), unresolved: rng.int(0...4),
                    commentsUrl: nil, ci: rng.pick(["passing", "failing", "running", "passing", "none"]), mine: mine, stale: false,
                    agents: i % 3 == 0 ? [AgentRef(id: "agent-\(i)", title: rng.sentence(3...6), status: "running", updatedAt: now - 300)] : nil,
                    stackId: stacked ? "stack-1" : nil, stackPos: stacked ? i + 1 : nil, stackSize: stacked ? 3 : nil,
                    lastCommit: now - Double(rng.int(600...200_000))))
            }
            let mine = Array(prs.prefix(8))

            func slot(_ n: Int) -> Slot {
                Slot(pool: "code-abc123", name: "\(n)", path: "/tmp/agent-board-perf/slot-\(n)", leased: true,
                     leaseHolder: "agent", branch: "me/topic-\(n)", dirty: n % 3 == 0, pushed: n % 2 == 0, ahead: n % 4,
                     processes: nil, returnBlockers: n % 5 == 0 ? ["uncommitted changes"] : nil, displayName: "slot \(n)")
            }
            var cards: [Card] = []
            for i in 0..<12 {
                let running = i < 3
                let needs: [String] = running ? [] : [["finished"], ["changes requested"], [], ["finished", "changes requested"]][i % 4]
                let own = i < 8 ? [mine[i]] + (i == 0 ? Array(mine[1..<3]) : []) : []
                cards.append(Card(id: "card-\(i)", title: rng.sentence(4...10), updatedAt: now - Double(i * 900 + 60),
                                  status: running ? "running" : "idle", needsYou: needs, slot: i < 7 ? slot(i + 1) : nil, prs: own))
            }
            let sections = PRSections(mine: mine, review: Array(prs.suffix(6)))
            return BoardState(generatedAt: now, cards: cards, looseSlots: [slot(9), slot(10)], prs: sections, prsFetchedAt: now)
    }

    init(seed: UInt64 = 7) {
        var rng = Rng(state: seed)
        let now = Date().timeIntervalSince1970
        let repo = Config.shared.homeRepo ?? "acme/app"

        // Built twice from one seed: equal values in separate storage, like two decodes of the same file.
        let start = rng
        state = Self.boardState(&rng, now: now, repo: repo)
        var again = start
        let copy = Self.boardState(&again, now: now, repo: repo)
        trimmed = BoardState(generatedAt: now, cards: Array(copy.cards.dropFirst()), looseSlots: copy.looseSlots, prs: copy.prs,
                             prsFetchedAt: now)
        var third = start
        let same = Self.boardState(&third, now: now, repo: repo)
        restamped = BoardState(generatedAt: now + 15, cards: same.cards, looseSlots: same.looseSlots, prs: same.prs,
                               prsFetchedAt: now)
        let mine = state.prs?.mine ?? []
        diffPR = mine[0]

        var files: [DiffFile] = []
        for i in 0..<36 {
            let generated = i == 20 || i == 31
            let size = generated ? 2000 : rng.pick([12, 40, 90, 200, 600, 1500, 60, 30])
            let ext = rng.pick(["swift", "ts", "py", "rb", "go"])
            let path = generated ? "gen/__generated__/schema-\(i).ts" : "src/\(rng.word())/\(rng.word())_\(i).\(ext)"
            let lines = rng.patch(size)
            files.append(DiffFile(path: path, previousPath: nil, status: i == 9 ? "added" : "modified",
                                  additions: lines.filter { $0.kind == .add }.count,
                                  deletions: lines.filter { $0.kind == .delete }.count, lines: lines, generated: generated))
        }
        diff = PRDiff(sha: "perf", files: files)

        let at = Date(timeIntervalSince1970: now - 7200)
        var threads: [ReviewThread] = []
        for i in 0..<12 {
            let file = i == 0 ? files.first { !$0.generated && !$0.lines.isEmpty }! : files[rng.int(0...35)]
            let anchored = file.lines.filter { $0.new != nil && $0.kind != .hunk }
            guard let line = (i == 0 ? anchored.first : anchored.randomElement(using: &rng))?.new else { continue }
            let comments = (0..<rng.int(1...3)).map { c in
                ThreadComment(id: "https://github.com/\(repo)/pull/\(mine[0].number)#discussion_r\(i * 10 + c)",
                              author: rng.pick(["dana", "lee", "me", "review-bot"]), bot: c == 2, body: rng.markdown(),
                              at: at.addingTimeInterval(Double(c * 600)))
            }
            threads.append(ReviewThread(id: "thread-\(i)", resolved: i % 4 == 3, outdated: false, path: file.path, line: line,
                                        context: [], highlighted: 1, comments: comments, side: "RIGHT"))
        }
        let conversation = (0..<5).map { c in
            ThreadComment(id: "https://github.com/\(repo)/pull/\(mine[0].number)#issuecomment-\(c)",
                          author: rng.pick(["dana", "lee", "me"]), bot: false, body: rng.markdown(),
                          at: at.addingTimeInterval(Double(c * 900)))
        }
        discussion = PRDiscussion(threads: threads, conversation: conversation)
        overview = PROverview(
            body: """
            ## Summary

            Fetch the index **once** per panel and reuse it, so a scroll no longer refetches. See `IndexCache`.

            - Moves the fetch into `PanelIndex`
              and keeps the old call as a thin wrapper
            - Drops the second request on open
              1. nested step one
              2. nested step two

            ## Test plan

            - [x] Unit tests for the cache key
            - [x] Scrolled a 2k-row panel
            - [ ] Rollout behind the flag

            > [!NOTE]
            > The flag defaults off.

            | Case | Before | After |
            | --- | --- | --- |
            | open | 2 requests | 1 request |
            | scroll | 1 per page | 0 |

            ```swift
            let index = cache.index(for: panel)
            ```
            """,
            state: "OPEN", draft: false, author: "me", createdAt: at, base: "master", head: "me/index-cache",
            headSha: "perf", additions: 3920, deletions: 2382, files: 36, commits: 4, mergeable: "MERGEABLE", mergeState: "BLOCKED",
            decision: "REVIEW_REQUIRED", queueEnabled: false, queued: false, queuePosition: nil, autoMerge: nil, autoMergeBy: nil,
            canUpdateBranch: true,
            labels: [PROverview.Label(name: "perf", color: "0e8a16"), PROverview.Label(name: "needs-review", color: "fbca04")],
            reviewers: [PROverview.Reviewer(login: "dana", state: "COMMENTED", team: false),
                        PROverview.Reviewer(login: "lee", state: "REQUESTED", team: false),
                        PROverview.Reviewer(login: "platform", state: "REQUESTED", team: true)],
            methods: [.squash, .merge], defaultMethod: .squash, autoMergeAllowed: true)

        var drafts: [AgentReview.Comment] = []
        for i in 0..<10 {
            let file = files[rng.int(0...35)]
            let anchored = file.lines.compactMap(\.new)
            guard let line = anchored.randomElement(using: &rng) else { continue }
            drafts.append(AgentReview.Comment(id: "draft-\(i)", path: file.path, line: line, side: "RIGHT",
                                              severity: rng.pick(["high", "medium", "low"]), body: rng.markdown()))
        }
        review = AgentReview(sha: "perf", summary: rng.markdown() + "\n\n" + rng.markdown(),
                             files: files.prefix(6).map { AgentReview.File(path: $0.path, note: rng.sentence(6...14)) },
                             comments: drafts)

        checks = (0..<28).map { i in
            let bucket = rng.pick(["pass", "pass", "pass", "fail", "pending", "skipping"])
            return CICheck(name: rng.sentence(2...4), workflow: rng.pick(["ci", "lint", "deploy", nil]), bucket: bucket,
                           link: "https://github.com/\(repo)/actions/runs/\(i)",
                           started: at, completed: bucket == "pending" ? nil : at.addingTimeInterval(Double(rng.int(30...900))))
        }
    }
}

/// A small linear congruential generator, so fixtures do not depend on the system random source.
struct Rng: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func pick<T>(_ options: [T]) -> T { options[int(0...options.count - 1)] }

    static let words = ["order", "billing", "search", "review", "queue", "cache", "token", "render", "panel", "status",
                        "thread", "merge", "branch", "deploy", "config", "parser", "layout", "scroll", "index", "fetch"]
    mutating func word() -> String { pick(Rng.words) }
    mutating func sentence(_ count: ClosedRange<Int>) -> String { (0..<int(count)).map { _ in word() }.joined(separator: " ") }

    mutating func markdown() -> String {
        var parts = [sentence(8...24).capitalized + "."]
        if int(0...2) == 0 { parts.append("```swift\nlet \(word()) = \(word())(\(word()): \(int(1...99)))\n```") }
        if int(0...2) == 0 { parts.append((0..<3).map { _ in "- " + sentence(3...8) }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// Hunks of mixed context, added, and deleted lines. One line in ten runs long enough to wrap.
    mutating func patch(_ count: Int) -> [DiffLine] {
        var out: [DiffLine] = []
        var old = 1, new = 1, hunk = -1
        while out.count < count {
            hunk += 1
            old += int(5...40)
            new = old
            out.append(DiffLine(kind: .hunk, text: "@@ -\(old),40 +\(new),40 @@ func \(word())()", old: nil, new: nil, hunk: hunk))
            for _ in 0..<min(int(30...110), count - out.count) {
                let indent = String(repeating: "    ", count: int(0...3))
                let long = int(0...9) == 0 ? " // " + sentence(20...30) : ""
                let text = indent + "let \(word()) = \(word()).\(word())(\(word()): \(int(0...999)))" + long
                switch int(0...19) {
                case 0...11:
                    out.append(DiffLine(kind: .context, text: text, old: old, new: new, hunk: hunk)); old += 1; new += 1
                case 12...16:
                    out.append(DiffLine(kind: .add, text: text, old: nil, new: new, hunk: hunk)); new += 1
                default:
                    out.append(DiffLine(kind: .delete, text: text, old: old, new: nil, hunk: hunk)); old += 1
                }
            }
        }
        return out
    }
}
