import AppKit

/// A coding agent the board works with. `id` matches the collector source that reads the tool's chats and the
/// `tool` field on each card, so a card's actions go to the tool its chat lives in.
protocol AgentTool {
    var id: String { get }
    var name: String { get }
    /// Sending types into the tool's window, which needs the Accessibility grant.
    var needsAccessibility: Bool { get }
    /// Folders of rules, skills, and commands this tool reads, for the prompt library.
    func libraryDirs(home: String) -> [LibraryDir]
    /// Where installed plugins live, laid out as `<marketplace>/<plugin>/<version>/{skills,rules}`.
    func pluginCache(home: String) -> PluginCache?
    /// Shows a chat. `done` gets nil on success or the reason it failed. Called on the main thread.
    func open(_ chat: ChatRef, done: @escaping (String?) -> Void)
    /// Puts a prompt into an existing chat. Called off the main thread.
    func send(_ text: String, to chat: ChatRef) -> Delivery
    /// Starts a chat with a prompt. Called off the main thread.
    func start(_ text: String) -> Delivery
    /// Opens an empty chat. Returns nil on success or the reason it failed. Called off the main thread.
    func newChat() -> String?
    func openFile(_ path: String)
}

/// What a tool needs to find one of its chats.
struct ChatRef {
    let id: String
    let title: String
    /// The folder the chat ran in, for tools that resume a chat from its directory.
    var cwd: String? = nil
    var running = false
}

enum Delivery: Equatable {
    case sent
    /// The prompt is on the clipboard; `hint` says where to paste it.
    case copied(hint: String)
    case failed(String)
}

struct LibraryDir {
    let path: String
    let depth: Int
    let kind: LibraryItem.Kind
    let source: String
}

struct PluginCache {
    let path: String
    /// The manifest's path inside a plugin version folder. Its `name` labels the plugin's items.
    let manifest: String
}

extension AgentTool {
    func pluginCache(home: String) -> PluginCache? { nil }
}

/// The tools named in `config.json`'s `tools` list. The first one takes new chats.
enum Tools {
    static let known: [AgentTool] = [CursorTool(), ClaudeCodeTool(), CodexTool(), ClipboardTool()]
    static let enabled: [AgentTool] = {
        let picked = Config.shared.tools.compactMap { id in known.first { $0.id == id } }
        return picked.isEmpty ? [known[0]] : picked
    }()
    static var primary: AgentTool { enabled[0] }
    static var needsAccessibility: Bool { enabled.contains { $0.needsAccessibility } }

    /// A card from a tool that is no longer enabled still opens in that tool.
    static func tool(_ id: String?) -> AgentTool {
        guard let id else { return primary }
        return known.first { $0.id == id } ?? primary
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Opens a file in the default editor for its type.
func openInEditor(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

/// Works with any tool: prompts go on the clipboard to paste wherever the agent runs.
struct ClipboardTool: AgentTool {
    let id = "clipboard"
    let name = "Clipboard"
    let needsAccessibility = false
    func libraryDirs(home: String) -> [LibraryDir] { [] }

    func open(_ chat: ChatRef, done: @escaping (String?) -> Void) { done("This tool can't open chats") }
    func send(_ text: String, to chat: ChatRef) -> Delivery {
        copyToClipboard(text)
        return .copied(hint: "Paste it into “\(chat.title)”.")
    }
    func start(_ text: String) -> Delivery {
        copyToClipboard(text)
        return .copied(hint: "Paste it into a new chat.")
    }
    func newChat() -> String? { "This tool can't start chats" }
    func openFile(_ path: String) { openInEditor(path) }
}
