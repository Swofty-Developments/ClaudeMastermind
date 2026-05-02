#!/usr/bin/env bash
# Spawn a new mastermind sub-agent in tmux + claude, opened in a GUI terminal
# window when one is available. Auto-detects the terminal emulator across
# macOS / Linux / WSL. Falls back to a detached tmux session (no GUI window)
# when no supported terminal is found — the orchestrator can still drive
# the agent; the user just attaches manually with `tmux attach -t SESSION`.
#
# Hard dependencies: tmux, claude, jq. If any is missing, exits 2 with a
# `MASTERMIND_DEP_MISSING` block on stderr describing how to install it.
# The orchestrator must relay that block to the user verbatim.
#
# Args:
#   spawn.sh [--n N] [role]
#   --n N  : explicitly assign agent number (use when spawning in parallel
#            so callers pre-allocate IDs and avoid jq read/write races).
#   role   : informational, used in the window title (default: builder)
#
# Stdout (success): session name on its own line (e.g. "mastermind-3")
# Stderr (soft notice): MASTERMIND_NOTICE: ... when no GUI terminal launched

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/state.json"

# ---------- dependency checks ----------
# Format is load-bearing: the orchestrator greps for MASTERMIND_DEP_MISSING
# and surfaces the block verbatim to the user.
die_missing() {
  local dep="$1"; shift
  {
    echo "MASTERMIND_DEP_MISSING: $dep"
    echo "Mastermind requires \`$dep\`, which isn't on PATH. Tell the user to install it:"
    for line in "$@"; do echo "  $line"; done
    echo "Then re-invoke mastermind."
  } >&2
  exit 2
}

command -v tmux >/dev/null 2>&1 || die_missing tmux \
  "macOS:         brew install tmux" \
  "Debian/Ubuntu: sudo apt install tmux" \
  "Fedora/RHEL:   sudo dnf install tmux" \
  "Arch:          sudo pacman -S tmux" \
  "NixOS:         add 'tmux' to environment.systemPackages, then nixos-rebuild switch"

command -v claude >/dev/null 2>&1 || die_missing claude \
  "Install Claude Code: https://claude.com/claude-code" \
  "After install, ensure \`claude\` is on PATH (try: which claude)."

command -v jq >/dev/null 2>&1 || die_missing jq \
  "macOS:         brew install jq" \
  "Debian/Ubuntu: sudo apt install jq" \
  "Fedora/RHEL:   sudo dnf install jq" \
  "Arch:          sudo pacman -S jq" \
  "NixOS:         add 'jq' to environment.systemPackages, then nixos-rebuild switch"

# ---------- arg parsing ----------
EXPLICIT_N=""
if [ "${1:-}" = "--n" ]; then
  EXPLICIT_N="$2"
  shift 2
fi
ROLE="${1:-builder}"

