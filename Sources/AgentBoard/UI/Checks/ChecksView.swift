import AppKit
import SwiftUI

/// A PR's CI checks in one list. Each row opens its check on GitHub.
struct ChecksView: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR

    var body: some View {
        let all = board.checks[pr.key]
        VStack(alignment: .leading, spacing: 0) {
            PRDrawerHeader(pr: pr, loading: board.checksLoading.contains(pr.key), back: board.closeChecks,
                           reload: { board.loadChecks(pr, explicit: true) }) {
                DrawerIconButton(icon: "arrow.up.forward.square", help: "Open the checks on GitHub") { board.openLink(pr.checksURL) }
            }
            Rectangle().fill(T.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let all {
                        if all.isEmpty { note("No checks on this PR.") }
                        ForEach(sortedChecks(all)) { CheckRow(pr: pr, check: $0) }
                    } else if let error = board.checksErrors[pr.key] {
                        note(error, retry: true)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, z(40))
                    }
                }
                .padding(.horizontal, z(6)).padding(.top, z(6)).padding(.bottom, z(60))
            }
            .scrollIndicators(.automatic)
        }
        .task(id: pr.key) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if board.checks[pr.key]?.contains(where: { $0.bucket == "pending" }) == true { board.loadChecks(pr) }
            }
        }
    }

    func note(_ text: String, retry: Bool = false) -> some View {
        VStack(spacing: z(8)) {
            Text(text).font(ui(12)).foregroundStyle(T.text3).multilineTextAlignment(.center)
            if retry { QuietButton(title: "Try again", icon: "arrow.clockwise") { board.loadChecks(pr, explicit: true) } }
        }
        .frame(maxWidth: .infinity).padding(.top, z(40))
    }
}

