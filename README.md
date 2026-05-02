# mastermind

A [Claude Code](https://claude.com/claude-code) skill for orchestrating large multi-agent projects 0→100 with minimal user interruption.

You hand it a goal. It breaks the work into chunks, spawns one Claude Code sub-agent per chunk in its own GUI terminal window (auto-detected: Alacritty / Ghostty / kitty / WezTerm / iTerm / Terminal.app / gnome-terminal / konsole / Windows Terminal — across macOS, Linux, and WSL), drives them via tmux, and runs them through setup → build → self-review → cross-review → integrate phases. The orchestrator reads only short synopses from each agent — never raw diffs — until the final integration phase, so the parent context stays small even on multi-day projects. Open questions are batched and only escalated to you when the queue gets large or a blocker lands.

## Install

With `npx skills` (the [vercel-labs/skills](https://github.com/vercel-labs/skills) installer):

```sh
npx skills add Swofty-Developments/ClaudeMastermind -a claude-code
```

Or clone manually into your Claude skills directory:

```sh
git clone git@github.com:Swofty-Developments/ClaudeMastermind.git ~/.claude/skills/mastermind
```

Either way, restart Claude Code (or run `/reload-plugins`) and the skill becomes invocable as `/mastermind`.

## Requirements

mastermind shells out to a few standard tools. If any are missing, `spawn.sh` exits with a `MASTERMIND_DEP_MISSING` block telling you exactly what to install:

- **`tmux`** — every sub-agent runs inside one
- **`claude`** — the Claude Code CLI itself, on `$PATH`
- **`jq`** — for `state.json` reads/writes
- **A GUI terminal emulator** — soft requirement. If none of the supported terminals is detected, mastermind still works — it just leaves the tmux session detached and prints attach instructions. Supported emulators per platform:
  - **macOS**: kitty, Alacritty, Ghostty, WezTerm, iTerm, Terminal.app — or `$TERMINAL` (when set to `kitty` or `alacritty`)
  - **Linux**: `$TERMINAL` env var → kitty, alacritty, ghostty, wezterm, gnome-terminal, konsole, xfce4-terminal, terminator, tilix, xterm
  - **WSL / Windows**: Windows Terminal (`wt.exe`)

Install the missing tool with your platform's package manager (`brew`, `apt`, `dnf`, `pacman`, `nix`, etc.) and re-invoke. On NixOS, add the dep (`tmux`, `jq`) to `environment.systemPackages` and rebuild.

## Usage

In Claude Code, run:

```
/mastermind
```

Then describe the project. Mastermind will plan, spawn agents, and only come back to you when forced to. From there:

- Each sub-agent opens in its own visible terminal window — you can watch any of them at any time, or just walk away.
- Mastermind batches questions and only escalates when at least three non-blocking questions are queued, or one blocking question lands.
- When all chunks pass cross-review, mastermind integrates the work and writes a single delivery message: what got built, where it lives, how to run it.

## How it works

The skill is a `SKILL.md` plus five small shell scripts:

- `spawn.sh` — opens a new tmux+claude session in an auto-detected GUI terminal, dismisses the trust-folder prompt, and runs `/rename` + `/color` so each agent is visually identifiable
- `send.sh` — submits a prompt to a session **non-blockingly** (returns immediately, snapshots state for watch.sh to diff against)
- `watch.sh` — designed to be the command of a `Monitor` tool invocation; emits one event line when a response settles
- `peek.sh` — non-blocking snapshot of an agent's current state; cheap to call
- `close.sh` — `tmux kill-session`; the GUI window exits when its child shell dies

The async send/watch split lets the orchestrator drive N agents in parallel without blocking on any one of them. See `SKILL.md` for the full architecture, including the load-bearing detection mechanics for "is this agent done responding?" (it's harder than it sounds — the SKILL.md documents three approaches that *don't* work robustly and the one that does).

## Adding support for a new terminal emulator

`spawn.sh` has a per-OS `case` block that probes terminals in priority order. To add one, add a branch with the right launch syntax for that emulator (each one has its own conventions for `-e` vs `--` vs positional args). Update the lists in `SKILL.md` ("Environment & dependencies") and this README to match.

## License

MIT
