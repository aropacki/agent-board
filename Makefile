# Settings below can be overridden in local.mk (gitignored) or on the command line.
-include local.mk

# macOS keys the Accessibility grant and saved preferences to the bundle id and signing identity.
# Keep both fixed once installed; "-" signs ad hoc, which drops the grant on every rebuild.
BUNDLE_ID ?= local.agentboard
SIGN_IDENTITY ?= -
AGENT_BOARD_HOME ?= $(HOME)/.agent-board
APP_DIR ?= $(HOME)/Applications

APP := $(APP_DIR)/AgentBoard.app
STAGE := .build/AgentBoard.app
AGENT := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist
BIN := .build/release/AgentBoard
DOMAIN := gui/$(shell id -u)

.PHONY: build test perf perf-save perf-profile app install uninstall restart

build:
	swift build -c release

test: build
	@out="$$(BENCH_LOGIC=1 $(BIN) --bench)"; echo "$$out" | grep -E '^FAIL|failures:'; echo "$$out" | grep -q 'logic failures: 0'
	@out="$$(BENCH_CONSISTENCY=1 $(BIN) --bench)"; echo "$$out" | grep -E '^FAIL|failures:'; echo "$$out" | grep -q 'consistency failures: 0'
	@echo "menu audit"; ! BENCH_MENUAUDIT=1 $(BIN) --bench | grep -E 'no actions|won by unrelated|nothing at'
	python3 -m unittest discover -s collector -p 'test_*.py'

# ONLY=diff runs the scenarios whose names start with it. ROUNDS sets the passes per scenario (default 3).
# LOAD=n runs n busy threads alongside, and compares against the load baseline.
perf: build
	@BENCH_ONLY="$(ONLY)" BENCH_ROUNDS="$(ROUNDS)" BENCH_LOAD="$(LOAD)" $(BIN) --bench

perf-save:
	cp .build/perf/last.tsv .build/perf/baseline.tsv
	@if [ -f .build/perf/last-load.tsv ]; then cp .build/perf/last-load.tsv .build/perf/baseline-load.tsv; fi

perf-profile: build
	@test -n "$(ONLY)" || { echo "usage: make perf-profile ONLY=<scenario>"; exit 1; }
	@BENCH_PROFILE="$(ONLY)" $(BIN) --bench & pid=$$!; sleep 4; \
	  sample $$pid 6 -mayDie -file .build/perf/profile.txt >/dev/null 2>&1; wait $$pid; \
	  python3 extras/profile_top.py .build/perf/profile.txt

app: build
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/Contents/MacOS"
	cp "$(BIN)" "$(STAGE)/Contents/MacOS/AgentBoard"
	sed 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' install/Info.plist > "$(STAGE)/Contents/Info.plist"
	codesign --force --identifier "$(BUNDLE_ID)" -s "$(SIGN_IDENTITY)" "$(STAGE)"

# The bundle is swapped in whole, since overwriting a running binary in place can crash it.
# Chrome loads the extension unpacked from the data directory, so it is updated in place.
install: app
	mkdir -p "$(APP_DIR)" "$(AGENT_BOARD_HOME)/bin" "$(HOME)/Library/LaunchAgents"
	rm -rf "$(APP).new" && cp -R "$(STAGE)" "$(APP).new" && rm -rf "$(APP)" && mv "$(APP).new" "$(APP)"
	install -m 755 collector/collect.py collector/journal-hook.py collector/act.sh "$(AGENT_BOARD_HOME)/bin/"
	install -m 644 collector/config.py collector/refs.py collector/common.py "$(AGENT_BOARD_HOME)/bin/"
	mkdir -p "$(AGENT_BOARD_HOME)/bin/sources" "$(AGENT_BOARD_HOME)/bin/worktrees"
	install -m 644 collector/sources/*.py "$(AGENT_BOARD_HOME)/bin/sources/"
	install -m 644 collector/worktrees/*.py "$(AGENT_BOARD_HOME)/bin/worktrees/"
	mkdir -p "$(AGENT_BOARD_HOME)/chrome-extension" && cp -R extras/chrome-extension/. "$(AGENT_BOARD_HOME)/chrome-extension/"
	sed -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' -e 's|@APP@|$(APP)|g' -e 's|@AGENT_BOARD_HOME@|$(AGENT_BOARD_HOME)|g' \
		install/launchagent.plist > .build/launchagent.plist
	@if ! cmp -s .build/launchagent.plist "$(AGENT)"; then \
		launchctl bootout "$(DOMAIN)/$(BUNDLE_ID)" 2>/dev/null || true; \
		cp .build/launchagent.plist "$(AGENT)"; \
		launchctl bootstrap "$(DOMAIN)" "$(AGENT)"; \
	fi
	launchctl kickstart -k "$(DOMAIN)/$(BUNDLE_ID)"

restart:
	launchctl kickstart -k "$(DOMAIN)/$(BUNDLE_ID)"

# Leaves the data directory and Cursor hooks in place.
uninstall:
	launchctl bootout "$(DOMAIN)/$(BUNDLE_ID)" 2>/dev/null || true
	rm -f "$(AGENT)"
	rm -rf "$(APP)"
