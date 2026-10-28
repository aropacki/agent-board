"""Summarizes the main thread of a macOS `sample` report: framework phases, this app's functions, and leaf self time.

Usage: python3 extras/profile_top.py <sample.txt>
"""

import re
import sys

LINE = re.compile(r"^([\s+!:|]*?)(\d+) (.+?)\s+\(in ([^)]+)\)")
THREAD = re.compile(r"^\s{4}\d+ Thread_")

# Substrings of SwiftUI and system symbols, grouped into the phases a frame spends time in. Phases overlap:
# layout runs inside view updates, so the percentages do not add up to 100.
PHASES = {
    "view bodies": ["DynamicBody.updateValue", "StaticBody.updateValue", ".body.getter"],
    "ForEach diffing": ["DynamicContainerInfo.updateItems", "ForEachState"],
    "layout": ["sizeThatFits", "placeSubviews", "childGeometries", "ViewLayoutEngine"],
    "lazy stacks": ["LazyLayoutViewCache", "LazySubviewPlacements", "IncrementalLayout"],
    "display list": ["DisplayList.ViewUpdater"],
    "text": ["CTLine", "CTFramesetter", "CTTypesetter", "TextLayout", "ResolvedStyledText"],
    "CA commit": ["CA::Transaction::commit"],
    "observation": ["ObservationRegistrar", "withObservationTracking"],
}
SCAFFOLD = ("closure #", "partial apply", "thunk", "implicit closure", "<deduplicated", "specialized closure", "@objc")


def main_thread(text):
    nodes, inside = [], False
    for line in text.splitlines():
        if THREAD.match(line):
            if inside:
                break
            inside = "com.apple.main-thread" in line or "Main Thread" in line
            continue
        if inside:
            m = LINE.match(line)
            if m:
                name = re.sub(r"\s*\+ \d+.*$", "", m.group(3)).strip()
                nodes.append((len(m.group(1)), int(m.group(2)), name, m.group(4)))
    return nodes


def summarize(nodes):
    total = nodes[0][1] if nodes else 0
    inclusive, self_time, phases = {}, {}, {p: 0 for p in PHASES}
    stack = []
    for i, (depth, count, name, lib) in enumerate(nodes):
        while stack and stack[-1][0] >= depth:
            stack.pop()
        outer = [s[1] for s in stack]
        if name not in outer:
            inclusive[(name, lib)] = inclusive.get((name, lib), 0) + count
        for phase, keys in PHASES.items():
            if any(k in name for k in keys) and not any(any(k in o for k in keys) for o in outer):
                phases[phase] += count
        stack.append((depth, name))
        children, child_depth = 0, None
        for d, c, _, _ in nodes[i + 1:]:
            if d <= depth:
                break
            child_depth = child_depth or d
            if d == child_depth:
                children += c
        self_time[(name, lib)] = self_time.get((name, lib), 0) + count - children

    idle = sum(v for (n, _), v in self_time.items() if n.startswith("mach_msg"))
    busy = max(1, total - idle)
    print(f"main thread busy {busy} of {total} samples ({100 * busy / max(1, total):.0f}%)")

    print("\nphases (inclusive, % of busy)")
    for phase, v in sorted(phases.items(), key=lambda kv: -kv[1]):
        if v:
            print(f"  {phase:<16} {100 * v / busy:5.1f}%")

    print("\nthis app's functions (inclusive, % of busy)")
    ours = [(v, n) for (n, lib), v in inclusive.items() if lib == "AgentBoard" and not n.startswith(SCAFFOLD)]
    for v, n in sorted(ours, reverse=True)[:15]:
        print(f"  {100 * v / busy:5.1f}%  {n[:110]}")

    print("\nleaf self time (% of busy)")
    leaves = [(v, n, lib) for (n, lib), v in self_time.items() if v > 0 and not n.startswith("mach_msg")]
    for v, n, lib in sorted(leaves, reverse=True)[:12]:
        print(f"  {100 * v / busy:5.1f}%  {n[:90]}  ({lib})")


if __name__ == "__main__":
    summarize(main_thread(open(sys.argv[1]).read()))
