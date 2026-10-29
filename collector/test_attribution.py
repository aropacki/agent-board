#!/usr/bin/python3
"""Attribution tests: which slot and PRs a chat's card shows. Run: python3 collector/test_attribution.py"""

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect  # noqa: E402
from refs import branches, pr_numbers, pr_verb  # noqa: E402
from sources import cursor  # noqa: E402
from worktrees import treehouse  # noqa: E402

SLOT1 = "/Users/me/.treehouse/code-abc123/1/code"
SLOT2 = "/Users/me/.treehouse/code-abc123/2/code"
LEASED_AT = "2026-10-12T13:49:27-07:00"
_spec = importlib.util.spec_from_file_location("journal_hook", os.path.join(os.path.dirname(__file__), "journal-hook.py"))
journal_hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(journal_hook)
T = collect.lease_start({"leased": True, "leased_at": LEASED_AT})


def slot(path, holder=None, leased=True):
    return {path: {"path": path, "leased": leased, "lease_holder": holder, "leased_at": LEASED_AT if leased else None}}


def chat(cid, updated_at):
    return {"id": cid, "updated_at": updated_at}


class ClaimSlots(unittest.TestCase):
    def test_labeled_lease_goes_to_the_chat_that_used_the_label(self):
        chats = [chat("inspector", T + 500), chat("owner", T + 100)]
        per = {"inspector": {"slot_path": SLOT1, "slot_ts": T + 500}}
        facts = {"owner": {"holders": ["feature-dev"]}, "inspector": {"holders": ["review-4242"]}}
        self.assertEqual(collect.claim_slots(chats, per, slot(SLOT1, "feature-dev"), facts), {"owner": SLOT1})

    def test_a_chat_leasing_under_another_label_never_claims_by_path(self):
        per = {"reviewer": {"slot_path": SLOT1, "slot_ts": T + 500}}
        facts = {"reviewer": {"slot": SLOT1, "holders": ["review-4242"]}}
        self.assertEqual(collect.claim_slots([chat("reviewer", T + 500)], per, slot(SLOT1, "feature-dev"), facts), {})

    def test_label_seen_live_by_the_hook_claims_before_the_transcript_exists(self):
        per = {"live": {"holders": {"stack-review"}}, "reader": {"slot_path": SLOT1, "slot_ts": T + 900}}
        chats = [chat("reader", T + 900), chat("live", T + 50)]
        self.assertEqual(collect.claim_slots(chats, per, slot(SLOT1, "stack-review"), {}), {"live": SLOT1})

    def test_unmatched_label_falls_back_to_path_evidence_from_a_chat_without_labels(self):
        per = {"worker": {"slot_path": SLOT1, "slot_ts": T + 500}}
        self.assertEqual(collect.claim_slots([chat("worker", T + 500)], per, slot(SLOT1, "pr-4300"), {}),
                         {"worker": SLOT1})

    def test_label_from_a_chat_older_than_the_lease_does_not_claim(self):
        facts = {"earlier": {"holders": ["review"]}}
        self.assertEqual(collect.claim_slots([chat("earlier", T - 60)], {}, slot(SLOT1, "review"), facts), {})

    def test_unlabeled_slot_goes_to_the_newest_evidence_after_the_lease(self):
        chats = [chat("new", T + 300), chat("old", T + 100), chat("stale", T - 100)]
        per = {"new": {"slot_path": SLOT2, "slot_ts": T + 300}, "old": {"slot_path": SLOT2, "slot_ts": T + 100},
               "stale": {"slot_path": SLOT2, "slot_ts": T - 100}}
        self.assertEqual(collect.claim_slots(chats, per, slot(SLOT2), {}), {"new": SLOT2})

    def test_evidence_from_before_the_lease_is_about_an_earlier_holder(self):
        per = {"yesterday": {"slot_path": SLOT2, "slot_ts": T - 3600}}
        self.assertEqual(collect.claim_slots([chat("yesterday", T + 10)], per, slot(SLOT2), {}), {})


