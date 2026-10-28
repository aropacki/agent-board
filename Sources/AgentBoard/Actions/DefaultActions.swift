import AppKit

extension QuickAction {
    static let defaults: [QuickAction] = [
        QuickAction(id: "review", title: "Review", icon: "eye", template: """
            {{^many}}
            Review this PR: {{pr_url}}

            Check it out in a separate worktree, read the description and the full diff, and report your findings here. Do not post anything on the PR. Return the worktree when you are done.
            {{/many}}
            {{#many}}
            Review these {{count}} PRs together:
            {{prs}}

            {{#stack}}They are one stack, listed base first; each PR builds on the one before it.{{/stack}}{{^stack}}They are related and should be judged as one change.{{/stack}} Use one worktree for all of them. Read every description and full diff in order before you judge anything. Report on the set as a whole first (design, sequencing, gaps between PRs), then list findings per PR with its number. Do not post anything on any PR. Return the worktree when you are done.
            {{/many}}
            """,
            placements: [Placement(.pr, when: [.others], button: true), Placement(.stack, when: [.others], button: true), Placement(.selection)],
            delivery: .newChat),
        QuickAction(id: "comments", title: "Address comments", icon: "text.bubble", template: """
            {{^many}}
            Work through the review feedback on my PR {{pr_url}} ({{pr_title}}).
            {{/many}}
            {{#many}}
            Work through the review feedback on these {{count}} PRs of mine{{#stack}}, one stack listed base first{{/stack}}:
            {{prs_feedback}}
            {{/many}}

            Read every unresolved review thread and every review that requested changes. For each one, read the code it points at and decide: fix it, answer it, or push back. Give the reason in one line.

            Make the fixes on each PR's own branch. Use this chat's worktree if it already has the branch; otherwise check the branch out in a separate worktree. Commit and push with hooks on.{{#stack}} After you change a lower PR, rebase the PRs above it so the stack stays consistent.{{/stack}}

            Do not post, reply to, or resolve anything on GitHub. When you are done, list per thread: the link, your decision, what you changed, and a draft reply I can paste. Return any worktree you acquired once it is clean and pushed.
            """,
            placements: [Placement(.pr, when: [.feedback], button: true), Placement(.stack, when: [.feedback]),
                         Placement(.selection, when: [.feedback]), Placement(.agent, when: [.feedback], button: true)]),
        QuickAction(id: "fix-ci", title: "Fix CI", icon: "wrench.and.screwdriver", template: """
            {{^many}}
            CI is failing on my PR {{pr_url}} ({{pr_title}}){{#failing}}. Failing checks: {{failing}}{{/failing}}.
            {{/many}}
            {{#many}}
            CI is failing on these {{count}} PRs of mine:
            {{prs_failing}}
            {{/many}}

            Investigate the failing checks and fix them on each PR's own branch, then push. Leave any other PRs in this chat alone.
            """,
            placements: [Placement(.agent, when: [.mine, .ciFailing], button: true), Placement(.pr, when: [.mine, .ciFailing]),
                         Placement(.stack, when: [.mine, .ciFailing])]),
        QuickAction(id: "fix-check", title: "Fix this check", icon: "wrench.and.screwdriver", template: """
            The CI check {{check_name}} is failing on my PR {{pr_url}} ({{pr_title}}): {{check_url}}

            Read its log, find the cause, and fix it on the PR's branch. Use this chat's worktree if it already has the branch; otherwise check the branch out in a separate worktree. Commit and push with hooks on. Return any worktree you acquired once it is clean and pushed.
            """,
            placements: [Placement(.check, when: [.failedCheck, .mine])]),
        QuickAction(id: "wrap-up", title: "Wrap up", icon: "shippingbox",
                    template: "Please wrap up: commit and push your work so the tree is clean, then release your worktree. Report the branch, the PR link, and that the worktree was released.",
                    placements: [Placement(.agent, when: [.worktree], button: true)]),
        QuickAction(id: "return", title: "Return", icon: "arrow.uturn.backward",
                    template: "Release your worktree now. No PR needed. You decide what to do with anything left in it: commit and push what is worth keeping, discard the rest. Then confirm the worktree was released.",
                    placements: [Placement(.agent, when: [.worktree], button: true)]),
        QuickAction(id: "thread-analyze", title: "Analyze", icon: "magnifyingglass", template: """
            Analyze this review thread on my PR {{pr_url}} ({{pr_title}}):
            {{thread_url}}
            File: {{file}}{{#line}}, line {{line}}{{/line}}

            {{thread}}

            Read the code it points at. Tell me whether the comment is right, what a fix would involve, and what you recommend, a line or two each. Do not change code, and do not post, reply to, or resolve anything on GitHub.
            """,
            placements: [Placement(.thread, when: [.openThread])]),
        QuickAction(id: "thread-push-back", title: "Push back", icon: "hand.raised", template: """
            I want to push back on this review thread on {{pr_url}} ({{pr_title}}):
            {{thread_url}}
            File: {{file}}{{#line}}, line {{line}}{{/line}}

            {{thread}}

            Read the code it points at and check whether the comment holds. Then draft a short reply, backed by the code, that explains why it should stay as it is. If the comment turns out to be right, tell me that instead of drafting a push-back. Do not change code, and do not post, reply to, or resolve anything on GitHub. Show me the draft.
            """,
            placements: [Placement(.thread, when: [.openThread])]),
        QuickAction(id: "thread-agree", title: "Agree", icon: "hand.thumbsup", template: """
            I agree with this review thread on {{pr_url}} ({{pr_title}}):
            {{thread_url}}
            File: {{file}}{{#line}}, line {{line}}{{/line}}

            {{thread}}

            Make the change on the PR's branch. Use this chat's worktree if it already has the branch; otherwise check the branch out in a separate worktree. Commit and push with hooks on. Then draft a one-line reply that says what changed. Do not post, reply to, or resolve anything on GitHub. Return any worktree you acquired once it is clean and pushed.
            """,
            placements: [Placement(.thread, when: [.openThread])]),
        QuickAction(id: "cleanup", title: "Clean up", icon: "xmark.bin", template: """
            Clean up work I am not continuing.

            {{#prs}}
            PRs:
            {{prs}}
            {{#stack}}
            These PRs are one stack, listed base first.
            {{/stack}}

            {{/prs}}
            {{#chat_title}}
            Agent chat: “{{chat_title}}” (conversation id {{chat_id}}).

            {{/chat_title}}
            {{#worktree}}
            Worktree: {{worktree}} on {{branch}}.

            {{/worktree}}
            {{#tickets}}
            Tickets referenced: {{tickets}}.

            {{/tickets}}
            Do this:
            {{#prs}}
            - Close each PR above with `gh pr close`.{{#stack}} Start from the top of the stack and work down to the base.{{/stack}} Do not comment on the PRs and do not delete branches.
            {{/prs}}
            - For each ticket referenced here, check whether anything else still uses it: other open PRs that mention the key, links on the ticket, and recent activity. Cancel it only if nothing else does. If something does, leave the ticket unchanged and tell me what still uses it.
            {{#worktree}}
            - Release the worktree if it is clean and pushed. If it has uncommitted or unpushed work, leave it and tell me.
            {{/worktree}}
            - Report what you closed, cancelled, returned, and left alone, with links.
            """,
            placements: [Placement(.pr, when: [.mine]), Placement(.stack, when: [.mine]), Placement(.selection, when: [.mine]),
                         Placement(.agent, when: [.mine])],
            delivery: .newChat, confirm: true, hidesAfter: true),
    ]

    static let icons = ["sparkles", "eye", "text.bubble", "wrench.and.screwdriver", "hammer", "shippingbox", "arrow.uturn.backward",
                        "magnifyingglass", "hand.raised", "hand.thumbsup", "checkmark.seal", "xmark.bin", "checklist", "ladybug",
                        "bolt", "lightbulb", "doc.text", "text.book.closed", "terminal", "paperplane", "flag", "arrow.triangle.branch"]
}
