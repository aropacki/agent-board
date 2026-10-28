"""Worktree providers: where the board finds the checkouts agents work in. config.json's `worktrees` picks one by
NAME; without it, treehouse when its pools exist, else git.

A provider is a module with:

  NAME                                  its config name
  available()                           True when this machine has any of its slots
  slots(home_repo)                      {path: {"pool", "name", "display_name", "path", "leased", "lease_holder", "leased_at"}}
                                        leased_at is ISO 8601; lease_holder may be None
  slot_in_command(command, known)       the last slot path a shell command cds into, or None
  slot_in_dir(path, known)              the slot holding a working directory, or None
  slot_in_output(command, output)       a slot path the command printed, such as a lease that hands one out, or None
  holders(command)                      lease-holder labels the command used; a set, empty when the tool has none
  give_back(path)                       (exit code, message); frees a slot the board has already checked is safe

`known` is the dict from slots() when the caller has it, so path matching does not list the slots again.
"""

from config import CONFIG

from . import git, treehouse

PROVIDERS = {m.NAME: m for m in (treehouse, git)}


class _NoWorktrees:
    NAME = "none"

    @staticmethod
    def available():
        return False

    @staticmethod
    def slots(home_repo=None):
        return {}

    @staticmethod
    def slot_in_command(command, known=None):
        return None

    @staticmethod
    def slot_in_dir(path, known=None):
        return None

    @staticmethod
    def slot_in_output(command, output):
        return None

    @staticmethod
    def holders(command):
        return set()

    @staticmethod
    def give_back(path):
        return 2, "This board has no worktree provider"


def provider():
    name = CONFIG.get("worktrees")
    if name == "none":
        return _NoWorktrees
    if name in PROVIDERS:
        return PROVIDERS[name]
    return treehouse if treehouse.available() else git
