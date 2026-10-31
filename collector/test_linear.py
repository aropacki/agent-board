#!/usr/bin/python3
"""Linear inbox tests: which notifications become board events, and what they open. Run: python3 collector/test_linear.py"""

import os
import sys
import unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import linear  # noqa: E402

PR_URL = "https://github.com/o/r/pull/7"


def pr_note(nid, kind, subtitle, actor=None, bot=None, read=None):
    return {"id": nid, "type": kind, "subtitle": subtitle, "url": "https://linear.app/x/review/%s" % nid,
            "createdAt": "2026-10-30T12:00:%02d.000Z" % int(nid[1:]), "readAt": read,
            "actor": {"name": actor, "displayName": actor} if actor else None, "botActor": {"name": bot} if bot else None,
            "pullRequest": {"number": 7, "title": "Fix it", "url": PR_URL}}


class LinearEvents(unittest.TestCase):
    def events(self, notes, board=("o/r#7",)):
        return linear.events([linear.record(n) for n in notes], set(board))

    def test_review_requests_count_only_when_they_name_you(self):
        got = self.events([pr_note("n1", "pullRequestReviewRequested", "Ana requested your review", "Ana"),
                           pr_note("n2", "pullRequestReviewRequested", "Ana requested a review from Offers", "Ana")])
        self.assertEqual([(e["id"], e["kind"], e["text"], e["target"]) for e in got],
                         [("n1", "review", "Review requested: #7 Fix it · Ana", PR_URL)])

    def test_bot_comments_are_kept_and_open_the_comments_on_the_board(self):
        got = self.events([pr_note("n3", "pullRequestCommented", "Claude commented:  Looks\n good", bot="Claude")])
        self.assertEqual([(e["kind"], e["text"], e["target"]) for e in got],
                         [("comments", "Comment from Claude: #7 Fix it · “Looks good”", "comments:o/r#7")])

    def test_a_pr_off_the_board_opens_the_notification_in_linear(self):
        got = self.events([pr_note("n4", "pullRequestCommented", "Bo commented: why", "Bo")], board=())
        self.assertEqual(got[0]["target"], "https://linear.app/x/review/n4")

    def test_review_outcomes_and_read_state(self):
        got = self.events([pr_note("n5", "pullRequestApproved", "Bo approved with comment: ship it", "Bo", read="t"),
                           pr_note("n6", "pullRequestCommented", "Bo requested changes: not yet", "Bo")])
        self.assertEqual([(e["kind"], e["text"], e["read"]) for e in got],
                         [("changes", "Changes requested by Bo: #7 Fix it · “not yet”", False),
                          ("approved", "Approved by Bo: #7 Fix it · “ship it”", True)])

    def test_issue_activity_addressed_to_you_only(self):
        issue = {"identifier": "OFF-12", "title": "Slow board", "url": "https://linear.app/x/issue/OFF-12"}
        notes = [{"id": "n7", "type": "issueNewComment", "subtitle": "Cy commented: try this", "url": issue["url"],
                  "createdAt": "2026-10-30T12:00:07.000Z", "actor": {"name": "Cy"}, "issue": issue},
                 {"id": "n8", "type": "issueStatusChanged", "subtitle": "Cy moved it", "url": issue["url"],
                  "createdAt": "2026-10-30T12:00:08.000Z", "actor": {"name": "Cy"}, "issue": issue}]
        got = self.events(notes)
        self.assertEqual([(e["kind"], e["text"], e["target"]) for e in got],
                         [("issue", "Comment from Cy: OFF-12 Slow board · “try this”", issue["url"])])


if __name__ == "__main__":
    unittest.main()
