import AppKit
import SwiftUI

/// A PR's page without its diff: where it stands, what can be done with it, its stack, and its description.
struct PROverviewPage: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: z(20)) {
                if let o = board.overviews[pr.key] {
                    summary(o)
                    MergeBox(pr: pr, overview: o)
                    let stack = board.stackMembers(of: pr)
                    if stack.count > 1 { StackList(current: pr, members: stack) }
                    VStack(alignment: .leading, spacing: z(8)) {
                        SectionLabel(title: "Description")
                        if o.body.isEmpty {
                            Text("No description.").font(ui(12.5)).foregroundStyle(T.text3)
                        } else {
                            MarkdownDoc(text: o.body)
                        }
                    }
                } else if let error = board.overviewErrors[pr.key] {
                    VStack(spacing: z(8)) {
                        Text(error).font(ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center)
                        QuietButton(title: "Try again", icon: "arrow.clockwise") { board.loadOverview(pr, explicit: true) }
                    }
                    .frame(maxWidth: .infinity).padding(.top, z(40))
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, z(40))
                }
            }
            .frame(maxWidth: z(780), alignment: .leading)
            .padding(.horizontal, z(24)).padding(.top, z(18)).padding(.bottom, z(48))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .task(id: pr.key) {
            if board.checks[pr.key] == nil { board.loadChecks(pr) }
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(30))) != nil else { return }
                if board.overviews[pr.key]?.open != false { board.loadOverview(pr) }
                if board.checks[pr.key]?.contains(where: { $0.bucket == "pending" }) == true { board.loadChecks(pr) }
            }
        }
    }

    func summary(_ o: PROverview) -> some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Text(pr.displayTitle).font(ui(16, .semibold)).foregroundStyle(T.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: z(8)) {
                StatePill(overview: o)
                Text("@\(o.author) opened \(shortAge(from: o.createdAt, to: board.now)) ago").font(ui(12)).foregroundStyle(T.text3)
            }
            HStack(spacing: z(6)) {
                BranchName(name: o.base)
                Image(systemName: "arrow.left").font(.system(size: z(9), weight: .semibold)).foregroundStyle(T.text3)
                BranchName(name: o.head)
                Text("·").foregroundStyle(T.text3)
                Text("\(o.commits) \(o.commits == 1 ? "commit" : "commits"), \(o.files) \(o.files == 1 ? "file" : "files")")
                    .font(ui(11.5)).foregroundStyle(T.text3)
                Text(verbatim: "+\(o.additions)").font(mono(10.5)).foregroundStyle(T.green.opacity(0.85))
                Text(verbatim: "−\(o.deletions)").font(mono(10.5)).foregroundStyle(T.red.opacity(0.85))
            }
            if !o.labels.isEmpty {
                FlowLayout(spacing: z(4)) { ForEach(o.labels) { LabelChip(label: $0) } }
            }
        }
    }
}

struct SectionLabel: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: z(6)) {
            Text(title).font(ui(11.5, .semibold)).foregroundStyle(T.text2)
            if let detail { Text(detail).font(ui(11.5)).foregroundStyle(T.text3) }
        }
    }
}

