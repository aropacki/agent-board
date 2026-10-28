import AppKit

/// An action that applies somewhere, with the PRs it covers there.
struct ActionItem: Identifiable {
    let action: QuickAction
    let targets: [PR]
    var id: String { action.id }
}

/// A quick action ready to send, held while the board asks first.
struct PendingAction: Identifiable {
    let id = UUID()
    let action: QuickAction
    let context: ActionContext
    let targets: [PR]
    let chat: Card?
    let text: String

    var question: String {
        chat.map { "Send “\(action.title)” to “\($0.title)”?" } ?? "Start an agent for “\(action.title)”?"
    }

    var hiddenNote: String? {
        guard action.hidesAfter else { return nil }
        let chat = context.surface == .agent && context.card != nil
        if targets.isEmpty { return chat ? "Then moves the chat to Hidden." : nil }
        let prs = targets.count == 1 ? "#\(targets[0].number)" : "these \(targets.count) PRs"
        return "Then moves \(prs)\(chat ? " and the chat" : "") to Hidden."
    }

    var preview: String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(4).joined(separator: "\n")
    }
}

/// The chat an own-chat action goes to: the card it ran on, else the chat holding the worktree, else the one
/// chat that holds every PR it covers. Nil means a new chat.
func ownerChat(_ ctx: ActionContext, targets: [PR], cards: [Card]) -> Card? {
    if let card = ctx.card { return card }
    if let slot = ctx.slot { return cards.first { $0.slot?.path == slot.path } }
    let keys = Set((targets.isEmpty ? ctx.prs : targets).map(\.key))
    guard !keys.isEmpty else { return nil }
    return cards.first { card in keys.allSatisfy { key in card.prs.contains { $0.key == key } } }
}

struct MenuAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var destructive = false
    var divider = false
    var shortcut: String? = nil
    let run: () -> Void
}

struct ChecksPeek: Equatable {
    let key: String
    let surface: String
    /// The CI fact's frame, in the board's coordinates.
    let anchor: CGRect
}

struct RowMenu: Identifiable {
    let id = UUID()
    let owner: String
    var surface = "panel"
    /// In the board's coordinates. Zero size means a right-click point.
    let anchor: CGRect
    let actions: [MenuAction]
}
