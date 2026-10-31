"""The Linear inbox as an event source. On while the Keychain holds a Linear API key under KEYCHAIN_SERVICE:

  security add-generic-password -s agent-board-linear -a linear -w

Pull request events carry the GitHub PR's URL, so each one opens the PR it names on the board."""

import calendar
import json
import re
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from common import run

KEYCHAIN_SERVICE = "agent-board-linear"
API = "https://api.linear.app/graphql"
WINDOW_S = 2 * 86400
EXCERPT = 160

QUERY = """query($since: DateTimeOrDuration!) {
  notifications(first: 50, filter: {createdAt: {gt: $since}}) { nodes {
    id type subtitle url createdAt readAt
    actor { name displayName } botActor { name } externalUserActor { name displayName }
    ... on PullRequestNotification { pullRequest { number title url } }
    ... on IssueNotification { issue { identifier title url } }
  } }
}"""

MARK_READ = """mutation($id: String!, $at: DateTime!) { notificationUpdate(id: $id, input: {readAt: $at}) { success } }"""

PR_URL = re.compile(r"github\.com/([^/]+/[^/]+)/pull/(\d+)")

# Issue activity someone addressed to you; status, blocking, and project changes stay in Linear.
ISSUE_LABELS = {"issueNewComment": "Comment from", "issueCommentMention": "Mentioned by",
                "issueMention": "Mentioned by", "issueAssignedToYou": "Assigned by"}


def api_key():
    code, out, _ = run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], timeout=5)
    return out.strip() if code == 0 and out.strip() else None


def call(key, query, variables, timeout=15):
    """The response's data, or (None, why). The key never appears in the reason."""
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = Request(API, data=body, headers={"Authorization": key, "Content-Type": "application/json",
                                           "User-Agent": "agent-board"})
    try:
        with urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read())
    except HTTPError as e:
        return None, "Linear answered %d" % e.code
    except (URLError, OSError, ValueError) as e:
        return None, "Linear could not be reached: %s" % getattr(e, "reason", e)
    if payload.get("errors"):
        return None, "Linear: %s" % (payload["errors"][0].get("message") or "query failed")[:160]
    return payload.get("data"), None


def stamp(iso):
    return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")) if iso else 0


def fetch(key, now):
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - WINDOW_S))
    data, why = call(key, QUERY, {"since": since})
    if why:
        return None, why
    return [record(n) for n in ((data or {}).get("notifications") or {}).get("nodes") or [] if n], None


def mark_read(key, notification_id):
    data, why = call(key, MARK_READ, {"id": notification_id, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    return why or (None if ((data or {}).get("notificationUpdate") or {}).get("success") else "Linear did not mark it read")


def record(n):
    """The fields the board keeps from one notification."""
    who = n.get("actor") or n.get("externalUserActor") or n.get("botActor") or {}
    pr, issue = n.get("pullRequest") or {}, n.get("issue") or {}
    match = PR_URL.search(pr.get("url") or "")
    return {"id": n["id"], "type": n.get("type") or "", "subtitle": n.get("subtitle") or "", "url": n.get("url"),
            "at": stamp(n.get("createdAt")), "read": bool(n.get("readAt")),
            "actor": who.get("displayName") or who.get("name") or "someone",
            "pr": {"key": "%s#%s" % match.groups(), "number": int(pr["number"]), "title": pr.get("title") or "",
                   "url": pr["url"]} if match else None,
            "issue": {"identifier": issue.get("identifier"), "title": issue.get("title") or ""} if issue.get("identifier") else None}


def kind(rec):
    """The board event kind, or None for activity the board leaves to Linear. Bots' comments count: an agent's
    review is one of them. A review request counts only when it names you, not a team you are on."""
    t, sub = rec["type"], rec["subtitle"]
    if rec["pr"]:
        if t == "pullRequestReviewRequested":
            return "review" if sub.endswith("requested your review") else None
        if "ChangesRequested" in t or "requested changes" in sub:
            return "changes"
        if t == "pullRequestApproved":
            return "approved"
        if t == "pullRequestCommented":
            return "comments"
        return None
    return "issue" if rec["issue"] and t in ISSUE_LABELS else None


def excerpt(rec):
    """What follows "Name commented:" in the subtitle, the comment's first words."""
    _, sep, rest = rec["subtitle"].partition(": ")
    text = " ".join(rest.split())[:EXCERPT] if sep else ""
    return " · “%s”" % text if text else ""


def event(rec, board_prs):
    """One board event, worded like the GitHub ones: "<label>: <subject> · <detail>"."""
    k = kind(rec)
    if not k:
        return None
    who, pr = rec["actor"], rec["pr"]
    if pr:
        name = "#%d %s" % (pr["number"], pr["title"])
        text = {"review": "Review requested: %s · %s" % (name, who),
                "approved": "Approved by %s: %s%s" % (who, name, excerpt(rec)),
                "changes": "Changes requested by %s: %s%s" % (who, name, excerpt(rec)),
                "comments": "Comment from %s: %s%s" % (who, name, excerpt(rec))}[k]
        on_board = pr["key"] in board_prs
        if k in ("comments", "changes"):
            target = "comments:" + pr["key"] if on_board else rec["url"]
        else:
            target = pr["url"]
    else:
        issue = rec["issue"]
        text = "%s %s: %s %s%s" % (ISSUE_LABELS[rec["type"]], who, issue["identifier"], issue["title"], excerpt(rec))
        target = rec["url"]
    return {"id": rec["id"], "kind": k, "text": text, "target": target, "at": rec["at"], "read": rec["read"]}


def events(records, board_prs):
    return [e for e in (event(r, board_prs) for r in sorted(records, key=lambda r: -r["at"])) if e]
