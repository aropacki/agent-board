#!/usr/bin/python3
"""Agent source and worktree provider tests: what each tool's files say about its chats.
Run: python3 collector/test_sources.py"""

import datetime
import json
import os
import sys
import tempfile
import time
import unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import chat_status  # noqa: E402
from sources import claude_code, codex  # noqa: E402
from worktrees import git  # noqa: E402

NOW = int(time.time())


def stamp(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat()


def write(path, entries, mode="w"):
    with open(path, mode) as fh:
        for e in entries:
            fh.write(json.dumps(e) + "\n")


class ClaudeCode(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        claude_code.PROJECTS = os.path.join(self.dir.name, "projects")
        claude_code.CACHE = os.path.join(self.dir.name, "cache.json")
        os.makedirs(os.path.join(claude_code.PROJECTS, "-Users-me-repo"))
        self.path = os.path.join(claude_code.PROJECTS, "-Users-me-repo", "s1.jsonl")

    def tearDown(self):
        self.dir.cleanup()

    def entry(self, kind, ts, content, stop=None, **extra):
        message = {"role": kind, "content": content}
        if stop:
            message["stop_reason"] = stop
        return dict({"type": kind, "timestamp": stamp(ts), "cwd": "/Users/me/repo", "sessionId": "s1",
                     "message": message}, **extra)

    def status(self):
        claude_code.chats(NOW)
        return chat_status(claude_code.summary(self.path, NOW), NOW)

    def test_turns_come_from_prompts_and_finished_replies_not_tool_traffic(self):
        tool_use = [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]
        write(self.path, [self.entry("user", NOW - 60, "fix it"),
                          self.entry("assistant", NOW - 50, tool_use, stop="tool_use"),
                          self.entry("user", NOW - 40, [{"type": "tool_result", "content": "ok"}])])
        self.assertEqual(self.status(), "running")
        write(self.path, [self.entry("assistant", NOW - 30, [{"type": "text", "text": "done"}], stop="end_turn")], "a")
        self.assertEqual(self.status(), "done")
        write(self.path, [self.entry("user", NOW - 20, "again"),
                          self.entry("user", NOW - 10, [{"type": "text", "text": "[Request interrupted by user]"}])], "a")
        self.assertEqual(self.status(), "aborted")

    def test_a_sidechain_reply_does_not_finish_the_main_turn(self):
        write(self.path, [self.entry("user", NOW - 60, "fix it"),
                          self.entry("assistant", NOW - 50, [{"type": "text", "text": "x"}], stop="end_turn",
                                     isSidechain=True)])
        self.assertEqual(self.status(), "running")

    def test_a_title_the_user_set_wins_over_the_generated_one(self):
        write(self.path, [self.entry("user", NOW - 60, "hi"), {"type": "ai-title", "aiTitle": "Generated"},
                          {"type": "custom-title", "customTitle": "Mine"}])
        self.assertEqual([(c["id"], c["title"], c["cwd"]) for c in claude_code.chats(NOW)],
                         [("s1", "Mine", "/Users/me/repo")])

    def test_shell_commands_are_bash_tool_calls(self):
        e = self.entry("assistant", NOW, [{"type": "tool_use", "name": "Bash", "input": {"command": "gh pr edit 4"}},
                                          {"type": "tool_use", "name": "Read", "input": {"file_path": "/a"}}])
        self.assertEqual(list(claude_code.lines(e)), [("shell", "gh pr edit 4")])

    def test_hook_payloads_map_to_journal_terms(self):
        bash = claude_code.hook({"session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash",
                                 "tool_input": {"command": "git push origin me/x"}, "cwd": "/w"})
        self.assertEqual((bash["event"], bash["command"], bash["dirs"]), ("tool", "git push origin me/x", ["/w"]))
        read = claude_code.hook({"session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Read",
                                 "tool_input": {"command": "not a shell"}})
        self.assertEqual(read["command"], "")
        self.assertIsNone(claude_code.hook({"hook_event_name": "Stop"}))


class Codex(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        codex.SESSIONS = os.path.join(self.dir.name, "sessions")
        codex.INDEX = os.path.join(self.dir.name, "session_index.jsonl")
        codex.CACHE = os.path.join(self.dir.name, "cache.json")
        os.makedirs(os.path.join(codex.SESSIONS, "2026", "01", "01"))

    def tearDown(self):
        self.dir.cleanup()

    def session(self, sid, events, source="vscode"):
        path = os.path.join(codex.SESSIONS, "2026", "01", "01", "rollout-2026-01-01T00-00-00-%s.jsonl" % sid)
        meta = {"type": "session_meta", "timestamp": stamp(NOW - 100),
                "payload": {"id": sid, "cwd": "/w", "source": source}}
        write(path, [meta] + [{"type": "event_msg", "timestamp": stamp(ts), "payload": {"type": t}} for t, ts in events])
        return path

    def test_status_follows_the_last_turn_event(self):
        parent = "019e0000-0000-7000-8000-000000000001"
        paths = {
            "running": self.session(parent, [("task_started", NOW - 60)]),
            "done": self.session("019e0000-0000-7000-8000-000000000002",
                                 [("task_started", NOW - 60), ("task_complete", NOW - 30)]),
            "aborted": self.session("019e0000-0000-7000-8000-000000000003",
                                    [("task_started", NOW - 60), ("turn_aborted", NOW - 30)]),
        }
        write(codex.INDEX, [{"id": parent, "thread_name": "Parent"}])
        chats = {c["id"]: c for c in codex.chats(NOW)}
        self.assertEqual(chats[parent]["title"], "Parent")
        for want, path in paths.items():
            self.assertEqual(chat_status(codex.summary(path, NOW), NOW), want)

    def test_a_spawned_subagent_hangs_under_its_parent_and_never_needs_you(self):
        parent, child = "019e0000-0000-7000-8000-00000000000a", "019e0000-0000-7000-8000-00000000000b"
        self.session(parent, [("task_started", NOW - 60)])
        spawn = {"subagent": {"thread_spawn": {"parent_thread_id": parent, "agent_nickname": "Scout"}}}
        self.session(child, [("task_started", NOW - 50), ("task_complete", NOW - 40)], source=spawn)
        chats = codex.chats(NOW)
        cards = [dict(c, needs_you=["finished"]) for c in chats]
        _, parents = codex.family(cards, {}, NOW, {})
        kid = next(c for c in cards if c["id"] == child)
        self.assertEqual((parents, kid["title"], kid["kind"], kid["needs_you"]), ({child: parent}, "Scout", "subagent", []))


class GitWorktrees(unittest.TestCase):
    PORCELAIN = ("worktree /src/repo\nHEAD abc\nbranch refs/heads/main\n\n"
                 "worktree /src/wt/feature\nHEAD def\nbranch refs/heads/me/feature\n\n"
                 "worktree /src/wt/gone\nHEAD 123\ndetached\nprunable gitdir file points to non-existent location\n")

    def test_linked_worktrees_skip_the_main_checkout_and_prunable_ones(self):
        self.assertEqual([w["path"] for w in git.parse(self.PORCELAIN)], ["/src/wt/feature"])

    def test_a_cd_into_a_worktree_subfolder_names_the_worktree(self):
        known = {"/src/wt/feature": {}, "/src/wt/feature-2": {}}
        self.assertEqual(git.slot_in_command("cd /src/wt/feature/js && ls", known), "/src/wt/feature")
        self.assertEqual(git.slot_in_command("cd /src/wt/feature-2 && cd /tmp", known), "/src/wt/feature-2")
        self.assertIsNone(git.slot_in_command("cd /src/wt/feature-other", known))


if __name__ == "__main__":
    unittest.main()
