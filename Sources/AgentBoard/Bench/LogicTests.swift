import AppKit
import SwiftUI

extension Bench {
    /// Guards contracts that fail silently: what gets posted to GitHub, which chat and PRs a prompt goes to,
    /// parsers of GitHub and agent output, and the timers that move cards. Layout and copy are checked by eye.
    static func logic() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print("\(ok ? "ok" : "FAIL")  \(name)"); if !ok { failures += 1 } }
        func pr(_ n: Int, mine: Bool = false, ci: String = "passing", review: String? = nil, unresolved: Int = 0,
                stack: String? = nil, pos: Int? = nil, title: String? = nil) -> PR {
            PR(key: "o/r#\(n)", number: n, title: title ?? "T\(n)", url: "https://github.com/o/r/pull/\(n)", repo: "o/r",
               author: mine ? "me" : "a", draft: false, review: review, unresolved: unresolved, commentsUrl: nil, ci: ci, mine: mine,
               stale: false, agents: nil, stackId: stack, stackPos: pos, stackSize: stack == nil ? nil : 3)
        }
        func commented(_ p: PR, _ urls: [String]) -> PR {
            var p = p
            p.newComments = urls.map { PRComment(at: 0, author: "alice", url: $0, excerpt: "Why this?") }
            return p
        }
        func card(_ id: String, _ status: String = "done", _ needs: [String] = [], slot: Slot? = nil, prs: [PR] = []) -> Card {
            Card(id: id, title: "Chat \(id)", updatedAt: 0, status: status, needsYou: needs, slot: slot, prs: prs)
        }
        func actx(_ surface: ActionSurface, _ list: [PR], card: Card? = nil) -> ActionContext {
            ActionContext(surface: surface, key: "k", prs: list, card: card)
        }
        func action(_ id: String) -> QuickAction { QuickAction.defaults.first { $0.id == id }! }
        func ciCheck(_ name: String, _ bucket: String) -> CICheck {
            CICheck(name: name, workflow: nil, bucket: bucket, link: nil, started: nil, completed: nil)
        }

        let marks = BoardState(generatedAt: 0, cards: [card("n", "done", ["review"])], looseSlots: [], prs: nil)
        check("agents: a PR's agent shows its card's needs mark, and a chat off the board keeps its own status",
              marks.status(of: AgentRef(id: "n", title: "", status: "done", updatedAt: 0)) == "needs"
              && marks.status(of: AgentRef(id: "gone", title: "", status: "done", updatedAt: 0)) == "done")

        check("row clicks: a plain click opens the diff, ⌘ opens the web page even while selecting, and ⇧ or a selection selects",
              rowClick([], selecting: false) == .diff && rowClick(.command, selecting: true) == .web
              && rowClick(.shift, selecting: false) == .select && rowClick([], selecting: true) == .select)

        let button = CGRect(x: 300, y: 100, width: 20, height: 20), menuSize = CGSize(width: 200, height: 120)
        let opensDown = Dropdown.growth(anchor: button, origin: CGPoint(x: 120, y: 124), size: menuSize)
        let opensUp = Dropdown.growth(anchor: button, origin: CGPoint(x: 120, y: -24), size: menuSize)
        check("dropdowns: a menu grows from the corner nearest its button, from the bottom when it opens upward",
              abs(opensDown.x - 0.95) < 0.001 && opensDown.y == 0 && abs(opensUp.x - 0.95) < 0.001 && opensUp.y == 1)

        let s1 = pr(1, stack: "s", pos: 1), s2 = pr(2, stack: "s", pos: 2), s3 = pr(3, stack: "s", pos: 3)
        let units = prUnits([s3, pr(9), s1, s2, pr(7, stack: "t", pos: 2)])
        var members: [Int] = []
        if case .stack(_, let m) = units[0] { members = m.map(\.number) }
        let loneIsPlain: Bool = { if case .single = units[2] { return true }; return false }()
        check("stacks: grouped at the newest member, base first, and a lone member is a plain row",
              units.map(\.id) == ["stack:s", "o/r#9", "o/r#7"] && members == [1, 2, 3] && loneIsPlain
              && reviewOrder([s3, s1, s2]).map(\.number) == [1, 2, 3])

        let t = "A{{#x}} x={{x}}{{/x}}{{^x}} none{{/x}}.\n{{#y}}\nY\n{{/y}}\n{{z}}end"
        check("templates: set sections show, unset ones drop, and inverted and nested sections work",
              Prompts.render(t, ["x": "1"]) == "A x=1.\nend" && Prompts.render(t, [:]) == "A none.\nend"
              && Prompts.render(t, ["y": "1"]) == "A none.\nY\nend"
              && Prompts.render("{{#a}}[{{#b}}B{{/b}}{{^b}}-{{/b}}]{{/a}}", ["a": "1"]) == "[-]")
        let unplaced = QuickAction.defaults.filter { !$0.unknownNames.isEmpty || $0.placements.isEmpty }.map(\.id)
        check("templates: every built-in shows somewhere and uses only names its places provide \(unplaced)",
              unplaced.isEmpty && Set(QuickAction.defaults.map(\.id)).count == QuickAction.defaults.count)

        let fb = pr(5, mine: true, review: "CHANGES_REQUESTED", unresolved: 3, title: "[APP-12] Thing")
        let more = pr(6, mine: true, ci: "failing", title: "APP-12: More")
        let vars = actionVars(actx(.selection, [fb, more]), prs: [fb, more], checks: ["o/r#6": [ciCheck("lint", "fail"), ciCheck("test", "pass")]])
        check("prompt variables: numbered PRs carry their feedback and failing checks, and a shared ticket is listed once",
              vars["prs_feedback"] == "1. https://github.com/o/r/pull/5 ([APP-12] Thing): 3 unresolved, changes requested\n2. https://github.com/o/r/pull/6 (APP-12: More)"
              && vars["prs_failing"]?.hasSuffix("(APP-12: More): lint") == true && vars["tickets"] == "APP-12" && vars["many"] == "yes")
        check("prompt variables: only one stack counts as a stack", isOneStack([s1, s3]) && !isOneStack([s1, fb]))

        let cardPRs = [pr(1, mine: true), pr(2, mine: true, ci: "failing"), pr(3, mine: true, ci: "running"), pr(4, ci: "failing"),
                       pr(5, mine: true, ci: "failing")]
        let fixCtx = actx(.agent, cardPRs, card: card("c3", prs: cardPRs))
        let review = action("review")
        var hidden = pr(9)
        hidden.hidden = true
        let open = ReviewThread(id: "T", resolved: false, outdated: false, path: "app/x.rb", line: 12, context: [], highlighted: 0,
                                comments: [ThreadComment(id: "https://x/9#r1", author: "reviewer", bot: false, body: "Why?", at: .distantPast)])
        var closed = open
        closed.resolved = true
        let analyze = action("thread-analyze").placement(.thread)!
        let fixCheck = action("fix-check").placement(.check)!
        check("action targets: fix CI sends only my failing PRs, review skips mine, and a stack review covers others' base first",
              actionTargets(action("fix-ci").placement(.agent)!, fixCtx, ci: \.ci)?.map(\.number) == [2, 5]
              && actionTargets(review.placement(.pr)!, actx(.pr, [fb]), ci: \.ci) == nil
              && actionTargets(review.placement(.stack)!, actx(.stack, [s3, fb, s1]), ci: \.ci)?.map(\.number) == [1, 3])
        check("action targets: hidden PRs, closed threads, and passing checks offer nothing",
              actionTargets(Placement(.pr), actx(.pr, [hidden]), ci: \.ci) == nil
              && actionTargets(analyze, ActionContext(surface: .thread, key: "T", prs: [fb], thread: open), ci: \.ci) != nil
              && actionTargets(analyze, ActionContext(surface: .thread, key: "T", prs: [fb], thread: closed), ci: \.ci) == nil
              && actionTargets(fixCheck, ActionContext(surface: .check, key: "k", prs: [more], check: ciCheck("lint", "fail")), ci: \.ci) != nil
              && actionTargets(fixCheck, ActionContext(surface: .check, key: "k", prs: [more], check: ciCheck("lint", "pass")), ci: \.ci) == nil)

        let leased = Slot(pool: "p", name: "3", path: "/tmp/s3", leased: true, leaseHolder: "x", branch: "me/t",
                          dirty: false, pushed: true, ahead: 0, processes: nil, returnBlockers: nil)
        let slotChat = card("c1", slot: leased, prs: [more]), workChat = card("c9", prs: [fb, more])
        check("own chat: the card it ran on, the one chat holding every PR, a new chat for spread PRs, and a worktree's holder",
              ownerChat(actx(.agent, [fb], card: workChat), targets: [fb], cards: [workChat])?.id == "c9"
              && ownerChat(actx(.selection, [fb, more]), targets: [fb, more], cards: [slotChat, workChat])?.id == "c9"
              && ownerChat(actx(.selection, [fb, s1]), targets: [fb, s1], cards: [slotChat, workChat]) == nil
              && ownerChat(ActionContext(surface: .worktree, key: "w", slot: leased), targets: [], cards: [workChat, slotChat])?.id == "c1")

        let custom = QuickAction(id: "custom-1", title: "Mine", icon: "sparkles", template: "{{target}}", placements: [Placement(.pr)])
        let sparse = try? JSONDecoder().decode(ActionStore.File.self, from: Data(#"{"actions":[{"id":"x","title":"X","placements":[{"surface":"pr"}]}]}"#.utf8))
        let merged = ActionStore.merged([custom] + QuickAction.defaults.filter { $0.id != "fix-check" })
        check("saved actions: a sparse entry gets defaults, and a built-in missing from the file returns at its spot",
              sparse?.actions.first.map { $0.enabled && $0.delivery == .ownChat && $0.placements == [Placement(.pr)] && !$0.confirm && !$0.emitsReview } == true
              && merged.map(\.id).firstIndex(of: "fix-check") == 3 && merged.count == QuickAction.defaults.count + 1)
        let front = Library.parse("---\nname: pr-desc\ndescription: >\n  Writes PR\n  bodies.\nother: \"q\"\n---\n# Title\nBody line")
        check("front matter: folded text joins and quotes drop",
              front.fields["name"] == "pr-desc" && front.fields["description"] == "Writes PR bodies." && front.fields["other"] == "q" && front.body.contains("Body line"))
        check("chrome script: a link cannot break out of its string", chromeTabScript(#"https://x/?q="a"\b"#).contains(#"{URL:"https://x/?q=\"a\"\\b"}"#))

        let tricky = "it's \"$HOME\" `date` $(whoami) \\n done"
        let (_, echoed) = runTool("/bin/sh", ["-c", "printf '%s|%s' " + (Terminal.prompt(tricky) ?? "") + " " + shellQuote("'; x")])
        check("terminal tools: a prompt and a quoted word reach the command unchanged", echoed == tricky + "|'; x")
        let launcher = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-launch-test.command")
        try? Terminal.script("printf '%s' \"$PWD\"", in: "/usr/bin").write(to: launcher, atomically: true, encoding: .utf8)
        let (_, ran) = runTool("/usr/bin/env", ["SHELL=/bin/sh", "/bin/sh", launcher.path])
        check("terminal tools: the launch script runs the command in the chat's folder and removes itself",
              ran == "/usr/bin" && !FileManager.default.fileExists(atPath: launcher.path))
        check("tools: a card opens in its own tool even when that tool is not enabled, and an unknown one in the default",
              Tools.tool("claude-code").id == "claude-code" && Tools.tool("nope").id == Tools.primary.id
              && Tools.tool(nil).id == Tools.primary.id)

        let fixture = """
        {"data":{"repository":{"pullRequest":{
          "reviewThreads":{"nodes":[
            {"id":"T1","isResolved":false,"isOutdated":false,"path":"app/jobs/finalize.rb","line":12,"startLine":11,"diffSide":"RIGHT",
             "originalLine":12,"originalStartLine":11,"comments":{"nodes":[
               {"author":{"login":"reviewer","__typename":"User"},"body":"Why do we need this?","createdAt":"2026-10-15T05:00:00Z",
                "url":"https://github.com/o/r/pull/1#discussion_r1","diffHunk":"@@ -1,3 +1,5 @@\\n a\\n+b\\n+c\\n-d\\n+e"},
               {"author":{"login":"me","__typename":"User"},"body":"It bounds retries.","createdAt":"2026-10-15T06:00:00Z",
                "url":"https://github.com/o/r/pull/1#discussion_r2","diffHunk":null}]}},
            {"id":"T2","isResolved":true,"isOutdated":true,"path":"spec/x_spec.rb","line":null,"startLine":null,
             "originalLine":8,"originalStartLine":null,"comments":{"nodes":[
               {"author":{"login":"claude","__typename":"Bot"},"body":"Old note","createdAt":"2026-10-14T05:00:00Z",
                "url":"https://github.com/o/r/pull/1#discussion_r3","diffHunk":"@@ -1 +1 @@\\n+x"}]}}]},
          "comments":{"nodes":[
            {"author":{"login":"linear-code","__typename":"Bot"},"body":"<!-- linear-linkback -->","createdAt":"2026-10-14T01:00:00Z","url":"u1"},
            {"author":{"login":"reviewer","__typename":"User"},"body":"Looks close.<br>One question.","createdAt":"2026-10-14T02:00:00Z","url":"u2"}]},
          "reviews":{"nodes":[
            {"author":{"login":"reviewer","__typename":"User"},"body":"","submittedAt":"2026-10-14T03:00:00Z","url":"u3"}]}
        }}}}
        """
        let parsed = parseDiscussion(Data(fixture.utf8))
        let top = parsed?.threads.last, old = parsed?.threads.first
        check("comments: newest thread last with replies in order, its side and excerpt kept, and an outdated thread on its original line",
              top?.id == "T1" && top?.comments.map(\.author) == ["reviewer", "me"] && top?.side == "RIGHT"
              && top?.context == ["+b", "+c", "-d", "+e"] && top?.highlighted == 2
              && old?.line == 8 && old?.outdated == true && old?.side == nil && old?.comments.first?.bot == true)
        check("comments: empty and comment-only bodies leave the conversation, and code keeps its angle brackets",
              parsed?.conversation.map(\.id) == ["u2"] && parsed?.conversation.first?.body == "Looks close.\nOne question."
              && cleanCommentBody("```\nlet a: Array<String>\n```") == "```\nlet a: Array<String>\n```")

        let patch = parsePatch("@@ -10,4 +10,5 @@ func a() {\n ctx\n-old\n+new\n+more\n ctx2\n\\ No newline at end of file\n@@ -40 +41,2 @@\n+x\n y")
        let rows = DiffRowMap([("a", 10), ("b", 0), ("c", 5)])
        let located = [0, 7.5, 12.5, 19, 100].compactMap { rows.locate($0) }.map { "\($0.path)\($0.row)" }
        check("diff scrollbar: rows map to files, a header or gap is the next file's first row, and the end clamps",
              located == ["a0", "a5", "b0", "c1", "c4"] && rows.total == 24 && rows.start("c") == 18)
        let spanning = viewportRow([(2, 10, CGRect(x: 0, y: -80, width: 1, height: 160)), (18, 5, CGRect(x: 0, y: 90, width: 1, height: 80))])
        let below = viewportRow([(18, 5, CGRect(x: 0, y: 32, width: 1, height: 80))])
        check("diff scrollbar: the viewport row comes from the piece across its top, or extrapolates from the nearest",
              spanning?.row == 7 && spanning?.rowHeight == 16 && below?.row == 16)
        let thumb = thumbFrame(top: 40, visible: 20, total: 100, track: 200, minimum: 10)
        check("diff scrollbar: the thumb is sized by rows in view and dragging it back gives the row it showed",
              thumb.y == 80 && thumb.height == 40 && thumbRow(y: 80, height: 40, visible: 20, total: 100, track: 200) == 40
              && thumbFrame(top: 500, visible: 20, total: 100, track: 200, minimum: 10).y == 160)

        check("diff: patch lines carry old and new numbers and their hunk",
              patch.map { "\($0.old.map { String($0) } ?? "_")/\($0.new.map { String($0) } ?? "_")" }
                == ["_/_", "10/10", "11/_", "_/11", "_/12", "12/13", "_/_", "_/41", "40/42"]
              && patch.map(\.hunk) == [0, 0, 0, 0, 0, 0, 1, 1, 1])
        let commentPR = pr(7, mine: true)
        let single = reviewCommentArgs(commentPR, sha: "abc", path: "a.ts", lines: [patch[3]], body: "Why?") ?? []
        let ranged = reviewCommentArgs(commentPR, sha: "abc", path: "a.ts", lines: Array(patch[2...4]), body: "x") ?? []
        check("diff comments: one line posts its line and side, a range starts on its first line's side, and a hunk header posts nothing",
              single == ["api", "repos/o/r/pulls/7/comments", "-f", "body=Why?", "-f", "commit_id=abc", "-f", "path=a.ts", "-F", "line=11", "-f", "side=RIGHT"]
              && ranged.suffix(8) == ["-F", "line=12", "-f", "side=RIGHT", "-F", "start_line=11", "-f", "start_side=LEFT"]
              && reviewCommentArgs(commentPR, sha: "abc", path: "a.ts", lines: [patch[0]], body: "x") == nil)
        let file = DiffFile(path: "a.ts", previousPath: nil, status: "modified", additions: 3, deletions: 1, lines: patch, generated: false)
        let touched = DiffFile(path: "a.ts", previousPath: nil, status: "modified", additions: 3, deletions: 1,
                               lines: parsePatch("@@ -10,4 +10,5 @@ func a() {\n ctx\n-old\n+newer\n+more\n ctx2"), generated: false)
        check("diff: a reviewed file comes back when its diff changes", file.stamp == file.stamp && file.stamp != touched.stamp)

        let reviewJSON = #"""
        {"sha":"abc","summary":"Adds a queue.","files":[{"path":"b.ts","note":"the model"},{"path":"a.ts"}],
         "comments":[{"path":"a.ts","line":11,"side":"left","severity":"Blocker","body":"Why drop this?"},
                     {"path":"a.ts","line":12,"start_line":11,"body":"Range","id":"keep"}]}
        """#
        let agentReview = parseReview(Data(reviewJSON.utf8))
        check("agent review: snake-case fields read, sides and severity normalize, ids fill in, and a bare file reads",
              agentReview?.comments.map(\.id) == ["c0", "keep"] && agentReview?.comments[0].side == "LEFT" && agentReview?.comments[0].severity == "blocker"
              && agentReview?.comments[1].startLine == 11 && parseReview(Data("{}".utf8)) != nil)
        check("agent review: saving keeps the agent's field names",
              encodeReview(agentReview!).flatMap { String(data: $0, encoding: .utf8) }.map { $0.contains("\"start_line\"") && !$0.contains("startLine") } == true)
        check("agent review: a draft lands on its line and side, a range covers its rows, and a line outside the diff has no place",
              ghostSpan(agentReview!.comments[0], in: file) == 2...2
              && ghostSpan(AgentReview.Comment(path: "a.ts", line: 12, startLine: 10, body: ""), in: file) == 1...4
              && ghostSpan(AgentReview.Comment(path: "a.ts", line: 41, startLine: 10, body: ""), in: file) == 7...7
              && ghostSpan(AgentReview.Comment(path: "a.ts", line: 99, body: ""), in: file) == nil)

        let rollup = """
        {"data":{"p0":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-15T16:20:00Z",
           "completedAt":"2026-10-15T16:21:00Z","detailsUrl":"u1","checkSuite":{"workflowRun":{"workflow":{"name":"Go"}}}},
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-15T16:30:00Z",
           "completedAt":"2026-10-15T16:31:00Z","detailsUrl":"u2","checkSuite":{"workflowRun":{"workflow":{"name":"Go"}}}},
          {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"0001-01-01T00:00:00Z",
           "completedAt":"0001-01-01T00:00:00Z","detailsUrl":"u4","checkSuite":null},
          {"__typename":"StatusContext","context":"danger","state":"ERROR","targetUrl":"u5"}
        ]}}}}]}}},
        "p1":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}},
        "p2":null}}
        gh: Could not resolve to a PullRequest with the number of 9.
        """
        let rollups = parseCheckRollups(rollup)
        let rolled = rollups?[0] ?? []
        check("checks: a re-run job shows only its latest run, an unstarted check has no times, and a missing PR is left out",
              rolled.filter { $0.name == "lint" }.map(\.bucket) == ["pass"] && rolled.first { $0.name == "danger" }?.bucket == "fail"
              && rolled.first { $0.name == "deploy" }?.started == nil && rollups?[1] == [] && rollups?[2] == nil)
        check("ci verdict: a stray cancel does not fail a pass, failures beat running, and posted required checks alone decide",
              ciVerdict([ciCheck("lint", "pass"), ciCheck("matrix", "cancel"), ciCheck("docs", "skipping")], required: []) == "passing"
              && ciVerdict([ciCheck("lint", "fail"), ciCheck("test", "pending")], required: []) == "failing"
              && ciVerdict([ciCheck("lint", "pass"), ciCheck("test", "pending")], required: []) == "running"
              && ciVerdict([ciCheck("gate", "pass"), ciCheck("advisory", "fail")], required: ["gate"]) == "passing"
              && ciVerdict([ciCheck("gate", "cancel")], required: ["gate"]) == "failing"
              && ciVerdict([ciCheck("advisory", "fail")], required: ["gate"]) == "failing")

        let recent = Date().addingTimeInterval(-60)
        let entry = FetchCacheEntry(key: "o/r#1", checks: [ciCheck("lint", "fail")], checksAt: recent, unresolved: 1)
        var refetched = entry, later = entry, changed = entry
        refetched.checksAt = recent.addingTimeInterval(600)
        later.checksAt = recent.addingTimeInterval(7200)
        changed.unresolved = 2
        check("fetch cache: an unchanged refetch skips the write until its time falls an hour behind",
              !refetched.needsWrite(over: entry) && later.needsWrite(over: entry) && changed.needsWrite(over: entry) && entry.needsWrite(over: nil))
        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-fetch-\(getpid())")
        try? FileManager.default.removeItem(at: storeDir)
        let store = FetchCacheStore(dir: storeDir)
        let other = FetchCacheEntry(key: "o/r#3", checks: [ciCheck("test", "pass")], checksAt: recent)
        let stale = FetchCacheEntry(key: "o/r#4", checks: [ciCheck("test", "pass")], checksAt: recent.addingTimeInterval(-3 * 86400))
        let saves = DispatchSemaphore(value: 0)
        var rounds: [([String], [String])] = []
        store.save(FetchCache(entries: [entry, other, stale])) { rounds.append(($0.sorted(), $1)); saves.signal() }
        store.save(FetchCache(entries: [entry, other])) { rounds.append(($0, $1)); saves.signal() }
        store.save(FetchCache(entries: [other])) { rounds.append(($0, $1)); saves.signal() }
        (0..<3).forEach { _ in saves.wait() }
        check("fetch cache: each PR is written once, an unchanged save writes nothing, dropped and expired PRs are removed, and files load back",
              rounds.map(\.0) == [["o/r#1", "o/r#3"], [], []] && rounds.map(\.1) == [[], [], ["o/r#1"]]
              && FetchCacheStore(dir: storeDir).load() == FetchCache(entries: [other]))
        try? FileManager.default.removeItem(at: storeDir)

        let toasts = Board()
        toasts.refreshFailed("checks", "first")
        toasts.refreshFailed("checks", "second")
        let quiet = toasts.toast?.text == "first"
        toasts.refreshFailed("checks", "asked", explicit: true)
        let asked = toasts.toast?.text == "asked"
        toasts.refreshSucceeded("checks")
        toasts.refreshFailed("checks", "again")
        check("refresh errors: a failing source toasts once until it recovers, and a refresh you ask for always reports",
              quiet && asked && toasts.toast?.text == "again")

        let held = Board(), list = UUID(), column = UUID()
        held.present(BoardState(generatedAt: 0, cards: [], looseSlots: [], prs: nil))
        held.scrollMoved(list, moving: true)
        held.scrollMoved(column, moving: true)
        held.present(BoardState(generatedAt: 1, cards: [], looseSlots: [], prs: nil))
        held.present(BoardState(generatedAt: 2, cards: [], looseSlots: [], prs: nil))
        let waited = held.state?.generatedAt == 0
        held.scrollMoved(list, moving: false)
        let waitedForAll = held.state?.generatedAt == 0
        held.scrollMoved(column, moving: false)
        check("refresh during scroll: the board waits until every scroll stops, then shows the newest state",
              waited && waitedForAll && held.state?.generatedAt == 2)

        let before = BoardState(generatedAt: 0, cards: [card("a", "running"), card("b", "idle"), card("c", "idle")], looseSlots: [],
                                prs: PRSections(mine: [pr(1, mine: true, ci: "running"), commented(pr(2, mine: true, unresolved: 1), ["c1"])], review: [pr(5)]))
        let after = BoardState(generatedAt: 1, cards: [card("a", "done", ["finished"]), card("b", "running"), card("c", "idle", ["changes requested"])],
                               looseSlots: [], prs: PRSections(mine: [pr(1, mine: true, ci: "failing", review: "APPROVED"), commented(pr(2, mine: true, unresolved: 3), ["c2", "c1"])],
                                                               review: [pr(5), pr(6)]))
        let events = tickerEvents(from: before, to: after)
        check("ticker: each change reports once and opens something, and no change is quiet",
              events.map(\.kind) == [.finished, .needsYou, .review, .ciFailed, .approved, .comments]
              && events.allSatisfy { $0.target != nil } && tickerEvents(from: after, to: after).isEmpty
              && events.last?.text == "Comment from @alice: #2 T2 · “Why this?”")
        var parent = card("p", "idle", prs: [pr(9, mine: true)]), busy = card("q", "idle")
        var side = card("s", "done", ["finished"], prs: [pr(9, mine: true)])
        side.kind = "side"
        var sub = card("u", "running")
        sub.kind = "subagent"
        parent.children = [side]
        busy.children = [sub]
        var working = card("w", "running")
        working.children = [card("x", "done", ["finished"])]
        let family = BoardState(generatedAt: 0, cards: [parent, busy, working], looseSlots: [], prs: nil)
        let placed = BoardLists(family)
        var doneSub = card("u", "done")
        doneSub.kind = "subagent"
        busy.children = [doneSub]
        let subEvents = tickerEvents(from: family, to: BoardState(generatedAt: 1, cards: [parent, busy, working], looseSlots: [], prs: nil))
        let prCtx = ActionContext(surface: .pr, key: "k", prs: [pr(9, mine: true)])
        check("chat families: a family runs while any member runs, else needs you when one does; a PR's own chat takes its actions; subagents stay off the ticker",
              placed.needs.map(\.id) == ["p"] && placed.running.map(\.id) == ["q", "w"] && parent.dotStatus == "idle"
              && ownerChat(prCtx, targets: [], cards: family.allCards)?.id == "s" && subEvents.isEmpty)

        let editWindow = PopupPanel(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 40),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        field.string = "select me"
        editWindow.contentView = field
        editWindow.orderFrontRegardless()
        editWindow.makeKey()
        editWindow.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: 0, length: 0))
        let menu = editingMenu()
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                         windowNumber: editWindow.windowNumber, context: nil, characters: "a",
                                         charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        let handled = menu.performKeyEquivalent(with: selectAll)
        let keys = Set(menu.items.compactMap(\.submenu).flatMap(\.items).map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" })
        editWindow.orderOut(nil)
        check("editing keys: the main menu routes ⌘A to the focused field and carries cut, copy, paste, and undo",
              handled && field.selectedRange() == NSRange(location: 0, length: 9)
              && ["x", "c", "v", "z"].allSatisfy { keys.contains("\(NSEvent.ModifierFlags.command.rawValue)-\($0)") })

        let stamp = Date()
        let log = [TickerEvent(kind: .finished, text: "old", at: stamp.addingTimeInterval(-8 * 86400))]
            + (0..<5).map { TickerEvent(kind: .finished, text: "e\($0)", at: stamp.addingTimeInterval(Double($0))) }
        check("activity: entries older than a week drop and the newest are kept", trimActivity(log, now: stamp, keep: 3).map(\.text) == ["e2", "e3", "e4"])

        var clock = NeedsClock()
        let waiting = [card("w", "idle", ["finished"])]
        let away = clock.tick(needs: waiting, step: 3000, idle: 600)
        let first = clock.tick(needs: waiting, step: 3000, idle: 5)
        let second = clock.tick(needs: waiting, step: 3000, idle: 5)
        var reset = NeedsClock()
        _ = reset.tick(needs: waiting, step: 3000, idle: 0)
        _ = reset.tick(needs: [], step: 60, idle: 0)
        check("needs you: drops to Recent after an active hour, not while away, and leaving starts the wait over",
              away.isEmpty && first.isEmpty && second.map(\.id) == ["w"] && clock.waited.isEmpty
              && reset.tick(needs: waiting, step: 3000, idle: 0).isEmpty)
        let lists = BoardLists(BoardState(generatedAt: 1, cards: [card("busy", "running", ["changes requested"]), card("idle", "idle", ["changes requested"])],
                                          looseSlots: [], prs: nil))
        check("needs you: a running agent stays in Running", lists.running.map(\.id) == ["busy"] && lists.needs.map(\.id) == ["idle"] && lists.recent.isEmpty)

        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-config-\(getpid()).json")
        try? #"{"issueTracker": {"url": "https://x.atlassian.net/browse/{key}"}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let jira = Config.load(configURL)
        try? FileManager.default.removeItem(at: configURL)
        check("config: the ticket link fills its template, and with no file tickets do not link",
              jira.issueTracker.link("AB-12") == "https://x.atlassian.net/browse/AB-12" && Config.load(configURL).issueTracker.link("AB-12") == nil)
        print("logic failures: \(failures)")
    }

    /// Feeds a card through its states, with and without time to animate between them, and checks that its row ends
    /// in the right section with the right dot. Each step waits for the row to settle rather than for a fixed time,
    /// so only a row that stays wrong fails.
    static func consistency(_ board: Board) {
        Probe.on = true
        func card(_ id: String, _ title: String, _ status: String, _ needs: [String]) -> Card {
            Card(id: id, title: title, updatedAt: Date().timeIntervalSince1970, status: status, needsYou: needs, slot: nil, prs: [])
        }
        let steps: [(String, [String])] = [
            ("running", []), ("done", ["finished"]), ("done", []), ("running", []),
            ("error", ["error"]), ("running", []), ("done", ["finished"]), ("done", []),
        ]
        var failures = 0
        for (gap, label) in [(0.6, "settled"), (0.12, "rapid"), (0.02, "burst")] {
            for (i, step) in steps.enumerated() {
                let rank = { (c: Card) in c.needsYou.isEmpty ? (c.status == "running" ? 1 : 2) : 0 }
                let cards = [card("A", "Alpha", step.0, step.1), card("B", "Bravo", "running", []), card("C", "Charlie", "done", [])]
                    .sorted { rank($0) < rank($1) }
                withAnimation(.snappy(duration: 0.3)) {
                    board.state = BoardState(generatedAt: Date().timeIntervalSince1970, cards: cards, looseSlots: [], prs: nil)
                }
                spin(gap)
                if gap < 0.5 && i < steps.count - 1 { continue }
                let expectSection = !step.1.isEmpty ? "Needs you" : step.0 == "running" ? "Running" : "Recent"
                let expectDot = step.1.isEmpty ? step.0 : "needs"
                var live = Probe.rows.values.filter { $0.id == "A" }
                let settled = { live.count == 1 && live[0].section == expectSection && live[0].dot == expectDot && live[0].reasons == step.1 }
                let deadline = Date().addingTimeInterval(3)
                while !settled() && Date() < deadline {
                    spin(0.05)
                    live = Probe.rows.values.filter { $0.id == "A" }
                }
                let ok = settled()
                if !ok { failures += 1 }
                let seen = live.map { "\($0.section)/\($0.dot)/\($0.reasons)" }.joined(separator: " + ")
                print("\(label) step \(i) want \(expectSection)/\(expectDot)/\(step.1)  got \(seen.isEmpty ? "nothing" : seen)  \(ok ? "ok" : "MISMATCH")")
            }
        }
        print("consistency failures: \(failures)")
    }
}
