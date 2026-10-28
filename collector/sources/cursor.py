"""Cursor chats. The chat list comes from Cursor's search index, names and subagent links from its own record of each
chat, and status from the journal its hooks write (install/cursor-hooks.json)."""

import json
import os
import re
import sqlite3

from common import BOARD_WINDOW_S, HOME, RETENTION_S, ago, chat_status

NAME = "cursor"
GLOBAL = os.path.join(HOME, "Library/Application Support/Cursor/User/globalStorage")
CONV_DB = os.path.join(GLOBAL, "conversation-search.db")
STATE_DB = os.path.join(GLOBAL, "state.vscdb")
PROJECTS = os.path.join(HOME, ".cursor/projects")
SIDE_CHAT = 0
# A subagent's record never says it is working; only its transcript growing does, and a long tool call writes nothing.
SUBAGENT_QUIET_S = 180


def chats(now, active_ids=()):
    """Chats from the search index, plus chats the hook saw that the index has not caught up with."""
    try:
        db = sqlite3.connect("file:%s?mode=ro" % CONV_DB, uri=True, timeout=5)
        rows = db.execute(
            "select id, title, updated_at from conversations "
            "where source = 'local' and is_archived = 0 and updated_at >= ? "
            "order by updated_at desc",
            (int((now - RETENTION_S) * 1000),),
        ).fetchall()
        db.close()
    except Exception:
        rows = []
    found = [{"id": r[0], "title": r[1] or "Untitled chat", "updated_at": r[2] / 1000.0} for r in rows]
    indexed = {c["id"] for c in found}
    found += unindexed_chats([i for i in active_ids if i not in indexed], now)
    return sorted(found, key=lambda c: -c["updated_at"])


def composer_fields(ids, paths):
    """Fields of Cursor's own record of each chat, read by exact key only: the state database runs to tens of
    gigabytes, so any scan stalls the collector."""
    if not ids:
        return {}
    try:
        db = sqlite3.connect("file:%s?mode=ro" % STATE_DB, uri=True, timeout=5)
        rows = db.execute(
            "select substr(key, 14), %s from cursorDiskKV where key in (%s)"
            % (", ".join("json_extract(value, ?)" for _ in paths), ",".join("?" * len(ids))),
            list(paths) + ["composerData:" + i for i in ids],
        ).fetchall()
        db.close()
    except Exception:
        return {}
    return {r[0]: r[1:] for r in rows}


def unindexed_chats(ids, now):
    rows = composer_fields(list(ids), ["$.name", "$.lastUpdatedAt", "$.isArchived"])
    return [{"id": cid, "title": name or "Untitled chat", "updated_at": updated / 1000.0}
            for cid, (name, updated, archived) in rows.items()
            if updated and not archived and updated / 1000.0 >= now - RETENTION_S]


def transcripts():
    """Chat id to transcript path, from one listing of each project's transcripts directory.
    Globbing per chat stats every project directory once for every chat."""
    found = {}
    try:
        projects = os.scandir(PROJECTS)
    except OSError:
        return found
    with projects:
        for project in projects:
            root = os.path.join(project.path, "agent-transcripts")
            try:
                names = os.listdir(root)
            except OSError:
                continue
            for name in names:
                found.setdefault(name, os.path.join(root, name, name + ".jsonl"))
    return found


def lines(entry):
    """What one transcript line says: the user's prompts and the shell commands the agent ran."""
    for part in (entry.get("message") or {}).get("content") or []:
        if entry.get("role") == "user" and part.get("type") == "text":
            query = re.search(r"<user_query>(.*?)</user_query>", part.get("text") or "", re.S)
            yield "prompt", query.group(1) if query else ""
        elif part.get("type") == "tool_use" and part.get("name") == "Shell":
            yield "shell", str((part.get("input") or {}).get("command") or "")


def summary(path, now):
    """The hooks report every prompt and stop, so the transcript adds nothing to the journal."""
    return None


