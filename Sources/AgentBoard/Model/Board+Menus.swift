import AppKit
import SwiftUI

extension Board {
    /// Opens the PRs as one named Chrome tab group; ⌘ held keeps Chrome behind.
    func openTabGroup(_ prs: [PR], title: String) {
        let urls = prs.map(\.url)
        guard let first = urls.first.flatMap(URL.init(string:)) else { return }
        let background = NSEvent.modifierFlags.contains(.command)
        let openEach = { for url in urls { openInChrome(url, background: background) { _, _ in } } }
        guard chromeHandles(first) else { openEach(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = tabGroupExtensionInstalled()
            DispatchQueue.main.async {
                guard installed else {
                    self.copy(tabGroupExtensionDir.path)
                    self.show(.error, "Tab groups need the Agent Board extension. In chrome://extensions turn on Developer mode, then Load unpacked and pick the folder (path copied).")
                    return
                }
                runChromeScript(chromeTabScript(tabGroupPageURL(title: tabGroupTitle(title), urls: urls, focus: !background), focus: !background)) { ok, needsAccess, _ in
                    if ok { self.show(.ok, "Opened \(urls.count) PRs as a tab group") } else {
                        openEach()
                        if let message = chromeFailureMessage(needsAccess: needsAccess) { self.show(.error, message) }
                    }
                }
            }
        }
    }

    func menuOpen(_ owner: String, _ surface: String) -> Bool { menu?.owner == owner && menu?.surface == surface }

    func toggleMenu(owner: String, anchor: CGRect, surface: String = "panel") {
        if menuOpen(owner, surface) { closeMenu() } else { showMenu(owner: owner, anchor: anchor, surface: surface) }
    }

    func showMenu(owner: String, anchor: CGRect, surface: String = "panel") {
        menuSurface = surface
        closeChecksPeek()
        let actions = actions(for: owner)
        guard !actions.isEmpty else { return }
        menuOpenedAt = Date()
        withAnimation(.easeOut(duration: 0.1)) { menu = RowMenu(owner: owner, surface: surface, anchor: anchor, actions: actions) }
    }

    func closeMenu(surface: String? = nil) {
        guard let menu, surface == nil || menu.surface == surface else { return }
        withAnimation(.easeOut(duration: 0.08)) { self.menu = nil }
    }

    /// The innermost row under a point that has a menu, so a PR inside a card gets the PR's menu
    /// and a row with nothing to offer passes the click to the row around it.
    func menuOwner(at point: CGPoint, surface: String = "panel") -> String? {
        let covers = menuViewports.filter { $0.value.surface == surface && $0.key.contains("|cover") && $0.value.frame.contains(point) }.keys
        let cover = covers.first { $0.hasSuffix("|cover-diff") } ?? covers.first
        return menuTargets.values
            .filter { $0.surface == surface && $0.frame.contains(point) && menuViewports[$0.viewport]?.frame.contains(point) == true }
            .filter { cover == nil || $0.viewport == cover }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            .first { !actions(for: $0.owner).isEmpty }?.owner
    }

    /// Every open member of a PR's stack, base first, across sections.
    func stackMembers(of pr: PR) -> [PR] {
        guard let sid = pr.stackId else { return [pr] }
        var seen = Set<String>()
        return reviewOrder(allPRs.filter { $0.stackId == sid && $0.hidden != true && seen.insert($0.key).inserted })
    }

    func actions(for owner: String) -> [MenuAction] {
        let parts = owner.split(separator: ":", maxSplits: 1).map(String.init)
        let ref = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "activity":
            guard let event = activity.first(where: { $0.id.uuidString == ref }) else { return [] }
            var a: [MenuAction] = []
            let surface = menuSurface
            if event.target != nil { a.append(MenuAction(title: "Open", icon: "arrow.up.forward") { self.openActivity(event, surface: surface) }) }
            a.append(MenuAction(title: "Copy text", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.text, forType: .string)
            })
            return a
        case "header":
            var a: [MenuAction] = []
            a.append(MenuAction(title: "Open the board", icon: "macwindow", shortcut: "⌥Space") { self.openBoard() })
            a.append(MenuAction(title: "Edit quick actions", icon: "slider.horizontal.3") {
                self.openBoard()
                self.showActions = true
            })
            a.append(MenuAction(title: "Quit Agent Board", icon: "power", divider: !a.isEmpty) { NSApp.terminate(nil) })
            return a
        case "header-window":
            return [MenuAction(title: showActions ? "Back to the board" : "Edit quick actions", icon: showActions ? "rectangle.split.3x1" : "slider.horizontal.3") {
                        withAnimation(.snappy(duration: 0.2)) { self.showActions.toggle() }
                    },
                    MenuAction(title: "Quit Agent Board", icon: "power", divider: true) { NSApp.terminate(nil) }]
        case "card":
            let cards = (state?.allCards ?? []) + (state?.hiddenCards ?? [])
            if let card = cards.first(where: { $0.id == ref }) { return cardActions(card) }
            // A PR's agent can be a chat old enough to have left the board.
            guard allPRs.contains(where: { $0.agents?.contains { $0.id == ref } == true }) else { return [] }
            return [MenuAction(title: "Open chat", icon: "text.bubble") { self.open(id: ref) }]
        case "pr":
            return self.pr(key: ref).map(prActions) ?? []
        case "slot":
            let slots = (state?.looseSlots ?? []) + (state?.allCards ?? []).compactMap(\.slot)
            return slots.first { $0.path == ref }.map(slotActions) ?? []
        case "stack":
            guard let first = allPRs.first(where: { $0.stackId == ref }) else { return [] }
            return stackActions(stackMembers(of: first).isEmpty ? [first] : stackMembers(of: first))
        case "check":
            let bits = ref.split(separator: "|", maxSplits: 1).map(String.init)
            guard bits.count == 2, let pr = self.pr(key: bits[0]),
                  let check = checks[pr.key]?.first(where: { $0.id == bits[1] }) else { return [] }
            return checkActions(pr, check)
        default:
            return []
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyLinks(_ prs: [PR]) {
        copy(prLinkLines(prs))
        show(.ok, prs.count == 1 ? "Copied 1 link" : "Copied \(prs.count) links")
    }

    func slotActions(_ slot: Slot) -> [MenuAction] {
        var a = [MenuAction(title: "Copy worktree path", icon: "doc.on.doc") { self.copy(slot.path) }]
        if let branch = slot.branch { a.append(MenuAction(title: "Copy branch name", icon: "arrow.triangle.branch") { self.copy(branch) }) }
        a += menuItems(context(slot: slot))
        if slot.leased && slot.blockerText == nil {
            a.append(MenuAction(title: "Return to the pool", icon: "arrow.uturn.backward", destructive: true, divider: true) {
                self.confirmReturn = slot.path
                self.tapReturn(slot)
            })
        }
        return a
    }

    func cardActions(_ card: Card) -> [MenuAction] {
        var a = [MenuAction(title: "Open chat", icon: "text.bubble") { self.open(card) }]
        if card.prs.count > 1 {
            a.append(MenuAction(title: "Open PRs as tab group (\(card.prs.count))", icon: "rectangle.stack") {
                self.openTabGroup(card.prs, title: card.title)
            })
        }
        if let slot = card.slot { a.append(MenuAction(title: "Copy worktree path", icon: "doc.on.doc") { self.copy(slot.path) }) }
        if !card.needsYou.isEmpty && card.status != "running" && card.hidden != true {
            a.append(MenuAction(title: "Move to Recent", icon: "arrow.down.to.line") { self.moveToRecent(card) })
        }
        if card.hidden == true {
            a.append(MenuAction(title: "Unhide", icon: "eye", divider: true) { self.unhide(card) })
        } else {
            a += menuItems(context(card: card))
            a.append(MenuAction(title: "Hide", icon: "eye.slash", divider: true) { self.hide(card) })
        }
        return a
    }

    func prActions(_ pr: PR) -> [MenuAction] {
        let surface = menuSurface
        var a = [
            MenuAction(title: "Open PR", icon: "arrow.up.right.square") { self.openLink(pr.url) },
            MenuAction(title: "Show checks", icon: "checklist") { self.openChecks(pr, surface: surface) },
            MenuAction(title: "Show diff", icon: "plusminus") { self.openDiff(pr) },
        ]
        a.append(MenuAction(title: "Show comments", icon: "text.bubble") { self.openDiscussion(pr, surface: surface) })
        if pr.unresolved > 0 { a.append(MenuAction(title: "Open unresolved comment", icon: "bubble.left") { self.openLink(pr.threadURL) }) }
        if let ticket = pr.ticket, let link = Config.shared.issueTracker.link(ticket) {
            a.append(MenuAction(title: "Open \(ticket)", icon: "ticket") { self.openLink(link) })
        }
        a.append(MenuAction(title: "Copy link", icon: "link") { self.copy(pr.url) })
        a.append(MenuAction(title: "Copy link and title", icon: "doc.on.doc") { self.copyLinks([pr]) })
        a.append(MenuAction(title: isSelected(pr) ? "Deselect" : "Select", icon: "checkmark.circle", divider: true) { self.toggleSelect(pr) })
        if pr.hidden == true {
            a.append(MenuAction(title: "Unhide", icon: "eye", divider: true) { self.unhide([pr]) })
            return a
        }
        a += menuItems(context(pr: pr))
        a.append(MenuAction(title: "Hide", icon: "eye.slash", divider: true) { self.hide(pr) })
        return a
    }

    func checkActions(_ pr: PR, _ check: CICheck) -> [MenuAction] {
        var a: [MenuAction] = []
        if let link = check.link, !link.isEmpty {
            a.append(MenuAction(title: "Open on GitHub", icon: "arrow.up.right.square") { self.openLink(link) })
            a.append(MenuAction(title: "Copy link", icon: "link") { self.copy(link) })
        }
        a.append(MenuAction(title: "Copy check name", icon: "doc.on.doc") { self.copy(check.name) })
        return a + menuItems(context(pr, check: check))
    }

    func stackActions(_ prs: [PR]) -> [MenuAction] {
        let allPicked = prs.allSatisfy { isSelected($0) }
        var a = [MenuAction(title: allPicked ? "Deselect stack" : "Select stack", icon: "checkmark.circle") {
            for pr in prs where self.isSelected(pr) == allPicked { self.toggleSelect(pr) }
        }]
        a.append(MenuAction(title: "Open stack as tab group", icon: "rectangle.stack") {
            self.openTabGroup(prs, title: "Stack #\(prs[0].number)")
        })
        a.append(MenuAction(title: "Copy stack links (\(prs.count))", icon: "doc.on.doc") { self.copyLinks(prs) })
        a += menuItems(context(stack: prs))
        a.append(MenuAction(title: "Hide stack", icon: "eye.slash", divider: true) { self.hide(prs) })
        return a
    }
}
