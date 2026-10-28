#!/bin/bash
# Agent board actions.
#   act.sh return <slot-path>
# Exit 0 on success; otherwise prints the reason on stdout.

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
BOARD="${AGENT_BOARD_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"

case "${1:-}" in
  return)
    [ -n "${2:-}" ] || { echo "Missing slot path"; exit 2; }
    out=$("$BOARD/bin/collect.py" return "$2"); code=$?
    echo "$out"
    "$BOARD/bin/collect.py" --fresh >/dev/null 2>&1 &
    exit $code
    ;;
  *)
    echo "usage: act.sh return <path>"
    exit 2
    ;;
esac
