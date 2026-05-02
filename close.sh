#!/usr/bin/env bash
# Close a sub-agent. Kills the tmux session; the attached GUI terminal window
# (whichever emulator spawn.sh chose) exits when its child shell dies.
# Args:
#   $1 = tmux session name
set -euo pipefail
SESSION="$1"
tmux kill-session -t "$SESSION" 2>/dev/null || true
echo "closed $SESSION"
