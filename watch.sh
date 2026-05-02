#!/usr/bin/env bash
# Watch a sub-claude session for a new response and emit ONE event when it
# settles. Designed to be run as the command of the Monitor tool — its
# stdout is a stream of events, exit ends the watch.
#
# Args:
#   $1 = tmux session name
#
# Reads:
#   /tmp/<session>.last_resp — baseline (last ⏺ line before send.sh was called)
#
# Writes:
#   /tmp/<session>.response — the latest response block (extracted: from the
#   last ⏺ to the next "✻ <verb> for Ns" marker)
#
# Emits exactly one event line on stdout when complete:
#   "RESPONSE_READY <session> <bytes>"
# The orchestrator reads /tmp/<session>.response after seeing the event.
#
# Detection:
#   Response complete when:
#     (a) the last ⏺ line in the pane has changed from baseline, AND
#     (b) the footer spinner anchor "shift+tab to cycle) · esc" is absent.
#   Anchor to the footer adjacency, NOT the bare "esc to interrupt" string —
#   agents may quote the latter in their actual response text.
#
#   Edge case: if two consecutive responses are textually identical (e.g.
#   both "⏺ ok"), the last-line check won't trip. Mitigated by also
#   tracking the count of ⏺ markers in the pane: if it changed, fire.
set -euo pipefail

SESSION="$1"
PRE=$(cat "/tmp/$SESSION.last_resp" 2>/dev/null || echo "")
PRE_COUNT_FILE="/tmp/$SESSION.last_count"
PRE_COUNT=$(cat "$PRE_COUNT_FILE" 2>/dev/null || echo "0")
OUT="/tmp/$SESSION.response"
# Detect spinner via "esc to interrupt" in the LAST 3 LINES of the pane.
# Anchoring by tail location (= footer region) instead of by adjacent text
# survives narrow-pane wrapping where "shift+tab to cycle) · esc" gets split
# across multiple lines. Agent text in scrollback can't false-positive
# because it's outside the tail window.
FOOTER_REGION_LINES=3
FOOTER_PATTERN="esc to interrupt"

while true; do
  pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null) || {
    echo "WATCH_ERROR session $SESSION not found"
    exit 1
  }
  cur_last=$(echo "$pane" | grep '⏺ ' | tail -1 || true)
  cur_count=$(echo "$pane" | grep -c '⏺ ' || true)
  spinning=$(echo "$pane" | tail -n "$FOOTER_REGION_LINES" | grep -c "$FOOTER_PATTERN" || true)

  changed=0
  if [ "$cur_last" != "$PRE" ]; then changed=1; fi
  if [ "$cur_count" != "$PRE_COUNT" ]; then changed=1; fi

  if [ "$changed" -eq 1 ] && [ "$spinning" -eq 0 ]; then
    last_line_n=$(echo "$pane" | grep -n '⏺ ' | tail -1 | cut -d: -f1 || true)
    if [ -n "$last_line_n" ]; then
      suffix=$(echo "$pane" | tail -n "+$last_line_n")
      end_offset=$(echo "$suffix" | grep -nE '^✻ [A-Za-z]+ for [0-9]+s' | head -1 | cut -d: -f1 || true)
      if [ -n "$end_offset" ]; then
        echo "$suffix" | head -n "$end_offset" > "$OUT"
      else
        echo "$suffix" > "$OUT"
      fi
      bytes=$(wc -c < "$OUT" | tr -d ' ')
      # Update baseline for future sends in this session
      echo "$cur_last" > "/tmp/$SESSION.last_resp"
      echo "$cur_count" > "$PRE_COUNT_FILE"
      echo "RESPONSE_READY $SESSION $bytes"
      exit 0
    fi
  fi
  sleep 1
done
