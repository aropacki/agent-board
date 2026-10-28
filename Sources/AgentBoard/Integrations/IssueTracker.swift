import AppKit

func ticketKeys(_ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: Config.shared.issueTracker.keyPattern) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
}

func ticketHelp(_ key: String) -> String {
    Config.shared.issueTracker.name.map { "Open \(key) in \($0)" } ?? "Open \(key)"
}
