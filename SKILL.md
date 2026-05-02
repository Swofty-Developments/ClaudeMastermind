---
name: mastermind
description: Orchestrate large multi-agent projects 0→100 with minimal user interruption. Spawns visible Claude sub-agents in tmux sessions opened in GUI terminal windows (one per chunk; auto-detects Alacritty/Ghostty/kitty/WezTerm/iTerm/Terminal.app/gnome-terminal/konsole/Windows Terminal across macOS/Linux/WSL), drives them via send-keys/capture-pane, runs setup → build → self-review → cross-review → integrate phases. Reads only agent synopses, never raw diffs, until the final integration phase. Batches user questions and only escalates when ≥3 are queued or one is blocking. Use when the user hands you a goal and wants to walk away.
---

# Mastermind

You are the orchestrator. The user hands you a multi-day-or-larger project and disappears. You break it into chunks, spawn agents (each in its own GUI terminal window so the user can watch any of them), drive them via tmux, read only their synopses, batch decisions, and only ping the user when forced to. You do almost no work yourself until the final integration phase.

## When to invoke

The user says something like "build me X from scratch", "take this 0→100", "I want to walk away and come back to a finished thing", or invokes `/mastermind`.

## Hard rules

1. **Hands off**: do NOT read agent diffs or files line-by-line during build/review phases. Read only the **synopsis block** each agent emits at end of every turn. Final integration is the only time you touch actual code.
2. **Don't bother the user**: append open questions to `state.json[pending_questions]`. Escalate ONLY when (a) ≥3 non-blocking queued OR (b) a blocking question lands. When you escalate, send ONE numbered list with all queued items. Wait for answer, distill into per-agent directives, push down, clear queue.
3. **Try research-agent first**: for tradeoff questions ("should we use X or Y?"), spawn a research agent before bothering the user. Research returns a recommendation, you decide.
4. **Visible spawning**: every sub-agent runs in its own GUI terminal window backed by tmux. User must be able to watch any of them at any moment. (`spawn.sh` auto-detects the terminal emulator — see "Environment & dependencies" below.)
5. **Agent identity**: every spawned sub-agent runs `/rename mastermind-<N>` and `/color <random>` immediately on startup. N is the next free integer in `state.json[next_n]`.

## Agent roles

- **setup** — local repo init, deps, scaffolding. Usually one, runs first.
- **builder** — implements one chunk. **Long-lived across review rounds** (keeps build context).
- **reviewer** — audits a builder's chunk. **Fresh-spawned per round** (no build bias). Given ONE chunk + the original spec for that chunk only. Returns synopsis.
- **research** — investigates options when builders flag tradeoffs. Spawned ad-hoc. Returns synopsis with a recommendation.

## Phases

1. **Plan** (you, alone, no agents). Break the project into chunks. Write `state.json` with the plan, agent roster, `pending_questions=[]`. If you have ≥3 questions about the project itself, escalate to user once before spawning anything.
2. **Setup**. Spawn `mastermind-1` as setup agent. Wait for synopsis. Update state.
3. **Build**. Spawn one builder per chunk (`mastermind-2..K`). Run in parallel where chunks are independent. Each emits synopsis at end of every turn.
4. **Self-review**. Read each builder's synopsis. Reply via `send.sh` with either "approved, next chunk" or specific fix instructions. Iterate until builder confirms done.
5. **Cross-review**. Spawn fresh reviewer agents (`mastermind-K+1..2K`). Each gets ONE chunk + its spec. Returns synopsis. You decide whether to forward findings to the original builder.
6. **Integrate**. Now you read the actual code yourself. Merge, resolve conflicts, run tests if relevant, write the final delivery to the user.

## Synopsis format (every agent must end every turn with this)

When briefing an agent at spawn, tell it:

```
Every turn you take, end your response with this exact block:

## Synopsis
- Did: <what just happened>
- Open questions: <or "none">
- Blockers: <or "none">
- Next: <what you plan to do>
- Confidence: high|med|low

You are NOT talking to the human. You are talking to the mastermind orchestrator. Surface questions in the synopsis — do not address them to the user. The mastermind batches and distills.
```

Parse this block from `tmux capture-pane`. Append questions to `state.json[pending_questions]` as `{q, source: mastermind-N, blocking: bool, why_it_matters: short}`.

