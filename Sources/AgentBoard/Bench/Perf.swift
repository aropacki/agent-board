import AppKit
import SwiftUI

/// `make perf`: plays scripted interactions against the real views on seeded data, one step per 120 Hz frame.
/// Reports the main thread's time per frame and saves a PNG of each scenario mid-run, so a change can be judged by
/// what it costs and by what it looks like.
enum Perf {
    enum Surface { case panel, popup }

    struct Scenario {
        let name: String
        var surface = Surface.panel
        var frames = 120
        /// Counts frames where the scroll content's height changed, which shows as the scrollbar or content jumping.
        var scrolls = false
        /// The frame saved as the scenario's PNG. Toggling scenarios show their "on" state at even frames.
        var snapAt: Int? = nil
        var setup: (Board, Fixtures) -> Void = { _, _ in }
        let step: (Stage, Int) -> Void
    }

    struct Stage {
        let board: Board
        let data: Fixtures
        let scroller: NSScrollView?
        /// The scroll range once the surface settled, so a sweep covers the same distance every round.
        let range: Double

        func scroll(to y: Double) {
            guard let scroller else { return }
            let live = (scroller.documentView?.frame.height ?? 0) - scroller.contentView.bounds.height
            scroller.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, live))))
            scroller.reflectScrolledClipView(scroller.contentView)
        }

        func sweep(_ i: Int) { scroll(to: range * (0.5 - 0.5 * cos(Double(i) / 20))) }
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "panel/idle") { _, _ in },
        Scenario(name: "panel/clock") { s, i in s.board.now = Date().addingTimeInterval(Double(i) * 61) },
        Scenario(name: "panel/scroll", frames: 240, scrolls: true, snapAt: 31) { s, i in s.sweep(i) },
        // A refresh every 40 frames, animated as the app does, so its transitions finish before the next one.
        Scenario(name: "panel/state", frames: 120) { s, i in
            if i % 40 == 0 { s.board.present(i % 80 == 0 ? s.data.trimmed : s.data.state) }
        },
        Scenario(name: "panel/checks", frames: 60) { s, i in
            let prs = s.data.allPRs
            for pr in (0..<6).map({ prs[(i * 6 + $0) % prs.count] }) {
                s.board.checks[pr.key] = i % 2 == 0 ? Array(s.data.checks.dropLast()) : s.data.checks
                s.board.checksFetchedAt[pr.key] = Date()
            }
        },
        // Overlays toggle slower than their animations run, so each frame measures one open or close, not a pile-up.
        Scenario(name: "panel/menu", frames: 80) { s, i in
            if i % 20 == 0, let pr = s.data.allPRs.first {
                s.board.showMenu(owner: "pr:\(pr.key)", anchor: CGRect(x: 200, y: 200, width: 0, height: 0))
            } else if i % 20 == 10 {
                s.board.closeMenu()
            }
        },
        Scenario(name: "panel/peek", frames: 60) { s, i in
            s.board.checksPeek = i % 2 == 0
                ? ChecksPeek(key: s.data.allPRs[0].key, surface: "panel", anchor: CGRect(x: 60, y: 140, width: 60, height: 16)) : nil
        },
        Scenario(name: "panel/toast", frames: 120) { s, i in
            if i % 60 == 0 { s.board.show(.error, "Could not reach GitHub \(i)") } else if i % 60 == 30 { s.board.toast = nil }
        },
        Scenario(name: "board/open", surface: .popup, frames: 20) { s, i in s.board.boardOpen = i % 2 == 0 },
        Scenario(name: "board/scroll", surface: .popup, frames: 240, scrolls: true, snapAt: 31,
                 setup: { b, _ in b.boardOpen = true }) { s, i in s.sweep(i) },
        Scenario(name: "board/state", surface: .popup, frames: 120, setup: { b, _ in b.boardOpen = true }) { s, i in
            if i % 40 == 0 { s.board.present(i % 80 == 0 ? s.data.trimmed : s.data.state) }
        },
        Scenario(name: "discussion/open", frames: 80) { s, i in
            if i % 40 == 0 { s.board.discussion = (s.data.diffPR.key, "panel") } else if i % 40 == 20 { s.board.discussion = nil }
        },
        Scenario(name: "discussion/scroll", frames: 240, scrolls: true, snapAt: 31,
                 setup: { b, d in b.discussion = (d.diffPR.key, "panel") }) { s, i in s.sweep(i) },
        Scenario(name: "diff/open", surface: .popup, frames: 20) { s, i in s.board.diffOpen = i % 2 == 0 ? s.data.target : nil },
        Scenario(name: "diff/scroll", surface: .popup, frames: 240, scrolls: true, snapAt: 31,
                 setup: { b, d in b.diffOpen = d.target }) { s, i in s.sweep(i) },
        Scenario(name: "diff/fling", surface: .popup, frames: 480, scrolls: true,
                 setup: { b, d in b.diffOpen = d.target }) { s, i in s.scroll(to: Double(i) * 24) },
        Scenario(name: "diff/jump", surface: .popup, frames: 80, scrolls: true,
                 setup: { b, d in b.diffOpen = d.target }) { s, i in
            guard i % 4 == 0 else { return }
            let files = s.data.diff.files
            s.board.diffOpen = DiffTarget(key: s.data.diffPR.key, path: files[(i / 4 * 7) % files.count].path, line: nil)
        },
        Scenario(name: "diff/pick", surface: .popup, frames: 60, setup: { b, d in b.diffOpen = d.target }) { s, i in
            s.board.diffDragging = i < 59
            s.board.diffSelection = DiffSelection(path: s.data.bigFile.path, anchor: 1, head: 1 + i % 8)
        },
        Scenario(name: "diff/click", surface: .popup, frames: 60, setup: { b, d in b.diffOpen = d.target }) { s, i in
            s.board.diffSelection = DiffSelection(path: s.data.bigFile.path, anchor: 1 + i % 8, head: 1 + i % 8)
        },
        Scenario(name: "diff/note", surface: .popup, frames: 40, setup: { b, d in b.diffOpen = d.target }) { s, i in
            let t = s.data.discussion.threads[0]
            let key = t.path + "|t-" + t.id
            if i % 2 == 0 { s.board.diffOpenNotes.insert(key) } else { s.board.diffOpenNotes.remove(key) }
        },
        // Last, since it leaves the popup on the overview page.
        Scenario(name: "diff/overview", surface: .popup, frames: 120, scrolls: true, snapAt: 1, setup: { b, d in
            UserDefaults.standard.set(DiffPage.overview.rawValue, forKey: "diffPage")
            b.diffOpen = d.target
        }) { s, i in s.sweep(i) },
    ]

    struct Result {
        let name: String
        let p50, p95, max, cold: Double
        let miss120, miss60: Int
        let reflow: Int?
        let late95: Double
        /// Millions of instructions the process retired in a frame, p95. Unlike time, it does not move with the
        /// clock speed or with which core ran the frame, so it is the steady number to compare two builds by.
        let minst95: Double

        var tsv: String {
            [name, f(p50), f(p95), f(max), f(cold), "\(miss120)", "\(miss60)", reflow.map(String.init) ?? "-", f(late95), f(minst95)]
                .joined(separator: "\t")
        }
    }

    static let out = URL(fileURLWithPath: ".build/perf")

    static func run() {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-perf")
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("AGENT_BOARD_HOME", home.path, 1)
        precondition(boardDir.path == home.path, "the perf bench must not read the live data directory")
        toolsDisabled = true
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let data = Fixtures()
        let only = env["BENCH_ONLY"]
        let picked = scenarios.filter { only == nil || $0.name.hasPrefix(only!) }
        if let name = env["BENCH_PROFILE"], let s = scenarios.first(where: { $0.name == name }) {
            profile(s, data)
            return
        }
        let rounds = max(1, Int(env["BENCH_ROUNDS"] ?? "") ?? 3)
        let load = Int(env["BENCH_LOAD"] ?? "") ?? 0
        startLoad(threads: load)
        let baseline = read(out.appendingPathComponent(load > 0 ? "baseline-load.tsv" : "baseline.tsv"))
        print("main-thread ms per frame; budget 8.3 at 120 Hz. cold = worst frame of the first round. PNGs in \(out.path)/")
        print("late = p95 ms a frame ran past its 8.3 ms slot, counting time the main thread waited for a core."
              + (load > 0 ? " \(load) busy threads compete for the cores." : ""))
        print(pad("scenario", 14) + ["p50", "p95", "max", "cold", ">8ms", ">16ms", "reflow", "late", "Minst"].map { lpad($0, 7) }.joined()
              + "   vs baseline")
        var results: [Result] = []
        for s in picked {
            // Each scenario drains its own pool, or its window, views, and board outlive it and keep running.
            let r = autoreleasepool { measure(s, data, rounds: rounds) }
            Bench.spin(0.1)
            results.append(r)
            var line = pad(r.name, 14) + [f(r.p50), f(r.p95), f(r.max), f(r.cold), "\(r.miss120)", "\(r.miss60)",
                                           r.reflow.map(String.init) ?? "-", f(r.late95), f(r.minst95)].map { lpad($0, 7) }.joined()
            if let b = baseline[r.name] {
                line += "   p95 \(delta(r.p95, b.p95))  max \(delta(r.max, b.max))  cold \(delta(r.cold, b.cold))"
                    + "  late \(delta(r.late95, b.late95))  Minst \(delta(r.minst95, b.minst95))"
            }
            print(line)
        }
        let rows = results.map(\.tsv).joined(separator: "\n") + "\n"
        try? rows.write(to: out.appendingPathComponent(load > 0 ? "last-load.tsv" : "last.tsv"), atomically: true, encoding: .utf8)
    }

    /// Busy threads at default QoS stand in for a machine running hard. They spin until the bench exits.
    static func startLoad(threads: Int) {
        for _ in 0..<threads {
            let t = Thread {
                var x: UInt64 = 1
                while true { x = x &* 6364136223846793005 &+ 1442695040888963407 }
            }
            t.qualityOfService = .default
            t.start()
        }
    }

    static func measure(_ s: Scenario, _ data: Fixtures, rounds: Int) -> Result {
        let blocked0 = blockedTools.count
        let (board, window, host, stage) = mount(s, data)
        var cold: [Double] = [], warm: [Double] = [], lates: [Double] = [], insts: [Double] = []
        var reflow = 0
        let snapAt = s.snapAt ?? s.frames / 2 & ~1
        for round in 0..<rounds {
            var height = stage.scroller?.documentView?.frame.height ?? 0
            for i in 0..<s.frames {
                let t = mainMs(), w = CACurrentMediaTime(), n = instructions()
                s.step(stage, i)
                Bench.spin(1.0 / 120)
                let ms = mainMs() - t
                if round == 0 { cold.append(ms) } else { warm.append(ms) }
                if round > 0 || rounds == 1 {
                    lates.append(max(0, (CACurrentMediaTime() - w) * 1000 - 1000.0 / 120))
                    insts.append(Double(instructions() - n) / 1e6)
                }
                let h = stage.scroller?.documentView?.frame.height ?? 0
                if abs(h - height) > 0.5 { reflow += 1 }
                height = h
                if round == 0 && i == snapAt { snapshot(host, s.name) }
            }
        }
        window.contentView = nil
        window.close()
        _ = board
        Bench.spin(0.3)
        let blocked = Set(blockedTools.dropFirst(blocked0))
        if !blocked.isEmpty { print("  \(s.name) tried to run, so seed what it fetched: \(blocked.sorted().joined(separator: "; "))") }
        if ProcessInfo.processInfo.environment["BENCH_FRAMES"] != nil {
            print("  \(s.name) frames: " + (warm.isEmpty ? cold : warm).prefix(s.frames).map(f).joined(separator: " "))
        }
        let frames = (warm.isEmpty ? cold : warm).sorted()
        let perRound = Double(max(1, rounds - 1))
        let lateSorted = lates.sorted(), instSorted = insts.sorted()
        return Result(name: s.name, p50: frames[frames.count / 2], p95: frames[min(frames.count - 1, frames.count * 95 / 100)],
                      max: frames.last ?? 0, cold: cold.max() ?? 0,
                      miss120: Int((Double(frames.filter { $0 > 8.33 }.count) / perRound).rounded()),
                      miss60: Int((Double(frames.filter { $0 > 16.7 }.count) / perRound).rounded()),
                      reflow: s.scrolls ? reflow : nil,
                      late95: lateSorted.isEmpty ? 0 : lateSorted[min(lateSorted.count - 1, lateSorted.count * 95 / 100)],
                      minst95: instSorted.isEmpty ? 0 : instSorted[min(instSorted.count - 1, instSorted.count * 95 / 100)])
    }

    /// Loops one scenario long enough for `sample` to attach; `make perf-profile` runs both.
    static func profile(_ s: Scenario, _ data: Fixtures) {
        let (_, _, _, stage) = mount(s, data)
        print("profiling \(s.name)")
        let end = Date().addingTimeInterval(12)
        var i = 0
        while Date() < end {
            s.step(stage, i % s.frames)
            Bench.spin(1.0 / 120)
            i += 1
        }
    }

    static func mount(_ s: Scenario, _ data: Fixtures) -> (Board, NSWindow, NSView, Stage) {
        let board = Board()
        data.seed(board)
        s.setup(board, data)
        let host: NSView, size: NSSize
        switch s.surface {
        case .panel:
            let h = NSHostingView(rootView: BoardView().environment(board))
            h.sizingOptions = []
            host = panelContainer(h)
            size = NSSize(width: 372, height: 930)
        case .popup:
            board.popupPresented = true
            let h = NSHostingView(rootView: PopupRoot().environment(board))
            h.sizingOptions = []
            host = h
            size = NSSize(width: 1440, height: 900)
        }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -9000, y: -4000), size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        Bench.spin(1.2)
        func scrollers(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollers) }
        func range(_ v: NSScrollView) -> Double { (v.documentView?.frame.height ?? 0) - v.contentView.bounds.height }
        let tallest = scrollers(host).max { range($0) < range($1) }
        return (board, window, host, Stage(board: board, data: data, scroller: tallest, range: tallest.map { max(0, range($0)) } ?? 0))
    }

    static func snapshot(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let file = out.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    static func read(_ url: URL) -> [String: Result] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: Result] = [:]
        for line in text.split(separator: "\n") {
            let c = line.split(separator: "\t").map(String.init)
            guard c.count >= 8, let p50 = Double(c[1]), let p95 = Double(c[2]), let mx = Double(c[3]), let cold = Double(c[4]) else { continue }
            out[c[0]] = Result(name: c[0], p50: p50, p95: p95, max: mx, cold: cold, miss120: Int(c[5]) ?? 0, miss60: Int(c[6]) ?? 0,
                               reflow: Int(c[7]), late95: c.count > 8 ? Double(c[8]) ?? 0 : 0,
                               minst95: c.count > 9 ? Double(c[9]) ?? 0 : 0)
        }
        return out
    }

    static func instructions() -> UInt64 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? info.ri_instructions : 0
    }

    static func mainMs() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
    }

    static func f(_ v: Double) -> String { String(format: "%.1f", v) }
    static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count + 1), withPad: " ", startingAt: 0) }
    static func lpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(1, n - s.count)) + s }

    /// Small differences are noise between runs, so they print as a flat mark.
    static func delta(_ now: Double, _ base: Double) -> String {
        guard base > 0.05, abs(now - base) > max(0.3, base * 0.1) else { return "~" }
        return String(format: "%+.0f%%", (now - base) / base * 100)
    }
}
