import AppKit

/// The first line of a failed tool's output, short enough for a toast. Nil when it printed nothing useful.
func failureReason(_ output: String) -> String? {
    guard let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
          !line.hasPrefix("{") else { return nil }
    return String(line.prefix(140))
}

func withReason(_ message: String, _ output: String) -> String {
    failureReason(output).map { "\(message) (\($0))" } ?? message
}

let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", NSHomeDirectory() + "/homebrew/bin/gh"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/gh"

/// Set once before anything runs. `make perf` plays fake PRs, so no command may reach GitHub or an agent.
nonisolated(unsafe) var toolsDisabled = false
/// Commands refused while `toolsDisabled` is set; a scenario that triggers one is measuring a fetch it should not.
nonisolated(unsafe) var blockedTools: [String] = []

@discardableResult
func runTool(_ launchPath: String, _ args: [String], qos: QualityOfService = .userInitiated) -> (Int32, String) {
    guard !toolsDisabled else {
        let command = ([URL(fileURLWithPath: launchPath).lastPathComponent] + args.prefix(4).map { String($0.prefix(40)) }).joined(separator: " ")
        DispatchQueue.main.async { blockedTools.append(command) }
        return (1, "tools are disabled in the perf bench")
    }
    let p = Process()
    p.qualityOfService = qos
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
