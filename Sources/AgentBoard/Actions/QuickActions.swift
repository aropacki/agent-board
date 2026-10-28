import AppKit

/// Every place a quick action can show.
enum ActionSurface: String, Codable, CaseIterable, Identifiable {
    case pr, stack, selection, agent, worktree, thread, comment, check
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pr: return "PR"
        case .stack: return "Stack"
        case .selection: return "Selected PRs"
        case .agent: return "Agent chat"
        case .worktree: return "Worktree"
        case .thread: return "Review thread"
        case .comment: return "PR comment"
        case .check: return "CI check"
        }
    }

    var about: String {
        switch self {
        case .pr: return "A PR row's ⋯ menu, or a button under the row"
        case .stack: return "A stack's ⋯ menu, or a button in its header"
        case .selection: return "A button in the bar that shows while PRs are selected"
        case .agent: return "An agent card's ⋯ menu, or a button under the card"
        case .worktree: return "The ⋯ menu of a worktree that has no chat"
        case .thread: return "A button under a review thread in the comments drawer"
        case .comment: return "A button under a comment in the comments drawer's Conversation tab"
        case .check: return "The right-click menu of a check in the checks drawer"
        }
    }

    var icon: String {
        switch self {
        case .pr: return "arrow.triangle.pull"
        case .stack: return "square.stack.3d.up"
        case .selection: return "checkmark.circle"
        case .agent: return "text.bubble"
        case .worktree: return "arrow.triangle.branch"
        case .thread: return "bubble.left.and.bubble.right"
        case .comment: return "bubble.left"
        case .check: return "checklist"
        }
    }

    /// Has both a menu and a row of buttons, so each action picks whether it is also a button.
    var choosesButton: Bool { [.pr, .stack, .agent].contains(self) }

    var conditions: [ActionCondition] {
        switch self {
        case .pr, .stack, .selection: return [.mine, .others, .feedback, .ciFailing]
        case .agent: return [.mine, .feedback, .ciFailing, .worktree]
        case .worktree: return []
        case .thread: return [.openThread, .mine]
        case .comment: return [.mine]
        case .check: return [.failedCheck, .mine]
        }
    }

    var variables: [(name: String, about: String)] {
        var v: [(name: String, about: String)] = [("target", "What the action is on, written out")]
        if self != .worktree {
            v += [("pr_url", "PR link, when there is one PR"), ("pr_title", "PR title, when there is one PR"),
                  ("pr_number", "PR number, when there is one PR"), ("prs", "Numbered PR links with titles"),
                  ("prs_feedback", "Numbered PRs with their open feedback"), ("prs_failing", "Numbered PRs with their failing checks"),
                  ("count", "How many PRs"), ("many", "Set when there is more than one PR"), ("stack", "Set when the PRs are one stack"),
                  ("failing", "Failing check names, when there is one PR"), ("tickets", "Linear keys in the PR titles and chat title")]
        }
        switch self {
        case .agent:
            v += [("chat_title", "Agent chat title"), ("chat_id", "Agent chat id"),
                  ("worktree", "Leased worktree path, when the chat has one"), ("branch", "Worktree branch")]
        case .worktree:
            v += [("worktree", "Worktree path"), ("branch", "Worktree branch")]
        case .thread:
            v += [("thread_url", "Link to the thread's first comment"), ("file", "File the thread is on"),
                  ("line", "Line the thread is on, when it has one"), ("thread", "Every comment in the thread, oldest first")]
        case .comment:
            v += [("comment_url", "Link to the comment"), ("comment_author", "Who wrote it"), ("comment", "The comment's text")]
        case .check:
            v += [("check_name", "Check name"), ("check_url", "Link to the check's run"), ("check_workflow", "Workflow the check is in")]
        case .pr, .stack, .selection:
            break
        }
        return v
    }
}

/// Narrows where an action shows. The PR conditions also narrow which PRs it covers, and hide it when none are left.
enum ActionCondition: String, Codable, CaseIterable {
    case mine, others, feedback, ciFailing = "ci-failing", worktree, openThread = "open-thread", failedCheck = "failed-check"

    var title: String {
        switch self {
        case .mine: return "My PRs"
        case .others: return "Others' PRs"
        case .feedback: return "Open feedback"
        case .ciFailing: return "CI failing"
        case .worktree: return "Has a worktree"
        case .openThread: return "Unresolved"
        case .failedCheck: return "Failed"
        }
    }

