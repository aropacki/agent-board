"""Slots from treehouse pools (github.com/kunchenguid/treehouse). Each pool keeps its state in
~/.treehouse/<pool>/treehouse-state.json, and a slot's lease holder names the chat that leased it."""

import glob
import os
import re

from common import HOME, normalize, read_json, run

NAME = "treehouse"
STATES = os.path.join(HOME, ".treehouse/*/treehouse-state.json")
SLOT_PATH = r"(?:~|\$HOME|/Users/[^/\s'\"]+)/\.treehouse/[A-Za-z0-9_.-]+/\d+/[A-Za-z0-9_.-]+"
SLOT_RE = re.compile("(%s)" % SLOT_PATH)
CD_RE = re.compile(r"\bcd\s+[\"']?(%s)" % SLOT_PATH)
# treehouse get prints the slot path on a line of its own. Error text that names slots does not.
SLOT_LINE_RE = re.compile(r"^\s*(%s)\s*$" % SLOT_PATH, re.M)
HOLDER_RE = re.compile(r"--lease-holder[=\s]+[\"']?([A-Za-z0-9_.:@/-]+)|\.lease_holder\s*==\s*\\?\"([^\"\\]+)")


def available():
    return bool(glob.glob(STATES))


def label(pool, name, home_repo):
    """Pools are named <repo>-<hash>; slots of the home repo go by number alone."""
    repo = pool.rsplit("-", 1)[0] if "-" in pool else pool
    return "slot %s" % name if repo == home_repo else "%s %s" % (repo, name)


def slots(home_repo=None):
    found = {}
    for state_path in glob.glob(STATES):
        pool = os.path.basename(os.path.dirname(state_path))
        for wt in read_json(state_path, {}).get("worktrees") or []:
            found[wt["path"]] = {
                "pool": pool,
                "name": wt["name"],
                "display_name": label(pool, wt["name"], home_repo),
                "path": wt["path"],
                "leased": bool(wt.get("leased")),
                "lease_holder": wt.get("lease_holder"),
                "leased_at": wt.get("leased_at"),
            }
    return found


def slot_in_command(command, known=None):
    found = CD_RE.findall(command)
    return normalize(found[-1]) if found else None


def slot_in_dir(path, known=None):
    m = SLOT_RE.search(path or "")
    return normalize(m.group(1)) if m else None


def slot_in_output(command, output):
    if "treehouse get" not in command:
        return None
    m = SLOT_LINE_RE.search(output[:4000])
    return normalize(m.group(1)) if m else None


def holders(command):
    return {a or b for a, b in HOLDER_RE.findall(command)}


def give_back(path):
    code, out, err = run(["treehouse", "return", "--force", path], timeout=180)
    return code, (out + err).strip() or ("returned" if code == 0 else "treehouse return failed")
