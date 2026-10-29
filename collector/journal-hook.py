#!/usr/bin/python3
"""Agent hook: append fact-only events to the agent journal. Each tool's hook config runs it with the tool's source
name, `journal-hook.py <tool>`, and that source's hook() turns the payload into the terms below. With no name it reads
a Cursor payload.

Records when a chat submits a prompt, when a turn stops, which worktree slot a chat's shell commands run in, which
lease-holder labels they use, and which PR URLs and branch names a chat touches.
Never records prompt text, command text, or tool output beyond those references,
so the journal holds no agent prose and no secrets.

Journal events, one JSON object per line, each with "ts" (seconds) and "conversation_id":
  {"event": "beforeSubmitPrompt", "roots": [...]}        a prompt was submitted
  {"event": "stop", "status": "completed"|"aborted"|"error"}
  {"event": "slot", "slot_path": path}                   a command ran in or cd'd into a slot
  {"event": "lease", "holders": [label, ...]}            lease-holder labels a command used
  {"event": "ref", "role": "prompt"|"created"|"command"|"branch"|"transcript",
   "prs": ["owner/repo#n"], "pr_numbers": [...], "verb": ..., "branches": [...]}
"""

import fcntl
import json
import os
import re
import sys
import time

import sources
import worktrees
from config import BOARD
from refs import branches, pr_numbers, pr_urls, pr_verb

JOURNAL = os.path.join(BOARD, "journal", "events.jsonl")
# `gh stack submit` opens a PR for each branch of the stack and prints every link.
CREATE_PR_RE = re.compile(r"\bgh\s+(?:pr\s+create|stack\s+submit)\b")


def slot_of(h, wt):
    for d in h.get("dirs") or []:
        found = wt.slot_in_dir(d)
        if found:
            return found
    return wt.slot_in_command(h["command"]) or wt.slot_in_output(h["command"], h.get("output") or "")


def journal_records(h):
    base = {"ts": int(time.time()), "conversation_id": h["conversation_id"]}
    out = []
    if h["event"] == "prompt":
        out.append(dict(base, event="beforeSubmitPrompt", roots=h.get("roots") or []))
        prs = sorted(pr_urls(h.get("prompt") or ""))
        if prs:
            out.append(dict(base, event="ref", role="prompt", prs=prs))
    elif h["event"] == "stop":
        out.append(dict(base, event="stop", status=h.get("status")))
    elif h["event"] == "tool":
        wt = worktrees.provider()
        command = h.get("command") or ""
        slot = slot_of(h, wt)
        if slot:
            out.append(dict(base, event="slot", slot_path=slot))
        labels = sorted(wt.holders(command))
        if labels:
            out.append(dict(base, event="lease", holders=labels))
        if CREATE_PR_RE.search(command) or "create_pull_request" in (h.get("tool") or ""):
            created = sorted(pr_urls((h.get("output") or "")[:20000]))
            if created:
                out.append(dict(base, event="ref", role="created", prs=created))
        elif pr_verb(command):
            prs, nums = sorted(pr_urls(command)), sorted(pr_numbers(command))
            if prs or nums:
                out.append(dict(base, event="ref", role="command", verb=pr_verb(command), prs=prs, pr_numbers=nums))
        names = sorted(branches(command))
        if names:
            out.append(dict(base, event="ref", role="branch", branches=names))
    return out


def append(records):
    try:
        os.makedirs(os.path.dirname(JOURNAL), exist_ok=True)
        with open(JOURNAL, "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            for r in records:
                fh.write(json.dumps(r) + "\n")
            fcntl.flock(fh, fcntl.LOCK_UN)
    except Exception:
        pass


def main():
    source = sources.SOURCES.get(sys.argv[1] if len(sys.argv) > 1 else "cursor")
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {}
    payload = payload if isinstance(payload, dict) else {}
    if source is not None and hasattr(source, "hook"):
        try:
            h = source.hook(payload)
            if h:
                append(journal_records(h))
        except Exception:
            pass
        # Some tools add a prompt hook's output to the chat, so an empty reply prints nothing.
        reply = source.hook_reply(payload)
        if reply:
            print(reply)
    sys.exit(0)


if __name__ == "__main__":
    main()
