import AppKit

/// The quick actions, in menu and button order, saved to ~/.agent-board/actions.json.
enum ActionStore {
    static let url = boardDir.appendingPathComponent("actions.json")
    struct File: Codable { var actions: [QuickAction] }

    static func load() -> [QuickAction] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return QuickAction.defaults }
        return merged(file.actions)
    }

    /// A built-in the file lacks joins at its default spot, so new built-ins reach a saved list.
    static func merged(_ saved: [QuickAction]) -> [QuickAction] {
        var out = saved
        for (i, d) in QuickAction.defaults.enumerated() where !out.contains(where: { $0.id == d.id }) {
            out.insert(d, at: min(i, out.count))
        }
        return out
    }

    static func save(_ actions: [QuickAction]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: boardDir, withIntermediateDirectories: true)
        try encoder.encode(File(actions: actions)).write(to: url, options: .atomic)
    }
}
