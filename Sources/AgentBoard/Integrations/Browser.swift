import AppKit

/// Opens through LaunchServices without waiting, so a click returns immediately.
/// In the background, the browser gets the tab but stays where it is.
func openURL(_ string: String, activating bundleID: String? = nil, background: Bool = false, done: ((Bool) -> Void)? = nil) {
    guard let url = URL(string: string) else { done?(false); return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = !background
    let openTarget = {
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            DispatchQueue.main.async { done?(error == nil) }
        }
    }
    guard let bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        openTarget()
        return
    }
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
        if error != nil { DispatchQueue.main.async { done?(false) } } else { openTarget() }
    }
}

let chromeID = "com.google.Chrome"

/// Adds a tab to Chrome's front window. Unless `focus`, Chrome stays behind and keeps its current tab.
func chromeTabScript(_ url: String, focus: Bool = false) -> String {
    let quoted = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return """
    with timeout of 5 seconds
        tell application id "\(chromeID)"
            if (count of windows) is 0 then error "no window" number 1
            set w to window 1
            set keep to active tab index of w
            make new tab at end of tabs of w with properties {URL:"\(quoted)"}
            \(focus ? "activate" : "set active tab index of w to keep")
        end tell
    end timeout
    """
}

/// Returns to a tab already on the page instead of opening a copy, checking exact matches
/// before subpages. A link with a fragment matches its page and moves that tab to the fragment.
/// Prints `found` or `new`.
func chromeOpenScript(_ url: String, focus: Bool) -> String {
    func quoted(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let base = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
    let reveal = focus ? """
                                set active tab index of w to i
                                set index of w to 1
                                activate
        """ : ""
    return """
    with timeout of 5 seconds
        tell application id "\(chromeID)"
            set target to "\(quoted(url))"
            set base to "\(quoted(base))"
            repeat with pass from 1 to 2
                repeat with wi from 1 to (count of windows)
                    set w to window wi
                    set us to URL of tabs of w
                    repeat with i from 1 to (count of us)
                        set u to item i of us
                        if (pass is 1 and (u is base or u starts with (base & "#") or u starts with (base & "?"))) ¬
                            or (pass is 2 and u starts with (base & "/")) then
                            if target is not base then set URL of tab i of w to target
    \(reveal)
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
            if (count of windows) is 0 then error "no window" number 1
            set w to window 1
            set keep to active tab index of w
            make new tab at end of tabs of w with properties {URL:target}
            \(focus ? "activate" : "set active tab index of w to keep")
            return "new"
        end tell
    end timeout
    """
}

private let browserQueue = DispatchQueue(label: "agentboard.browser")

let chromeAccessMessage = "Allow Agent Board to control Google Chrome in System Settings → Privacy & Security → Automation, then try again."

func chromeHandles(_ url: URL) -> Bool {
    NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier } == chromeID
        && !NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).isEmpty
}

/// Runs off the main thread; calls back on main with nil, or with why it failed.
func runChromeScript(_ script: String, done: @escaping (_ ok: Bool, _ needsAccess: Bool, _ output: String) -> Void) {
    browserQueue.async {
        let (status, output) = runTool("/usr/bin/osascript", ["-e", script])
        DispatchQueue.main.async { done(status == 0, output.contains("-1743"), output) }
    }
}

/// Chrome links go by script, so a tab already on the page is reused and a background open
/// keeps Chrome behind. Calls back whether a tab was reused, and with a message when the user
/// must grant access.
func openInChrome(_ string: String, background: Bool, done: @escaping (_ reused: Bool, _ message: String?) -> Void) {
    guard let url = URL(string: string) else { return }
    guard chromeHandles(url) else { openURL(string, background: background); done(false, nil); return }
    runChromeScript(chromeOpenScript(string, focus: !background)) { ok, needsAccess, output in
        if ok { done(output.contains("found"), nil); return }
        openURL(string)
        done(false, needsAccess ? chromeAccessMessage : nil)
    }
}

/// The unpacked extension in ~/.agent-board/chrome-extension; its manifest key pins this id.
let tabGroupExtensionID = "dddjmamkljokfgecodpfealjfkneedeb"

let tabGroupExtensionDir = boardDir.appendingPathComponent("chrome-extension")

func tabGroupExtensionInstalled() -> Bool {
    let chrome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    let needle = Data(tabGroupExtensionID.utf8)
    let profiles = (try? FileManager.default.contentsOfDirectory(at: chrome, includingPropertiesForKeys: nil)) ?? []
    return profiles.contains { dir in
        ["Secure Preferences", "Preferences"].contains { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name)))?.range(of: needle) != nil
        }
    }
}

func tabGroupPageURL(title: String, urls: [String], focus: Bool) -> String {
    let body: [String: Any] = ["title": title, "urls": urls, "focus": focus]
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self)
    return "chrome-extension://\(tabGroupExtensionID)/open.html#" + (json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
}

func tabGroupTitle(_ text: String) -> String { text.count > 28 ? String(text.prefix(27)) + "…" : text }