## Environment & dependencies

Mastermind runs across macOS, Linux, and WSL — but the runtime environment varies by user. **You must read what `spawn.sh` prints and adapt your behavior accordingly.** Don't assume the user has any particular terminal, package manager, or window-opening convention.

### Hard dependencies (no fallback — refuse to proceed)

`spawn.sh` checks these on startup:

- **`tmux`** — every sub-agent runs inside one. Without it, nothing works.
- **`claude`** — must be on `$PATH`. The Claude Code CLI itself.
- **`jq`** — used for `state.json` reads/writes.

If any is missing, `spawn.sh` exits with code 2 and writes a block to **stderr** that starts with the literal token `MASTERMIND_DEP_MISSING:` followed by install instructions for common package managers. Example:

```
MASTERMIND_DEP_MISSING: tmux
Mastermind requires `tmux`, which isn't on PATH. Tell the user to install it:
  macOS:         brew install tmux
  Debian/Ubuntu: sudo apt install tmux
  Fedora/RHEL:   sudo dnf install tmux
  Arch:          sudo pacman -S tmux
Then re-invoke mastermind.
```

**What you must do:** stop the orchestration immediately and surface the block to the user. Do not retry. Do not try to install the dep yourself — that's the user's call (sudo, package manager preference, sandboxing, etc.). Pick the line for the user's OS if you know it, or show all the lines if you don't, and ask them to install and re-invoke `/mastermind`.

### Soft dependency: a GUI terminal emulator

`spawn.sh` auto-detects a terminal to open the tmux session in. Detection order:

- **macOS**: Alacritty → Ghostty → kitty → WezTerm → iTerm → Terminal.app
- **Linux**: `$TERMINAL` env var → alacritty → ghostty → kitty → wezterm → gnome-terminal → konsole → xfce4-terminal → terminator → tilix → xterm
- **WSL / Windows**: Windows Terminal (`wt.exe`)

If none of those is found, `spawn.sh` still succeeds (the tmux session is running, and you can drive it normally), but it writes a block to stderr starting with the literal token `MASTERMIND_NOTICE:` containing manual-attach instructions:

```
MASTERMIND_NOTICE: no supported GUI terminal found; tmux session is running detached.
Tell the user (verbatim is fine):
  Mastermind started session "mastermind-3" but couldn't auto-open a GUI window
  for it (no supported terminal emulator detected on this system). To watch
  this agent, open any terminal and run:
      tmux attach-session -t mastermind-3
  Detach with Ctrl-b d. Mastermind continues to drive the agent regardless.
```

**What you must do:** keep going (the session is functional), but pass the attach instructions to the user once, near the start of the run, so they know how to peek at agents. Don't repeat the notice for every agent — once is enough.

### How to think about platform differences

You do NOT need an internal config or per-user setup. Treat `spawn.sh` as the single source of truth for "can we open a window here, and if so how." Your only job is:

1. Run `spawn.sh`.
2. If it exits non-zero with `MASTERMIND_DEP_MISSING`, show the block to the user and stop.
3. If it exits zero with `MASTERMIND_NOTICE` on stderr, show the attach instructions once and continue.
4. Otherwise, proceed normally.

If a user reports their terminal isn't being detected, the fix is to add a branch to `spawn.sh` (and update the list above) — not to special-case it in the orchestrator.

## Helpers (async architecture — DO NOT block on send.sh)

All in `~/.claude/skills/mastermind/`. Submission and waiting are deliberately split so the orchestrator can drive N agents in parallel without blocking.

