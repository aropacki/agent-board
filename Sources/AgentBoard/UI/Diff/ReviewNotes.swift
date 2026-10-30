import AppKit
import SwiftUI

/// The agent's summary at the top of the diff, with what is left of its drafts.
struct ReviewSummaryCard: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let review: AgentReview
    let headSha: String?
    @AppStorage("diffSummaryFolded") private var folded = false

    var body: some View {
        let open = review.comments.filter(\.open).count
        let posted = review.comments.filter { $0.status == "posted" }.count
        let dropped = review.comments.filter { $0.status == "dropped" }.count
        let stale = review.sha.map { sha in headSha.map { !$0.hasPrefix(sha) && !sha.hasPrefix($0) } ?? false } ?? false
        VStack(alignment: .leading, spacing: z(8)) {
            HStack(spacing: z(6)) {
                Image(systemName: "sparkles").font(.system(size: z(10.5))).foregroundStyle(T.text3)
                Text("Agent review").font(ui(12, .semibold)).foregroundStyle(T.text)
                if let sha = review.sha { Text(verbatim: String(sha.prefix(7))).font(mono(10)).foregroundStyle(T.text3) }
                Text(open == 1 ? "1 draft" : "\(open) drafts").font(ui(11)).foregroundStyle(T.text3)
                if posted > 0 { Text("\(posted) posted").font(ui(11)).foregroundStyle(T.text3) }
                if stale {
                    Text("The PR moved since this review").font(ui(11)).foregroundStyle(T.yellow.opacity(0.9))
                        .help("Drafts post at the reviewed commit, so GitHub may show them as outdated.")
                }
                Spacer(minLength: z(6))
                if dropped > 0 {
                    Button { board.restoreGhosts(pr) } label: { Text("Restore \(dropped) dropped").font(ui(11)).foregroundStyle(T.text3) }
                        .buttonStyle(HoverButtonStyle.link).pointerOnly()
                }
                if let item = board.reviewActions(pr).first {
                    Button { board.run(item.action, board.context(pr: pr), targets: item.targets) } label: {
                        Text("Run again").font(ui(11)).foregroundStyle(T.text3)
                    }
                    .buttonStyle(HoverButtonStyle.link).pointerOnly()
                    .help("Run “\(item.action.title)” again")
                }
                Button { withAnimation(.snappy(duration: 0.15)) { folded.toggle() } } label: {
                    Image(systemName: "chevron.down").font(.system(size: z(9), weight: .semibold)).foregroundStyle(T.text3)
                        .rotationEffect(.degrees(folded ? -90 : 0))
                }
                .buttonStyle(HoverButtonStyle.link).pointerOnly()
            }
            if !folded && !review.summary.isEmpty { CommentBody(text: review.summary) }
        }
        .padding(z(12))
        .background(T.raised, in: RoundedRectangle(cornerRadius: z(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(8), style: .continuous).strokeBorder(T.border))
    }
}

/// An agent's comment, shown as a draft until it is posted or dropped.
struct GhostComment: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let comment: AgentReview.Comment
    let placed: Bool
    /// Folded shows a three-line glance; a click opens it.
    var folded = false
    var setFolded: (Bool) -> Void = { _ in }
    @State private var editing = false
    @State private var text = ""
    @State private var posting = false

    var body: some View {
        Group {
            if folded {
                Button { setFolded(false) } label: {
                    VStack(alignment: .leading, spacing: z(6)) {
                        title
                        CommentBody(text: comment.body, preview: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerOnly()
                .help("Show the whole draft")
            } else {
                full
            }
        }
        .padding(z(10))
        .background(T.raised, in: RoundedRectangle(cornerRadius: z(8), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: z(8), style: .continuous).strokeBorder(T.border))
    }

    var title: some View {
        HStack(spacing: z(6)) {
            Image(systemName: "sparkles").font(.system(size: z(10))).foregroundStyle(T.text3).frame(width: z(16))
            Text("Agent draft").font(ui(11.5, .semibold)).foregroundStyle(T.text2)
            if let severity = comment.severity, !severity.isEmpty {
                HStack(spacing: z(4)) {
                    Circle().fill(severityColor(severity)).frame(width: z(6), height: z(6))
                    Text(severity).font(ui(11.5)).foregroundStyle(T.text2)
                }
            }
            if !placed {
                Text(verbatim: "line \(comment.line) isn't in the diff").font(ui(10.5)).foregroundStyle(T.text3).lineLimit(1)
            }
            Spacer(minLength: z(6))
        }
    }

    var full: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            HStack(spacing: z(6)) {
                title
                if !editing {
                    link("Edit") { text = comment.body; editing = true }
                    link("Drop") { board.dropGhost(pr, comment.id) }
                    link("Fold") { setFolded(true) }
                }
            }
            if editing {
                InlineComposer(text: $text, placeholder: "Edit the comment…", focusToken: 1) { body, _, done in post(body, done) }
                HStack(spacing: z(8)) {
                    Spacer(minLength: 0)
                    link("Cancel") { editing = false }
                    link("Save draft") {
                        board.editGhost(pr, comment.id, body: text)
                        editing = false
                    }
                }
            } else {
                CommentBody(text: comment.body)
                HStack(spacing: z(6)) {
                    Spacer(minLength: 0)
                    Button { post(comment.body) { _ in } } label: {
                        HStack(spacing: z(4)) {
                            if posting { ProgressView().controlSize(.mini) } else { Image(systemName: "paperplane").font(.system(size: z(10))) }
                            Text("Post").font(ui(11.5, .medium))
                        }
                        .foregroundStyle(placed ? T.text : T.text3)
                    }
                    .buttonStyle(HoverButtonStyle.chip).pointerOnly()
                    .disabled(!placed || posting)
                    .help(placed ? "Post this comment on the PR as you" : "GitHub only takes inline comments on lines in the diff")
                }
            }
        }
    }

    func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(ui(11)).foregroundStyle(T.text3) }
            .buttonStyle(HoverButtonStyle.link).pointerOnly()
    }

    func post(_ body: String, _ done: @escaping (Bool) -> Void) {
        posting = true
        board.postGhost(pr, comment.id, body: body) { ok in
            posting = false
            if ok { editing = false }
            done(ok)
        }
    }
}

struct DiffCounts: View, Zoomed {
    @Environment(\.zoom) var zoom
    let file: DiffFile
    var body: some View {
        HStack(spacing: z(4)) {
            if file.additions > 0 { Text(verbatim: "+\(file.additions)").foregroundStyle(T.green) }
            if file.deletions > 0 { Text(verbatim: "−\(file.deletions)").foregroundStyle(T.red) }
        }
        .font(mono(10))
    }
}

/// A file the PR creates or deletes, tagged with its own icon so it reads before the counts do.
struct FileChangeTag: View, Zoomed {
    @Environment(\.zoom) var zoom
    let status: String
    var short = false

    var body: some View {
        if let (label, icon, color) = style {
            HStack(spacing: z(3)) {
                Image(systemName: icon).font(.system(size: z(8.5), weight: .bold))
                Text(label).font(ui(10, .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, z(5)).padding(.vertical, z(1.5))
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.55)))
            .fixedSize()
        }
    }

    var style: (String, String, Color)? {
        switch status {
        case "added": (short ? "New" : "New file", "plus", T.green)
        case "removed": (short ? "Deleted" : "Deleted file", "trash", T.red)
        default: nil
        }
    }
}
