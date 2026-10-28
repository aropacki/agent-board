"""PR and branch references found in prompts, commands, and transcripts."""

import re

PR_URL_RE = re.compile(r"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)")
# gh pr subcommands that act on a PR. Reading one (view, checks, diff) does not make a chat its agent.
OWNING_VERBS = ("checkout", "edit", "review", "ready", "merge", "close", "comment")
PR_VERB_RE = re.compile(r"\bgh\s+pr\s+(%s)\b" % "|".join(OWNING_VERBS))
PR_NUM_RE = re.compile(r"\bgh pr (?:%s)\s+#?(\d+)\b" % "|".join(OWNING_VERBS))
# Only namespaced branches (me/topic), which keeps master, HEAD, and file paths out.
BRANCH_RE = re.compile(
    r"\bgit (?:switch|checkout)\s+(?:-[cCbB]\s+)?([A-Za-z0-9._-]+/[A-Za-z0-9._/-]*[A-Za-z0-9_-])"
    r"|\bgit push\s+(?:(?:-u|--set-upstream|-f|--force-with-lease)\s+)*origin\s+([A-Za-z0-9._-]+/[A-Za-z0-9._/-]*[A-Za-z0-9_-])"
)


def pr_urls(text):
    return {"%s#%s" % (repo, num) for repo, num in PR_URL_RE.findall(text)}


def pr_verb(text):
    m = PR_VERB_RE.search(text)
    return m.group(1) if m else None


def pr_numbers(text):
    return set(PR_NUM_RE.findall(text))


def branches(text):
    found = set()
    for a, b in BRANCH_RE.findall(text):
        name = (a or b).removeprefix("origin/")
        if name not in ("master", "main"):
            found.add(name)
    return found
