#!/usr/bin/python3
"""PR refresh tests: which PRs survive a fetch. Run: python3 collector/test_prs.py"""

import os
import sys
import tempfile
import unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect  # noqa: E402

REPO = "o/r"


class GitHub:
    """Stands in for gh: `listed` is each search's answer, `states` each PR's state, absent when a lookup comes back
    empty. `updated` and `ci` are what each PR's updatedAt and head commit read now; `full` records full lookups."""

    def __init__(self, listed, states):
        self.listed, self.states = listed, states
        self.updated, self.ci, self.full = {}, {}, []

    def node(self, n):
        return {"number": n, "state": self.states[n], "updatedAt": self.updated.get(n, "t0"), "commits": self.ci.get(n)}

    def search_prs(self, query):
        kind = next(k for k, q in collect.PR_SEARCHES.items() if q == query)
        return [(REPO, n) for n in self.listed.get(kind, [])], None

    def fetch_details(self, batch):
        self.full += [n for _, n in batch]
        return [dict(self.node(n), title="T%d" % n) if n in self.states else None for _, n in batch], None

    def fetch_light(self, batch):
        return [self.node(n) if n in self.states else None for _, n in batch], None


def record(n, misses=0):
    return {"key": "%s#%d" % (REPO, n), "number": n, "misses": misses}


class FetchPRs(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = collect.search_prs, collect.fetch_details, collect.fetch_light, collect.LINKED_WANTED, collect.PR_NODES
        collect.LINKED_WANTED = os.path.join(self.dir.name, "linked.json")
        collect.PR_NODES = os.path.join(self.dir.name, "nodes.json")

    def tearDown(self):
        collect.search_prs, collect.fetch_details, collect.fetch_light, collect.LINKED_WANTED, collect.PR_NODES = self.saved
        self.dir.cleanup()

    def fetch(self, github, previous, now=1000):
        collect.search_prs, collect.fetch_details, collect.fetch_light = github.search_prs, github.fetch_details, github.fetch_light
        results, held, error = collect.fetch_prs(previous, now)
        self.assertIsNone(error)
        self.nodes = {n["number"]: n for nodes in results.values() for n, _ in nodes}
        shown = {kind: sorted((n["number"], misses) for n, misses in nodes) for kind, nodes in results.items()}
        return shown, {kind: sorted((r["number"], r["misses"]) for r in records) for kind, records in held.items()}

    def test_an_empty_search_keeps_your_open_prs(self):
        shown, _ = self.fetch(GitHub({"mine": []}, {1: "OPEN", 2: "OPEN"}), {"mine": [record(1), record(2, misses=5)]})
        self.assertEqual(shown["mine"], [(1, 1), (2, 6)])

    def test_a_closed_or_merged_pr_leaves_at_once(self):
        github = GitHub({"mine": [1]}, {1: "OPEN", 2: "MERGED", 3: "CLOSED"})
        shown, held = self.fetch(github, {"mine": [record(1), record(2), record(3)]})
        self.assertEqual((shown["mine"], held["mine"]), ([(1, 0)], []))

    def test_a_review_request_leaves_after_it_misses_enough_searches(self):
        github = GitHub({"review": []}, {7: "OPEN"})
        shown, _ = self.fetch(github, {"review": [record(7, misses=collect.MISS_LIMIT - 2)]})
        self.assertEqual(shown["review"], [(7, collect.MISS_LIMIT - 1)])
        shown, _ = self.fetch(github, {"review": [record(7, misses=collect.MISS_LIMIT - 1)]})
        self.assertEqual(shown["review"], [])

    def test_a_pr_whose_lookup_comes_back_empty_keeps_its_last_record(self):
        shown, held = self.fetch(GitHub({"mine": []}, {}), {"mine": [record(4)]})
        self.assertEqual((shown["mine"], held["mine"]), ([], [(4, 1)]))

    def test_a_pr_back_in_the_search_resets_its_misses(self):
        shown, _ = self.fetch(GitHub({"review": [7]}, {7: "OPEN"}), {"review": [record(7, misses=2)]})
        self.assertEqual(shown["review"], [(7, 0)])

    def test_an_unchanged_pr_keeps_its_details_and_takes_fresh_ci(self):
        github = GitHub({"mine": [1]}, {1: "OPEN"})
        github.ci[1] = "running"
        self.fetch(github, {})
        github.ci[1] = "passing"
        self.fetch(github, {}, now=1060)
        self.assertEqual((github.full, self.nodes[1]["title"], self.nodes[1]["commits"]), ([1], "T1", "passing"))

    def test_a_pr_whose_updated_at_moves_is_fetched_in_full(self):
        github = GitHub({"mine": [1]}, {1: "OPEN"})
        self.fetch(github, {})
        github.updated[1] = "t1"
        self.fetch(github, {}, now=1060)
        self.assertEqual(github.full, [1, 1])

    def test_details_older_than_the_limit_are_fetched_again(self):
        github = GitHub({"mine": [1]}, {1: "OPEN"})
        self.fetch(github, {})
        self.fetch(github, {}, now=1000 + collect.FULL_MAX_AGE_S)
        self.assertEqual(github.full, [1, 1])

    def test_a_closed_pr_keeps_its_details_past_the_limit(self):
        github = GitHub({}, {1: "MERGED"})
        with open(collect.LINKED_WANTED, "w") as f:
            f.write('["o/r#1"]')
        self.fetch(github, {})
        self.fetch(github, {}, now=1000 + collect.FULL_MAX_AGE_S)
        self.assertEqual(github.full, [1])

    def test_a_merge_seen_by_the_light_lookup_drops_the_pr(self):
        github = GitHub({"mine": [1]}, {1: "OPEN"})
        self.fetch(github, {})
        github.states[1] = "MERGED"
        shown, held = self.fetch(github, {"mine": [record(1)]}, now=1060)
        self.assertEqual((shown["mine"], held["mine"], github.full), ([], [], [1]))


if __name__ == "__main__":
    unittest.main()
