import AppKit

/// One parse per text. Views redraw on every hover and scroll, and a fetch parses its text off the main thread
/// before it lands, so a draw on the main thread finds the work done.
final class Memo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]

    func value(_ key: String, _ make: (String) -> Value) -> Value {
        if let hit = lock.withLock({ values[key] }) { return hit }
        let made = make(key)
        lock.withLock {
            if values.count >= 4000 { values.removeAll(keepingCapacity: true) }
            values[key] = made
        }
        return made
    }
}

private let blockMemo = Memo<[(code: Bool, lang: String, text: String)]>()
private let documentMemo = Memo<[MarkdownBlock]>()
private let inlineMemo = Memo<AttributedString>()

/// Off the main thread: the comment bodies a discussion view draws.
func warmMarkdown(_ discussion: PRDiscussion) {
    for comment in discussion.conversation + discussion.threads.flatMap(\.comments) { warmMarkdown(comment: comment.body) }
}

func warmMarkdown(comment body: String) {
    for block in commentBlocks(body) where !block.code { _ = inlineMarkdown(block.text) }
}

func warmMarkdown(document body: String) {
    for block in markdownBlocks(body) {
        switch block {
        case .heading(_, let s), .paragraph(let s), .quote(let s): _ = inlineMarkdown(s)
        case .list(let items): items.forEach { _ = inlineMarkdown($0.text) }
        case .table(let rows): rows.joined().forEach { _ = inlineMarkdown($0) }
        case .code, .rule: break
        }
    }
}

/// A comment body as prose and fenced code, in order.
func commentBlocks(_ body: String) -> [(code: Bool, lang: String, text: String)] { blockMemo.value(body, parseCommentBlocks) }

private func parseCommentBlocks(_ body: String) -> [(code: Bool, lang: String, text: String)] {
    var out: [(code: Bool, lang: String, text: String)] = []
    var buffer: [String] = []
    var lang: String?
    func flush(_ code: Bool) {
        let text = buffer.joined(separator: "\n")
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code { out.append((code, lang ?? "", text)) }
        buffer = []
    }
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if lang == nil {
                flush(false)
                lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                flush(true)
                lang = nil
            }
        } else {
            buffer.append(line)
        }
    }
    flush(lang != nil)
    return out
}

/// Inline markdown, with headings shown as bold lines.
/// Rewrites the block syntax that inline-only parsing leaves raw: headings, quotes, alert tags, list bullets.
func flattenMarkdownBlocks(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
        var line = String(raw)
        if line.range(of: "^\\s*>\\s*\\[![A-Za-z]+\\]\\s*$", options: .regularExpression) != nil { return nil }
        line = line.replacingOccurrences(of: "^\\s*>\\s?", with: "", options: .regularExpression)
        if let r = line.range(of: "^#{1,6}\\s+", options: .regularExpression) { return "**" + line[r.upperBound...] + "**" }
        return line.replacingOccurrences(of: "^(\\s*)[-*+]\\s+", with: "$1• ", options: .regularExpression)
    }.joined(separator: "\n")
}

struct MarkdownItem: Equatable {
    let indent: Int
    /// "•" or the number with its dot; empty for a task, which shows its box instead.
    let marker: String
    let done: Bool?
    var text: String
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list([MarkdownItem])
    case quote(String)
    case code(lang: String, text: String)
    case table([[String]])
    case rule
}

/// A document's block structure, for text long enough that flattening it to one run would lose its shape.
func markdownBlocks(_ body: String) -> [MarkdownBlock] { documentMemo.value(body, parseMarkdownBlocks) }

private func parseMarkdownBlocks(_ body: String) -> [MarkdownBlock] {
    var out: [MarkdownBlock] = []
    for part in commentBlocks(body) {
        if part.code { out.append(.code(lang: part.lang, text: part.text)); continue }
        let lines = part.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var paragraph: [String] = [], quote: [String] = [], items: [MarkdownItem] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !items.isEmpty { out.append(.list(items)); items = [] }
        }
        func cells(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if trimmed.isEmpty { flush(); continue }
            if let r = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flush()
                out.append(.heading(trimmed[..<r.upperBound].filter { $0 == "#" }.count, String(trimmed[r.upperBound...])))
                continue
            }
            if trimmed.range(of: "^([-*_])(\\s*\\1){2,}$", options: .regularExpression) != nil { flush(); out.append(.rule); continue }
            if trimmed.contains("|"), i + 1 < lines.count,
               lines[i + 1].range(of: "^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$", options: .regularExpression) != nil {
                flush()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, lines[i].contains("|") { rows.append(cells(lines[i])); i += 1 }
                i -= 1
                out.append(.table(rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                let text = trimmed.replacingOccurrences(of: "^>\\s?", with: "", options: .regularExpression)
                if text.range(of: "^\\[![A-Za-z]+\\]$", options: .regularExpression) == nil { quote.append(text) }
                continue
            }
            let pattern = "^(\\s*)([-*+]|\\d+[.)])\\s+(\\[([ xX])\\]\\s+)?(.*)$"
            if let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if items.isEmpty { flush() }
                func group(_ n: Int) -> String? { Range(m.range(at: n), in: line).map { String(line[$0]) } }
                let marker = group(2) ?? "-", box = group(4)
                items.append(MarkdownItem(indent: (group(1) ?? "").count / 2, marker: box != nil ? "" : marker.first?.isNumber == true ? marker : "•",
                                          done: box.map { $0 != " " }, text: group(5) ?? ""))
                continue
            }
            if !items.isEmpty, line.first?.isWhitespace == true {
                items[items.count - 1].text += " " + trimmed
                continue
            }
            if !items.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
    }
    return out
}

func inlineMarkdown(_ text: String) -> AttributedString { inlineMemo.value(text, parseInlineMarkdown) }

private func parseInlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: flattenMarkdownBlocks(text), options: options)) ?? AttributedString(text)
}
