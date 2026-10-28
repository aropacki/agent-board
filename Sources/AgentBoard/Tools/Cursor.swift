import AppKit
import ApplicationServices

/// Puts a prompt into a specific Cursor chat and submits it. Every step re-checks that the
/// chat's prompt field holds focus, so a focus change aborts instead of typing elsewhere.
enum Typist {
    static let cursorID = "com.todesktop.230313mzl4w4u92"
    static let promptLabel = "Prompt"

    static func isCursorFront() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cursorID
    }

    static func waitFor(_ seconds: Double, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if check() { return true }
            usleep(120_000)
        } while Date() < deadline
        return check()
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap { element($0) }
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func isPrompt(_ el: AXUIElement) -> Bool {
        string(el, kAXDescriptionAttribute) == promptLabel || string(el, kAXTitleAttribute) == promptLabel
    }

    static let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXMenuItem", "AXCheckBox"]

    static func search(_ app: AXUIElement, _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard let window = element(attr(app, kAXFocusedWindowAttribute)) ?? element(attr(app, kAXMainWindowAttribute)) else { return [] }
        var queue = [window], index = 0, matches: [AXUIElement] = []
        while index < queue.count && index < 25_000 {
            let el = queue[index]
            index += 1
            if match(el) {
                matches.append(el)
                continue
            }
            if let role = string(el, kAXRoleAttribute), leafRoles.contains(role) { continue }
            queue.append(contentsOf: children(el))
        }
        return matches
    }

    /// The bottom-most visible element labeled "Prompt" in Cursor's focused window.
    static func findPrompt(_ app: AXUIElement) -> AXUIElement? {
        if let focused = element(attr(app, kAXFocusedUIElementAttribute)), isPrompt(focused) { return focused }
        let prompts = search(app) { isPrompt($0) && (frame($0)?.width ?? 0) > 60 }
        return prompts.max { (frame($0)?.maxY ?? 0) < (frame($1)?.maxY ?? 0) }
    }

    static func findButton(_ app: AXUIElement, _ label: String) -> AXUIElement? {
        search(app) { el in
            guard string(el, kAXRoleAttribute) == "AXButton" else { return false }
            if string(el, kAXTitleAttribute) == label || string(el, kAXDescriptionAttribute) == label { return true }
            return children(el).contains { string($0, kAXValueAttribute) == label }
        }.first
    }

    /// Creates a new chat through Cursor's prompt deeplink, which always opens a fresh chat
    /// prefilled with the text, so the prompt cannot land in an existing chat.
    static func startNew(text: String) -> String? {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        runTool("/usr/bin/open", ["-b", cursorID])
        runTool("/usr/bin/open", ["cursor://anysphere.cursor-deeplink/prompt?text=" + encoded])
        guard waitFor(3, isCursorFront) else { return "Cursor didn't come to the front. Nothing was sent." }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cursorID).first else {
            return "Cursor isn't running."
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var found: AXUIElement?
        _ = waitFor(4) { found = findButton(appEl, "Create Chat"); return found != nil }
        guard let button = found, isCursorFront() else { return "Cursor's Create Chat dialog didn't appear. Nothing was sent." }
        AXUIElementPerformAction(button, kAXPressAction as CFString)

        let prefix = String(text.prefix(24))
        var input: AXUIElement?
        _ = waitFor(4) {
            input = search(appEl) { isPrompt($0) && (string($0, kAXValueAttribute) ?? "").contains(prefix) }.first
            return input != nil
        }
        guard let input else { return "The new chat opened, but I couldn't find its prompt. It is waiting there unsent." }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(200_000)
        guard isCursorFront(), isFocused(appEl, input) else {
            return "Focus moved before Enter. The new chat has the prompt but it isn't sent."
        }
        press(36)
        return nil
    }

    static func isFocused(_ app: AXUIElement, _ input: AXUIElement) -> Bool {
        guard let focused = element(attr(app, kAXFocusedUIElementAttribute)) else { return false }
        return CFEqual(focused, input)
    }

    /// Opens a blank agent with the Agents window's File › New Agent, which works without keyboard focus.
    static func newAgent() -> String? {
        runTool("/usr/bin/open", ["cursor://anysphere.cursor-deeplink/glass"])
        guard waitFor(3, isCursorFront) else { return "Cursor didn't come to the front." }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cursorID).first else { return "Cursor isn't running." }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var item: AXUIElement?
        _ = waitFor(3) { item = menuItem(appEl, menu: "File", title: "New Agent"); return item != nil }
        guard let item else { return "Cursor's File menu has no New Agent item." }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return nil
    }

    static func menuItem(_ app: AXUIElement, menu: String, title: String) -> AXUIElement? {
        guard let bar = element(attr(app, kAXMenuBarAttribute)) else { return nil }
        for top in children(bar) where string(top, kAXTitleAttribute) == menu {
            for list in children(top) {
                if let item = children(list).first(where: { string($0, kAXTitleAttribute) == title }) { return item }
            }
        }
        return nil
    }

    static func press(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        usleep(20_000)
    }

    static func click(_ point: CGPoint) {
        let original = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        if let original { CGWarpMouseCursorPosition(original) }
    }

    static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !saved.isEmpty else { return }
        pb.writeObjects(saved.map { dict in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        })
    }

    /// Returns nil on success, otherwise a reason to show the user.
    static func send(chatID: String, text: String) -> String? {
        guard chatID.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil else {
            return "That chat id isn't valid. Nothing was typed."
        }
        runTool("/usr/bin/open", ["-b", cursorID])
        runTool("/usr/bin/open", ["cursor://anysphere.cursor-deeplink/agent?id=\(chatID)"])
        guard waitFor(3, isCursorFront) else { return "Cursor didn't come to the front. Nothing was typed." }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cursorID).first else {
            return "Cursor isn't running."
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(700_000)

        var found: AXUIElement?
        _ = waitFor(3) { found = findPrompt(appEl); return found != nil }
        guard let input = found else { return "Couldn't find the chat's prompt field. Nothing was typed." }

        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(200_000)
        if !isFocused(appEl, input), isCursorFront(), let f = frame(input) {
            click(CGPoint(x: f.midX, y: f.midY))
            usleep(250_000)
        }
        guard isCursorFront(), isFocused(appEl, input) else { return "Couldn't focus the chat's prompt field. Nothing was typed." }

        let placeholder = string(input, kAXPlaceholderValueAttribute) ?? ""
        let existing = (string(input, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.isEmpty || existing == placeholder else {
            return "That chat already has unsent text in its prompt, so I left it alone."
        }

        let saved = DispatchQueue.main.sync { () -> [[NSPasteboard.PasteboardType: Data]] in
            let s = savePasteboard()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return s
        }
        press(9, .maskCommand)
        usleep(450_000)
        DispatchQueue.main.sync { restorePasteboard(saved) }

        if let value = string(input, kAXValueAttribute), !value.contains(String(text.prefix(24))) {
            return "The paste didn't land in the prompt field. Nothing was sent."
        }
        guard isCursorFront(), isFocused(appEl, input) else {
            return "Focus moved before Enter. The prompt is in the field but not sent."
        }
        press(36)
        return nil
    }
}

struct CursorTool: AgentTool {
    let id = "cursor"
    let name = "Cursor"
    let needsAccessibility = true

    func libraryDirs(home: String) -> [LibraryDir] {
        var dirs = [
            LibraryDir(path: home + "/.cursor/rules", depth: 3, kind: .rule, source: "Your rules"),
            LibraryDir(path: home + "/.cursor/skills", depth: 3, kind: .skill, source: "Your skills"),
            LibraryDir(path: home + "/.cursor/commands", depth: 1, kind: .command, source: "Your commands"),
            LibraryDir(path: home + "/.cursor/skills-cursor", depth: 3, kind: .skill, source: "Cursor"),
        ]
        let stores = home + "/Library/Application Support/Cursor/AgentStores/cursor_agent_stores"
        for store in ((try? FileManager.default.contentsOfDirectory(atPath: stores)) ?? []).filter({ $0.hasPrefix("t") }) {
            dirs.append(LibraryDir(path: "\(stores)/\(store)/files/skills", depth: 3, kind: .skill, source: "Personal store"))
        }
        return dirs
    }

    func pluginCache(home: String) -> PluginCache? {
        PluginCache(path: home + "/.cursor/plugins/cache", manifest: ".cursor-plugin/plugin.json")
    }

    func open(_ chat: ChatRef, done: @escaping (String?) -> Void) {
        guard let encoded = chat.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) else {
            done("Couldn't open the chat")
            return
        }
        openURL("cursor://anysphere.cursor-deeplink/agent?id=\(encoded)", activating: Typist.cursorID) { ok in
            done(ok ? nil : "Couldn't open the chat")
        }
    }

    func send(_ text: String, to chat: ChatRef) -> Delivery {
        Typist.send(chatID: chat.id, text: text).map(Delivery.failed) ?? .sent
    }

    func start(_ text: String) -> Delivery { Typist.startNew(text: text).map(Delivery.failed) ?? .sent }

    func newChat() -> String? { Typist.newAgent() }

    func openFile(_ path: String) {
        openURL("cursor://file" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path), activating: Typist.cursorID)
    }
}
