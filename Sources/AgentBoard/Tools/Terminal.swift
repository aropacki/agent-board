import AppKit

/// Runs a command in a new terminal window. A `.command` file opens in the terminal app without an Automation grant.
/// It runs through the user's interactive login shell, so their aliases and wrapper functions apply.
enum Terminal {
    static func run(_ command: String, in cwd: String?) -> String? {
        let dir = boardDir.appendingPathComponent("run")
        let file = dir.appendingPathComponent(UUID().uuidString + ".command")
        let folder = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? Config.shared.newChatFolder
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script(command, in: folder).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return "Couldn't write the launch script: \(error.localizedDescription)"
        }
        let app = Config.shared.terminalApp
        let (code, out) = runTool("/usr/bin/open", ["-a", app, file.path])
        guard code == 0 else {
            try? FileManager.default.removeItem(at: file)
            return out.isEmpty ? "Couldn't open \(app)" : out
        }
        return nil
    }

    /// Deletes itself first, so a window that fails to start leaves nothing behind.
    static func script(_ command: String, in folder: String) -> String {
        """
        #!/bin/sh
        rm -f "$0"
        cd \(shellQuote(folder)) || exit 1
        exec "${SHELL:-/bin/zsh}" -ilc \(shellQuote(command))

        """
    }

    /// The shell word for a prompt. The text goes through a file, so no quoting or expansion can change it.
    static func prompt(_ text: String) -> String? {
        let file = boardDir.appendingPathComponent("run").appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch { return nil }
        let q = shellQuote(file.path)
        return "\"$(cat \(q); rm -f \(q))\""
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// A tool whose chats run in a terminal and resume by session id.
protocol TerminalTool: AgentTool {
    /// The executable, looked up in the user's shell.
    var command: String { get }
    func resume(_ id: String) -> String
}

extension TerminalTool {
    var needsAccessibility: Bool { false }

    func open(_ chat: ChatRef, done: @escaping (String?) -> Void) {
        done(Terminal.run(resume(chat.id), in: chat.cwd))
    }

    /// A running session owns its terminal, and a second one would write the same history. The prompt waits on the
    /// clipboard for that terminal instead.
    func send(_ text: String, to chat: ChatRef) -> Delivery {
        if chat.running {
            copyToClipboard(text)
            return .copied(hint: "Paste it into the running \(name) session.")
        }
        guard let prompt = Terminal.prompt(text) else { return .failed("Couldn't stage the prompt") }
        return Terminal.run(resume(chat.id) + " " + prompt, in: chat.cwd).map(Delivery.failed) ?? .sent
    }

    func start(_ text: String) -> Delivery {
        guard let prompt = Terminal.prompt(text) else { return .failed("Couldn't stage the prompt") }
        return Terminal.run(command + " " + prompt, in: nil).map(Delivery.failed) ?? .sent
    }

    func newChat() -> String? { Terminal.run(command, in: nil) }

    func openFile(_ path: String) { openInEditor(path) }
}

struct ClaudeCodeTool: TerminalTool {
    let id = "claude-code"
    let name = "Claude Code"
    let command = "claude"

    func resume(_ id: String) -> String { "\(command) --resume \(shellQuote(id))" }

    func libraryDirs(home: String) -> [LibraryDir] {
        [LibraryDir(path: home + "/.claude/skills", depth: 3, kind: .skill, source: "Your skills"),
         LibraryDir(path: home + "/.claude/commands", depth: 1, kind: .command, source: "Your commands")]
    }

    func pluginCache(home: String) -> PluginCache? {
        PluginCache(path: home + "/.claude/plugins/cache", manifest: ".claude-plugin/plugin.json")
    }
}

struct CodexTool: TerminalTool {
    let id = "codex"
    let name = "Codex"
    let command = "codex"

    func resume(_ id: String) -> String { "\(command) resume \(shellQuote(id))" }

    func libraryDirs(home: String) -> [LibraryDir] {
        [LibraryDir(path: home + "/.codex/skills", depth: 3, kind: .skill, source: "Your skills"),
         LibraryDir(path: home + "/.codex/prompts", depth: 1, kind: .command, source: "Your commands")]
    }
}