    var filtersPRs: Bool { [.mine, .others, .feedback, .ciFailing].contains(self) }
}

struct Placement: Codable, Equatable {
    var surface: ActionSurface
    var when: [ActionCondition]
    /// Also a button on the row, where the surface has both.
    var button: Bool

    init(_ surface: ActionSurface, when: [ActionCondition] = [], button: Bool = false) {
        self.surface = surface
        self.when = when
        self.button = button
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(ActionSurface.self, forKey: .surface)
        when = try c.decodeIfPresent([ActionCondition].self, forKey: .when) ?? []
        button = try c.decodeIfPresent(Bool.self, forKey: .button) ?? false
    }
}

enum ActionDelivery: String, Codable, CaseIterable {
    /// The agent chat the target belongs to, or a new chat when it has none.
    case ownChat = "own-chat"
    case newChat = "new-chat"
}

struct QuickAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var icon: String
    var template: String
    var placements: [Placement]
    var delivery: ActionDelivery
    /// Asks in a bar at the bottom of the board before it sends.
    var confirm: Bool
    /// Moves the PRs it covers, and its chat, to Hidden once the agent starts.
    var hidesAfter: Bool
    /// Asks the agent to write its findings where the diff viewer shows them.
    var emitsReview: Bool
    var enabled: Bool
    /// The rule, skill, or command it was made from.
    var source: String?

    init(id: String, title: String, icon: String, template: String, placements: [Placement], delivery: ActionDelivery = .ownChat,
         confirm: Bool = false, hidesAfter: Bool = false, emitsReview: Bool = false, enabled: Bool = true, source: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.template = template
        self.placements = placements
        self.delivery = delivery
        self.confirm = confirm
        self.hidesAfter = hidesAfter
        self.emitsReview = emitsReview
        self.enabled = enabled
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        placements = try c.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        delivery = try c.decodeIfPresent(ActionDelivery.self, forKey: .delivery) ?? .ownChat
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
        hidesAfter = try c.decodeIfPresent(Bool.self, forKey: .hidesAfter) ?? false
        emitsReview = try c.decodeIfPresent(Bool.self, forKey: .emitsReview) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    func placement(_ surface: ActionSurface) -> Placement? { placements.first { $0.surface == surface } }
    var builtIn: QuickAction? { QuickAction.defaults.first { $0.id == id } }
    var menuTitle: String { confirm ? title + "…" : title }

    /// Names the template uses that none of its surfaces provide; they render as nothing.
    var unknownNames: [String] {
        let surfaces = placements.isEmpty ? ActionSurface.allCases : placements.map(\.surface)
        let known = Set(surfaces.flatMap { $0.variables.map(\.name) })
        var seen = Set<String>()
        return Prompts.names(template).filter { !known.contains($0) && seen.insert($0).inserted }
    }
}

/// What an action runs on. Only the fields its surface has are set.
struct ActionContext {
    let surface: ActionSurface
    /// Keys the busy and done marks.
    let key: String
    var prs: [PR] = []
    var card: Card? = nil
    var slot: Slot? = nil
    var thread: ReviewThread? = nil
    var comment: ThreadComment? = nil
    var check: CICheck? = nil
}

/// The PRs the action covers there, base first, or nil when it does not show there.
func actionTargets(_ p: Placement, _ ctx: ActionContext, ci: (PR) -> String) -> [PR]? {
    if ctx.card?.hidden == true { return nil }
    let open = ctx.prs.filter { $0.hidden != true }
    if [.pr, .stack, .selection].contains(ctx.surface) && !ctx.prs.isEmpty && open.isEmpty { return nil }
    var prs = open
    for c in p.when {
        switch c {
        case .mine: prs = prs.filter(\.mine)
        case .others: prs = prs.filter { !$0.mine }
        case .feedback: prs = prs.filter(\.hasFeedback)
        case .ciFailing: prs = prs.filter { ci($0) == "failing" }
        case .worktree: if (ctx.card?.slot ?? ctx.slot) == nil { return nil }
        case .openThread: if ctx.thread?.resolved != false { return nil }
        case .failedCheck: if ctx.check?.bucket != "fail" { return nil }
        }
    }
    if p.when.contains(where: \.filtersPRs) && prs.isEmpty { return nil }
    return reviewOrder(prs)
}

