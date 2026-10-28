"""Claude Code sessions, from ~/.claude/projects/<folder>/<session id>.jsonl. The transcript records each prompt and
each finished turn, so status needs no hook; install/claude-code-hooks.json adds live slot and PR facts."""

import json
import os

from common import HOME, RETENTION_S, iso_ts, new_entries, read_json, write_atomic
from config import BOARD

NAME = "claude-code"
PROJECTS = os.path.join(HOME, ".claude/projects")
CACHE = os.path.join(BOARD, "cache", "claude-code.json")
INTERRUPTED = "[Request interrupted by user"
_sessions = {}


def transcripts():
    found = {}
    try:
        projects = os.scandir(PROJECTS)
    except OSError:
        return found
    with projects:
        for project in projects:
            try:
                names = os.listdir(project.path)
            except OSError:
                continue
            for name in names:
                if name.endswith(".jsonl"):
                    found.setdefault(name[:-len(".jsonl")], os.path.join(project.path, name))
    return found


def text_of(content):
    """A message's text, or None when it holds only tool results."""
    if isinstance(content, str):
        return content
    texts = [p.get("text") or "" for p in content or [] if isinstance(p, dict) and p.get("type") == "text"]
    return "\n".join(texts) if texts else None


def read(path, info):
    """Folds the lines the transcript gained into `info`: title, folder, and the newest prompt and finished turn."""
    entries, offset, restarted = new_entries(path, info.get("offset", 0))
    if entries is None:
        return None
    if restarted:
        info = {}
    for e in entries:
        kind, at = e.get("type"), iso_ts(e.get("timestamp"))
        if kind == "custom-title":
            info["custom_title"] = e.get("customTitle")
        elif kind == "ai-title":
            info["ai_title"] = e.get("aiTitle")
        if e.get("cwd"):
            info["cwd"] = e["cwd"]
        if at:
            info["updated_at"] = max(info.get("updated_at", 0), at)
        if e.get("isSidechain"):
            continue
        message = e.get("message") or {}
        if kind == "user":
            text = text_of(message.get("content"))
            if text is None:
                continue
            if text.startswith(INTERRUPTED):
                info["stop_ts"], info["stop_status"] = at, "aborted"
            else:
                info["prompt_ts"] = at
        elif kind == "assistant" and message.get("stop_reason") in ("end_turn", "stop_sequence", "max_tokens"):
            info["stop_ts"], info["stop_status"] = at, "completed"
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
    found = []
    for info in scan(now).values():
        if not info.get("prompt_ts"):
            continue
        found.append({"id": info["id"], "title": info.get("custom_title") or info.get("ai_title") or "Untitled chat",
                      "updated_at": info.get("updated_at") or info["prompt_ts"], "cwd": info.get("cwd")})
    return sorted(found, key=lambda c: -c["updated_at"])


def summary(path, now):
    info = _sessions.get(path)
    if not info:
        return None
    return {"prompt_ts": info.get("prompt_ts", 0), "stop_ts": info.get("stop_ts", 0),
            "stop_status": info.get("stop_status")}


def lines(entry):
    message = entry.get("message") or {}
    if entry.get("type") == "user":
        text = text_of(message.get("content"))
        if text:
            yield "prompt", text
    elif entry.get("type") == "assistant":
        for part in message.get("content") or []:
            if isinstance(part, dict) and part.get("type") == "tool_use" and part.get("name") == "Bash":
                yield "shell", str((part.get("input") or {}).get("command") or "")


def hook(payload):
    conv = payload.get("session_id")
    if not conv:
        return None
    event = payload.get("hook_event_name") or ""
    if event == "UserPromptSubmit":
        return {"event": "prompt", "conversation_id": conv, "prompt": str(payload.get("prompt") or "")}
    if event == "Stop":
        return {"event": "stop", "conversation_id": conv, "status": "completed"}
    if event == "PostToolUse":
        ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        response = payload.get("tool_response")
        output = json.dumps(response) if isinstance(response, (dict, list)) else str(response or "")
        command = str(ti.get("command") or "") if payload.get("tool_name") == "Bash" else ""
        return {"event": "tool", "conversation_id": conv, "command": command, "dirs": [str(payload.get("cwd") or "")],
                "output": output, "tool": str(payload.get("tool_name") or "") + " " + json.dumps(ti)[:2000]}
    return None


def hook_reply(payload):
    return ""