struct StatePill: View, Zoomed {
    @Environment(\.zoom) var zoom
    let overview: PROverview
    var body: some View {
        let o = overview
        let (title, icon, color): (String, String, Color) =
            o.state == "MERGED" ? ("Merged", "arrow.triangle.merge", T.purple)
            : o.state == "CLOSED" ? ("Closed", "xmark", T.red)
            : o.draft ? ("Draft", "pencil", T.text3)
            : o.queued ? ("Queued", "list.number", T.yellow)
            : ("Open", "arrow.triangle.pull", T.green)
        HStack(spacing: z(4)) {
            Image(systemName: icon).font(.system(size: z(9.5), weight: .semibold))
            Text(title).font(ui(11.5, .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, z(7)).padding(.vertical, z(2.5))
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Clicking copies it, since a branch name is mostly wanted for a checkout.
struct BranchName: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let name: String
    var body: some View {
        Button {
            board.copy(name)
            board.show(.ok, "Copied \(name)")
        } label: {
            Text(name).font(mono(11)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(HoverButtonStyle(padH: z(5), padV: z(1.5), rest: 0.06, hover: 0.1, press: 0.14, radius: z(4))).pointerOnly()
        .help("Copy \(name)")
    }
}

struct LabelChip: View, Zoomed {
    @Environment(\.zoom) var zoom
    let label: PROverview.Label
    var body: some View {
        let color = Color(hex: UInt32(label.color, radix: 16) ?? 0x888888)
        HStack(spacing: z(4)) {
            Circle().fill(color).frame(width: z(6), height: z(6))
            Text(label.name).font(ui(11)).foregroundStyle(T.text2)
        }
        .padding(.horizontal, z(6)).padding(.vertical, z(2))
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// Reviews, checks, and the branch, each as one line that says whether it holds up the merge, over the actions.
struct MergeBox: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let overview: PROverview
    @State private var showAllChecks = false

    var body: some View {
        let o = overview
        VStack(alignment: .leading, spacing: 0) {
            reviews(o)
            divider
            checks()
            if o.open {
                divider
                branch(o)
            }
            if o.open, let stack = o.stack, stack.lands.count > 1 {
                divider
                stackLine(stack)
            }
            Rectangle().fill(T.border).frame(height: 1)
            MergeActions(pr: pr, overview: o)
                .padding(.horizontal, z(12)).padding(.vertical, z(10))
                .background(Color.white.opacity(0.02))
        }
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: z(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(10), style: .continuous).strokeBorder(T.border))
    }

    var divider: some View { Rectangle().fill(T.border).frame(height: 1).padding(.leading, z(36)) }

    func reviews(_ o: PROverview) -> some View {
        let waiting = o.reviewers.filter { $0.state == "REQUESTED" }.count
        let (title, icon, tint): (String, String, Color) = switch o.decision {
        case "APPROVED": ("Approved", "checkmark.circle.fill", T.green)
        case "CHANGES_REQUESTED": ("Changes requested", "xmark.circle.fill", T.red)
        case "REVIEW_REQUIRED": ("Review required", "circle.dashed", T.yellow)
        default: (o.reviewers.isEmpty ? "No reviews" : "Reviewed", "person.2", T.text3)
        }
        return StatusLine(icon: icon, tint: tint, title: title, detail: waiting > 0 ? "\(waiting) waiting" : nil) {
            EmptyView()
        } more: {
            if !o.reviewers.isEmpty {
                FlowLayout(spacing: z(6)) { ForEach(o.reviewers) { ReviewerChip(reviewer: $0) } }
            }
        }
    }

    func checks() -> some View {
        let all = board.checks[pr.key]
        let counted = (all ?? []).filter { !checkSkipped($0) }
        let failing = counted.filter { $0.bucket == "fail" }, running = counted.filter { $0.bucket == "pending" }
        let passed = counted.count - failing.count - running.count
        let (title, icon, tint): (String, String, Color) =
            all == nil ? (board.checksErrors[pr.key] == nil ? "Loading checks" : "Couldn't load checks", "circle.dotted", T.text3)
            : counted.isEmpty ? ("No checks", "minus.circle", T.text3)
            : !failing.isEmpty ? ("\(failing.count) failing", "xmark.circle.fill", T.red)
            : !running.isEmpty ? ("\(running.count) running", "clock", T.yellow)
            : ("All checks passed", "checkmark.circle.fill", T.green)
        let detail = [passed == 0 ? nil : passed < counted.count ? "\(passed) passed" : "\(passed) checks",
                      !failing.isEmpty && !running.isEmpty ? "\(running.count) running" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        let shown = showAllChecks ? sortedChecks(counted) : sortedChecks(failing + running)
        return StatusLine(icon: icon, tint: tint, title: title, detail: detail.isEmpty ? nil : detail) {
            if passed > 0 {
                QuietButton(title: showAllChecks ? "Hide passed" : "Show all", icon: showAllChecks ? "chevron.up" : "chevron.down") {
                    withAnimation(.snappy(duration: 0.2)) { showAllChecks.toggle() }
                }
            }
        } more: {
            if !shown.isEmpty {
                VStack(spacing: 0) { ForEach(shown) { CheckRow(pr: pr, check: $0, compact: true) } }
                    .padding(.leading, -z(6))
            }
        }
    }

    func branch(_ o: PROverview) -> some View {
        let conflicts = o.mergeState == "DIRTY" || o.mergeable == "CONFLICTING"
        let required = o.mergeState == "BEHIND"
        let (title, detail, icon, tint): (String, String?, String, Color) =
            conflicts ? ("Conflicts with \(o.base)", "Resolve them on the branch and push", "exclamationmark.triangle.fill", T.red)
            : required || o.canUpdateBranch
                ? ("Behind \(o.base)", required ? "The base requires an up-to-date branch" : "No conflicts", "arrow.down.circle",
                   required ? T.yellow : T.text3)
            : o.mergeable == "UNKNOWN" ? ("Checking for conflicts", nil, "circle.dotted", T.text3)
            : ("No conflicts with \(o.base)", nil, "checkmark.circle.fill", T.green)
        return StatusLine(icon: icon, tint: tint, title: title, detail: detail) {
            if o.canUpdateBranch && !conflicts {
                ActionChip(title: "Update branch", key: board.prCommandKey(pr)) { board.runPRCommand(pr, .updateBranch) }
                    .help("Merge \(o.base) into \(o.head)")
                    .padding(.trailing, z(7))
            }
        } more: { EmptyView() }
    }

    func stackLine(_ stack: PRStack) -> some View {
        let below = stack.lands.filter { $0.number != pr.number }
        let blocker = stack.blocker(below: pr.number)
        return StatusLine(icon: "square.stack.3d.up", tint: blocker == nil ? T.green : T.yellow,
                          title: "Merges with \(below.count) below",
                          detail: blocker ?? below.map { "#\($0.number)" }.joined(separator: ", ")) {
            EmptyView()
        } more: { EmptyView() }
    }
}

/// One fact in the merge box: a status mark, what it is, and an optional action, with detail rows below.
struct StatusLine<Accessory: View, More: View>: View, Zoomed {
    @Environment(\.zoom) var zoom
    let icon: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let more: More

    var body: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            HStack(spacing: z(10)) {
                Image(systemName: icon).font(.system(size: z(13), weight: .medium)).foregroundStyle(tint).frame(width: z(14))
                Text(title).font(ui(12.5, .medium)).foregroundStyle(T.text)
                if let detail { Text(detail).font(ui(12)).foregroundStyle(T.text3).lineLimit(1) }
                Spacer(minLength: z(6))
                accessory
            }
            more.padding(.leading, z(24))
        }
        .padding(.horizontal, z(12)).padding(.vertical, z(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewerChip: View, Zoomed {
    @Environment(\.zoom) var zoom
    let reviewer: PROverview.Reviewer
    var body: some View {
        let (icon, tint, word): (String, Color, String) = switch reviewer.state {
        case "APPROVED": ("checkmark", T.green, "approved")
        case "CHANGES_REQUESTED": ("xmark", T.red, "requested changes")
        case "REQUESTED": ("clock", T.text3, "review requested")
        case "DISMISSED": ("minus", T.text3, "review dismissed")
        default: ("text.bubble", T.text3, "commented")
        }
        HStack(spacing: z(5)) {
            if reviewer.team {
                Image(systemName: "person.2.fill").font(.system(size: z(8))).foregroundStyle(T.text3)
                    .frame(width: z(16), height: z(16)).background(Color.white.opacity(0.08), in: Circle())
            } else {
                Avatar(login: reviewer.login, size: 16)
            }
            Text(reviewer.login).font(ui(11.5)).foregroundStyle(T.text2)
            Image(systemName: icon).font(.system(size: z(8.5), weight: .bold)).foregroundStyle(tint)
        }
        .padding(.leading, z(2)).padding(.trailing, z(7)).padding(.vertical, z(2))
        .background(Color.white.opacity(0.04), in: Capsule())
        .help("\(reviewer.login): \(word)")
    }
}

/// The merge box's buttons. Merging, or arming a merge for later, takes a second click, since neither can be taken back.
struct MergeActions: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let overview: PROverview
    @AppStorage("mergeMethod") private var chosen = ""
    @State private var armed: String?

    var method: MergeMethod {
        let o = overview
        return o.methods.first { $0.rawValue == chosen } ?? o.defaultMethod.flatMap { o.methods.contains($0) ? $0 : nil }
            ?? o.methods.first ?? .squash
    }

    var body: some View {
        let o = overview
        let busy = board.busy.contains(board.prCommandKey(pr))
        HStack(spacing: z(10)) {
            if !o.open {
                Text(o.state == "MERGED" ? "Merged into \(o.base)." : "Closed without merging.").font(ui(12)).foregroundStyle(T.text3)
            } else if o.draft {
                PrimaryButton(title: "Ready for review", tint: T.blue, busy: busy) { board.runPRCommand(pr, .ready) }
                Text("A draft can't merge.").font(ui(11.5)).foregroundStyle(T.text3)
            } else if o.queued {
                Text(o.queuePosition.map { "In the merge queue, position \($0)." } ?? "In the merge queue.")
                    .font(ui(12)).foregroundStyle(T.text2)
            } else if let auto = o.autoMerge {
                Text("Merges by \(auto.short.lowercased()) once the requirements pass" + (o.autoMergeBy.map { ", set by @\($0)." } ?? "."))
                    .font(ui(12)).foregroundStyle(T.text2)
                ActionChip(title: "Turn off", key: board.prCommandKey(pr)) { board.runPRCommand(pr, .disableAuto) }
            } else {
                choices(o, busy: busy)
            }
            Spacer(minLength: z(6))
            if o.open && !o.draft && !o.queued {
                QuietButton(title: "Convert to draft", icon: "pencil") { board.runPRCommand(pr, .draft) }
                    .disabled(busy)
            }
        }
        .frame(minHeight: z(26))
        .onChange(of: o.headSha) { armed = nil }
        .task(id: armed) {
            guard armed != nil, (try? await Task.sleep(for: .seconds(6))) != nil else { return }
            withAnimation(.snappy(duration: 0.2)) { armed = nil }
        }
    }

    @ViewBuilder func choices(_ o: PROverview, busy: Bool) -> some View {
        let ready = ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(o.mergeState)
        let conflicts = o.mergeState == "DIRTY" || o.mergeable == "CONFLICTING"
        if conflicts {
            Text("Fix the conflicts to merge.").font(ui(12)).foregroundStyle(T.text3)
        } else if let stack = o.stack {
            stackChoices(o, stack, ready: ready, busy: busy)
        } else if o.queueEnabled {
            armedButton("queue", ready ? "Add to merge queue" : "Merge when ready", confirm: "Confirm: queue #\(pr.number)",
                        tint: T.green, busy: busy) { board.runPRCommand(pr, .merge(nil, auto: false)) }
        } else {
            methodChips(o)
            if ready {
                armedButton("merge", method.title, confirm: "Confirm: \(method.title.lowercased()) #\(pr.number)",
                            tint: T.green, busy: busy) { board.runPRCommand(pr, .merge(method, auto: false)) }
            } else if o.autoMergeAllowed {
                armedButton("auto", "Merge when ready", confirm: "Confirm: auto-merge #\(pr.number)", tint: T.green, busy: busy) {
                    board.runPRCommand(pr, .merge(method, auto: true))
                }
                .help("Turn on auto-merge: GitHub merges once reviews and required checks pass")
            } else {
                Text("Waiting on reviews or required checks.").font(ui(12)).foregroundStyle(T.text3)
            }
        }
    }

    @ViewBuilder func methodChips(_ o: PROverview) -> some View {
        if o.methods.count > 1 {
            HStack(spacing: z(2)) {
                ForEach(o.methods, id: \.self) { m in
                    ToggleChip(title: m.short, on: m == method) { chosen = m.rawValue; armed = nil }
                }
            }
        }
    }

    /// GitHub has no auto-merge for stacks, so a stack that isn't ready says what it waits on instead.
    @ViewBuilder func stackChoices(_ o: PROverview, _ stack: PRStack, ready: Bool, busy: Bool) -> some View {
        let blocker = stack.blocker(below: pr.number)
        let whole = stack.lands.count > 1
        if !ready || blocker != nil {
            Text(blocker == nil ? "Waiting on reviews or required checks." : "Waiting on the PRs below.")
                .font(ui(12)).foregroundStyle(T.text3)
        } else if o.queueEnabled {
            armedButton("queue", whole ? "Queue the stack" : "Add to merge queue", confirm: "Confirm: queue \(stack.list)",
                        tint: T.green, busy: busy) { board.runStackMerge(pr, nil) }
        } else {
            methodChips(o)
            armedButton("merge", whole ? "Merge stack (\(stack.lands.count))" : method.title,
                        confirm: "Confirm: \(method.short.lowercased()) \(stack.list)", tint: T.green, busy: busy) {
                board.runStackMerge(pr, method)
            }
            .help(whole ? "Merge \(stack.list) into \(stack.base) together, bottom first" : "")
        }
    }

    func armedButton(_ id: String, _ title: String, confirm: String, tint: Color, busy: Bool,
                     run: @escaping () -> Void) -> some View {
        let on = armed == id
        return HStack(spacing: z(6)) {
            PrimaryButton(title: on ? confirm : title, tint: on ? T.orange : tint, strong: on, busy: busy) {
                if on {
                    armed = nil
                    run()
                } else {
                    withAnimation(.snappy(duration: 0.2)) { armed = id }
                }
            }
            if on { QuietButton(title: "Cancel", icon: "xmark") { withAnimation(.snappy(duration: 0.2)) { armed = nil } } }
        }
    }
}

struct PrimaryButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    let title: String
    let tint: Color
    var strong = false
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(ui(12, .semibold)).foregroundStyle(strong ? T.text : tint)
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.mini) } }
                .padding(.horizontal, z(11)).padding(.vertical, z(5))
                .background(tint.opacity(strong ? 0.32 : 0.14), in: RoundedRectangle(cornerRadius: z(6), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: z(6), style: .continuous).strokeBorder(tint.opacity(0.35)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .disabled(busy)
    }
}

/// The stack base first, the open PR marked. Clicking another one moves the page to it.
struct StackList: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let current: PR
    let members: [PR]

    var body: some View {
        let at = members.firstIndex { $0.key == current.key }.map { $0 + 1 }
        VStack(alignment: .leading, spacing: z(6)) {
            SectionLabel(title: "Stack", detail: at.map { "\($0) of \(members.count)" })
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.key) { i, m in
                    let here = m.key == current.key
                    if i > 0 { Rectangle().fill(T.border).frame(height: 1).padding(.leading, z(36)) }
                    TapTarget(padH: 10, padV: 7, hover: here ? 0 : 0.04, radius: 0, action: { if !here { board.openDiff(m) } }) {
                        HStack(spacing: z(10)) {
                            Text(verbatim: "\(i + 1)").font(mono(10.5)).foregroundStyle(here ? T.blue : T.text3).frame(width: z(16))
                            CIDot(ci: board.ci(m))
                            Text(m.displayTitle).font(ui(12.5, here ? .semibold : .regular)).foregroundStyle(here ? T.text : T.text2)
                                .lineLimit(1)
                            Spacer(minLength: z(6))
                            if m.draft { Text("draft").font(ui(11)).foregroundStyle(T.text3) }
                            if m.review == "APPROVED" {
                                Image(systemName: "checkmark").font(.system(size: z(9), weight: .bold)).foregroundStyle(T.green)
                            } else if m.review == "CHANGES_REQUESTED" {
                                Image(systemName: "hand.raised").font(.system(size: z(9.5))).foregroundStyle(T.red)
                            }
                            Text(verbatim: "#\(m.number)").font(mono(10.5)).foregroundStyle(T.text3)
                        }
                    }
                    .background(here ? T.blue.opacity(0.08) : .clear)
                }
            }
            .background(Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: z(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: z(10), style: .continuous).strokeBorder(T.border))
        }
    }
}

/// A description's headings, lists, tasks, quotes, tables, and code, in the comment text's type.
struct MarkdownDoc: View, Zoomed {
    @Environment(\.zoom) var zoom
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: z(10)) {
            ForEach(Array(markdownBlocks(text).enumerated()), id: \.offset) { _, block in view(block) }
        }
        .tint(T.blue)
        .textSelection(.enabled)
    }

    func prose(_ s: String, size: CGFloat = 13, weight: Font.Weight = .regular, color: Color = T.text) -> some View {
        Text(inlineMarkdown(s)).font(ui(size, weight)).foregroundStyle(color).lineSpacing(z(2.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            prose(s, size: level == 1 ? 15.5 : level == 2 ? 14 : 13, weight: .semibold).padding(.top, z(level <= 2 ? 6 : 2))
        case .paragraph(let s):
            prose(s)
        case .list(let items):
            VStack(alignment: .leading, spacing: z(4)) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: z(7)) {
                        if let done = item.done {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .font(.system(size: z(11))).foregroundStyle(done ? T.green.opacity(0.85) : T.text3)
                        } else {
                            Text(item.marker).font(ui(13)).foregroundStyle(T.text3)
                        }
                        prose(item.text, color: item.done == true ? T.text2 : T.text)
                    }
                    .padding(.leading, z(CGFloat(item.indent) * 16))
                }
            }
        case .quote(let s):
            prose(s, color: T.text2)
                .padding(.leading, z(10))
                .overlay(alignment: .leading) { Rectangle().fill(T.text3.opacity(0.5)).frame(width: z(2)) }
        case .code(_, let s):
            Text(s).font(mono(11)).foregroundStyle(T.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(z(9))
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: z(6), style: .continuous))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: z(14), verticalSpacing: z(6)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            prose(cell, size: 12, weight: r == 0 ? .semibold : .regular, color: r == 0 ? T.text : T.text2)
                        }
                    }
                    if r == 0 { Rectangle().fill(T.border).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(z(10))
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: z(8), style: .continuous))
        case .rule:
            Rectangle().fill(T.border).frame(height: 1)
        }
    }
}