class Refs(unittest.TestCase):
    def test_printed_slot_takes_only_a_bare_path_line(self):
        get = "treehouse get --lease"
        self.assertEqual(treehouse.slot_in_output(get, "/tmp/x\n%s\n" % SLOT1), SLOT1)
        self.assertIsNone(treehouse.slot_in_output(get, "error: pool full; %s is leased by feature-dev" % SLOT1))

    def test_lease_holders_from_get_and_resume_commands(self):
        self.assertEqual(treehouse.holders('cd "$(treehouse get --lease --lease-holder review-4242)"'), {"review-4242"})
        self.assertEqual(treehouse.holders("treehouse get --lease --lease-holder=pr-1"), {"pr-1"})
        self.assertEqual(treehouse.holders("jq -r '.[] | select(.lease_holder == \"stack-review\") | .path'"), {"stack-review"})

    def test_reading_a_pr_does_not_own_it(self):
        self.assertIsNone(pr_verb("gh pr view 4242 --json title"))
        self.assertIsNone(pr_verb("gh pr checks 4242"))
        self.assertEqual(pr_verb("gh pr checkout 4242"), "checkout")

    def test_a_loop_that_acts_on_each_pr_owns_every_number_in_it(self):
        self.assertEqual(pr_numbers("for n in 11 12 13; do gh pr edit $n --body-file b$n.md; done"), {"11", "12", "13"})
        self.assertEqual(pr_numbers('for pr in 11 12; do gh pr view "$pr" --json body; done'), set())

    def test_gh_stack_names_the_branches_it_creates(self):
        self.assertEqual(branches("gh stack init me/base me/one && gh stack add --quiet me/two; gh stack add main"),
                         {"me/base", "me/one", "me/two"})

    def test_a_stack_submit_creates_the_prs_it_prints(self):
        h = {"event": "tool", "conversation_id": "c1", "command": "gh stack submit --auto", "dirs": [],
             "output": "Created https://github.com/o/r/pull/11\nUpdated https://github.com/o/r/pull/12\n", "tool": ""}
        created = [r for r in journal_hook.journal_records(h) if r.get("role") == "created"]
        self.assertEqual([r["prs"] for r in created], [["o/r#11", "o/r#12"]])


class TranscriptFacts(unittest.TestCase):
    def test_reads_only_new_complete_lines(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "c1"))
            path = os.path.join(d, "c1", "c1.jsonl")
            index = {"c1": path}

            def shell(command):
                return json.dumps({"role": "assistant", "message": {"content": [
                    {"type": "tool_use", "name": "Shell", "input": {"command": command}}]}}) + "\n"

            with open(path, "w") as fh:
                fh.write(shell("treehouse get --lease --lease-holder first"))
                fh.write(shell("cd %s && git status" % SLOT1)[:40])
            cache = {}
            facts = collect.transcript_facts("c1", cache, index, cursor, treehouse, {})
            self.assertEqual((facts["holders"], facts["slot"]), (["first"], None))
            with open(path, "w") as fh:
                fh.write(shell("treehouse get --lease --lease-holder first"))
                fh.write(shell("cd %s && git status" % SLOT1))
            facts = collect.transcript_facts("c1", cache, index, cursor, treehouse, {})
            self.assertEqual((facts["holders"], facts["slot"]), (["first"], SLOT1))


class MergeTranscript(unittest.TestCase):
    def test_transcript_prs_and_branches_count_when_the_tool_reads_no_turns(self):
        per = {}
        facts = {"prs": ["o/r#7"], "pr_numbers": ["8"], "branches": ["me/stack-2"]}
        collect.merge_transcript(per, chat("c", T), None, facts)
        self.assertEqual((per["c"]["prs"], per["c"]["pr_numbers"], per["c"]["branches"]),
                         ({"o/r#7": "transcript"}, {"8"}, {"me/stack-2"}))

    def test_a_chat_with_nothing_to_add_gets_no_summary(self):
        per = {}
        collect.merge_transcript(per, chat("c", T), None, {"slot": SLOT1, "holders": [], "prs": []})
        self.assertNotIn("c", per)


class LinkedWanted(unittest.TestCase):
    def test_wants_referenced_prs_the_searches_miss_and_keeps_fetched_ones(self):
        with tempfile.TemporaryDirectory() as d:
            collect.LINKED_WANTED = os.path.join(d, "linked.json")
            now = T + 1000
            per = {"c": {"prs": {"o/r#1": "prompt", "o/r#2": "prompt", "o/r#3": "command"}}}
            every_pr = {"o/r#1": {"linked": False}, "o/r#2": {"linked": True}}
            collect.write_linked_wanted([chat("c", now - 10)], per, every_pr, now)
            self.assertEqual(collect.read_json(collect.LINKED_WANTED, None), ["o/r#2", "o/r#3"])


