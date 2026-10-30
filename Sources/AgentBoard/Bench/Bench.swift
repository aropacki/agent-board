import AppKit
import SwiftUI

/// `AgentBoard --bench`: with no `BENCH_*` mode set it runs `Perf`; the modes render or check the live board off screen.
enum Bench {
    static func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// A machine with no live board, such as CI or a clone that is not installed yet, checks seeded data instead.
    /// Runs before anything reads `boardDir`, which is fixed on first use.
    static func seedWhenNoLiveState() -> Fixtures? {
        let env = ProcessInfo.processInfo.environment
        let live = env["AGENT_BOARD_HOME"].map(expandTilde) ?? NSHomeDirectory() + "/.agent-board"
        guard !FileManager.default.fileExists(atPath: live + "/state.json") else { return nil }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-check")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("AGENT_BOARD_HOME", home.path, 1)
        precondition(boardDir.path == home.path, "seeded checks must not read the live data directory")
        print("no live board state; checking seeded data")
        return Fixtures()
    }

    static func run() {
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["BENCH_PAGE"] ?? DiffPage.files.rawValue, forKey: "diffPage")
        let modes = ["BENCH_LOGIC", "BENCH_CONSISTENCY", "BENCH_MENUAUDIT", "BENCH_FULL", "BENCH_SNAP", "BENCH_TICKER", "BENCH_BANNER"]
        guard modes.contains(where: { ProcessInfo.processInfo.environment[$0] != nil }) else {
            Perf.run()
            return
        }
        let seeded = seedWhenNoLiveState()
        let board = Board()
        if let seeded {
            seeded.seed(board)
        } else {
            let deadline = Date().addingTimeInterval(20)
            while board.state == nil {
                guard Date() < deadline else {
                    print("FAIL: \(stateURL.path) did not load")
                    exit(1)
                }
                spin(0.05)
            }
        }
        board.isFront = true
        let host = NSHostingView(rootView: BoardView().environment(board))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 372, height: 930),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panelContainer(host)
        window.orderFrontRegardless()
        spin(1)
        func scrollView(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = scrollView(sub) { return s } }
            return nil
        }
        if ProcessInfo.processInfo.environment["BENCH_ACTIVITY"] != nil {
            let t = Date()
            let cards = board.state?.cards ?? [], prs = board.allPRs
            board.activity = [
                TickerEvent(kind: .review, text: "Review requested: #\(prs.first?.number ?? 1) \(prs.first?.displayTitle ?? "PR") · @someone",
                            at: t.addingTimeInterval(-90000), target: prs.first?.url),
                TickerEvent(kind: .ciFailed, text: "CI failing: #\(prs.last?.number ?? 2) \(prs.last?.displayTitle ?? "PR")",
                            at: t.addingTimeInterval(-7200), target: prs.last.map { "checks:\($0.key)" }),
                TickerEvent(kind: .approved, text: "Approved: #\(prs.first?.number ?? 1) \(prs.first?.displayTitle ?? "PR")",
                            at: t.addingTimeInterval(-3000), target: prs.first?.url),
                TickerEvent(kind: .finished, text: "Finished: \(cards.first?.title ?? "Chat")", at: t.addingTimeInterval(-600),
                            target: cards.first.map { "card:\($0.id)" }),
                TickerEvent(kind: .comments, text: "New comments: #\(prs.first?.number ?? 1) \(prs.first?.displayTitle ?? "PR") · 2 unresolved",
                            at: t.addingTimeInterval(-120), target: prs.first?.threadURL),
            ]
            board.activitySeenAt = t.addingTimeInterval(-1800)
        }
        if let file = ProcessInfo.processInfo.environment["BENCH_DISCUSSION"],
           let data = FileManager.default.contents(atPath: file), let discussion = parseDiscussion(data) {
            let number = Int(ProcessInfo.processInfo.environment["BENCH_DISCUSSION_PR"] ?? "")
            if let pr = board.allPRs.first(where: { number == nil || $0.number == number }) {
                board.discussions[pr.key] = discussion
                board.discussion = (pr.key, ProcessInfo.processInfo.environment["BENCH_FULL"] != nil ? "window" : "panel")
            }
        }
        if let file = ProcessInfo.processInfo.environment["BENCH_DIFF"], let text = try? String(contentsOfFile: file, encoding: .utf8) {
            let env = ProcessInfo.processInfo.environment
            let number = Int(env["BENCH_DIFF_PR"] ?? "")
            if let pr = board.allPRs.first(where: { number == nil || $0.number == number }) {
                board.diffs[pr.key] = PRDiff(sha: "bench", files: parsePRFiles(text))
                board.diffOpen = DiffTarget(key: pr.key, path: env["BENCH_DIFF_PATH"], line: Int(env["BENCH_DIFF_LINE"] ?? ""),
                                            thread: env["BENCH_DIFF_THREAD"])
                if let file = env["BENCH_REVIEW"], let data = FileManager.default.contents(atPath: file) {
                    board.reviews[reviewFileName(pr)] = parseReview(data)
                }
                let pick = (env["BENCH_DIFF_SELECT"] ?? "").split(separator: "|").map(String.init)
                if pick.count == 3, let a = Int(pick[1]), let b = Int(pick[2]) { board.diffSelection = DiffSelection(path: pick[0], anchor: a, head: b) }
            }
        }
        if let file = ProcessInfo.processInfo.environment["BENCH_OVERVIEW"], let data = FileManager.default.contents(atPath: file),
           let key = board.diffOpen?.key {
            board.overviews[key] = parseOverview(data)
        }
        if let file = ProcessInfo.processInfo.environment["BENCH_CHECKS"],
           let data = FileManager.default.contents(atPath: file),
           let checks = parseCheckRollups(String(decoding: data, as: UTF8.self))?[0] {
            let number = Int(ProcessInfo.processInfo.environment["BENCH_CHECKS_PR"] ?? "")
            if let pr = board.allPRs.first(where: { number == nil || $0.number == number }) {
                board.checks[pr.key] = checks
                if ProcessInfo.processInfo.environment["BENCH_PEEK"] != nil {
                    board.checksPeek = ChecksPeek(key: pr.key, surface: "panel", anchor: CGRect(x: 60, y: 140, width: 60, height: 16))
                } else {
                    board.checksOpen = (pr.key, ProcessInfo.processInfo.environment["BENCH_FULL"] != nil ? "window" : "panel")
                }
            }
        }
        let scroller = scrollView(host)
        if ProcessInfo.processInfo.environment["BENCH_LOGIC"] != nil {
            logic()
            return
        }
        if let out = ProcessInfo.processInfo.environment["BENCH_BANNER"] {
            let banners = Banners()
            banners.items = [
                TickerEvent(kind: .review, text: "Review requested: #138222 validata: add resolution_strategy (model_first / "
                    + "seller_first) to confidence signals · @octocat"),
                TickerEvent(kind: .comments, text: "Comment from @octocat: #4512 Example PR title · “Can we keep the old name "
                    + "here? Callers outside this package still import it.”"),
                TickerEvent(kind: .changes, text: "Changes requested: #4513 Another example PR"),
            ]
            let bannerHost = NSHostingView(rootView: BannerStack(banners: banners, open: { _ in }, close: { _ in }, resized: { _ in }))
            bannerHost.sizingOptions = []
            let stack = NSWindow(contentRect: NSRect(x: -9000, y: -4000, width: 400, height: 420), styleMask: .borderless,
                                 backing: .buffered, defer: false)
            stack.backgroundColor = NSColor(white: 0.32, alpha: 1)
            stack.contentView = bannerHost
            stack.orderFrontRegardless()
            spin(Double(ProcessInfo.processInfo.environment["BENCH_WAIT"] ?? "3") ?? 3)
            let rep = bannerHost.bitmapImageRepForCachingDisplay(in: bannerHost.bounds)!
            bannerHost.cacheDisplay(in: bannerHost.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            return
        }
        if let out = ProcessInfo.processInfo.environment["BENCH_TICKER"] {
            if let text = ProcessInfo.processInfo.environment["BENCH_NOTE"] { board.tickerNote = TickerEvent(kind: .finished, text: text) }
            board.tickerLast = TickerEvent(kind: .ciFailed, text: "CI failing: #123 Example PR", at: Date().addingTimeInterval(-300))
            board.tickerNotchInset = Double(ProcessInfo.processInfo.environment["BENCH_INSET"] ?? "0") ?? 0
            let width = Double(ProcessInfo.processInfo.environment["BENCH_WIDTH"] ?? "659") ?? 659
            for (side, name) in [(TickerSide.status, out), (TickerSide.notes, out + ".notes.png")] {
                let tickerHost = NSHostingView(rootView: TickerBar(side: side).environment(board))
                tickerHost.sizingOptions = []
                let strip = NSWindow(contentRect: NSRect(x: -9000, y: -4000, width: CGFloat(width), height: 33), styleMask: .borderless, backing: .buffered, defer: false)
                strip.contentView = tickerHost
                strip.orderFrontRegardless()
                spin(1.0)
                let rep = tickerHost.bitmapImageRepForCachingDisplay(in: tickerHost.bounds)!
                tickerHost.cacheDisplay(in: tickerHost.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
            }
            return
        }
        if let out = ProcessInfo.processInfo.environment["BENCH_FULL"] {
            let width = Double(ProcessInfo.processInfo.environment["BENCH_WIDTH"] ?? "1440") ?? 1440
            board.showActions = ProcessInfo.processInfo.environment["BENCH_ACTIONS"] != nil
            board.boardOpen = ProcessInfo.processInfo.environment["BENCH_POPUP_BOARD"] != "0"
            board.popupPresented = true
            let fullHost = NSHostingView(rootView: PopupRoot().environment(board))
            let full = NSWindow(contentRect: NSRect(x: -9000, y: -4000, width: width, height: 900), styleMask: .borderless,
                                backing: .buffered, defer: false)
            full.contentView = fullHost
            full.orderFrontRegardless()
            spin(1.5)
            let rep = fullHost.bitmapImageRepForCachingDisplay(in: fullHost.bounds)!
            fullHost.cacheDisplay(in: fullHost.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            return
        }
        if ProcessInfo.processInfo.environment["BENCH_MENUAUDIT"] != nil {
            board.boardOpen = true
            board.popupPresented = true
            let fullHost = NSHostingView(rootView: PopupRoot().environment(board))
            let full = NSWindow(contentRect: NSRect(x: -9000, y: -4000, width: 1440, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
            full.contentView = fullHost
            full.orderFrontRegardless()
            spin(1.5)
            func audit(_ label: String, _ surfaces: [String]) {
            for surface in surfaces {
                let targets = board.menuTargets.values.filter { $0.surface == surface }
                let ports = board.menuViewports.values.filter { $0.surface == surface }
                var problems: [String: Int] = [:]
                var kinds: [String: Int] = [:]
                for t in targets {
                    kinds[String(t.owner.split(separator: ":")[0]), default: 0] += 1
                    let visible = ports.contains { $0.frame.intersects(t.frame) }
                    if !visible { problems["outside every viewport: \(t.owner.split(separator: ":")[0])", default: 0] += 1; continue }
                    if board.actions(for: t.owner).isEmpty { problems["no actions: \(t.owner)", default: 0] += 1 }
                    let f = t.frame.insetBy(dx: 2, dy: 2)
                    for fx in [0.0, 0.5, 1.0] { for fy in [0.0, 0.5, 1.0] {
                        let pt = CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
                        guard board.menuViewports[t.viewport]?.frame.contains(pt) == true else { continue }
                        guard let hit = board.menuOwner(at: pt, surface: surface) else { problems["nothing at a point of \(t.owner.split(separator: ":")[0])", default: 0] += 1; continue }
                        if hit == t.owner { continue }
                        let inner = targets.first { $0.owner == hit && t.frame.contains($0.frame) && $0.frame.contains(pt) }
                        if inner == nil { problems["\(t.owner.split(separator: ":")[0]) point won by unrelated \(hit.split(separator: ":")[0])", default: 0] += 1 }
                    } }
                }
                print("\(label) \(surface): targets \(kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) viewports \(ports.count)")
                for (k, v) in problems.sorted(by: { $0.key < $1.key }) { print("  \(v)x \(k)") }
            }
            }
            audit("start", ["panel", "window"])
            // Hiding the popup detaches its view tree, and showing it attaches the same tree again.
            let shown = board.menuTargets.values.filter { $0.surface == "window" }.count
            full.contentView = NSView()
            spin(0.3)
            full.contentView = fullHost
            spin(0.6)
            let back = board.menuTargets.values.filter { $0.surface == "window" }.count
            if back < shown { print("  \(shown - back)x nothing at a point of a row after the popup reopened") }
            audit("reopened", ["window"])
            let before = Dictionary(board.menuTargets.filter { $0.value.surface == "panel" }.map { ($0.key, $0.value.frame) }, uniquingKeysWith: { a, _ in a })
            if let scroller {
                scroller.contentView.scroll(to: NSPoint(x: 0, y: 260))
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            spin(0.6)
            let moved = before.filter { board.menuTargets[$0.key]?.frame != $0.value }.count
            print("after scroll: \(moved) of \(before.count) panel targets moved")
            audit("scrolled", ["panel"])
            return
        }
        if let out = ProcessInfo.processInfo.environment["BENCH_SNAP"] {
            let want = ProcessInfo.processInfo.environment["BENCH_MENU"] ?? "stack"
            let targets = board.menuTargets.values.filter { t in t.owner.hasPrefix(want + ":") && board.menuViewports.values.contains { $0.frame.contains(t.frame) } }
            // A PR line inside a card must resolve to the PR, not the card around it.
            for t in board.menuTargets.values where t.owner.hasPrefix("pr:") {
                for c in board.menuTargets.values where c.owner.hasPrefix("card:") && c.frame.contains(t.frame) {
                    let hit = board.menuOwner(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
                    print("nested hit \(hit == t.owner ? "ok" : "WRONG \(hit ?? "nil")")")
                    break
                }
            }
            if let t = targets.min(by: { $0.frame.minY < $1.frame.minY }) {
                board.showMenu(owner: t.owner, anchor: CGRect(x: t.frame.maxX - 60, y: t.frame.minY + 14, width: 0, height: 0))
                print("menu for \(t.owner): \(board.menu?.actions.map(\.title) ?? [])")
            } else {
                print("no \(want) row on screen")
            }
            spin(0.6)
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            return
        }
        consistency(board)
    }
}
