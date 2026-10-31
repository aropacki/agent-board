import AppKit

struct Procs: Decodable, Equatable { let count: Int; let blocking: [String] }

struct Slot: Decodable, Equatable, Identifiable {
    let pool: String
    let name: String
    let path: String
    let leased: Bool
    let leaseHolder: String?
    let branch: String?
    let dirty: Bool?
    let pushed: Bool?
    let ahead: Int?
    let processes: Procs?
    let returnBlockers: [String]?
    var id: String { path }

    /// The worktree provider's name for the slot.
    var displayName: String? = nil
    var label: String { displayName ?? "\(pool) \(name)" }
    var blockerText: String? {
        guard let b = returnBlockers, !b.isEmpty else { return nil }
        return "Can't return: " + b.joined(separator: "; ")
    }
}

struct AgentRef: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let updatedAt: Double
    var tool: String? = nil
}

struct PR: Decodable, Identifiable, Equatable {
    let key: String
    let number: Int
    let title: String
    let url: String
    let repo: String
    let author: String
    let draft: Bool
    let review: String?
    let unresolved: Int
    let commentsUrl: String?
    let ci: String
    let mine: Bool
    let stale: Bool
    let agents: [AgentRef]?
    let stackId: String?
    let stackPos: Int?
    let stackSize: Int?
    var hidden: Bool? = nil
    var lastCommit: Double? = nil
    /// The base branch's required checks. Once all have posted, they alone decide `ci`.
    var requiredChecks: [String]? = nil
    /// Comments from other people you have not seen yet, newest first.
    var newComments: [PRComment]? = nil
    var id: String { key }

    var ticket: String? {
        ticketKeys(title).first
    }
    var shortRepo: String? { repo == Config.shared.homeRepo ? nil : repo.split(separator: "/").last.map(String.init) }
    var checksURL: String { url + "/checks" }
    /// The title without a leading ticket key, since the ticket has its own link pill.
    var displayTitle: String {
        guard let r = title.range(of: "^\\[?(?:\(Config.shared.issueTracker.keyPattern))\\]?[:\\s-]*", options: .regularExpression), r.upperBound < title.endIndex
        else { return title }
        return String(title[r.upperBound...])
    }
    /// The title with no leading ticket key or bracketed team tag.
    var plainTitle: String {
        guard let r = title.range(of: "^(\\[[A-Z]{2,}(-[0-9]+)?\\]|\\[?(?:\(Config.shared.issueTracker.keyPattern))\\]?)[:\\s-]*", options: .regularExpression),
              r.upperBound < title.endIndex
        else { return title }
        return String(title[r.upperBound...])
    }
    var threadURL: String { commentsUrl ?? url }
    var hasFeedback: Bool { mine && (unresolved > 0 || review == "CHANGES_REQUESTED" || !(newComments ?? []).isEmpty) }
    var unread: [PRComment] { newComments ?? [] }
}

struct PRComment: Decodable, Equatable {
    let at: Double
    let author: String
    let url: String
    let excerpt: String
}

struct PRSections: Decodable, Equatable {
    let mine: [PR]
    let review: [PR]
    var hidden: [PR]? = nil
}

struct Card: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Double
    let status: String
    let needsYou: [String]
    let slot: Slot?
    let prs: [PR]
    var hidden: Bool? = nil
    /// Side chats and subagents spawned from this chat, newest first.
    var children: [Card]? = nil
    var kind: String? = nil
    /// The `AgentTool.id` the chat lives in.
    var tool: String? = nil
    var cwd: String? = nil

    var chat: ChatRef { ChatRef(id: id, title: title, cwd: cwd, running: status == "running") }
    var minePRs: [PR] { prs.filter(\.mine) }
    var canCleanUp: Bool { !minePRs.isEmpty || slot?.leased == true }
    var dotStatus: String { needsYou.isEmpty || status == "running" ? status : "needs" }
    /// A family runs while any member runs, as a single chat does even when it needs you; otherwise it needs you
    /// when any member does.
    var section: String {
        let members = [self] + (children ?? [])
        if members.contains(where: { $0.status == "running" }) { return "running" }
        return members.contains { !$0.needsYou.isEmpty } ? "needs" : "recent"
    }
}

struct LinearFeed: Decodable, Equatable {
    struct Event: Decodable, Equatable {
        let id: String
        let kind: String
        let text: String
        let target: String?
        let read: Bool
    }
    /// Why the last fetch failed; the events are then the last ones fetched.
    var error: String? = nil
    let events: [Event]
}

struct BoardState: Decodable, Equatable {
    let generatedAt: Double
    let cards: [Card]
    let looseSlots: [Slot]
    let prs: PRSections?
    var hiddenCards: [Card]? = nil
    /// Why the last GitHub PR fetch failed; nil once one succeeds.
    var prError: String? = nil
    var prsFetchedAt: Double? = nil
    /// The Linear inbox; nil while no Linear key is set.
    var linear: LinearFeed? = nil

    /// Children come before their parent: a parent also lists its children's PRs, and a PR's own chat should win.
    var allCards: [Card] { cards.flatMap { ($0.children ?? []) + [$0] } }
    /// A PR's agent wears its card's mark: only the card knows the chat needs you.
    func status(of agent: AgentRef) -> String { allCards.first { $0.id == agent.id }?.dotStatus ?? agent.status }
}