class StackOrder(unittest.TestCase):
    def test_a_stack_runs_from_the_pr_on_master_and_sits_where_its_newest_commit_does(self):
        def pr(n, last, stack=None, pos=None):
            return {"key": "o/r#%d" % n, "number": n, "last_commit": last, "stack_id": stack, "stack_pos": pos}
        prs = [pr(30, 300, "s", 3), pr(5, 100), pr(10, 50, "s", 1), pr(20, 80, "s", 2), pr(7, 400)]
        self.assertEqual([p["number"] for p in collect.stack_order(prs)], [7, 10, 20, 30, 5])


class LoadChats(unittest.TestCase):
    def test_a_chat_the_search_index_lacks_still_shows_once_the_hook_has_seen_it(self):
        with tempfile.TemporaryDirectory() as d:
            cursor.CONV_DB, cursor.STATE_DB = os.path.join(d, "search.db"), os.path.join(d, "state.db")
            now = T + 1000
            search = sqlite3.connect(cursor.CONV_DB)
            search.execute("create table conversations (id, title, updated_at, source, is_archived)")
            search.execute("insert into conversations values ('indexed', 'Indexed', ?, 'local', 0)", (int(now * 1000),))
            search.commit()
            state = sqlite3.connect(cursor.STATE_DB)
            state.execute("create table cursorDiskKV (key primary key, value)")
            for cid, doc in [("indexed", {"name": "Stale name", "lastUpdatedAt": 1}),
                             ("live", {"name": "Live chat", "lastUpdatedAt": int((now + 5) * 1000)}),
                             ("archived", {"name": "Gone", "lastUpdatedAt": int(now * 1000), "isArchived": True})]:
                state.execute("insert into cursorDiskKV values (?, ?)", ("composerData:" + cid, json.dumps(doc)))
            state.commit()
            chats = cursor.chats(now, ["indexed", "live", "archived", "unknown"])
            self.assertEqual([(c["id"], c["title"]) for c in chats], [("live", "Live chat"), ("indexed", "Indexed")])


def card(cid, updated, status="done", needs=(), prs=()):
    return {"hidden": False, "id": cid, "title": cid, "updated_at": updated, "status": status,
            "needs_you": list(needs), "slot": None, "prs": [{"key": k} for k in prs]}


class Feedback(unittest.TestCase):
    def test_only_people_other_than_the_author_count_and_writing_or_looking_reads_them(self):
        def note(login, stamp, url, kind="User", text="hi"):
            return {"author": {"login": login, "__typename": kind}, "createdAt": stamp, "submittedAt": stamp,
                    "url": url, "bodyText": text}
        collect.BOT_ACCOUNTS = {"ci-user"}
        node = {
            "comments": {"nodes": [note("alice", "2026-01-01T00:00:10Z", "c1"), note("ci-user", "2026-01-01T00:00:11Z", "c2"),
                                   note("me", "2026-01-01T00:00:20Z", "c3")]},
            "reviews": {"nodes": [note("bob", "2026-01-01T00:00:30Z", "r1", text=" "),
                                  note("bob", "2026-01-01T00:00:40Z", "r2", text="Please   split\nthis")]},
            "reviewThreads": {"nodes": [{"latest": {"nodes": [note("claude", "2026-01-01T00:00:50Z", "t1", kind="Bot"),
                                                              note("carol", "2026-01-01T00:00:15Z", "t2")]}}]},
        }
        notes, replied = collect.feedback(node, "me")
        self.assertEqual([(n["url"], n["author"]) for n in notes], [("r2", "bob"), ("t2", "carol"), ("c1", "alice")])
        self.assertEqual(notes[0]["excerpt"], "Please split this")
        base = collect.gh_time("2026-01-01T00:00:00Z")
        pr = {"key": "o/r#1", "last_commit": base + 12, "feedback": notes, "replied_at": replied}
        self.assertEqual([f["url"] for f in collect.unread_feedback(pr, {})], ["r2"])
        self.assertEqual([f["url"] for f in collect.unread_feedback(dict(pr, replied_at=0), {"o/r#1": base + 1})],
                         ["r2", "t2", "c1"])
        self.assertEqual(collect.unread_feedback(pr, {"o/r#1": base + 40}), [])


class LiveStatus(unittest.TestCase):
    def test_a_chat_that_keeps_writing_after_its_stop_is_still_running(self):
        with tempfile.TemporaryDirectory() as d:
            now = T + 1000
            transcript = os.path.join(d, "c.jsonl")
            os.makedirs(os.path.join(d, "subagents"))
            sub = os.path.join(d, "subagents", "s.jsonl")
            for f in (transcript, sub):
                open(f, "w").close()
            stopped = {"prompt_ts": now - 600, "stop_ts": now - 300}

            def at(path, ts):
                os.utime(path, (ts, ts))

            at(transcript, now - 298)
            at(sub, now - 400)
            self.assertEqual(collect.live_status(stopped, transcript, now, cursor), "done")
            at(sub, now - 10)
            self.assertEqual(collect.live_status(stopped, transcript, now, cursor), "running")
            at(sub, now - collect.QUIET_S - 1)
            self.assertEqual(collect.live_status(stopped, transcript, now, cursor), "done")
            self.assertEqual(collect.live_status(stopped, None, now, cursor), "done")


