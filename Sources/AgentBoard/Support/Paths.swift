import AppKit

/// `AGENT_BOARD_HOME` moves the data directory; the launch agent sets it for a non-default install.
let boardDir = ProcessInfo.processInfo.environment["AGENT_BOARD_HOME"].map { URL(fileURLWithPath: expandTilde($0)) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-board")

let stateURL = boardDir.appendingPathComponent("state.json")

let seenURL = boardDir.appendingPathComponent("seen.json")

let dismissedURL = boardDir.appendingPathComponent("dismissed.json")

let actScript = boardDir.appendingPathComponent("bin/act.sh").path

/// The bench reads the live state but must not start collectors that outlive it.
let isBench = CommandLine.arguments.contains("--bench")

let collectScript = boardDir.appendingPathComponent("bin/collect.py").path

let hiddenChatsURL = boardDir.appendingPathComponent("hidden-chats.json")

let activityURL = boardDir.appendingPathComponent("activity.json")

let fetchCacheStore = FetchCacheStore(dir: boardDir.appendingPathComponent("cache/fetched"))

let reviewsDir = boardDir.appendingPathComponent("reviews")

let hiddenPRsURL = URL(fileURLWithPath: Config.shared.hiddenPRsFile)