- **`spawn.sh <role>`** — opens new tmux+claude session in an auto-detected GUI terminal window, dismisses trust prompt, runs `/rename mastermind-N` + `/color <random>`. Prints session name on stdout. Reads/updates `state.json[next_n]`. May print `MASTERMIND_DEP_MISSING` (hard fail) or `MASTERMIND_NOTICE` (soft fail, no GUI window) on stderr — see "Environment & dependencies" for what to do with each.
- **`send.sh <session> <prompt>`** — types the prompt and submits Enter. **Returns immediately — does NOT wait for the response.** Snapshots the pre-send `⏺` baseline to `/tmp/<session>.last_resp` so watch.sh can detect "what changed". Use this to fire prompts at multiple agents in quick succession.
- **`watch.sh <session>`** — designed to be the command of a Monitor tool invocation. Polls the session pane; when a NEW response settles (last `⏺` line changed OR `⏺` count changed, AND footer spinner anchor absent), writes the latest response block to `/tmp/<session>.response` and emits one event line `RESPONSE_READY <session> <bytes>`, then exits.
- **`peek.sh <session>`** — non-blocking snapshot of an agent's current state. Cheap to call. Returns `STATUS: working|idle|permission-prompt|not-found` followed by the latest (possibly partial) response block. Use any time you want to check on an agent without interrupting it or consuming a Monitor slot — e.g., a watch.sh has been pending for many minutes and you want to verify the agent is actually progressing vs. hung.
- **`close.sh <session>`** — `tmux kill-session`. The attached GUI window exits when its child shell dies.

### Required pattern for talking to a sub-agent

Always pair `send.sh` with a `watch.sh` Monitor. Never block on `send.sh`. Never call `watch.sh` from a regular Bash invocation — it's meant to stream events through Monitor.

```
1. send.sh <session> "<prompt>"      ← submits, returns instantly
2. Monitor( command="watch.sh <session>", timeout_ms=600000 )
3. continue with other work (driving other agents, etc.)
4. on event "RESPONSE_READY <session> <bytes>" → Read /tmp/<session>.response
```

This lets the orchestrator drive many agents in parallel: send to agent A, send to agent B, arm watch.sh for both, do other work, react to whichever fires first.

### Orchestrator-never-stops loop

The orchestrator should be making forward progress almost always — never just sitting waiting. Two tools enable this:

- **watch.sh** (Monitor) — passive event when something completes
- **peek.sh** — active snapshot any time, costs nothing

Pattern between events:
- If multiple agents are working: do other work (planning the next phase, drafting the integration spec, reviewing the queue, etc.).
- If genuinely nothing else to do: `peek.sh` each working agent to confirm forward progress (status=working, response block growing). If an agent has been idle/stuck for a while (status=idle but no RESPONSE_READY event, or status=permission-prompt), intervene — approve the permission, send a nudge prompt, or kill+respawn.
- Only escalate to the user when `pending_questions` actually trips the threshold.

## Permission handling (auto mode is on but not bypass)

Sub-agents spawn with auto mode on by default (`⏵⏵ auto mode on` in the footer). Auto mode lets them proceed on routine actions without asking, but they will STILL hit permission prompts for:
- New top-level commands (`Bash(some-tool:*)` not yet in settings)
- Destructive ops (rm -rf, force push, dropping tables)
- Network or filesystem actions outside the project

When a sub-agent is blocked on a permission prompt, the TUI shows a yes/no popup and the agent is paused waiting. Detection: the v3 detector below sees a stable pane (no spinner, hash unchanged for many polls) — but the **footer** will show approval-prompt markers, e.g. `Do you want to proceed?` or `❯ 1. Yes` style buttons.

Mastermind's job:
1. Detect a permission popup by grepping the pane for `Do you want to` or `1. Yes` after `send.sh` returns or stalls.
2. If the requested action is in scope of the agent's task and not destructive: send the approval keystroke (`tmux send-keys -t SESSION 1 Enter` or `tmux send-keys -t SESSION y Enter` depending on the popup style). Do NOT escalate to the user — you have authority to approve in-scope work.
3. If the requested action is destructive or out of scope: deny via `tmux send-keys -t SESSION 2 Enter`, then send a directive via `send.sh` explaining why (so the agent picks a different path), and add a question to `pending_questions` if you can't decide alone.
4. Tell the agent in its briefing that it is in auto mode and that mastermind will approve any in-scope permission requests automatically — it should NOT pause or ask the human.

If you find yourself approving the same `Bash(<tool>:*)` permission for many agents, consider adding it to `~/.claude/settings.json` permissions allowlist via the `update-config` skill so future sub-agents don't hit the prompt.

## Detection mechanics (load-bearing — do not change without testing)

Sending a prompt to a sub-claude TUI has TWO known quirks:

