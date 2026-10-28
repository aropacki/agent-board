# Agent Board

A small macOS panel for people who run many coding agents at once.
It works with Cursor, Claude Code, and Codex, and with anything else through the clipboard.
Press ⌥Space to see each agent chat, the worktree it uses, and the PRs it touches.
Review diffs, read checks and comments, and send follow-up prompts without leaving the panel.

It is built to fork.
Most changes are a setting in `config.json`.
To support a new tool or worktree manager, add one module; see [CONTRIBUTING.md](CONTRIBUTING.md).

## What it shows

- **Agents**: running, waiting on you, and recent chats, each with its worktree and PRs.
- **PRs**: your open PRs, stacks, and PRs that request your review, with CI and comment counts.
- **Diff review**: files, inline threads, and draft notes that stay local until you post them.
- **Quick actions**: prompt templates such as "Review" or "Fix CI", filled in from the PR or chat and sent to the chat's tool.

## Requirements

- macOS 26 or later.
- Swift 6.2: Xcode or the Command Line Tools.
- [GitHub CLI](https://cli.github.com), signed in with `gh auth login`.
- `/usr/bin/python3`, which comes with the Command Line Tools.
- One or more of the tools below.

## Install

The quick way: clone the repo, open it in your coding agent, and ask it to set the board up.
It follows [SETUP.md](SETUP.md): it finds your tools, asks a few questions, connects the hooks, and checks the result.

To do it yourself:

```bash
git clone <your fork> agent-board && cd agent-board
make install
```

`make install` does these steps:

1. Builds the app and installs it to `~/Applications/AgentBoard.app`.
2. Copies the collector scripts to `~/.agent-board/bin`.
3. Loads a launch agent that starts the app at login.

Then pick your tools in `~/.agent-board/config.json`.
The first tool in the list takes new chats.
Without the key, the board uses Cursor.

```json
{ "tools": ["claude-code", "cursor"] }
```

## Tools

| Tool | `tools` id | Sending a prompt | Setup |
|---|---|---|---|
| Cursor | `cursor` | Types it into the chat. Needs Accessibility access. | Merge `install/cursor-hooks.json` into `~/.cursor/hooks.json`. |
| Claude Code | `claude-code` | Opens Terminal and resumes the chat with the prompt. A chat that is running gets the prompt on the clipboard. | Optional: merge `install/claude-code-hooks.json` into `~/.claude/settings.json`. |
| Codex | `codex` | Like Claude Code, with `codex resume`. | None. |
| Clipboard | `clipboard` | Copies it for you to paste. | None. Reads no chats; pair it with a tool above, or use it alone for the PR views. |

The board reads each tool's chat history to link chats to worktrees and PRs.
It keeps no prompt text and no command output.

The Cursor hook is required: Cursor's transcripts do not mark when a turn ends.
Claude Code and Codex transcripts do, so their status works without hooks.
The Claude Code hook also records PRs that MCP tools touch, which the transcript reader skips.

Terminal tools launch through a `.command` file, so they need no extra macOS permission.
To use another terminal, set `terminalApp` to an app that runs `.command` files when it opens them.
Set `newChatFolder` for the folder new chats start in.

### Keep the Accessibility grant across rebuilds

Only Cursor needs this.
macOS ties the Accessibility grant to the app's signature.
The default signature is ad hoc, so each rebuild loses the grant.
For a stable signature, do these steps:

1. Open Keychain Access and choose Certificate Assistant › Create a Certificate.
2. Set the type to Code Signing.
3. Name the certificate, for example "Agent Board Local Signing".
4. Put your settings in `local.mk`:

```make
BUNDLE_ID = com.yourname.agentboard
SIGN_IDENTITY = Agent Board Local Signing
```

Keep `BUNDLE_ID` fixed after the first install.
Saved preferences and the Accessibility grant belong to it.

## Worktrees

The board shows which worktree each chat works in, and lets you return idle ones.

| `worktrees` | Reads |
|---|---|
| `treehouse` | [treehouse](https://github.com/kunchenguid/treehouse) pools. The default when a pool exists. |
| `git` | `git worktree list` for each repo in `worktreeRepos`. The default otherwise. |
| `none` | Nothing. Chats show no worktree. |

Return means `treehouse return` for treehouse.
For git it means `git worktree remove`, which refuses a worktree with changes.

## Configure

Put settings in `~/.agent-board/config.json`.
Every key is optional.
`install/config.example.json` shows all of them.

| Key | Effect |
|---|---|
| `tools` | Tool ids, from the table above. The first takes new chats. Default `["cursor"]`. |
| `terminalApp` | App that runs Claude Code and Codex. Default `Terminal`. |
| `newChatFolder` | Folder that new terminal chats start in. Default your home folder. |
| `worktrees` | `treehouse`, `git`, or `none`. |
| `worktreeRepos` | Repo checkouts whose git worktrees show, for `worktrees: git`. |
| `issueTracker.keyPattern` | Regex for ticket keys in PR titles. Default `[A-Z]{2,}-[0-9]+`. |
| `issueTracker.url` | Ticket link, with `{key}` in place of the key. With no URL, tickets show but do not link. |
| `issueTracker.name` | Tracker name in tooltips, for example `Jira`. |
| `homeRepo` | `owner/name` of your main repo. PR rows leave out this repo's name, and its treehouse slots show as "slot N". |
| `libraryRepo` | A checkout whose `.cursor/rules`, `.claude/skills`, and `.agents/skills` join the prompt library. |
| `hiddenPRsFile` | A file with one PR URL per line. Those PRs go to the hidden section. |
| `botAccounts` | User accounts whose PR comments are automated. Comments from them, and from accounts GitHub marks as bots, never alert you. |

The prompt library also reads each tool's own rules, skills, commands, and installed plugins.

To edit the quick-action prompts, click Quick actions in the full board.
The app saves them to `~/.agent-board/actions.json`.

To put the data directory somewhere else, set `AGENT_BOARD_HOME` for `make install`.
The launch agent passes the value to the app.
The hook commands in `install/` assume the default location, so change them too.

### Optional: Chrome tab groups

"Open PRs as tab group" uses a small Chrome extension.
Load it unpacked from `~/.agent-board/chrome-extension`.
Use `chrome://extensions` with Developer mode turned on.

## Data

All state is in `~/.agent-board`. Delete the directory to start over.

| Path | Contents |
|---|---|
| `state.json` | The collector's latest snapshot, which the app reads. |
| `journal/` | Hook events, and `CURRENT.md`, a summary of active chats. |
| `actions.json`, `config.json` | Your settings. |
| `reviews/` | Draft review notes for each PR. |
| `cache/` | Fetch and transcript caches. Safe to delete. |

`make uninstall` removes the app and the launch agent.
It keeps the data directory.

## Develop

```bash
make test    # logic tests and collector tests
make perf    # frame timings and screenshots on seeded data
make install # rebuild and restart
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a tool or worktree provider,
[AGENTS.md](AGENTS.md) for how the code is checked, and [CODEMAP.md](CODEMAP.md) for where things live.

## Why Swift and Python

The app is SwiftUI and AppKit.
It needs a global hotkey, a floating panel, Accessibility, and native text rendering.
On macOS, only Swift gets all of these without a bridge.

The collector is stdlib-only Python.
It reads each tool's chat history, git, and `gh`, and it needs no install step.
A separate process keeps slow work, such as network calls and file scans, out of the UI.