def last_activity(transcript):
    """The newest write to a chat's transcript or to any of its subagents' transcripts."""
    try:
        latest = os.path.getmtime(transcript)
    except (OSError, TypeError):
        return 0
    try:
        with os.scandir(os.path.join(os.path.dirname(transcript), "subagents")) as entries:
            latest = max([latest] + [e.stat().st_mtime for e in entries])
    except OSError:
        pass
    return latest


def subagent_activity(parent_transcript, sid):
    try:
        return os.path.getmtime(os.path.join(os.path.dirname(parent_transcript), "subagents", sid + ".jsonl"))
    except (OSError, TypeError):
        return 0


def family(cards, per, now, index):
    """Each board chat's parent, plus cards for the recent subagents of board chats that the board lacks."""
    ids = [c["id"] for c in cards]
    links = composer_fields(ids, ["$.subagentInfo.parentComposerId", "$.subagentInfo.subagentType",
                                  "$.subagentComposerIds"])
    parents, kinds = {}, {}
    for cid, (parent, kind, _) in links.items():
        if parent:
            parents[cid], kinds[cid] = parent, "side" if kind == SIDE_CHAT else "subagent"
    status_of = {c["id"]: c["status"] for c in cards}
    owner = {sub: cid for cid, (_, _, subs) in links.items() for sub in json.loads(subs or "[]") if sub not in status_of}
    extra = []
    fields = ["$.name", "$.lastUpdatedAt", "$.createdAt", "$.status", "$.isArchived"]
    for sid, (name, updated, created, state, archived) in composer_fields(list(owner), fields).items():
        active = subagent_activity(index.get(owner[sid]), sid)
        at = max(active, (updated or created or 0) / 1000.0)
        if archived or now - at >= BOARD_WINDOW_S:
            continue
        if sid in per:
            status = chat_status(per[sid], now)
        elif state in ("error", "aborted"):
            status = state
        elif state != "completed" and status_of[owner[sid]] == "running" and now - active < SUBAGENT_QUIET_S:
            status = "running"
        else:
            status = "done"
        parents[sid], kinds[sid] = owner[sid], "subagent"
        extra.append({"hidden": False, "id": sid, "title": name or "Subagent", "updated_at": at,
                      "updated_ago": ago(now - at), "status": status, "needs_you": [], "slot": None, "prs": [],
                      "tool": NAME})
    for c in cards + extra:
        if c["id"] in kinds:
            c["kind"] = kinds[c["id"]]
            if c["kind"] == "subagent":
                # A subagent reports to its parent chat, not to you.
                c["needs_you"] = []
    return extra, parents


def hook(payload):
    """A Cursor hook payload in the journal's terms, or None for one without a chat."""
    conv = payload.get("conversation_id") or payload.get("conversationId")
    if not conv:
        return None
    event = payload.get("hook_event_name") or ""
    if event == "beforeSubmitPrompt":
        return {"event": "prompt", "conversation_id": conv, "prompt": str(payload.get("prompt") or ""),
                "roots": payload.get("workspace_roots") or []}
    if event == "stop":
        return {"event": "stop", "conversation_id": conv, "status": payload.get("status")}
    if event == "postToolUse":
        ti = payload.get("tool_input") or {}
        if isinstance(ti, str):
            try:
                ti = json.loads(ti)
            except ValueError:
                ti = {"command": ti}
        ti = ti if isinstance(ti, dict) else {}
        return {"event": "tool", "conversation_id": conv, "command": str(ti.get("command") or ""),
                "dirs": [str(ti.get(k) or payload.get(k) or "") for k in ("working_directory", "cwd")],
                "output": str(payload.get("tool_output") or ""),
                "tool": str(payload.get("tool_name") or "") + " " + json.dumps(ti)[:2000]}
    return None


def hook_reply(payload):
    return json.dumps({"continue": True} if payload.get("hook_event_name") == "beforeSubmitPrompt" else {})
