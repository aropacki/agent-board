import AppKit

enum Prompts {
    /// `{{name}}` inserts a value. `{{#name}}…{{/name}}` keeps its text only when the value is set,
    /// `{{^name}}…{{/name}}` only when it is not. A tag alone on a line takes its line break with it.
    static func render(_ template: String, _ vars: [String: String]) -> String {
        var text = template.replacingOccurrences(of: #"(?m)^[ \t]*(\{\{[#^/][A-Za-z_]+\}\})[ \t]*\n"#, with: "$1", options: .regularExpression)
        let section = try! NSRegularExpression(pattern: #"\{\{([#^])([A-Za-z_]+)\}\}(.*?)\{\{/\2\}\}"#, options: [.dotMatchesLineSeparators])
        while let m = section.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString
            let set = !(vars[ns.substring(with: m.range(at: 2))] ?? "").isEmpty
            let keep = (ns.substring(with: m.range(at: 1)) == "#") == set
            text = ns.replacingCharacters(in: m.range, with: keep ? ns.substring(with: m.range(at: 3)) : "")
        }
        for (name, value) in vars { text = text.replacingOccurrences(of: "{{\(name)}}", with: value) }
        text = text.replacingOccurrences(of: #"\{\{[A-Za-z_]+\}\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func names(_ template: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\{\{[#^/]?([A-Za-z_]+)\}\}"#) else { return [] }
        let ns = template as NSString
        return re.matches(in: template, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

func isOneStack(_ prs: [PR]) -> Bool {
    prs.count > 1 && prs.allSatisfy { $0.stackId != nil } && Set(prs.compactMap(\.stackId)).count == 1
}

/// The collector's CI rule applied to loaded checks: the required checks decide once they have all
/// posted, and a cancelled one fails; otherwise any failure fails, then anything running. Skipped
/// and cancelled checks outside the required set do not count.
func ciVerdict(_ checks: [CICheck], required: [String]) -> String {
    let byName = Dictionary(checks.map { ($0.name, $0) }, uniquingKeysWith: { a, b in (a.started ?? .distantPast) >= (b.started ?? .distantPast) ? a : b })
    let decided = required.compactMap { byName[$0]?.bucket }
    if !required.isEmpty && decided.count == required.count {
        if decided.contains("fail") || decided.contains("cancel") { return "failing" }
        if decided.contains("pending") { return "running" }
        return decided.allSatisfy { $0 == "pass" } ? "passing" : "none"
    }
    let buckets = Set(checks.map(\.bucket))
    if buckets.contains("fail") { return "failing" }
    if buckets.contains("pending") { return "running" }
    return buckets.contains("pass") ? "passing" : "none"
}

/// Review order: stack position within a stack, then PR number.
func reviewOrder(_ prs: [PR]) -> [PR] {
    prs.sorted { ($0.stackId ?? $0.key, $0.stackPos ?? 0, $0.number) < ($1.stackId ?? $1.key, $1.stackPos ?? 0, $1.number) }
}

func prLinkLines(_ prs: [PR]) -> String {
    prs.map { "\($0.url) \($0.plainTitle)" }.joined(separator: "\n")
}