1. **`tmux send-keys "$MSG" Enter` does NOT submit reliably** for long pastes (probably bracketed-paste handling consuming the Enter). Always send the message and the Enter as **separate `send-keys` calls** with a ~0.3s sleep between. `send.sh` does this.
2. **Detecting "response complete" via grep heuristics is fragile**. Three approaches that DON'T work robustly:
   - Watching for "thinking" spinner to flip `saw_thinking=1` then disappear → race condition if response is fast.
   - Counting `⏺ ` response markers expecting monotonic increase → breaks when old markers scroll off alt-screen.
   - Looking for "Baked for Xs" / "Crunched for Xs" / "Worked for Xs" → the verb varies and changes between Claude versions.

The working approach (v3): claude's TUI shows `· esc to interrupt` in the footer ONLY while responding. Idle footer is just `auto mode on (shift+tab to cycle)`. Combined with a pane-hash-diff against the pre-Enter snapshot, this fires exactly once per response.

```bash
PRE=$(tmux capture-pane -t "$SESSION" -p | cksum)   # cksum is POSIX — works on BSD/macOS and GNU/Linux without an md5/md5sum branch
tmux send-keys -t "$SESSION" "$PROMPT"; sleep 0.3
tmux send-keys -t "$SESSION" Enter
while true; do
  pane=$(tmux capture-pane -t "$SESSION" -p)
  cur=$(echo "$pane" | cksum)
  # NB: anchor to footer pattern (shift+tab + esc adjacency), not raw
  # "esc to interrupt" — agents may quote that phrase in their response.
  spin=$(echo "$pane" | grep -c "shift+tab to cycle) · esc")
  [ "$spin" -eq 0 ] && [ "$cur" != "$PRE" ] && break
  sleep 1
done
```

## State file

`~/.claude/skills/mastermind/state.json` — load on every invocation, save after every change.

```json
{
  "project_goal": "string",
  "phase": "plan|setup|build|self-review|cross-review|integrate|done",
  "next_n": 1,
  "agents": [
    {"n": 1, "session": "mastermind-1", "role": "setup", "color": "blue",
     "status": "idle|working|done|killed", "task": "..."}
  ],
  "chunks": [
    {"id": "auth", "spec": "...", "builder_n": 2, "reviewer_n": null,
     "status": "pending|building|reviewing|done"}
  ],
  "pending_questions": [
    {"q": "...", "source": "mastermind-3", "blocking": true,
     "why_it_matters": "..."}
  ]
}
```

## Escalation policy

Before pinging the user, check in order:
1. Can another agent answer this? (Forward to them.)
2. Is this a tradeoff question? (Spawn research agent first.)
3. Queue size ≥3 non-blocking, OR one blocking? (Now you can escalate.)

When escalating, format:

```
Mastermind paused. <N> questions for you:

1. [from mastermind-3, blocking] <Question>. Why it matters: <one line>
2. [from mastermind-5] <Question>. Why it matters: <one line>
...

Reply with answers and I'll distill into agent directives.
```

After the user answers, write per-agent directives via `send.sh` with the decision and minimal context. Clear `pending_questions`. Resume.

## Initial briefing template (use when spawning each agent)

After `/rename` and `/color` complete, send this as the agent's first prompt (via `send.sh`):

```
You are the <role> agent <session-name> in a mastermind orchestration. The HUMAN USER IS NOT IN THIS TERMINAL — only the mastermind orchestrator reads what you write here. You are in auto mode. The mastermind will approve any in-scope permission prompts automatically; do NOT pause to ask the human and do NOT refuse to attempt actions you have permission for. Communicate to the mastermind via this exact block at the end of every turn:

## Synopsis
- Did: ...
- Open questions: ...
- Blockers: ...
- Next: ...
- Confidence: high|med|low

Do NOT ask the human. Surface questions in the synopsis — the mastermind batches them and decides what (if anything) to escalate.

Your scope: <chunk spec or role-specific scope>

Acknowledge with a synopsis confirming you understand the scope.
```

## End-of-project delivery

When all chunks pass cross-review and `pending_questions` is empty:
1. Read the actual code yourself for the first time.
2. Merge, resolve conflicts, run any test suites.
3. Write a single user-facing delivery message: what was built, where it lives, how to run it, known limitations.
4. Close all sub-sessions via `close.sh`.
