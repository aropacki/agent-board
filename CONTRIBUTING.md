# Contributing

Fork the repo and make it yours.
Send a change upstream when other people would want it too.

## Change data before code

Most team differences are settings, not code:

- Tools, worktrees, tracker, repos, and bot accounts go in `~/.agent-board/config.json`.
- Prompts go in `~/.agent-board/actions.json`, through the Quick actions editor.

A fork that changes only these pulls upstream changes with no conflicts.
If you need a value that is not a setting yet, add the setting instead of hard-coding the value.

## What merges upstream

- A new agent tool, as both halves below.
- A new worktree provider.
- Fixes, and features that work with every tool.

What stays in your fork:

- Values for one team: names, repos, URLs, prompt text.
- A default that suits one team but not others.
- A dependency. The collector uses only the Python standard library, and the app uses only Apple frameworks.

## Add an agent tool

A tool has two halves that share one id, such as `claude-code`.
The collector reads its chats, and the app sends prompts to it.

1. **Collector.** Add `collector/sources/<tool>.py` and register it in `SOURCES`.
   The module docstring in `collector/sources/__init__.py` lists the functions a source provides.
   `NAME` is the tool id.
2. **App.** Add a type that conforms to `AgentTool` in `Sources/AgentBoard/Tools/` and register it in `Tools.known`.
   For a command-line agent that resumes chats by id, conform to `TerminalTool` instead.
   Then you only give the command and its resume form.
3. **Hooks, if the tool has them.** Give the source `hook` and `hook_reply`.
   Add `install/<tool>-hooks.json`, which runs `journal-hook.py <tool id>`.
   The docstring in `collector/journal-hook.py` defines the journal events.
4. **Tests.** Add a case to `collector/test_sources.py`, built from a short transcript you write by hand.
   Never copy a real transcript into the repo. Transcripts hold prompts and command output.
5. **Docs.** Add a row to the Tools table in `README.md`.

## Add a worktree provider

Add `collector/worktrees/<provider>.py` and register it in `PROVIDERS`.
The module docstring in `collector/worktrees/__init__.py` lists the functions a provider gives.
Add a row to the Worktrees table in `README.md`.

## The app and the collector

The collector writes `state.json`, and `Model/BoardState.swift` decodes it.
Those Swift types are the schema.
Add a field on both sides together, and make it optional in Swift so that an older collector still decodes.

A setting that both sides read goes in both `Sources/AgentBoard/Support/Config.swift` and `collector/config.py`.

## Before you open a PR

- `make test` passes.
- For a view change, `make perf` shows no new slow frames. See [AGENTS.md](AGENTS.md).
- Hooks and the collector keep facts only: PR links, branch names, worktree paths, and times.
  They never store prompt text, command text, or tool output.
- Sample data and fixtures use made-up names, repos, and URLs.
- Comments say why, not what.
