import AppKit
import SwiftUI

/// A resolved thread folded to one line; a click unfolds it.
struct ResolvedThreadRow: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let thread: ReviewThread
    var showFile = true
    let open: () -> Void

    var body: some View {
        let first = thread.comments.first
        Button(action: open) {
            HStack(spacing: z(7)) {
                Image(systemName: "checkmark.circle").font(.system(size: z(10.5))).foregroundStyle(T.green.opacity(0.7))
                if showFile {
                    Text((thread.path as NSString).lastPathComponent + (thread.line.map { ":\($0)" } ?? ""))
                        .font(mono(10.5)).foregroundStyle(T.text3).lineLimit(1)
                }
                if let first {
                    Text(first.author).font(ui(11.5, .medium)).foregroundStyle(T.text2)
                    Text(first.body.split(separator: "\n").first.map(String.init) ?? "").font(ui(11.5)).foregroundStyle(T.text3).lineLimit(1)
                }
                Spacer(minLength: z(4))
                if thread.comments.count > 1 { Text(verbatim: "\(thread.comments.count)").font(mono(10)).foregroundStyle(T.text3) }
                Ago(date: thread.lastActivity, size: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle(padH: z(10), padV: z(7), rest: 0.025, hover: 0.05, press: 0.08, radius: T.rowRadius)).pointerOnly()
        .help("Resolved. Click to show the thread.")
    }
}

/// Reply and Resolve under a thread shown in the diff.
struct ThreadReplyBar: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let thread: ReviewThread
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: z(6)) {
            InlineComposer(text: $draft, placeholder: "Reply…", resolves: !thread.resolved) { body, resolve, done in
                board.reply(pr, threadID: thread.id, body: body) { ok in
                    if ok {
                        draft = ""
                        if resolve { board.setResolved(pr, thread, true) }
                    }
                    done(ok)
                }
            }
            ResolveButton(pr: pr, thread: thread).padding(.top, z(5))
        }
    }
}

struct ResolveButton: View, Zoomed {
    @Environment(\.zoom) var zoom
    @Environment(Board.self) private var board
    let pr: PR
    let thread: ReviewThread

    var body: some View {
        let resolving = board.busy.contains("resolve-\(thread.id)")
        Button { board.setResolved(pr, thread, !thread.resolved) } label: {
            HStack(spacing: z(4)) {
                ZStack {
                    if resolving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: thread.resolved ? "arrow.uturn.backward" : "checkmark").font(.system(size: z(9.5), weight: .semibold))
                    }
                }
                .frame(width: z(11), height: z(11))
                Text(thread.resolved ? "Unresolve" : "Resolve").font(ui(11))
            }
            .foregroundStyle(T.text2)
        }
        .buttonStyle(HoverButtonStyle.link).pointerOnly()
        .disabled(resolving)
        .help(thread.resolved ? "Reopen this thread on GitHub" : "Resolve this thread on GitHub")
    }
}

/// An author in the comment filters: on shows their threads, off hides them.
struct AuthorChip: View, Zoomed {
    @Environment(\.zoom) var zoom
    let login: String
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: z(5)) {
                Avatar(login: login, size: 14).opacity(on ? 1 : 0.4)
                Text(login).font(ui(11.5))
                Text(verbatim: "\(count)").font(mono(10)).foregroundStyle(T.text3)
            }
            .foregroundStyle(on ? T.text : T.text3)
        }
        .buttonStyle(HoverButtonStyle(padH: z(6), padV: z(2.5), rest: on ? 0.1 : 0.03, hover: on ? 0.12 : 0.06, press: 0.14)).pointerOnly()
        .help((on ? "Hide " : "Show ") + login + ". ⌥-click shows only " + login + ".")
    }
}

/// The end of the diff hunk a thread is on, with the commented lines marked.
struct HunkView: View, Zoomed {
    @Environment(\.zoom) var zoom
    let lines: [String]
    let highlighted: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                let hit = i >= lines.count - highlighted
                let mark = line.first.map(String.init) ?? " "
                HStack(alignment: .top, spacing: z(6)) {
                    Text(mark == " " ? " " : mark)
                        .foregroundStyle(mark == "+" ? T.green : mark == "-" ? T.red : T.text3)
                        .frame(width: z(7), alignment: .leading)
                    Text(line.isEmpty ? " " : String(line.dropFirst())).foregroundStyle(hit ? T.text : T.text2)
                }
                .font(mono(10.5))
                .lineSpacing(z(1.5))
                .padding(.horizontal, z(8)).padding(.vertical, z(1.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hit ? T.blue.opacity(0.13) : mark == "+" ? T.green.opacity(0.05) : mark == "-" ? T.red.opacity(0.05) : .clear)
                .overlay(alignment: .leading) { if hit { Rectangle().fill(T.blue.opacity(0.8)).frame(width: 2) } }
            }
        }
        .padding(.vertical, z(4))
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: z(6), style: .continuous))
        .textSelection(.enabled)
    }
}

/// Prose with inline markdown and links; fenced code in a box, suggestions labeled.
struct CommentBody: View, Zoomed {
    @Environment(\.zoom) var zoom
    let text: String
    var dim = false
    /// Shows only the opening prose, cut at whole lines.
    var preview = false

    var body: some View {
        let blocks = commentBlocks(text)
        let shown = preview ? Array(blocks.filter { !$0.code }.prefix(1)) : blocks
        VStack(alignment: .leading, spacing: z(6)) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                if block.code {
                    VStack(alignment: .leading, spacing: z(3)) {
                        if block.lang == "suggestion" {
                            Text("Suggested change").font(ui(10.5, .medium)).foregroundStyle(T.green.opacity(0.85))
                        }
                        Text(block.text).font(mono(10.5)).foregroundStyle(T.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(z(8))
                            .background(Color.black.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: z(6), style: .continuous))
                    }
                } else {
                    Text(inlineMarkdown(block.text)).font(ui(13)).foregroundStyle(dim ? T.text2 : T.text)
                        .lineSpacing(z(2.5))
                        .tint(T.blue)
                        .lineLimit(preview ? 3 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}
