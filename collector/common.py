"""Helpers and windows shared by the collector core, the agent sources, and the worktree providers."""

import datetime
import json
import os
import re
import subprocess

HOME = os.path.expanduser("~")
RETENTION_S = 14 * 86400
BOARD_WINDOW_S = 2 * 86400
RUNNING_MAX_S = 3 * 3600


def run(cmd, cwd=None, timeout=20):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "timed out after %d seconds" % timeout
    except Exception as e:
        return 1, "", str(e)


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def normalize(p):
    if p.startswith("$HOME"):
        return HOME + p[len("$HOME"):]
    if p.startswith("~"):
        return HOME + p[1:]
    return p


def iso_ts(stamp):
    """Seconds since the epoch for an ISO 8601 time, or 0 when it does not parse."""
    try:
        return datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def ago(seconds):
    if seconds < 90:
        return "just now"
    if seconds < 5400:
        return "%dm ago" % (seconds // 60)
    if seconds < 172800:
        return "%dh ago" % (seconds // 3600)
    return "%dd ago" % (seconds // 86400)


def chat_status(ev, now):
    if ev.get("prompt_ts", 0) > ev.get("stop_ts", 0) and now - ev.get("prompt_ts", 0) < RUNNING_MAX_S:
        return "running"
    if ev.get("stop_status") in ("error", "aborted"):
        return ev["stop_status"]
    return "done" if ev.get("stop_ts") else "idle"


def new_entries(path, offset):
    """(entries, next offset, restarted): the JSON lines a transcript gained past `offset`. A partial last line waits
    for the next call. A file shorter than `offset` was rewritten, so reading starts over and `restarted` tells the
    caller to drop what it built from the old lines. Entries is None when the file is unreadable."""
    try:
        size = os.path.getsize(path)
    except (OSError, TypeError):
        return None, offset, False
    restarted = offset > size
    if restarted:
        offset = 0
    if offset == size:
        return [], offset, restarted
    with open(path, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read(size - offset)
    complete = chunk[:chunk.rfind(b"\n") + 1]
    entries = []
    for line in complete.decode("utf-8", "ignore").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries, offset + len(complete), restarted


CD_RE = re.compile(r"\bcd\s+[\"']?((?:~|\$HOME|/)[^\s\"';&|)]*)")


def cd_targets(command):
    return [normalize(p).rstrip("/") for p in CD_RE.findall(command)]


def within(path, roots):
    """The root that holds `path`, longest first, or None."""
    for root in sorted(roots, key=len, reverse=True):
        if path == root or path.startswith(root + "/"):
            return root
    return None
