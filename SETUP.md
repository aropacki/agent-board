# Set up Agent Board

For a coding agent that a user asked to set this repo up.
Read [README.md](README.md) first for what each setting does.
Work through the steps in order. Talk to the user at the points marked **Ask** and **Tell**.

## Rules

- Change the user's files only after they agree. Before you edit a file outside this repo, show the change and get a yes.
- Back up each file outside the repo before you change it, for example `hooks.json.bak`.
- Merge into existing config. Never replace a file and never drop the user's entries.
- Do not edit shell startup files such as `~/.zshrc`.
- `make install` restarts the app. Run it as often as you need.
- Never post, comment, or merge on GitHub to test the board. Read-only `gh` calls are fine.

## 1. Check the machine

| Need | Check | If missing |
|---|---|---|
| macOS 26 or later | `sw_vers -productVersion` | Stop. The app does not build on older macOS. |
| Swift 6.2 or later | `swift --version` | **Tell** the user to install Xcode or run `xcode-select --install`. |
| GitHub CLI, signed in | `gh auth status` exits 0 | **Tell** the user to run `gh auth login`. It opens a browser, so they must do it. |
| Python 3 | `/usr/bin/python3 --version` | Comes with the Command Line Tools. |

## 2. Find the user's tools

Look for each tool. Report what you found.

- **Cursor**: `~/.cursor` exists, or `mdfind "kMDItemCFBundleIdentifier == 'com.todesktop.230313mzl4w4u92'"` finds the app. It is not always in `/Applications`.
- **Claude Code**: `~/.claude/projects` exists, or `claude` is on the user's PATH. It is often in `~/.local/bin`.
- **Codex**: `~/.codex/sessions` exists. `codex` can be a shell function or an app, so do not rely on `which codex`.
- **treehouse**: `~/.treehouse/*/treehouse-state.json` exists. If not, the board reads git worktrees.

The newest files under `~/.cursor/projects`, `~/.claude/projects`, and `~/.codex/sessions` show which tool the user works in most.

**Ask** the user:

1. Which tools to show, and which one should take new chats. That one goes first in `tools`. If they use something else, add `clipboard`.
2. Without treehouse: which repo checkouts have worktrees to show (`worktreeRepos`).
3. Their main GitHub repo (`homeRepo`), and their ticket tracker's URL, if any (`issueTracker.url`).

Offer sensible answers from what you found, so that the user can just say yes.

## 3. Write the config

Write `~/.agent-board/config.json` with only the keys the user chose.
`install/config.example.json` shows the shape.
If the file exists, add or change only those keys.

## 4. Connect the hooks

Each hook runs `~/.agent-board/bin/journal-hook.py`.
If the user set `AGENT_BOARD_HOME`, change the path in the commands you add.

**Cursor (required).**
Merge `install/cursor-hooks.json` into `~/.cursor/hooks.json`.
For each event under `hooks`, add an entry from the template when no entry already has the same `command` and `matcher`.
Keep `"version": 1`.

**Claude Code (optional).**
Merge the `hooks` object from `install/claude-code-hooks.json` into `~/.claude/settings.json`.
For each event, add the template's group when no group already runs `journal-hook.py`.
Keep every other key in the file as it is.
Status works without this hook. Explain that the hook also links PRs that MCP tools touch, then let the user choose.

**Codex.** No hook is needed.

## 5. Install

From the repo root:

```bash
make install
```

This builds the app, copies the collector to `~/.agent-board/bin`, and starts the app at login.

## 6. Verify

1. `pgrep -x AgentBoard` prints a process id.
2. `~/.agent-board/bin/collect.py --fresh` exits 0.
   Then `~/.agent-board/state.json` has a `cards` list and a `pr_error` of null.
   A `pr_error` that mentions `gh auth login` means step 1 is not done.
3. `~/.agent-board/journal/CURRENT.md` lists the user's recent chats.
   It is empty when the user has no chats from the last 14 days.
4. For each tool with a hook, ask the user to send one prompt in that tool.
   Then check that `~/.agent-board/journal/events.jsonl` has a new line.
   If no line appears for Cursor, ask the user to restart Cursor and try again.
   Claude Code reads hooks when a session starts, so use a new session.

## 7. Hand over

**Tell** the user what is left for them, and only what applies:

- Press ⌥Space to open the panel.
- **Cursor**: the first prompt that the board sends asks for Accessibility access.
  Grant it in System Settings › Privacy & Security › Accessibility.
- **Cursor, if they rebuild often**: each rebuild drops that grant unless the app has a stable signature.
  The README section "Keep the Accessibility grant across rebuilds" explains how. It needs Keychain Access, so the user does it.
- **Optional**: the Chrome extension for "Open PRs as tab group", from `~/.agent-board/chrome-extension`.

Then summarize what you changed and where the backups are.
