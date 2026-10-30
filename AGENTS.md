# Agent Board: agent instructions

A macOS panel (Swift) fed by a stdlib Python collector. Read [CODEMAP.md](CODEMAP.md) first for where things live.

If the user asks you to set up, install, or configure the board, follow [SETUP.md](SETUP.md).

## Build and check

- `make build` builds `.build/release/AgentBoard`. `make install` rebuilds, installs, and restarts the app.
- `make test` is the gate. It runs the logic tests, the state consistency check, the menu audit, and the collector tests. Run it after every change.
- The toolchain may be Command Line Tools only, so there is no XCTest. Swift tests live in `Sources/AgentBoard/Bench/LogicTests.swift` and run through `--bench`.
- Add a `check(...)` only for a contract that would fail silently: what gets posted to GitHub, which chat and PRs a prompt goes to, a parser of GitHub or agent output, or a timer that moves cards. Extend an existing check before adding one. Layout, copy, and anything visible on first use are checked by eye and by the benches.
- Collector tests are `unittest` files named `collector/test_*.py`.

## Perf

`make perf` plays scripted interactions against the real views and prints one row per scenario.
It uses seeded data in a temp data directory, so runs differ only by the code. It never runs `gh` or an agent.

The loop for a perf change:

1. `make perf ONLY=diff`, then `make perf-save` to set the baseline.
2. `make perf-profile ONLY=diff/jump` to see where that scenario's frames go.
3. Change the code, then `make perf ONLY=diff` again. The last column compares with the baseline; `~` is noise.
4. Open `.build/perf/<scenario>.png` to check what the scenario looked like halfway through.

Columns are main-thread ms per frame. The 120 Hz budget is 8.3 ms. `cold` is the worst frame of the first pass,
which includes first layout. `reflow` counts frames where the scroll height changed, which shows as a jump.
`late` is wall-clock ms a frame ran past its slot, so it also counts time the main thread waited for a core.
`Minst` and `Mmax` are the p95 and worst frame in millions of instructions retired. Timings swing about 2x as the
main thread moves between performance and efficiency cores; instruction counts hold steady, so compare builds on
them. In a scenario where the costly event is a few frames out of many, p95 lands beside the event, so read `Mmax`.
`make perf LOAD=10` runs ten busy threads alongside and compares against its own baseline, for how the board
holds up on a machine running hard.
A line that says a scenario "tried to run" means a fetch leaked into it: seed that cache in `Fixtures.seed`.

`BENCH_FRAMES=1 BENCH_ONLY=<scenario> .build/release/AgentBoard --bench` prints every frame of one pass, which
shows a spike's shape: one costly frame, or an animation that keeps ticking. When the machine is busy, the baseline
column drifts; copy the old binary aside and run the two in turns instead.

Add a scenario to `Perf.scenarios` for any interaction you want to climb on. Drive it the way the app does, with
the same animation, and space its steps wider than that animation so each frame measures one change.

## Bench

`<binary> --bench` with one of these set renders or checks the live board offscreen. It never starts the collector.

| Variable | Use |
|---|---|
| `BENCH_LOGIC=1`, `BENCH_CONSISTENCY=1`, `BENCH_MENUAUDIT=1` | The checks that `make test` runs. |
| `BENCH_FULL=<file.png>` | Screenshot of the full board. Add `BENCH_DIFF*`, `BENCH_DISCUSSION*`, or `BENCH_CHECKS*` to open those views from fixture files. With `BENCH_DIFF`, `BENCH_OVERVIEW=<graphql.json>` fills the overview and `BENCH_PAGE=overview` shows it. |
| `BENCH_SNAP=<file.png>`, `BENCH_TICKER=<file.png>`, `BENCH_BANNER=<file.png>` | Screenshots of a row menu, the ticker, and the notification banners. `BENCH_WAIT=0.5` catches a banner while it arrives. `BENCH_BANNER_SEQ=<prefix>` writes frames of one banner arriving and leaving. |

## Rules

- Never post, reply, resolve, or comment on a real PR to test a change. Read-only `gh` calls are fine.
- Do not drive the user's screen. Do not send synthetic keys or move the pointer. Offscreen bench windows and `screencapture -x` are fine.
- The collector stays one process with no dependencies outside the Python standard library.
- Code for one agent tool goes in `Tools/` and `collector/sources/`; code for one worktree manager goes in `collector/worktrees/`. Shared code calls the interface, never a tool by name. [CONTRIBUTING.md](CONTRIBUTING.md) says how to add one.
- Source and provider tests use short transcripts written by hand. Never copy a real transcript or session file into the repo.
- Team-specific values belong in `config.json`, not in code. Defaults and sample data stay generic.
- Settings that the app and the collector share go in both `Sources/AgentBoard/Support/Config.swift` and `collector/config.py`.
- Hooks must stay fast and must not record prompt text, command text, or tool output. A hook's stdout goes back to its tool, and some tools add it to the chat, so print only the reply the tool expects.
- Keep views cheap. Read fast-changing observable state, such as `board.now`, in small leaf views, not in large parent bodies.
- Comments say why, not what. Do not narrate change history in comments or test names.
