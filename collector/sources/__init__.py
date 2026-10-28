"""Agent sources: where the board reads chats from, one module per tool. config.json's `tools` lists the ones to read,
by NAME, and the app opens and sends through the tool of the same id. Without the key, the board reads Cursor. Ids
with no source here, such as the app-only `clipboard`, read nothing.

A source is a module with:

  NAME                            the tool id; every card from this source carries it as `tool`
  chats(now, active_ids)          [{"id", "title", "updated_at", "cwd"?}] for chats updated within the retention
                                  window. `active_ids` are chats the journal has events for, which a lagging index may
                                  not list yet. `cwd` is the folder the chat runs in, for tools that resume from it.
  transcripts()                   {chat id: transcript path}, one JSON object per line
  lines(entry)                    for one parsed transcript line, yields ("prompt", text) for what the user typed and
                                  ("shell", text) for each command the agent ran. The board reads PR links, branch
                                  names, and worktree paths from these and keeps none of the text.
  summary(path, now)              {"prompt_ts", "stop_ts", "stop_status"} read from the transcript, for tools whose
                                  transcripts mark turns; None when only hooks report them. stop_status is
                                  "completed", "aborted", or "error".

Optional:

  last_activity(path)             the newest write that shows the chat working; defaults to the transcript's mtime
  family(cards, per, now, index)  (extra cards, {child id: parent id}) for tools with subagents or side chats
  hook(payload)                   a hook payload in journal terms, for journal-hook.py; see that file
  hook_reply(payload)             what the hook prints back to the tool
"""

import os

from config import TOOLS

from . import claude_code, codex, cursor

SOURCES = {m.NAME: m for m in (cursor, claude_code, codex)}


def enabled():
    return [SOURCES[n] for n in TOOLS if n in SOURCES]


def last_activity(source, path):
    if hasattr(source, "last_activity"):
        return source.last_activity(path)
    try:
        return os.path.getmtime(path)
    except (OSError, TypeError):
        return 0