func actionVars(_ ctx: ActionContext, prs: [PR], checks: [String: [CICheck]]) -> [String: String] {
    func failing(_ pr: PR) -> String {
        var seen = Set<String>()
        return sortedChecks(checks[pr.key] ?? []).filter { $0.bucket == "fail" && seen.insert($0.name).inserted }
            .map(\.name).joined(separator: ", ")
    }
    func feedback(_ pr: PR) -> String {
        var notes: [String] = []
        if pr.unresolved > 0 { notes.append("\(pr.unresolved) unresolved") }
        if pr.review == "CHANGES_REQUESTED" { notes.append("changes requested") }
        return notes.joined(separator: ", ")
    }
    func numbered(_ note: (PR) -> String) -> String {
        prs.enumerated().map { i, pr in
            let n = note(pr)
            return "\(i + 1). \(pr.url) (\(pr.title))" + (n.isEmpty ? "" : ": " + n)
        }.joined(separator: "\n")
    }
    let one = prs.count == 1 ? prs[0] : nil
    let slot = ctx.slot ?? (ctx.card?.slot?.leased == true ? ctx.card?.slot : nil)
    let tickets = Set(prs.flatMap { ticketKeys($0.title) } + ticketKeys(ctx.card?.title ?? "")).sorted()
    var v: [String: String] = [
        "pr_url": one?.url ?? "",
        "pr_title": one?.title ?? "",
        "pr_number": one.map { "\($0.number)" } ?? "",
        "prs": numbered { _ in "" },
        "prs_feedback": numbered(feedback),
        "prs_failing": numbered(failing),
        "count": prs.isEmpty ? "" : "\(prs.count)",
        "many": prs.count > 1 ? "yes" : "",
        "stack": isOneStack(prs) ? "yes" : "",
        "failing": one.map(failing) ?? "",
        "tickets": tickets.joined(separator: ", "),
        "chat_title": ctx.card?.title ?? "",
        "chat_id": ctx.card?.id ?? "",
        "worktree": slot?.path ?? "",
        "branch": slot.map { $0.branch ?? "detached HEAD" } ?? "",
    ]
    if let t = ctx.thread {
        v["thread_url"] = t.url
        v["file"] = t.path
        v["line"] = t.line.map(String.init) ?? ""
        v["thread"] = t.comments.map { "@\($0.author)\($0.bot ? " (bot)" : ""): \($0.body)" }.joined(separator: "\n\n")
    }
    if let c = ctx.comment {
        v["comment_url"] = c.id
        v["comment_author"] = c.author
        v["comment"] = c.body
    }
    if let c = ctx.check {
        v["check_name"] = c.name
        v["check_url"] = c.link ?? ""
        v["check_workflow"] = c.workflow ?? ""
    }
    v["target"] = Prompts.render(ActionContext.targetTemplate(ctx.surface), v)
    return v
}

extension ActionContext {
    /// `{{target}}`: the thing written out, for actions that work on any surface.
    static func targetTemplate(_ surface: ActionSurface) -> String {
        let prs = """
        {{^many}}
        PR: {{pr_url}} ({{pr_title}})
        {{/many}}
        {{#many}}
        These {{count}} PRs{{#stack}}, one stack listed base first{{/stack}}:
        {{prs}}
        {{/many}}
        """
        switch surface {
        case .pr, .stack, .selection:
            return prs
        case .agent:
            return """
            Agent chat: “{{chat_title}}” (conversation id {{chat_id}}).
            {{#worktree}}
            Worktree: {{worktree}} on {{branch}}.
            {{/worktree}}
            {{#prs}}
            Its PRs:
            {{prs}}
            {{/prs}}
            """
        case .worktree:
            return "Worktree: {{worktree}} on {{branch}}."
        case .thread:
            return """
            Review thread on {{pr_url}} ({{pr_title}}):
            {{thread_url}}
            File: {{file}}{{#line}}, line {{line}}{{/line}}

            {{thread}}
            """
        case .comment:
            return """
            Comment by @{{comment_author}} on {{pr_url}} ({{pr_title}}):
            {{comment_url}}

            {{comment}}
            """
        case .check:
            return "CI check {{check_name}}{{#check_workflow}} ({{check_workflow}}){{/check_workflow}} on {{pr_url}} ({{pr_title}}): {{check_url}}"
        }
    }
}

func renderAction(_ a: QuickAction, _ ctx: ActionContext, targets: [PR], checks: [String: [CICheck]] = [:]) -> String {
    let text = Prompts.render(a.template, actionVars(ctx, prs: targets, checks: checks))
    guard a.emitsReview, !targets.isEmpty else { return text }
    return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + reviewEmitSection(targets)
}
