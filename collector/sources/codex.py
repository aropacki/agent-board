"""Codex sessions, from ~/.codex/sessions/<y>/<m>/<d>/rollout-<time>-<id>.jsonl and their names in
~/.codex/session_index.jsonl. Rollouts record when each turn starts, finishes, or is aborted, so status needs no
hook."""

import json
import os

from common import HOME, RETENTION_S, iso_ts, new_entries, read_json, write_atomic
from config import BOARD

NAME = "codex"
ROOT = os.path.join(HOME, ".codex")
SESSIONS = os.path.join(ROOT, "sessions")
INDEX = os.path.join(ROOT, "session_index.jsonl")
CACHE = os.path.join(BOARD, "cache", "codex.json")
SHELL_CALLS = ("shell", "exec_command", "local_shell")
_sessions = {}


def names():
    found = {}
    try:
        with open(INDEX, errors="ignore") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("id") and row.get("thread_name"):
                    found[row["id"]] = row["thread_name"]
    except OSError:
        pass
    return found


def transcripts():
    """Rollout file names end in the session id, which is the last five dash-separated parts."""
    found = {}
    for folder, _, files in os.walk(SESSIONS):
        for name in files:
            if name.startswith("rollout-") and name.endswith(".jsonl"):
                found["-".join(name[:-len(".jsonl")].split("-")[-5:])] = os.path.join(folder, name)
    return found


def read(path, info):
    entries, offset, restarted = new_entries(path, info.get("offset", 0))
    if entries is None:
        return None
    if restarted:
        info = {}
    for e in entries:
        payload, at = e.get("payload") or {}, iso_ts(e.get("timestamp"))
        if at:
            info["updated_at"] = max(info.get("updated_at", 0), at)
        if e.get("type") == "session_meta":
            info["cwd"] = payload.get("cwd") or info.get("cwd")
            spawned = payload.get("source") if isinstance(payload.get("source"), dict) else {}
            sub = spawned.get("subagent")
            if sub is not None:
                spawn = sub.get("thread_spawn") or {} if isinstance(sub, dict) else {}
                info["subagent"], info["parent"] = True, spawn.get("parent_thread_id")
                info["nickname"] = spawn.get("agent_nickname") or (sub.get("other") if isinstance(sub, dict) else None)
        elif e.get("type") == "turn_context" and payload.get("cwd"):
            info["cwd"] = payload["cwd"]
        elif e.get("type") == "event_msg":
            kind = payload.get("type")
            if kind == "task_started":
                info["prompt_ts"] = at
            elif kind == "task_complete":
                info["stop_ts"], info["stop_status"] = at, "completed"
            elif kind == "turn_aborted":
                info["stop_ts"], info["stop_status"] = at, "aborted"
    info["offset"] = offset
    return info


def scan(now):
    cache = read_json(CACHE, {})
    fresh = {}
    for sid, path in transcripts().items():
        try:
            if os.path.getmtime(path) < now - RETENTION_S:
                continue
        except OSError:
            continue
        info = read(path, dict(cache.get(path) or {}))
        if info is not None:
            fresh[path] = dict(info, id=sid)
    if fresh != cache:
        write_atomic(CACHE, json.dumps(fresh))
    _sessions.clear()
    _sessions.update(fresh)
    return fresh


def chats(now, active_ids=()):
    titles = names()
    found = [{"id": info["id"], "title": titles.get(info["id"]) or info.get("nickname") or "Untitled chat",
              "updated_at": info.get("updated_at") or info["prompt_ts"], "cwd": info.get("cwd")}
             for info in scan(now).values() if info.get("prompt_ts")]
    return sorted(found, key=lambda c: -c["updated_at"])


def summary(path, now):
    info = _sessions.get(path)
    if not info:
        return None
    return {"prompt_ts": info.get("prompt_ts", 0), "stop_ts": info.get("stop_ts", 0),
            "stop_status": info.get("stop_status")}


def family(cards, per, now, index):
    """Subagent sessions hang under the thread that spawned them and report to it, not to you."""
    by_id = {info["id"]: info for info in _sessions.values()}
    parents = {}
    for card in cards:
        info = by_id.get(card["id"]) or {}
        if info.get("subagent"):
            card["kind"], card["needs_you"] = "subagent", []
            if info.get("parent"):
                parents[card["id"]] = info["parent"]
    return [], parents


def lines(entry):
    """Prompts come from user_message events, which hold what the person typed; user-role response items also carry
    the instruction files Codex injects."""
    payload = entry.get("payload") or {}
    kind = payload.get("type")
    if entry.get("type") == "event_msg" and kind == "user_message":
        yield "prompt", str(payload.get("message") or "")
    if entry.get("type") != "response_item":
        return
    if kind == "custom_tool_call":
        yield "shell", str(payload.get("input") or "")
    elif kind in ("function_call", "local_shell_call") and (payload.get("name") in SHELL_CALLS or kind == "local_shell_call"):
        yield "shell", str(payload.get("arguments") or payload.get("action") or "")
