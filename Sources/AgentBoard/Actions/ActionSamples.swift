import AppKit

/// Made-up targets, so the editor can preview a template on each surface.
enum ActionSamples {
    static let prA = PR(key: "acme/app#4210", number: 4210, title: "[APP-4540] Remove stale queue badges",
                        url: "https://github.com/acme/app/pull/4210", repo: "acme/app", author: "me", draft: false,
                        review: "CHANGES_REQUESTED", unresolved: 2, commentsUrl: nil, ci: "failing", mine: true, stale: false, agents: nil,
                        stackId: "s", stackPos: 0, stackSize: 2)
    static let prB = PR(key: "acme/app#4222", number: 4222, title: "[APP-4540] Badge counts follow-up",
                        url: "https://github.com/acme/app/pull/4222", repo: "acme/app", author: "me", draft: false,
                        review: nil, unresolved: 0, commentsUrl: nil, ci: "passing", mine: true, stale: false, agents: nil,
                        stackId: "s", stackPos: 1, stackSize: 2)
    static let slot = Slot(pool: "code-abc", name: "3", path: "~/.treehouse/code-abc/3", leased: true, leaseHolder: "badges",
                           branch: "me/APP-4540-badges", dirty: false, pushed: true, ahead: 0, processes: nil, returnBlockers: nil)
    static let card = Card(id: "a2be4db4-8c2e-405f-84e6-427323422174", title: "Remove stale queue badges", updatedAt: 0,
                           status: "done", needsYou: [], slot: slot, prs: [prA, prB])
    static let thread = ReviewThread(id: "T", resolved: false, outdated: false, path: "js/packages/opshub/src/QueueBadge.tsx", line: 133,
                                     context: [], highlighted: 0, comments: [
                                        ThreadComment(id: "https://github.com/acme/app/pull/4210#discussion_r2441", author: "reviewer",
                                                      bot: false, body: "Operators can miss newly parked tasks.", at: .distantPast),
                                        ThreadComment(id: "https://github.com/acme/app/pull/4210#discussion_r2442", author: "me",
                                                      bot: false, body: "The next reload corrects it.", at: .distantPast)])
    static let comment = ThreadComment(id: "https://github.com/acme/app/pull/4210#issuecomment-3301", author: "reviewer",
                                       bot: false, body: "Looks close. One question about the badge count.", at: .distantPast)
    static let check = CICheck(name: "go-test-gate", workflow: "Go", bucket: "fail",
                               link: "https://github.com/acme/app/actions/runs/1/job/2", started: nil, completed: nil)
    static let checks: [String: [CICheck]] = [prA.key: [check]]

    static func context(_ s: ActionSurface) -> ActionContext {
        switch s {
        case .pr: return ActionContext(surface: s, key: "sample", prs: [prA])
        case .stack, .selection: return ActionContext(surface: s, key: "sample", prs: [prA, prB])
        case .agent: return ActionContext(surface: s, key: "sample", prs: [prA, prB], card: card)
        case .worktree: return ActionContext(surface: s, key: "sample", slot: slot)
        case .thread: return ActionContext(surface: s, key: "sample", prs: [prA], thread: thread)
        case .comment: return ActionContext(surface: s, key: "sample", prs: [prA], comment: comment)
        case .check: return ActionContext(surface: s, key: "sample", prs: [prA], check: check)
        }
    }

    static func preview(_ a: QuickAction, on s: ActionSurface) -> String {
        let ctx = context(s)
        let targets = a.placement(s).flatMap { actionTargets($0, ctx, ci: \.ci) } ?? reviewOrder(ctx.prs)
        return renderAction(a, ctx, targets: targets, checks: checks)
    }
}
