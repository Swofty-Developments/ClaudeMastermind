#!/usr/bin/env bash
# Submit a prompt to a sub-claude. FIRE AND FORGET — does NOT wait for the
# response. The orchestrator should arm a Monitor with watch.sh immediately
# after this returns, and continue with other work.
#
# Args:
#   $1 = tmux session name (e.g. "mastermind-3")
#   $2 = prompt text (single argument; quote it)
#
# Side effect: writes /tmp/<session>.last_resp = the last ⏺ line in the pane
# BEFORE submission. watch.sh reads this as its baseline.
#
# Submission quirk:
#   `tmux send-keys "$MSG" Enter` does NOT reliably submit — bracketed-paste
#   handling consumes the Enter. ALWAYS send the message and Enter as
#   separate calls.
set -euo pipefail

SESSION="$1"
PROMPT="$2"

# Snapshot baseline for watch.sh — both the last ⏺ line text and the count
# of ⏺ markers in the visible pane. watch.sh fires on a change in EITHER,
# so both must be set fresh on each send (or it could trigger off stale
# state from a prior failed watch).
pane=$(tmux capture-pane -t "$SESSION" -p)
echo "$pane" | grep '⏺ ' | tail -1 > "/tmp/$SESSION.last_resp" \
  || echo "" > "/tmp/$SESSION.last_resp"
echo "$pane" | grep -c '⏺ ' > "/tmp/$SESSION.last_count" || echo 0 > "/tmp/$SESSION.last_count"

# Type prompt, settle, send Enter separately
tmux send-keys -t "$SESSION" "$PROMPT"
sleep 0.4
tmux send-keys -t "$SESSION" Enter

echo "submitted to $SESSION"
