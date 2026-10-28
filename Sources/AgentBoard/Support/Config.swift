import AppKit

/// Settings from `config.json` in the data directory. The file and each key are optional; anything missing
/// keeps the default here. The collector reads the same file.
struct Config {
    struct IssueTracker {
        /// Matches a ticket key in a PR title.
        var keyPattern = "[A-Z]{2,}-[0-9]+"
        /// Shown in link tooltips, e.g. "Linear" or "Jira".
        var name: String? = nil
        /// Ticket link with `{key}` in place of the key. With none, tickets show but do not link.
        var url: String? = nil

        func link(_ key: String) -> String? { url.map { $0.replacingOccurrences(of: "{key}", with: key) } }
    }

    var issueTracker = IssueTracker()
    /// The repo most PRs come from. Its name is left off PR rows to save space.
    var homeRepo: String? = nil
    /// A checkout whose `.cursor` and `.agents` rules and skills join the prompt library.
    var libraryRepo: String? = nil
    /// One PR URL per line. Listed PRs move to the hidden section.
    var hiddenPRsFile = boardDir.appendingPathComponent("hidden-prs").path
    /// The agent tools whose chats the board shows, by `AgentTool.id`. The first one takes new chats.
    var tools = ["cursor"]
    /// The app that runs terminal tools' chats. It must open `.command` files.
    var terminalApp = "Terminal"
    /// Where terminal tools start a new chat.
    var newChatFolder = NSHomeDirectory()

    static let shared = load(boardDir.appendingPathComponent("config.json"))

    static func load(_ url: URL) -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let t = json["issueTracker"] as? [String: Any] {
            if let p = t["keyPattern"] as? String, (try? NSRegularExpression(pattern: p)) != nil { c.issueTracker.keyPattern = p }
            c.issueTracker.name = t["name"] as? String
            c.issueTracker.url = t["url"] as? String
        }
        c.homeRepo = json["homeRepo"] as? String
        c.libraryRepo = (json["libraryRepo"] as? String).map(expandTilde)
        if let f = json["hiddenPRsFile"] as? String { c.hiddenPRsFile = expandTilde(f) }
        if let t = json["tools"] as? [String], !t.isEmpty { c.tools = t }
        if let t = json["terminalApp"] as? String { c.terminalApp = t }
        if let f = json["newChatFolder"] as? String { c.newChatFolder = expandTilde(f) }
        return c
    }
}

func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }
