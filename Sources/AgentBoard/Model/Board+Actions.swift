import AppKit
import SwiftUI

extension Board {
    func context(pr: PR) -> ActionContext { ActionContext(surface: .pr, key: pr.key, prs: [pr]) }

    func context(stack prs: [PR]) -> ActionContext {
        ActionContext(surface: .stack, key: "stack-\(prs.first?.stackId ?? prs.first?.key ?? "")", prs: prs)
    }

    func context(card: Card) -> ActionContext { ActionContext(surface: .agent, key: card.id, prs: card.prs, card: card) }

    func context(slot: Slot) -> ActionContext { ActionContext(surface: .worktree, key: slot.path, slot: slot) }

    var selectionContext: ActionContext { ActionContext(surface: .selection, key: "selected", prs: selectedPRs) }

    func context(_ pr: PR, thread: ReviewThread) -> ActionContext {
        ActionContext(surface: .thread, key: thread.id, prs: [pr], thread: thread)
    }

    func context(_ pr: PR, comment: ThreadComment) -> ActionContext {
        ActionContext(surface: .comment, key: comment.id, prs: [pr], comment: comment)
    }

    func context(_ pr: PR, check: CICheck) -> ActionContext {
        ActionContext(surface: .check, key: "\(pr.key)|\(check.id)", prs: [pr], check: check)
    }

    /// The actions that show on `ctx`, in the user's order. `buttons` keeps the ones that are also row buttons.
    func applicable(on ctx: ActionContext, buttons: Bool = false) -> [ActionItem] {
        quickActions.compactMap { a in
            guard a.enabled, let p = a.placement(ctx.surface), !buttons || p.button || !ctx.surface.choosesButton,
                  let targets = actionTargets(p, ctx, ci: { self.ci($0) }) else { return nil }
            return ActionItem(action: a, targets: targets)
        }
    }

    func actionKey(_ a: QuickAction, _ ctx: ActionContext) -> String { "\(a.id)-\(ctx.key)" }

    func menuItems(_ ctx: ActionContext) -> [MenuAction] {
        applicable(on: ctx).enumerated().map { i, item in
            MenuAction(title: item.action.menuTitle, icon: item.action.icon, destructive: item.action.hidesAfter, divider: i == 0) {
                self.run(item.action, ctx, targets: item.targets)
            }
        }
    }

    func run(_ action: QuickAction, _ ctx: ActionContext, targets: [PR]) {
        let chat = action.delivery == .ownChat ? ownerChat(ctx, targets: targets, cards: state?.allCards ?? []) : nil
        guard ensureTrust(for: Tools.tool(chat?.tool)) else { return }
        let pending = PendingAction(action: action, context: ctx, targets: targets, chat: chat,
                                    text: renderAction(action, ctx, targets: targets, checks: checks))
        if action.confirm { withAnimation(.snappy(duration: 0.15)) { pendingAction = pending } } else { send(pending) }
    }

    func cancelAction() { withAnimation(.snappy(duration: 0.15)) { pendingAction = nil } }

    func confirmAction() {
        guard let pending = pendingAction else { return }
        send(pending)
    }

    func send(_ p: PendingAction) {
        let tool = Tools.tool(p.chat?.tool)
        guard ensureTrust(for: tool) else { return }
        let key = actionKey(p.action, p.context)
        guard !busy.contains(key) else { return }
        if let chat = p.chat { markSeen(chat.id) }
        setBusy(key, true)
        let text = p.text
        // Typing moves focus to the tool's window, which would otherwise close the popup mid-send.
        let holds = tool.needsAccessibility
        if holds { holdPopup?(true) }
        typist.async {
            let delivery = p.chat.map { tool.send(text, to: $0.chat) } ?? tool.start(text)
            DispatchQueue.main.async {
                if holds { self.holdPopup?(false) }
                self.setBusy(key, false)
                if case .failed(let failure) = delivery { self.show(.error, failure); return }
                self.flagSuccess(key)
                if self.pendingAction?.id == p.id { self.cancelAction() }
                if p.action.hidesAfter {
                    self.hide(p.targets)
                    if p.context.surface == .agent, let card = p.context.card { self.hide(card, quiet: true) }
                }
                if p.context.surface == .selection { self.clearSelection() }
                if case .copied(let hint) = delivery {
                    self.show(.ok, "Copied “\(p.action.title)”. \(hint)")
                } else {
                    self.show(.ok, p.chat.map { "Sent “\(p.action.title)” to “\($0.title)”" } ?? "Started an agent: \(p.action.title)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.collect() }
            }
        }
    }

    /// Batches the writes: the editor changes the list on every keystroke.
    func editActions(_ change: (inout [QuickAction]) -> Void) {
        change(&quickActions)
        guard !isBench else { return }
        actionsSave?.cancel()
        let snapshot = quickActions
        let work = DispatchWorkItem { [weak self] in
            do { try ActionStore.save(snapshot) } catch { self?.show(.error, "Couldn't save the quick actions: \(error.localizedDescription)") }
        }
        actionsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func loadLibrary(force: Bool = false) {
        guard !libraryScanning, force || library == nil else { return }
        libraryScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Library.scan()
            DispatchQueue.main.async {
                self.libraryScanning = false
                self.library = items
            }
        }
    }
}