COLORS=(red blue green yellow purple orange pink cyan default)
COLOR=${COLORS[$RANDOM % ${#COLORS[@]}]}

if [ -n "$EXPLICIT_N" ]; then
  N="$EXPLICIT_N"
else
  # Allocate from state.json AND bump immediately, so this slot is reserved
  # before the slow tmux/claude/window startup. Sequential callers see
  # incrementing N; parallel callers should pre-allocate via --n.
  # If state.json is missing (orchestrator hasn't initialized it yet), seed
  # it here — otherwise consecutive spawns would all collide on N=1.
  if [ ! -f "$STATE" ]; then
    echo '{"next_n":1}' > "$STATE"
  fi
  N=$(jq -r '.next_n // 1' "$STATE")
  TMP=$(mktemp)
  jq --argjson n "$((N + 1))" '.next_n = $n' "$STATE" > "$TMP" && mv "$TMP" "$STATE"
fi

SESSION="mastermind-$N"
TITLE="$SESSION ($ROLE)"

# Clean any stale session with this name (handles a prior crash mid-spawn)
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Start tmux session detached, claude inside
tmux new-session -d -s "$SESSION" -x 180 -y 50 "$(command -v claude)"

# ---------- terminal launcher (auto-detect) ----------
# Try in priority order per OS. Each branch attaches a NEW GUI window to the
# already-running tmux session. If everything fails we leave the session
# running detached and emit MASTERMIND_NOTICE so the orchestrator can tell
# the user how to attach.
LAUNCHED=""

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

case "$(uname -s)" in
  Darwin)
    # macOS: prefer modern GPU terminals, fall back to Terminal.app via osascript.
    if [ -d "/Applications/Alacritty.app" ] || command -v alacritty >/dev/null 2>&1; then
      open -g -n -a Alacritty --args --title "$TITLE" -e tmux attach-session -t "$SESSION" \
        && LAUNCHED="Alacritty"
    elif [ -d "/Applications/Ghostty.app" ] || command -v ghostty >/dev/null 2>&1; then
      open -g -n -a Ghostty --args -e "tmux attach-session -t $SESSION" \
        && LAUNCHED="Ghostty"
    elif [ -d "/Applications/kitty.app" ] || command -v kitty >/dev/null 2>&1; then
      open -g -n -a kitty --args --title "$TITLE" tmux attach-session -t "$SESSION" \
        && LAUNCHED="kitty"
    elif [ -d "/Applications/WezTerm.app" ] || command -v wezterm >/dev/null 2>&1; then
      open -g -n -a WezTerm --args start -- tmux attach-session -t "$SESSION" \
        && LAUNCHED="WezTerm"
    elif [ -d "/Applications/iTerm.app" ]; then
      osascript >/dev/null 2>&1 <<EOF && LAUNCHED="iTerm"
tell application "iTerm"
  create window with default profile command "tmux attach-session -t $SESSION"
end tell
EOF
    fi
    if [ -z "$LAUNCHED" ]; then
      # Terminal.app is always present on macOS — last-resort fallback.
      osascript >/dev/null 2>&1 <<EOF && LAUNCHED="Terminal.app"
tell application "Terminal"
  do script "tmux attach-session -t $SESSION"
end tell
EOF
    fi
    ;;

  Linux)
    if is_wsl && command -v wt.exe >/dev/null 2>&1; then
      # WSL: Windows Terminal is the natural choice.
      wt.exe new-tab --title "$TITLE" wsl -- tmux attach-session -t "$SESSION" \
        >/dev/null 2>&1 & LAUNCHED="WindowsTerminal"
    elif [ -n "${TERMINAL:-}" ] && command -v "$TERMINAL" >/dev/null 2>&1; then
      # Honor user-set $TERMINAL first.
      "$TERMINAL" -e tmux attach-session -t "$SESSION" >/dev/null 2>&1 &
      LAUNCHED="$TERMINAL"
    else
      for T in alacritty ghostty kitty wezterm gnome-terminal konsole xfce4-terminal terminator tilix xterm; do
        command -v "$T" >/dev/null 2>&1 || continue
        case "$T" in
          alacritty)      alacritty --title "$TITLE" -e tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
          ghostty)        ghostty -e "tmux attach-session -t $SESSION" >/dev/null 2>&1 & ;;
          kitty)          kitty --title "$TITLE" tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
          wezterm)        wezterm start -- tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
          gnome-terminal) gnome-terminal --title="$TITLE" -- tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
          konsole)        konsole --new-tab -p "tabtitle=$TITLE" -e tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
          xfce4-terminal) xfce4-terminal --title="$TITLE" -e "tmux attach-session -t $SESSION" >/dev/null 2>&1 & ;;
          terminator)     terminator --title="$TITLE" -e "tmux attach-session -t $SESSION" >/dev/null 2>&1 & ;;
          tilix)          tilix --title="$TITLE" -e "tmux attach-session -t $SESSION" >/dev/null 2>&1 & ;;
          xterm)          xterm -title "$TITLE" -e tmux attach-session -t "$SESSION" >/dev/null 2>&1 & ;;
        esac
        LAUNCHED="$T"
        break
      done
    fi
    ;;

  CYGWIN*|MINGW*|MSYS*)
    if command -v wt.exe >/dev/null 2>&1; then
      wt.exe new-tab --title "$TITLE" tmux attach-session -t "$SESSION" \
        >/dev/null 2>&1 & LAUNCHED="WindowsTerminal"
    fi
    ;;
esac

if [ -z "$LAUNCHED" ]; then
  # Soft failure: tmux session exists and the orchestrator can still drive
  # it; the user just can't watch via a popup window. Emit a notice so the
  # orchestrator surfaces attach instructions.
  cat >&2 <<EOF
MASTERMIND_NOTICE: no supported GUI terminal found; tmux session is running detached.
Tell the user (verbatim is fine):
  Mastermind started session "$SESSION" but couldn't auto-open a GUI window
  for it (no supported terminal emulator detected on this system). To watch
  this agent, open any terminal and run:
      tmux attach-session -t $SESSION
  Detach with Ctrl-b d. Mastermind continues to drive the agent regardless.
EOF
fi

# ---------- TUI startup wait ----------
# Wait until claude TUI is in a known state: trust-folder prompt or main
# input prompt. The "Claude Code v" banner alone is NOT a reliable signal —
# the trust-folder screen omits it.
# NB: variable named TUI_STATE, NOT STATE — STATE already holds the
# state.json path above. Naming collision earlier made the next_n bump
# silently no-op because [ -f "$STATE" ] saw the wrong value.
ELAPSED=0
TUI_STATE=""
while [ -z "$TUI_STATE" ]; do
  pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || true)
  if echo "$pane" | grep -qE "Yes, I trust|trust this folder"; then
    TUI_STATE="trust"
  elif echo "$pane" | grep -q "⏵⏵ auto mode"; then
    TUI_STATE="ready"
  fi
  if [ -z "$TUI_STATE" ]; then
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -gt 40 ]; then
      echo "ERROR: claude TUI never rendered in $SESSION" >&2
      exit 1
    fi
  fi
done

# Dismiss trust-folder prompt if present
if [ "$TUI_STATE" = "trust" ]; then
  tmux send-keys -t "$SESSION" Enter
  ELAPSED=0
  while ! tmux capture-pane -t "$SESSION" -p 2>/dev/null \
      | grep -q "⏵⏵ auto mode"; do
    sleep 0.5
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -gt 80 ]; then
      echo "ERROR: trust dismissal didn't lead to ready state in $SESSION" >&2
      exit 1
    fi
  done
fi

# /rename — type, then Enter as separate send-keys (paste-bracket quirk)
tmux send-keys -t "$SESSION" "/rename $SESSION"
sleep 0.4
tmux send-keys -t "$SESSION" Enter
sleep 1

# /color
tmux send-keys -t "$SESSION" "/color $COLOR"
sleep 0.4
tmux send-keys -t "$SESSION" Enter
sleep 1

echo "$SESSION"
