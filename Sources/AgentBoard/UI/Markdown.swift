import AppKit

/// A comment body as prose and fenced code, in order.
func commentBlocks(_ body: String) -> [(code: Bool, lang: String, text: String)] {
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

func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: flattenMarkdownBlocks(text), options: options)) ?? AttributedString(text)
}
