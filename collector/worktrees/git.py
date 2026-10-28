"""Slots from plain `git worktree`: every linked worktree of the repos in config.json's `worktreeRepos`.
A linked worktree exists because someone made it, so each one counts as leased, with no holder label."""

import datetime
import os

from common import cd_targets, normalize, run, within
from config import CONFIG

NAME = "git"


def repos():
    return [os.path.realpath(normalize(r)) for r in CONFIG.get("worktreeRepos") or []]


def available():
    return bool(repos())


def parse(porcelain):
    """Linked worktrees from `git worktree list --porcelain`; the first entry is the main checkout."""
    entries, current = [], {}
    for line in porcelain.splitlines() + [""]:
        if not line:
            if current:
                entries.append(current)
            current = {}
        elif line.startswith("worktree "):
            current["path"] = line[len("worktree "):]
        elif line in ("bare", "prunable") or line.startswith("prunable "):
            current["skip"] = True
    return [e for e in entries[1:] if "path" in e and not e.get("skip")]


def created_at(path):
    try:
        st = os.stat(os.path.join(path, ".git"))
    except OSError:
        return None
    return datetime.datetime.fromtimestamp(getattr(st, "st_birthtime", st.st_mtime)).astimezone().isoformat()


def slots(home_repo=None):
    found = {}
    for repo in repos():
        code, out, _ = run(["git", "-C", repo, "worktree", "list", "--porcelain"], timeout=10)
        if code != 0:
            continue
        pool = os.path.basename(repo)
        for wt in parse(out):
            name = os.path.basename(wt["path"])
            found[wt["path"]] = {"pool": pool, "name": name, "display_name": "%s %s" % (pool, name), "path": wt["path"],
                                 "leased": True, "lease_holder": None, "leased_at": created_at(wt["path"])}
    return found


_listed = None


def listed():
    """slots() once per process, for a hook that matches one command's paths."""
    global _listed
    if _listed is None:
        _listed = slots()
    return _listed


def slot_in_command(command, known=None):
    roots = list(known if known is not None else listed())
    hits = [within(t, roots) for t in cd_targets(command)]
    hits = [h for h in hits if h]
    return hits[-1] if hits else None


def slot_in_dir(path, known=None):
    roots = list(known if known is not None else listed())
    return within(os.path.realpath(path), roots) if path else None


def slot_in_output(command, output):
    return None


def holders(command):
    return set()


def give_back(path):
    """Removes the worktree directory; its branch and commits stay in the repo. git refuses a dirty worktree."""
    code, out, err = run(["git", "-C", path, "worktree", "remove", path], timeout=60)
    return code, (out + err).strip() or ("removed" if code == 0 else "git worktree remove failed")
