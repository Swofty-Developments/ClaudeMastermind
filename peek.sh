#!/usr/bin/env bash
# Non-blocking snapshot of a sub-claude's current state. Use any time the
# orchestrator wants to see how an agent is going without interrupting it
# or waiting for watch.sh to fire. Cheap to call — does not consume Monitor
# slots.
#
# Args:
#   $1 = tmux session name
#
# Stdout (concise so it doesn't rot context):
#   Line 1: STATUS: working | idle | permission-prompt | not-found
#   Lines 2+: latest response block (or partial if mid-stream); if a
#             permission prompt is up, the popup region is shown instead.
set -euo pipefail

SESSION="$1"
# Detect spinner via "esc to interrupt" in the LAST 3 LINES of the pane.
# Anchoring by location (tail -3 = footer region) instead of by adjacent text
# survives narrow-pane wrapping where "shift+tab to cycle) · esc" gets split
# across lines. Agent text in the scrollback can't false-positive because
# it's outside the tail window.
FOOTER_REGION_LINES=3
FOOTER_PATTERN="esc to interrupt"

pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null) || {
  echo "STATUS: not-found"
  exit 0
}

# Permission popups have signature text in the bottom region
if echo "$pane" | tail -25 | grep -qE "Do you want to|^❯ 1\.|allow this"; then
  echo "STATUS: permission-prompt"
  echo "---"
  echo "$pane" | tail -25
  exit 0
fi

if echo "$pane" | tail -n "$FOOTER_REGION_LINES" | grep -q "$FOOTER_PATTERN"; then
  echo "STATUS: working"
else
  echo "STATUS: idle"
fi
echo "---"

# Extract latest ● block (may be partial mid-stream)
# `|| true` guards: if no ● in pane (e.g. scrolled off mid-stream before
# the new response arrives), grep exits 1 and pipefail would kill us.
last_line_n=$(echo "$pane" | grep -n '[⏺●] ' | tail -1 | cut -d: -f1 || true)
if [ -n "$last_line_n" ]; then
  suffix=$(echo "$pane" | tail -n "+$last_line_n")
  end_offset=$(echo "$suffix" | grep -nE '^✻ [A-Za-z]+ for [0-9]+s' | head -1 | cut -d: -f1 || true)
  if [ -n "$end_offset" ]; then
    echo "$suffix" | head -n "$end_offset"
  else
    echo "$suffix"
  fi
else
  # No ● yet — agent is still in pre-response thinking. Show tail of pane
  # so the orchestrator can still see what's on screen (spinner line, tip, etc.)
  echo "$pane" | tail -15
fi
