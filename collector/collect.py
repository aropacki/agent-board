#!/usr/bin/python3
"""Agent board collector.

Merges chats from each agent source (sources/), journal events, worktree slots (worktrees/), git state, and GitHub
PRs into ~/.agent-board/state.json (read by the board app) and ~/.agent-board/journal/CURRENT.md (read by agents).

Usage:
  collect.py                 refresh state.json and CURRENT.md
  collect.py return <path>   free a worktree slot after re-checking it is safe
  collect.py backfill        record PR and branch references from existing transcripts once
"""

import calendar
import datetime
import fcntl
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sources  # noqa: E402
import worktrees  # noqa: E402
from common import BOARD_WINDOW_S, RETENTION_S, ago, chat_status, new_entries, read_json, run, write_atomic  # noqa: E402
from config import BOARD, BOT_ACCOUNTS, CONFIG, HIDDEN_PRS  # noqa: E402
from refs import OWNING_VERBS, branches, pr_numbers, pr_urls, pr_verb  # noqa: E402

JOURNAL_DIR = os.path.join(BOARD, "journal")
EVENTS = os.path.join(JOURNAL_DIR, "events.jsonl")
CURRENT = os.path.join(JOURNAL_DIR, "CURRENT.md")
STATE = os.path.join(BOARD, "state.json")
SEEN = os.path.join(BOARD, "seen.json")
DISMISSED = os.path.join(BOARD, "dismissed.json")
CACHE_DIR = os.path.join(BOARD, "cache")
PR_CACHE = os.path.join(CACHE_DIR, "prs-v2.json")
PR_NODES = os.path.join(CACHE_DIR, "pr-nodes.json")
LINKED_WANTED = os.path.join(CACHE_DIR, "linked-prs.json")
REQUIRED_DIR = os.path.join(CACHE_DIR, "required-checks")
BACKFILL_MARKER = os.path.join(CACHE_DIR, "backfill-done")
HIDDEN_CHATS = os.path.join(BOARD, "hidden-chats.json")
STALE_S = 7 * 86400
TRANSCRIPT_CACHE = os.path.join(CACHE_DIR, "transcript-slots.json")

PR_TTL_S = 60
GIT_TTL_S = 300
LINKED_MAX = 30
SEARCH_MAX = 60
MISS_LIMIT = 3
# A PR's updatedAt misses some changes, resolving a thread among them, so full details are refetched this often anyway.
FULL_MAX_AGE_S = 600
LIGHT_BATCH = 40
PR_LOG = os.path.join(CACHE_DIR, "pr-refresh.jsonl")
PR_LOG_KEEP = 500
LSOF_TTL_S = 60
LSOF_CACHE = os.path.join(CACHE_DIR, "lsof.json")
GIT_CACHE = os.path.join(CACHE_DIR, "git.json")
FRESH = "--fresh" in sys.argv
SHELLS = {"zsh", "bash", "sh", "fish", "-zsh", "-bash", "login"}

os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", "")


# ---------- chats ----------

def load_chats(now, active_ids=()):
    """Every enabled source's chats, newest first, each tagged with the tool it came from."""
    chats = []
    for source in sources.enabled():
        for chat in source.chats(now, active_ids):
            chats.append(dict(chat, tool=source.NAME))
    return sorted(chats, key=lambda c: -c["updated_at"])


# A finished turn writes its transcript within seconds of its stop. A write well after means the chat woke without a
# prompt, as a parent does each time one of its background subagents reports back.
RESUME_SLACK_S = 15
QUIET_S = 180


def live_status(ev, transcript, now, source):
    status = chat_status(ev, now)
    if status == "running" or not ev.get("stop_ts"):
        return status
    active = sources.last_activity(source, transcript)
    return "running" if active > ev["stop_ts"] + RESUME_SLACK_S and now - active < QUIET_S else status


def chat_family(cards, per, now, index):
    """Parents and extra cards from each source that has subagents or side chats."""
    extra, parents = [], {}
    for source in sources.enabled():
        if hasattr(source, "family"):
            mine = [c for c in cards if c.get("tool") == source.NAME]
            e, p = source.family(mine, per, now, index)
            extra += e
            parents.update(p)
    return extra, parents


def group_rank(card):
    members = [card] + card.get("children", [])
    if any(m["status"] == "running" for m in members):
        return 1
    return 0 if any(m["needs_you"] for m in members) else 2


def nest_chats(cards, parents):
    """Hang each chat under the top chat of its family on the board, newest first; a chat whose parent is off the
    board stands alone. A family sits with its most urgent member, at its newest member's place."""
    by_id = {c["id"]: c for c in cards}

    def root(cid):
        seen = {cid}
        while parents.get(cid) in by_id and parents[cid] not in seen:
            cid = parents[cid]
            seen.add(cid)
        return cid

    top = []
    for c in cards:
        r = root(c["id"])
        if r == c["id"]:
            top.append(c)
        else:
            by_id[r].setdefault("children", []).append(c)
    for c in top:
        kids = c.get("children", [])
        kids.sort(key=lambda k: -k["updated_at"])
        have = {p["key"] for p in c["prs"]}
        c["prs"] = c["prs"] + [p for k in kids for p in k["prs"] if p["key"] not in have and not have.add(p["key"])]
    top.sort(key=lambda c: (group_rank(c), -max([c["updated_at"]] + [k["updated_at"] for k in c.get("children", [])])))
    return top


# ---------- journal ----------