/// One check. Clicking opens it on GitHub.
struct CheckRow: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let check: CICheck
    var compact = false

    var duration: String? {
        check.started.map { checkDuration((check.completed ?? board.now).timeIntervalSince($0)) }
    }

    var body: some View {
        let link = check.link ?? ""
        Button { board.openLink(link) } label: {
            HStack(spacing: z(7)) {
                CheckIcon(bucket: check.bucket).frame(width: z(14), height: z(14))
                Text(check.name).font(ui(compact ? 11.5 : 12)).foregroundStyle(T.text).lineLimit(1).layoutPriority(1)
                if let w = check.workflow, !w.isEmpty, w != check.name {
                    Text(w).font(ui(compact ? 10.5 : 11)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer(minLength: z(6))
                if let duration { Text(duration).font(digits(11.5)).foregroundStyle(T.text3) }
            }
            .padding(.horizontal, z(compact ? 6 : 8))
            .frame(maxWidth: .infinity, minHeight: z(compact ? 24 : 28), maxHeight: z(compact ? 24 : 28), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(padH: 0, padV: 0, hover: 0.05, press: 0.08, radius: z(6))).pointerOnly()
        .disabled(link.isEmpty)
        .help(link.isEmpty ? check.name : "Open \(check.name) on GitHub. Right-click for more.")
        .menuTarget("check:\(pr.key)|\(check.id)")
    }
}

/// The CI fact. Hovering lists the checks; clicking opens them.
struct CIMeta: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    @Environment(\.boardSurface) private var surface
    let pr: PR
    let action: () -> Void
    @State private var frame: CGRect = .zero

    var body: some View {
        let ci = board.ci(pr)
        Meta(text: pr.draft ? "draft" : ci == "none" ? "no CI" : ci == "passing" ? "" : ci,
             color: ci == "failing" && !pr.draft ? T.text2 : T.text3, ci: ci, help: "", action: action)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .trackHover { board.hoverChecksFact(pr, surface: surface, anchor: frame, inside: $0) }
            .onDisappear { board.hoverChecksFact(pr, surface: surface, anchor: frame, inside: false) }
    }
}

/// A PR's checks in the row menu's frame and rows: what is still running, then a divider and what
/// finished, failures first. Skipped and cancelled checks stay out.
struct ChecksPeekList: View {
    let pr: PR?
    let checks: [CICheck]?
    let error: String?
    @Environment(Board.self) private var board
    static let width: CGFloat = z(300)
    static let maxRows = 14

    static func rows(_ checks: [CICheck]) -> (finished: [CICheck], running: [CICheck]) {
        let shown = sortedChecks(checks.filter { !checkSkipped($0) })
        return (shown.filter { $0.bucket != "pending" }, shown.filter { $0.bucket == "pending" })
    }

    static func size(_ checks: [CICheck]?) -> CGSize {
        let (finished, running) = rows(checks ?? [])
        let count = max(1, min(finished.count + running.count, maxRows))
        let divider = !finished.isEmpty && !running.isEmpty && finished.count + running.count <= maxRows
        return CGSize(width: width, height: Dropdown.pad * 2 + CGFloat(count) * Dropdown.rowHeight + (divider ? Dropdown.dividerHeight : 0))
    }

    var body: some View {
        let (finished, running) = ChecksPeekList.rows(checks ?? [])
        let list = VStack(alignment: .leading, spacing: 0) {
            if let checks, finished.isEmpty && running.isEmpty {
                message(checks.isEmpty ? "No checks on this PR" : "Every check was skipped")
            } else if checks == nil {
                if let error { message(error) } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: Dropdown.rowHeight) }
            }
            ForEach(running) { row($0) }
            if !finished.isEmpty && !running.isEmpty {
                Rectangle().fill(T.border).frame(height: 1)
                    .padding(.vertical, (Dropdown.dividerHeight - 1) / 2).padding(.horizontal, z(4))
            }
            ForEach(finished) { row($0) }
        }
        .padding(Dropdown.pad)
        Group {
            if finished.count + running.count > ChecksPeekList.maxRows { ScrollView { list }.scrollIndicators(.never) } else { list }
        }
        .frame(width: ChecksPeekList.width, height: ChecksPeekList.size(checks).height)
        .background(Color(hex: 0x262626), in: RoundedRectangle(cornerRadius: z(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(9), style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .trackHover { board.hoverChecksList($0) }
    }

    func message(_ text: String) -> some View {
        Text(text).font(T.ui(12)).foregroundStyle(T.text3).padding(.horizontal, z(8))
            .frame(maxWidth: .infinity, minHeight: Dropdown.rowHeight, alignment: .leading)
    }

    func row(_ c: CICheck) -> some View {
        PeekRow(check: c) {
            board.closeChecksPeek()
            if let link = c.link, !link.isEmpty { board.openLink(link) } else if let pr { board.openChecks(pr, surface: board.menuSurface) }
        }
    }
}

/// A check as a row menu item: status where the icon goes, how long it took where a shortcut goes.
struct PeekRow: View {
    let check: CICheck
    let run: () -> Void
    @Environment(Board.self) private var board
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: z(8)) {
                CheckIcon(bucket: check.bucket).frame(width: z(15))
                Text(check.name).font(T.ui(12)).lineLimit(1).foregroundStyle(T.text)
                Spacer(minLength: z(6))
                if let started = check.started {
                    Text(checkDuration((check.completed ?? board.now).timeIntervalSince(started))).font(T.ui(11.5)).foregroundStyle(T.text3)
                }
            }
            .padding(.horizontal, z(8))
            .frame(height: Dropdown.rowHeight)
            .background(RoundedRectangle(cornerRadius: z(5), style: .continuous).fill(hovering ? T.text.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnly()
        .trackHover { hovering = $0 }
        .pointerStyle(.link)
        .help(check.workflow.map { "\($0) · \(check.name)" } ?? check.name)
    }
}

struct CheckIcon: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let bucket: String
    var body: some View {
        Group {
            switch bucket {
            case "pass": Image(systemName: "checkmark.circle.fill").foregroundStyle(T.green)
            case "fail": Image(systemName: "xmark.circle.fill").foregroundStyle(T.red)
            case "pending": Orb(color: T.yellow, size: z(8), moving: true)
            case "cancel": Image(systemName: "slash.circle").foregroundStyle(T.text3)
            default: Image(systemName: "minus.circle").foregroundStyle(T.text3)
            }
        }
        .font(.system(size: z(11), weight: .medium))
        .frame(width: z(12), height: z(12))
    }
}
