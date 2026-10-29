"""PR and branch references found in prompts, commands, and transcripts."""

import re

PR_URL_RE = re.compile(r"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)")
# gh pr subcommands that act on a PR. Reading one (view, checks, diff) does not make a chat its agent.
OWNING_VERBS = ("checkout", "edit", "review", "ready", "merge", "close", "comment")
PR_VERB_RE = re.compile(r"\bgh\s+pr\s+(%s)\b" % "|".join(OWNING_VERBS))
PR_NUM_RE = re.compile(r"\bgh pr (?:%s)\s+#?(\d+)\b" % "|".join(OWNING_VERBS))
# `for n in 101 102; do gh pr edit $n ...; done`, which agents use to act on a whole stack.
PR_LOOP_RE = re.compile(r"\bfor\s+(\w+)\s+in\s+((?:#?\d+\s+)*#?\d+)\s*;\s*do\b(.*?)\bdone\b", re.S)
# Only namespaced branches (me/topic), which keeps master, HEAD, and file paths out.
NAMESPACED = r"[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*[A-Za-z0-9_-]"
BRANCH_RE = re.compile(
    r"\bgit (?:switch|checkout)\s+(?:-[cCbB]\s+)?(%s)" % NAMESPACED
    + r"|\bgit push\s+(?:(?:-u|--set-upstream|-f|--force-with-lease)\s+)*origin\s+(%s)" % NAMESPACED
)
# gh-stack names the branches it creates: `gh stack init a/one a/two`, `gh stack add a/three`.
STACK_BRANCHES_RE = re.compile(r"\bgh stack (?:init|add)((?:\s+(?:--?[\w-]+|%s))+)" % NAMESPACED)


def pr_urls(text):
    return {"%s#%s" % (repo, num) for repo, num in PR_URL_RE.findall(text)}


def pr_verb(text):
    m = PR_VERB_RE.search(text)
    return m.group(1) if m else None


def pr_numbers(text):
    found = set(PR_NUM_RE.findall(text))
    for var, nums, body in PR_LOOP_RE.findall(text):
        if re.search(r"\bgh pr (?:%s)\s+\"?\$\{?%s\b" % ("|".join(OWNING_VERBS), var), body):
            found |= set(re.findall(r"\d+", nums))
    return found


def branches(text):
    names = [a or b for a, b in BRANCH_RE.findall(text)]
    for args in STACK_BRANCHES_RE.findall(text):
        names += [arg for arg in args.split() if not arg.startswith("-")]
    return {n.removeprefix("origin/") for n in names} - {"master", "main"}
