"""The data directory and its config.json, shared with the app. Every config key is optional."""

import json
import os


def _board_dir():
    env = os.environ.get("AGENT_BOARD_HOME")
    if env:
        return os.path.expanduser(env)
    here = os.path.dirname(os.path.realpath(__file__))
    # Installed copies live in <data dir>/bin. Hooks run them from there without the app's environment.
    if os.path.basename(here) == "bin":
        return os.path.dirname(here)
    return os.path.expanduser("~/.agent-board")


def _load(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


BOARD = _board_dir()
CONFIG = _load(os.path.join(BOARD, "config.json"))
HIDDEN_PRS = os.path.expanduser(CONFIG.get("hiddenPRsFile") or os.path.join(BOARD, "hidden-prs"))
# User accounts that post automated comments. Accounts GitHub marks as bots are skipped without being listed.
BOT_ACCOUNTS = set(CONFIG.get("botAccounts") or [])
# Tool ids whose chats the board shows. The app sends new chats to the first.
TOOLS = CONFIG.get("tools") or ["cursor"]