def load_events(now):
    """Read events and prune anything past retention, under the same lock the hook uses."""
    if not os.path.exists(EVENTS):
        return []
    cutoff = now - RETENTION_S
    with open(EVENTS, "r+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        lines = fh.readlines()
        events, keep = [], []
        for line in lines:
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("ts", 0) >= cutoff:
                events.append(ev)
                keep.append(line)
        if len(keep) != len(lines):
            fh.seek(0)
            fh.writelines(keep)
            fh.truncate()
        fcntl.flock(fh, fcntl.LOCK_UN)
    return events


def empty_summary():
    return {"prompt_ts": 0, "stop_ts": 0, "stop_status": None, "slot_path": None, "slot_ts": 0,
            "prs": {}, "pr_numbers": set(), "branches": set(), "holders": set()}


def summarize_events(events):
    per = {}
    for ev in events:
        c = ev.get("conversation_id")
        if not c:
            continue
        s = per.setdefault(c, empty_summary())
        if ev["event"] == "beforeSubmitPrompt":
            s["prompt_ts"] = max(s["prompt_ts"], ev["ts"])
        elif ev["event"] == "stop" and ev["ts"] >= s["stop_ts"]:
            s["stop_ts"], s["stop_status"] = ev["ts"], ev.get("status")
        elif ev["event"] == "slot" and ev["ts"] >= s["slot_ts"]:
            s["slot_ts"], s["slot_path"] = ev["ts"], ev.get("slot_path")
        elif ev["event"] == "lease":
            s["holders"].update(ev.get("holders") or [])
        elif ev["event"] == "ref":
            if ev.get("role") == "command" and ev.get("verb") not in OWNING_VERBS:
                continue
            for key in ev.get("prs") or []:
                s["prs"].setdefault(key, ev.get("role"))
                if ev.get("role") == "created":
                    s["prs"][key] = "created"
            s["pr_numbers"].update(ev.get("pr_numbers") or [])
            s["branches"].update(ev.get("branches") or [])
    return per


def transcript_refs(path, source):
    """Strict references from one transcript: PR URLs in the user's prompts, PR URLs and
    numbers in gh pr commands, and namespaced branches the chat switched to or pushed."""
    prs, nums, names = set(), set(), set()
    entries, _, _ = new_entries(path, 0)
    for entry in entries or []:
        for kind, text in source.lines(entry):
            if kind == "prompt":
                prs |= pr_urls(text)
            elif kind == "shell":
                if pr_verb(text):
                    prs |= pr_urls(text)
                    nums |= pr_numbers(text)
                names |= branches(text)
    return prs, nums, names


def transcript_index(chats):
    """Chat id to (source, transcript path) for every enabled source's chats."""
    tools = {c["id"]: c["tool"] for c in chats}
    index = {}
    for source in sources.enabled():
        for cid, path in source.transcripts().items():
            if tools.get(cid, source.NAME) == source.NAME:
                index.setdefault(cid, path)
    return index


def backfill(now):
    records = []
    chats = load_chats(now)
    index = transcript_index(chats)
    for chat in chats:
        path = index.get(chat["id"])
        if not path or not os.path.exists(path):
            continue
        prs, nums, names = transcript_refs(path, sources.SOURCES[chat["tool"]])
        if prs or nums or names:
            records.append({"ts": int(chat["updated_at"]), "conversation_id": chat["id"], "event": "ref",
                            "role": "transcript", "prs": sorted(prs), "pr_numbers": sorted(nums),
                            "branches": sorted(names)})
    os.makedirs(JOURNAL_DIR, exist_ok=True)
    with open(EVENTS, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        for r in records:
            fh.write(json.dumps(r) + "\n")
        fcntl.flock(fh, fcntl.LOCK_UN)
    write_atomic(BACKFILL_MARKER, str(int(now)))
    print("recorded references for %d chats" % len(records))


# Bump when refs.py or a source's lines() reads transcripts differently, so cached facts are read again.
FACTS_VERSION = 2


def transcript_facts(chat_id, cache, index, source, wt, known):
    """What a chat's transcript says: the last slot its shell commands cd'd into, every lease-holder label they used,
    and the PRs and branches it touched. Reads only what the transcript gained since the last call, so a long running
    chat costs little."""
    facts = cache.get(chat_id) or {}
    if facts.get("version") != FACTS_VERSION:
        facts = {}
    entries, offset, restarted = new_entries(index.get(chat_id), facts.get("offset", 0))
    if entries is None:
        return {}
    if restarted:
        facts = {}
    if offset == facts.get("offset", 0) and facts:
        return facts
    slot, holders = facts.get("slot"), set(facts.get("holders", []))
    prs, nums, names = set(facts.get("prs", [])), set(facts.get("pr_numbers", [])), set(facts.get("branches", []))
    for entry in entries:
        for kind, text in source.lines(entry):
            if kind == "prompt":
                prs |= pr_urls(text)
                continue
            holders |= wt.holders(text)
            slot = wt.slot_in_command(text, known) or slot
            if pr_verb(text):
                prs |= pr_urls(text)
                nums |= pr_numbers(text)
            names |= branches(text)
    facts = {"version": FACTS_VERSION, "offset": offset, "slot": slot, "holders": sorted(holders), "prs": sorted(prs),
             "pr_numbers": sorted(nums), "branches": sorted(names)}
    cache[chat_id] = facts
    return facts


def merge_transcript(per, chat, summary, facts):
    """Folds what a transcript says into the chat's journal summary. The transcript's PRs and branches count for
    every tool, since it keeps the commands a hook may have missed; its turns count only when `summary` reads them.
    A chat with nothing to add gets no summary, because having one is what shows an untitled chat."""
    summary = summary or {}
    if not (summary or any(facts.get(k) for k in ("prs", "pr_numbers", "branches"))):
        return
    s = per.setdefault(chat["id"], empty_summary())
    if summary.get("prompt_ts", 0) > s["prompt_ts"]:
        s["prompt_ts"] = summary["prompt_ts"]
    if summary.get("stop_ts", 0) > s["stop_ts"]:
        s["stop_ts"], s["stop_status"] = summary["stop_ts"], summary.get("stop_status")
    for key in facts.get("prs", []):
        s["prs"].setdefault(key, "transcript")
    s["pr_numbers"].update(facts.get("pr_numbers", []))
    s["branches"].update(facts.get("branches", []))


# ---------- slots ----------

def lease_start(slot):
    """When the current lease began, or 0 for an unleased slot or an unreadable time."""
    if not slot.get("leased") or not slot.get("leased_at"):
        return 0
    try:
        return datetime.datetime.fromisoformat(slot["leased_at"]).timestamp()
    except ValueError:
        return 0


def claim_slots(chats, per, slots, facts):
    """Chat id -> the slot it works in.

    A lease with a holder label belongs to the chat whose commands used that label: the label is
    the one fact a provider records about who leased the slot. Path evidence (a cd, a printed slot)
    decides the other slots, but only when it is newer than the current lease, because a returned
    slot is reset, and never from a chat that leases under another label, because that chat only
    looked inside."""
    holders = {c["id"]: set(facts.get(c["id"], {}).get("holders", ())) | set(per.get(c["id"], {}).get("holders", ()))
               for c in chats}
    labeled = {p: s for p, s in slots.items() if s["leased"] and s.get("lease_holder")}
    claims = {}
    for chat in chats:
        for path, slot in labeled.items():
            if (slot["lease_holder"] in holders[chat["id"]] and chat["updated_at"] >= lease_start(slot)
                    and chat["updated_at"] > claims.get(path, ("", 0))[1]):
                claims[path] = (chat["id"], chat["updated_at"])
    by_label = set(claims)
    for chat in chats:
        ev = per.get(chat["id"], {})
        path, evidence_ts = ev.get("slot_path"), ev.get("slot_ts", 0)
        if not path:
            path, evidence_ts = facts.get(chat["id"], {}).get("slot"), chat["updated_at"]
        if path not in slots or path in by_label:
            continue
        if path in labeled and holders[chat["id"]]:
            continue
        if evidence_ts > claims.get(path, ("", 0))[1] and evidence_ts >= lease_start(slots[path]):
            claims[path] = (chat["id"], evidence_ts)
    return {cid: path for path, (cid, _) in claims.items()}


def load_slots(wt):
    return wt.slots((CONFIG.get("homeRepo") or "").rsplit("/", 1)[-1] or None)


def git_fingerprint(path):
    """Mtimes that move on stage, commit, checkout, or reset. Costs a few stats, not a tree scan."""
    dot = os.path.join(path, ".git")
    try:
        if os.path.isfile(dot):
            gitdir = open(dot).read().split("gitdir:", 1)[1].strip()
            gitdir = gitdir if os.path.isabs(gitdir) else os.path.join(path, gitdir)
        else:
            gitdir = dot
    except (OSError, IndexError):
        return None
    marks = []
    for name in ("index", "HEAD", os.path.join("logs", "HEAD")):
        try:
            marks.append(os.stat(os.path.join(gitdir, name)).st_mtime_ns)
        except OSError:
            marks.append(0)
    return marks


NO_GIT = {"branch": None, "dirty": None, "pushed": None, "ahead": None}


def git_info(path):
    """None when git timed out, so the caller keeps the last answer instead of a slot with no branch."""
    info = dict(NO_GIT)
    if not os.path.isdir(path):
        return info
    code, out, err = run(["git", "symbolic-ref", "--short", "-q", "HEAD"], cwd=path)
    if err.startswith("timed out"):
        return None
    info["branch"] = out.strip() if code == 0 and out.strip() else None
    # Without --no-optional-locks, status takes index.lock to save refreshed stat data, which fails an
    # agent's rebase or commit in this slot. The probe runs exactly when the index moves, so it collides.
    code, out, err = run(["git", "--no-optional-locks", "status", "--porcelain"], cwd=path, timeout=60)
    if err.startswith("timed out"):
        return None
    info["dirty"] = bool(out.strip()) if code == 0 else None
    if info["branch"]:
        upstream = None
        code, out, _ = run(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd=path)
        if code == 0 and out.strip():
            upstream = out.strip()
        else:
            code, _, _ = run(["git", "rev-parse", "--verify", "-q", "refs/remotes/origin/" + info["branch"]], cwd=path)
            if code == 0:
                upstream = "origin/" + info["branch"]
        if upstream:
            code, out, _ = run(["git", "rev-list", "--count", upstream + "..HEAD"], cwd=path)
            if code == 0:
                info["ahead"] = int(out.strip() or 0)
                info["pushed"] = info["ahead"] == 0
        else:
            info["pushed"] = False
    return info


def processes_by_cwd(now):
    cached = read_json(LSOF_CACHE, {})
    if not FRESH and now - cached.get("at", 0) < LSOF_TTL_S:
        return [tuple(p) for p in cached.get("procs", [])]
    procs = scan_processes()
    write_atomic(LSOF_CACHE, json.dumps({"at": now, "procs": procs}))
    return procs


def scan_processes():
    code, out, _ = run(["lsof", "-a", "-d", "cwd", "-F", "pcn", "-w"], timeout=20)
    procs, pid, cmd = [], None, None
    for line in out.splitlines():
        if line.startswith("p"):
            pid, cmd = line[1:], None
        elif line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("n") and pid:
            procs.append((pid, cmd or "?", line[1:]))
    return procs


def slot_processes(path, procs):
    prefix = path.rstrip("/") + "/"
    hits = [(pid, cmd) for pid, cmd, cwd in procs if cwd == path or cwd.startswith(prefix)]
    blocking = sorted({cmd for _, cmd in hits if cmd not in SHELLS})
    return {"count": len(hits), "blocking": blocking}


# ---------- PRs ----------

PR_CI = """
  commits(last: 1) {
    nodes {
      commit {
        committedDate
        status { contexts { context state } }
        statusCheckRollup { contexts(first: 100) { nodes { ... on CheckRun { name status conclusion startedAt } } } }
      }
    }
  }
"""
PR_FRAGMENT = """
fragment pr on PullRequest {
  number title url state updatedAt isDraft reviewDecision baseRefName headRefName
  author { login }
  repository { nameWithOwner }
  reviewThreads(first: 100) {
    nodes {
      isResolved isOutdated comments(first: 1) { nodes { url } }
      latest: comments(last: 5) { nodes { author { login __typename } createdAt url bodyText } }
    }
  }
  comments(last: 20) { nodes { author { login __typename } createdAt url bodyText } }
  reviews(last: 20) { nodes { author { login __typename } submittedAt url bodyText } }
%s}
""" % PR_CI
# CI changes without moving updatedAt, so a PR whose updatedAt held still needs only this.
PR_LIGHT = "fragment light on PullRequest { number state updatedAt\n%s}\n" % PR_CI
PR_SEARCHES = {
    "mine": "is:pr is:open archived:false author:@me sort:updated-desc",
    "review": "is:pr is:open archived:false user-review-requested:@me sort:updated-desc",
}
FAILED = {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"}


def run_ci(check):
    if check is None:
        return None
    if check.get("status") != "COMPLETED":
        return "running"
    if check.get("conclusion") == "SUCCESS":
        return "passing"
    if check.get("conclusion") == "CANCELLED":
        return "cancelled"
    return "failing" if check.get("conclusion") in FAILED else "none"


def status_ci(state):
    if state is None:
        return None
    if state == "SUCCESS":
        return "passing"
    return "failing" if state in ("FAILURE", "ERROR") else "running"


def newest_run(runs, name):
    """A rerun leaves the superseded run behind; a queued run has no startedAt yet."""
    matching = sorted((r for r in runs if r.get("name") == name), key=lambda r: r.get("startedAt") or "9999")
    return matching[-1] if matching else None


def rollup_ci(statuses, runs):
    """Every check on the commit, newest run per name: any failure fails, then any still running.
    Skipped, neutral, and cancelled checks do not count; a newer push usually cancels a run."""
    results = [run_ci(newest_run(runs, name)) for name in {r["name"] for r in runs}]
    results += [status_ci(st.get("state")) for st in statuses]
    for verdict in ("failing", "running", "passing"):
        if verdict in results:
            return verdict
    return "none"


def pr_ci(commit, required):
    """The base branch's required checks decide once they have all posted. Until then, or
    with no rules, the rollup of every check stands in."""
    statuses = (commit.get("status") or {}).get("contexts") or []
    runs = [n for n in ((commit.get("statusCheckRollup") or {}).get("contexts") or {}).get("nodes") or [] if n and n.get("name")]
    results = []
    for name in required:
        state = next((st.get("state") for st in statuses if st.get("context") == name), None)
        results.append(status_ci(state) or run_ci(newest_run(runs, name)))
    if required and all(r is not None for r in results):
        if "failing" in results or "cancelled" in results:
            return "failing"
        if "running" in results:
            return "running"
        return "passing" if all(r == "passing" for r in results) else "none"
    return rollup_ci(statuses, runs)


def required_checks(repo, base, now):
    path = os.path.join(REQUIRED_DIR, "%s_%s.json" % (repo.replace("/", "_"), base.replace("/", "_")))
    cached = read_json(path, None)
    if cached and now - cached.get("at", 0) < 86400:
        return cached["required"]
    code, out, _ = run(["gh", "api", "repos/%s/rules/branches/%s" % (repo, quote(base, safe="")),
                        "--jq", "[.[] | select(.type == \"required_status_checks\") | .parameters.required_status_checks[].context]"])
    try:
        required = json.loads(out) if code == 0 else []
    except Exception:
        required = []
    write_atomic(path, json.dumps({"at": now, "required": required}))
    return required


def gh_error(err):
    """The first non-empty line of gh's stderr, short enough for a toast."""
    lines = [line.strip() for line in (err or "").splitlines() if line.strip()]
    return (lines[0] if lines else "gh exited with an error")[:160]


UNREADABLE = "GitHub sent a response the board could not read"
DETAIL_BATCH = 6


def search_prs(query):
    """(repo, number) pairs in the search's order, or (None, why) when GitHub fails."""
    gql = 'query { search(query: "%s", type: ISSUE, first: %d) { nodes { ... on PullRequest { number repository { nameWithOwner } } } } }' % (query, SEARCH_MAX)
    code, out, err = run(["gh", "api", "graphql", "-f", "query=" + gql], timeout=30)
    if code != 0:
        return None, gh_error(err)
    try:
        return [(n["repository"]["nameWithOwner"], n["number"]) for n in json.loads(out)["data"]["search"]["nodes"]
                if n and n.get("number")], None
    except Exception:
        return None, UNREADABLE


def gh_time(stamp):
    return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")) if stamp else 0


def feedback(n, owner):
    """What people other than the PR's author wrote on it, newest first, and when its author last wrote.
    A review's own body counts only when it has text; its line comments arrive through the threads."""
    notes = [(c, c.get("createdAt")) for c in (n.get("comments") or {}).get("nodes") or []]
    notes += [(r, r.get("submittedAt")) for r in (n.get("reviews") or {}).get("nodes") or [] if (r.get("bodyText") or "").strip()]
    notes += [(c, c.get("createdAt")) for t in (n.get("reviewThreads") or {}).get("nodes") or []
              for c in (t.get("latest") or {}).get("nodes") or []]
    others, replied = {}, 0
    for note, stamp in notes:
        who = note.get("author") or {}
        at = gh_time(stamp)
        if who.get("login") == owner:
            replied = max(replied, at)
        elif who.get("__typename") != "Bot" and who.get("login") not in BOT_ACCOUNTS and note.get("url"):
            others[note["url"]] = {"at": at, "author": who.get("login") or "ghost", "url": note["url"],
                                   "excerpt": " ".join((note.get("bodyText") or "").split())[:160]}
    return sorted(others.values(), key=lambda f: -f["at"])[:20], replied


def unread_feedback(pr, seen):
    """Comments newer than everything that says you have seen them: opening them on the board, writing on the PR
    yourself, or, before either, pushing after them."""
    read = max(seen.get(pr["key"], pr["last_commit"]), pr.get("replied_at") or 0)
    return [f for f in pr.get("feedback") or [] if f["at"] > read]


def fetch_nodes(batch, fragment, name):
    """PR nodes through `fragment` for (repo, number) pairs, None where a PR is gone, or (None, why) when GitHub
    fails. gh exits non-zero when any one alias errors, so the data decides, not the exit code."""
    parts = ['p%d: repository(owner: "%s", name: "%s") { pullRequest(number: %d) { ...%s } }'
             % (i, repo.split("/", 1)[0], repo.split("/", 1)[1], number, name) for i, (repo, number) in enumerate(batch)]
    code, out, err = run(["gh", "api", "graphql", "-f", "query=" + fragment + "query { %s }" % " ".join(parts)], timeout=60)
    try:
        data = json.loads(out[out.index("{"):])["data"]
        return [((data.get("p%d" % i) or {}).get("pullRequest")) for i in range(len(batch))], None
    except Exception:
        return None, gh_error(err) if code != 0 else UNREADABLE


def fetch_details(batch):
    return fetch_nodes(batch, PR_FRAGMENT, "pr")


def fetch_light(batch):
    return fetch_nodes(batch, PR_LIGHT, "light")


def chunks(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def pr_nodes(wanted, now):
    """Nodes for `wanted` (repo, number) pairs, or (None, why). A PR fetched in full within FULL_MAX_AGE_S, or
    closed, whose updatedAt has not moved keeps its stored node with fresh CI; the rest are fetched in full."""
    store = read_json(PR_NODES, {})
    stored = lambda pair: store.get("%s#%d" % pair)
    # A closed PR changes only by reopening, which moves updatedAt, so its details never age out.
    known = [p for p in wanted if stored(p) and (now - stored(p)["at"] < FULL_MAX_AGE_S or stored(p)["node"].get("state") != "OPEN")]
    nodes, empty = {}, set()
    for batch in chunks(known, LIGHT_BATCH):
        found, why = fetch_light(batch)
        if why:
            return None, why
        for pair, light in zip(batch, found):
            if not light:
                empty.add(pair)
            elif light.get("updatedAt") == stored(pair)["node"].get("updatedAt"):
                nodes[pair] = dict(stored(pair)["node"], **light)
    # An empty answer would come back empty in full too; the PR is held over, as any empty lookup is.
    full = [p for p in wanted if p not in nodes and p not in empty]
    batches = chunks(full, DETAIL_BATCH)
    fetched = {}
    with ThreadPoolExecutor(max_workers=max(1, min(4, len(batches)))) as pool:
        for batch, (found, why) in zip(batches, pool.map(fetch_details, batches)):
            if why:
                return None, why
            fetched.update({pair: n for pair, n in zip(batch, found) if n})
    kept = {"%s#%d" % pair: dict(stored(pair), node=n) for pair, n in nodes.items()}
    kept.update({"%s#%d" % pair: {"at": now, "node": n} for pair, n in fetched.items()})
    write_atomic(PR_NODES, json.dumps(kept))
    nodes.update(fetched)
    return nodes, None


def pr_pair(key):
    repo, number = key.split("#")
    return repo, int(number)


def fetch_prs(previous, now=None):
    """Open PR nodes by kind, plus the cached records this fetch could not vouch for.
    A light search lists PRs, then small detail batches run in parallel, which GitHub answers far
    sooner than one search carrying every PR's details.

    Search and detail lookups sometimes answer short without an error, so a cached PR the fetch
    leaves out stays until GitHub says it closed or MISS_LIMIT fetches in a row leave it out. Your
    own PRs stay while GitHub says they are open, since only closing one takes it off the search."""
    with ThreadPoolExecutor(max_workers=len(PR_SEARCHES)) as pool:
        listed = dict(zip(PR_SEARCHES, pool.map(search_prs, PR_SEARCHES.values())))
    errors = [why for _, why in listed.values() if why]
    if errors:
        return None, None, errors[0]
    searched = {pair for pairs, _ in listed.values() for pair in pairs}
    linked = [pr_pair(key) for key in read_json(LINKED_WANTED, [])]
    listed["linked"] = ([pair for pair in linked if pair not in searched], None)
    listed_pairs = {pair for pairs, _ in listed.values() for pair in pairs}
    missing = {kind: [p for p in previous.get(kind, []) if pr_pair(p["key"]) not in listed_pairs] for kind in PR_SEARCHES}
    wanted = list(dict.fromkeys([pair for pairs, _ in listed.values() for pair in pairs]
                                + [pr_pair(p["key"]) for records in missing.values() for p in records]))
    nodes, why = pr_nodes(wanted, now or time.time())
    if why:
        return None, None, why
    is_open = lambda pair: pair in nodes and nodes[pair].get("state") == "OPEN"
    results = {kind: [(nodes[pair], 0) for pair in pairs if is_open(pair)] for kind, (pairs, _) in listed.items()}
    held = {kind: [] for kind in PR_SEARCHES}
    for kind, records in missing.items():
        for record in records:
            pair = pr_pair(record["key"])
            if pair in nodes and not is_open(pair):
                continue
            misses = record.get("misses", 0) + 1
            if misses >= MISS_LIMIT and not (kind == "mine" and is_open(pair)):
                continue
            if is_open(pair):
                results[kind].append((nodes[pair], misses))
            else:
                held[kind].append(dict(record, misses=misses))
    return results, held, None


def load_prs(now):
    """Cached open PRs by kind ("mine", "review"). Starts a background refresh once the cache is PR_TTL_S old."""
    cached = read_json(PR_CACHE, {})
    last_try = max(cached.get("fetched_at", 0), cached.get("attempted_at", 0))
    if not FRESH and now - last_try >= PR_TTL_S:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--fresh"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cached.get("prs", {"mine": [], "review": []})


def refresh_prs(now):
    """Fetches PRs into the cache. Returns False when another refresh holds the lock or GitHub fails."""
    lock = open(os.path.join(BOARD, ".prs.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    started = time.time()
    cached = read_json(PR_CACHE, {})
    previous = cached.get("prs", {})
    results, held, error = fetch_prs(previous, now)
    if error:
        cached["attempted_at"] = now
        cached["error"] = error
        write_atomic(PR_CACHE, json.dumps(cached))
        log_refresh(now, started, previous, None, error)
        return False
    bases = {(n["repository"]["nameWithOwner"], n["baseRefName"]) for nodes in results.values() for n, _ in nodes}
    with ThreadPoolExecutor(max_workers=4) as pool:
        required = dict(zip(bases, pool.map(lambda rb: required_checks(rb[0], rb[1], now), bases)))
    prs = {}
    for kind, nodes in results.items():
        prs[kind] = []
        for n, misses in nodes:
            commit = ((n.get("commits") or {}).get("nodes") or [{}])[0].get("commit") or {}
            repo = n["repository"]["nameWithOwner"]
            committed = commit.get("committedDate") or "1970-01-01T00:00:00Z"
            open_threads = [t for t in (n.get("reviewThreads") or {}).get("nodes") or []
                            if not t.get("isResolved") and not t.get("isOutdated")]
            author = (n.get("author") or {}).get("login") or "ghost"
            notes, replied = feedback(n, author)
            prs[kind].append({
                "key": "%s#%d" % (repo, n["number"]),
                "number": n["number"],
                "title": n["title"],
                "url": n["url"],
                "repo": repo,
                "head": n["headRefName"],
                "base": n["baseRefName"],
                "author": author,
                "draft": n["isDraft"],
                "review": n.get("reviewDecision"),
                "unresolved": len(open_threads),
                "comments_url": next((c["url"] for t in open_threads
                                      for c in (t.get("comments") or {}).get("nodes") or []), None),
                "ci": pr_ci(commit, required.get((repo, n["baseRefName"]), [])),
                "required_checks": required.get((repo, n["baseRefName"]), []),
                "last_commit": calendar.timegm(time.strptime(committed, "%Y-%m-%dT%H:%M:%SZ")),
                "mine": kind == "mine",
                "linked": kind == "linked",
                "feedback": notes,
                "replied_at": replied,
                "misses": misses,
            })
    for kind, records in held.items():
        prs[kind] += records
    write_atomic(PR_CACHE, json.dumps({"fetched_at": now, "prs": prs}))
    log_refresh(now, started, previous, prs, None)
    return True


def log_refresh(now, started, previous, prs, error):
    """One line per PR refresh: counts, what joined or left, and what was held over a short answer."""
    keys = lambda by_kind: {kind: {p["key"] for p in records} for kind, records in (by_kind or {}).items()}
    before, after = keys(previous), keys(prs)
    line = {"at": round(now), "s": round(time.time() - started, 1), "error": error}
    if prs is not None:
        line["counts"] = {kind: len(v) for kind, v in after.items()}
        line["added"] = sorted(k for kind, v in after.items() for k in v - before.get(kind, set()))
        line["dropped"] = sorted(k for kind, v in before.items() for k in v - after.get(kind, set()))
        line["held"] = sorted(p["key"] for records in prs.values() for p in records if p.get("misses"))
    try:
        lines = open(PR_LOG).read().splitlines()[-(PR_LOG_KEEP - 1):] if os.path.exists(PR_LOG) else []
    except OSError:
        lines = []
    write_atomic(PR_LOG, "\n".join(lines + [json.dumps(line)]) + "\n")


# ---------- assembly ----------

def returnable(slot):
    reasons = []
    if not slot.get("leased"):
        reasons.append("not leased")
    if slot.get("dirty") is not False:
        reasons.append("uncommitted changes" if slot.get("dirty") else "git state unknown")
    if slot.get("branch") and slot.get("pushed") is not True:
        reasons.append("branch not pushed")
    if slot.get("processes", {}).get("blocking"):
        reasons.append("running: " + ", ".join(slot["processes"]["blocking"]))
    return reasons


def slot_order(slot):
    """Pool, then numbered slots by number before named ones by name."""
    name = str(slot["name"])
    return slot["pool"], not name.isdigit(), int(name) if name.isdigit() else 0, name


def build(now):
    per = summarize_events(load_events(now))
    chats = load_chats(now, per.keys())
    wt = worktrees.provider()
    slots = load_slots(wt)
    seen = read_json(SEEN, {})
    dismissed = read_json(DISMISSED, {})
    still_dismissed = {}
    tcache = read_json(TRANSCRIPT_CACHE, {})

    oldest_lease = min((lease_start(s) for s in slots.values() if s["leased"]), default=now)
    index = transcript_index(chats)
    facts = {c["id"]: transcript_facts(c["id"], tcache, index, sources.SOURCES[c["tool"]], wt, slots) for c in chats
             if c["updated_at"] >= min(oldest_lease, now - BOARD_WINDOW_S)}
    for chat in chats:
        summary = sources.SOURCES[chat["tool"]].summary(index.get(chat["id"]), now)
        merge_transcript(per, chat, summary, facts.get(chat["id"], {}))
    attributed = claim_slots(chats, per, slots, facts)
    write_atomic(TRANSCRIPT_CACHE, json.dumps({cid: f for cid, f in tcache.items() if cid in facts}))

    procs = processes_by_cwd(now)
    wanted = {p for p, s in slots.items() if s["leased"]} | set(attributed.values())
    gcache = read_json(GIT_CACHE, {})
    marks = {p: git_fingerprint(p) for p in wanted}
    stale = [p for p in wanted
             if gcache.get(p, {}).get("marks") != marks[p] or now - gcache.get(p, {}).get("at", 0) > GIT_TTL_S]
    with ThreadPoolExecutor(max_workers=2) as pool:
        for path, info in zip(stale, pool.map(git_info, stale)):
            if info is None and path in gcache:
                continue
            gcache[path] = {"at": now, "marks": marks[path], "info": info or dict(NO_GIT)}
    write_atomic(GIT_CACHE, json.dumps({p: v for p, v in gcache.items() if p in slots}))
    infos = {p: gcache[p]["info"] for p in wanted}
    for path in wanted:
        slots[path].update(infos[path])
        slots[path]["processes"] = slot_processes(path, procs)
        slots[path]["return_blockers"] = returnable(slots[path])

    # An unleased slot sitting on detached HEAD is an idle pool slot that a chat only inspected.
    for cid, path in list(attributed.items()):
        s = slots[path]
        if not s["leased"] and not s.get("branch"):
            del attributed[cid]

    hidden = set(open(HIDDEN_PRS).read().split()) if os.path.exists(HIDDEN_PRS) else set()
    hidden_chats = read_json(HIDDEN_CHATS, {})
    fetched = load_prs(now)
    every_pr = {}
    for kind in ("mine", "review", "linked"):
        for pr in fetched.get(kind, []):
            if pr["key"] not in every_pr:
                every_pr[pr["key"]] = dict(pr, stale=now - pr["last_commit"] > STALE_S, hidden=pr["url"] in hidden,
                                           new_comments=unread_feedback(pr, seen) if pr["mine"] else [])
    assign_stacks(every_pr)
    # Hidden PRs leave the sections and the cards, so a hidden failing PR stops asking for attention.
    open_prs = {k: p for k, p in every_pr.items() if not p["hidden"]}
    by_number = {}
    for pr in open_prs.values():
        by_number.setdefault(str(pr["number"]), []).append(pr)
    by_head = {pr["head"]: pr for pr in open_prs.values()}

    def linked_prs(cid):
        ev = per.get(cid, {})
        keys = {k for k in ev.get("prs", {}) if k in open_prs}
        for num in ev.get("pr_numbers", ()):
            if len(by_number.get(num, [])) == 1:
                keys.add(by_number[num][0]["key"])
        heads = set(ev.get("branches", ()))
        slot = slots.get(attributed.get(cid))
        if slot and slot.get("branch"):
            heads.add(slot["branch"])
        keys |= {by_head[h]["key"] for h in heads if h in by_head}
        return stack_order([open_prs[k] for k in keys])

    write_linked_wanted(chats, per, every_pr, now)

    statuses, links = {}, {}
    for chat in chats:
        statuses[chat["id"]] = live_status(per.get(chat["id"], {}), index.get(chat["id"]), now,
                                           sources.SOURCES[chat["tool"]])
        links[chat["id"]] = linked_prs(chat["id"])

    agents_by_pr = {}
    for chat in chats:
        for pr in links[chat["id"]]:
            agents_by_pr.setdefault(pr["key"], []).append({
                "id": chat["id"], "title": chat["title"], "status": statuses[chat["id"]],
                "updated_at": chat["updated_at"], "tool": chat["tool"]})

    cards = []
    for chat in chats:
        ev = per.get(chat["id"], {})
        status = statuses[chat["id"]]
        slot = slots.get(attributed.get(chat["id"]))
        prs = [pr_view(p) for p in links[chat["id"]]]
        mine = [p for p in prs if p["mine"]]
        unseen_finish = status in ("done", "error", "aborted") and ev.get("stop_ts", 0) > seen.get(chat["id"], 0)
        reasons = []
        if unseen_finish:
            reasons.append("finished" if status == "done" else status)
        if any(p["review"] == "CHANGES_REQUESTED" for p in mine):
            reasons.append("changes requested")
        if any(p["new_comments"] for p in mine):
            reasons.append("new comments")
        # A dismissed reason stays quiet until it clears, so the next occurrence shows again.
        quiet = [r for r in dismissed.get(chat["id"], []) if r in reasons]
        if quiet:
            still_dismissed[chat["id"]] = quiet
            reasons = [r for r in reasons if r not in quiet]
        recent = now - chat["updated_at"] < BOARD_WINDOW_S
        if not (recent or status == "running" or (slot and slot["leased"]) or mine):
            continue
        if chat["title"] == "Untitled chat" and not (ev or slot):
            continue
        # A hidden chat comes back once it is prompted again after it was hidden.
        is_hidden = chat["id"] in hidden_chats and ev.get("prompt_ts", 0) <= hidden_chats[chat["id"]]
        cards.append({
            "hidden": is_hidden,
            "id": chat["id"],
            "title": chat["title"],
            "updated_at": chat["updated_at"],
            "updated_ago": ago(now - chat["updated_at"]),
            "status": status,
            "needs_you": reasons,
            "slot": slot,
            "prs": prs,
            "tool": chat["tool"],
            "cwd": chat.get("cwd"),
        })

    extra, parents = chat_family(cards, per, now, index)
    cards = nest_chats(cards + extra, parents)
    hidden_kids = []
    for c in cards:
        if "children" in c and not c["hidden"]:
            hidden_kids += [k for k in c["children"] if k["hidden"]]
            c["children"] = [k for k in c["children"] if not k["hidden"]]
    if still_dismissed != dismissed:
        # Re-read so a dismissal written during this collect survives the prune.
        latest = read_json(DISMISSED, {})
        for cid, was in dismissed.items():
            keep = still_dismissed.get(cid, [])
            left = [r for r in latest.get(cid, []) if r in keep or r not in was]
            if left:
                latest[cid] = left
            else:
                latest.pop(cid, None)
        write_atomic(DISMISSED, json.dumps(latest))

    sections = {"mine": [], "review": []}
    for pr in sorted(open_prs.values(), key=lambda p: -p["last_commit"]):
        if pr.get("linked"):
            continue
        agents = sorted(agents_by_pr.get(pr["key"], []), key=lambda a: -a["updated_at"])[:6]
        sections["mine" if pr["mine"] else "review"].append(dict(pr_view(pr), agents=agents))

    used = {m["slot"]["path"] for c in cards for m in [c] + c.get("children", []) if m["slot"]}
    loose = [s for p, s in sorted(slots.items(), key=lambda kv: slot_order(kv[1]))
             if p in wanted and p not in used and (s["leased"] or s.get("dirty") or s.get("branch"))]
    sections["hidden"] = [pr_view(p) for p in sorted(every_pr.values(), key=lambda p: -p["last_commit"]) if p["hidden"]]
    pr_cache = read_json(PR_CACHE, {})
    pr_failed = pr_cache.get("attempted_at", 0) > pr_cache.get("fetched_at", 0)
    return {"generated_at": now, "cards": [c for c in cards if not c["hidden"]], "loose_slots": loose, "prs": sections,
            "hidden_cards": [c for c in cards if c["hidden"]] + hidden_kids,
            "pr_error": pr_cache.get("error") if pr_failed else None, "prs_fetched_at": pr_cache.get("fetched_at")}


def write_linked_wanted(chats, per, every_pr, now):
    """PRs that board chats reference but neither search returns, such as one already reviewed,
    so the next PR refresh fetches them for the cards."""
    searched = {k for k, p in every_pr.items() if not p.get("linked")}
    recent = sorted((c for c in chats if now - c["updated_at"] < BOARD_WINDOW_S), key=lambda c: -c["updated_at"])
    wanted = []
    for chat in recent:
        for key in sorted(per.get(chat["id"], {}).get("prs", {})):
            if key not in searched and key not in wanted:
                wanted.append(key)
    wanted = wanted[:LINKED_MAX]
    if wanted != read_json(LINKED_WANTED, None):
        write_atomic(LINKED_WANTED, json.dumps(wanted))


def assign_stacks(open_prs):
    """Marks PRs whose base branch is another open PR's head. Positions run base first."""
    by_head = {(p["repo"], p["head"]): k for k, p in open_prs.items()}
    parent = {}
    for k, p in open_prs.items():
        up = by_head.get((p["repo"], p.get("base")))
        if up and up != k:
            parent[k] = up
    children = {}
    for k, up in parent.items():
        children.setdefault(up, []).append(k)
    for root in (k for k in open_prs if k in children and k not in parent):
        order, todo, visited = [], [root], set()
        while todo:
            k = todo.pop()
            if k in visited:
                continue
            visited.add(k)
            order.append(k)
            todo.extend(sorted(children.get(k, []), key=lambda c: -open_prs[c]["number"]))
        for pos, k in enumerate(order, 1):
            open_prs[k].update(stack_id=root, stack_pos=pos, stack_size=len(order))


def stack_order(prs):
    """Newest commit first, except a stack's members run base first, at the place of the stack's newest commit."""
    units = {}
    for p in prs:
        units.setdefault(p.get("stack_id") or p["key"], []).append(p)
    ordered = sorted(units.values(), key=lambda u: -max(p["last_commit"] for p in u))
    return [p for u in ordered for p in sorted(u, key=lambda p: p.get("stack_pos") or 0)]


def pr_view(pr):
    keep = ("key", "number", "title", "url", "repo", "author", "draft", "review", "unresolved",
            "comments_url", "ci", "required_checks", "mine", "stale", "stack_id", "stack_pos", "stack_size", "hidden", "last_commit", "new_comments")
    return {k: pr.get(k) for k in keep}


def render_current(state):
    t = time.strftime("%Y-%m-%d %H:%M", time.localtime(state["generated_at"]))
    lines = [
        "# Current work",
        "",
        "Generated %s by the agent board. Facts only; regenerated every minute." % t,
        "",
        "| Chat | Status | Slot | Branch | PR | CI | Updated |",
        "|---|---|---|---|---|---|---|",
    ]
    rows = [c for card in state["cards"][:25]
            for c in [card] + [k for k in card.get("children", []) if k.get("kind") == "side"]]
    for c in rows:
        s = c["slot"] or {}
        slot = "%s/%s" % (s["pool"], s["name"]) if s else ""
        title = ("↳ " if c.get("kind") else "") + c["title"].replace("|", "/")
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            title, c["status"], slot, s.get("branch") or "",
            " ".join(p["url"] for p in c["prs"]), " ".join(p["ci"] for p in c["prs"]), c["updated_ago"]))
    if state["loose_slots"]:
        lines += ["", "Leased slots with no recent chat:", ""]
        for s in state["loose_slots"]:
            lines.append("- %s/%s holder=%s branch=%s dirty=%s" % (
                s["pool"], s["name"], s.get("lease_holder") or "-", s.get("branch") or "detached", s.get("dirty")))
    return "\n".join(lines) + "\n"


def do_return(path):
    wt = worktrees.provider()
    slots = load_slots(wt)
    if path not in slots:
        print("Not a %s slot: %s" % (wt.NAME, path))
        return 2
    slot = slots[path]
    slot.update(git_info(path))
    slot["processes"] = slot_processes(path, scan_processes())
    blockers = returnable(slot)
    if blockers:
        print("Not returned: " + "; ".join(blockers))
        return 3
    code, message = wt.give_back(path)
    print(message)
    return code


def main():
    # Inherited by git, gh, and lsof, so the board's bookkeeping yields to whatever the user is doing.
    os.nice(10)
    if len(sys.argv) >= 3 and sys.argv[1] == "return":
        sys.exit(do_return(sys.argv[2]))
    if len(sys.argv) >= 2 and sys.argv[1] == "backfill":
        backfill(time.time())
        return
    if FRESH:
        write_state(blocking=True)
        refresh_prs(time.time())
        # Also after a failed fetch, so the board learns why its PRs are stale.
        write_state(blocking=True)
    else:
        write_state(blocking=False)


def write_state(blocking):
    os.makedirs(BOARD, exist_ok=True)
    lock = open(os.path.join(BOARD, ".collect.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
    except OSError:
        return
    state = build(time.time())
    write_atomic(STATE, json.dumps(state))
    write_atomic(CURRENT, render_current(state))


if __name__ == "__main__":
    main()
