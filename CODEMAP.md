# Code map

Swift paths are relative to `Sources/AgentBoard/`. Other paths are relative to the repo root.

## Data flow

- `collector/collect.py` writes `state.json`. The app runs it on a timer and on refresh (`Model/Board+Refresh.swift`).
- `collector/sources/` reads each tool's chats and transcripts. `collector/worktrees/` reads worktree pools.
- `collector/journal-hook.py <tool>` is the hook for every tool. It appends to `journal/events.jsonl`, and the collector reads that file to link chats to worktrees and PRs.
- The app reads `state.json` into `Model/BoardState.swift` types. It fetches diffs, checks, and discussions on demand with `gh` (`GitHub/`).
- `Tools/` opens chats and sends prompts. A card's `tool` field picks the `AgentTool` (`Tools.tool`).

## Where to change things

| Change | Start at |
|---|---|
| Support another agent tool | `collector/sources/__init__.py` and `Tools/AgentTool.swift`; see `CONTRIBUTING.md` |
| Support another worktree manager | `collector/worktrees/__init__.py` |
| Ticket links, home repo, library repo | `Support/Config.swift` and `collector/config.py` |
| Another issue tracker's key format | `Integrations/IssueTracker.swift` |
| Built-in quick-action prompts | `Actions/DefaultActions.swift` |
| Prompt variables and where actions show | `Actions/QuickActions.swift` |
| Prompt library folders | each tool's `libraryDirs` and `pluginCache`; `Actions/Library.swift` scans them |
| Which chats and PRs show | `collector/collect.py` (`build`) |
| PR, branch, and slot facts from commands | `collector/refs.py` and the provider's `slot_in_*` |
| Hotkey, panel, and windows | `App/` |
| Row menus | `Model/Board+Menus.swift` |
| PR overview, merge, and other PR commands | `GitHub/Overview.swift` (`prCommandArgs`; stacked PRs only merge through `stackMergeArgs`), `UI/Diff/PROverviewPage.swift` |
| Colors, fonts, zoom | `UI/Theme.swift` |

## Boundaries

- Behavior for a specific tool or worktree manager lives in `Tools/`, `collector/sources/`, and `collector/worktrees/`. Other code reaches it through `Tools` and `worktrees.provider()`.
- `Board` (`Model/Board.swift`) holds all app state. `Model/Board+*.swift` add its behavior by domain.
- `Bench/` is test and timing code only. `main.swift` enters it on `--bench`. `Perf.swift` holds the scenarios; `Fixtures.swift` the seeded data.
- `install/` holds templates. `make install` fills them in. Do not edit installed copies.