class ChatFamilies(unittest.TestCase):
    def test_child_chats_hang_under_the_top_of_their_family_and_lift_it_to_their_section(self):
        cards = [card("busy", 50, "running"), card("parent", 10, prs=["o/r#1"]), card("side", 30, needs=["finished"], prs=["o/r#2"]),
                 card("side-of-side", 40), card("orphan", 20), card("working", 5, needs=["finished"]), card("helper", 60, "running")]
        top = collect.nest_chats(cards, {"side": "parent", "side-of-side": "side", "orphan": "off-board", "helper": "working"})
        self.assertEqual([c["id"] for c in top], ["parent", "working", "busy", "orphan"])
        self.assertEqual([k["id"] for k in top[0]["children"]], ["side-of-side", "side"])
        self.assertEqual([p["key"] for p in top[0]["prs"]], ["o/r#1", "o/r#2"])

    def test_recent_subagents_of_a_board_chat_join_it_without_needing_you(self):
        with tempfile.TemporaryDirectory() as d:
            cursor.STATE_DB = os.path.join(d, "state.db")
            now = T + 1000
            ms = lambda s: int(s * 1000)  # noqa: E731
            state = sqlite3.connect(cursor.STATE_DB)
            state.execute("create table cursorDiskKV (key primary key, value)")
            for cid, doc in [
                ("parent", {"subagentComposerIds": ["working", "quiet", "finished", "old", "hooked"]}),
                ("hooked", {"subagentInfo": {"parentComposerId": "parent", "subagentType": 3}}),
                ("side", {"subagentInfo": {"parentComposerId": "parent", "subagentType": cursor.SIDE_CHAT}}),
                ("working", {"name": "Working", "createdAt": ms(now - 600), "status": "none"}),
                ("quiet", {"name": "Quiet", "createdAt": ms(now - 600), "status": "none"}),
                ("finished", {"name": "Finished", "createdAt": ms(now - 60), "status": "completed"}),
                ("old", {"name": "Old", "createdAt": ms(now - collect.BOARD_WINDOW_S - 1), "status": "none"}),
            ]:
                state.execute("insert into cursorDiskKV values (?, ?)", ("composerData:" + cid, json.dumps(doc)))
            state.commit()
            subs = os.path.join(d, "parent", "subagents")
            os.makedirs(subs)
            for sid, at in [("working", now - 5), ("quiet", now - cursor.SUBAGENT_QUIET_S - 1)]:
                open(os.path.join(subs, sid + ".jsonl"), "w").close()
                os.utime(os.path.join(subs, sid + ".jsonl"), (at, at))
            index = {"parent": os.path.join(d, "parent", "parent.jsonl")}
            cards = [card("parent", now, "running"), card("hooked", now, needs=["finished"]), card("side", now, needs=["finished"])]
            extra, parents = cursor.family(cards, {}, now, index)
            self.assertEqual(sorted((c["id"], c["status"]) for c in extra),
                             [("finished", "done"), ("quiet", "done"), ("working", "running")])
            self.assertEqual(next(c for c in extra if c["id"] == "working")["updated_at"], now - 5)
            self.assertEqual(set(parents), {"hooked", "side", "working", "quiet", "finished"})
            self.assertEqual([(c["kind"], c["needs_you"]) for c in cards[1:]], [("subagent", []), ("side", ["finished"])])


class GitProbe(unittest.TestCase):
    def test_probe_never_writes_the_index(self):
        """A probe that rewrote the index would take index.lock and break a rebase running in the slot."""
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                collect.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=repo)
            git("init", "-q")
            with open(os.path.join(repo, "f"), "w") as fh:
                fh.write("x\n")
            git("add", "f")
            git("commit", "-qm", "c")
            index = os.path.join(repo, ".git", "index")
            os.utime(index, (1, 1))
            os.utime(os.path.join(repo, "f"), (2, 2))
            before = os.stat(index).st_mtime_ns
            info = collect.git_info(repo)
            self.assertFalse(info["dirty"])
            self.assertEqual(os.stat(index).st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
