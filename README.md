# rb-lite

[![CI](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml)

A small Bash CLI that drives an **implement → review** loop using an explicit
`claude`/`codex` implementer preset, a preset cycle, or a custom command. It
uses codex, [`claude`](https://docs.anthropic.com/claude/docs/claude-code), and
Gemini CLI as the default reviewer panel. Repeatedly invokes the implementer
until the git diff stabilizes, runs the reviewer panel in parallel, feeds
P0/P1/P2 findings back into the implementer, and stops when the panel is clean,
the implementer refuses to act on remaining findings, or a budget cap is hit.

Entirely in shell, no daemons, no state DB, runs in any git repo.

## Quick start

You need a git working tree, an explicit implementer choice, the reviewer CLIs
you use on `PATH`, and `nix` with flakes enabled.

```bash
# Run the latest version straight from GitHub (no install)
nix run github:douglaz/rb-lite -- run \
  --implementer codex \
  --task "Address whatever needs fixing on this branch" \
  --base origin/main
```

That single command:
1. Builds rb-lite from source (cached after first run)
2. Spawns the selected implementer preset or preset cycle in your repo's
   working tree
3. Loops implementer ↔ panel-reviewer (codex + claude, plus Gemini when available)
4. Stops when the panel reports no actionable findings, exits clean

Artifacts land in `.rb-lite/runs/<timestamp>-<pid>/`.

## Installing

Pick one:

```bash
# A) Run on demand without installing
nix run github:douglaz/rb-lite -- run --implementer codex --task "..." --base origin/main

# B) Install into your user profile
nix profile install github:douglaz/rb-lite
rb-lite run --implementer codex --task "..." --base origin/main

# C) Clone and run from source (if you want to hack on it)
git clone https://github.com/douglaz/rb-lite.git
cd rb-lite
bin/rb-lite run --implementer codex --task "..." --base origin/main
```

For (C), the script needs `bash`, `git`, and standard coreutils on `PATH`. (A)
and (B) wrap those dependencies via Nix automatically.

## Prerequisites

- A git repository (rb-lite refuses to run outside one).
- An explicit implementer: `--implementer codex`, `--implementer claude`,
  `--implementer claude,codex`, or `--implement-cmd '...'`. There is no
  default implementer.
- `codex` CLI on `PATH`, authenticated, if your implementer preset/cycle
  includes `codex` or you use the default reviewer panel. The codex preset runs
  `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"`,
  reusing the same session within a round when possible. The default reviewer
  panel includes `codex review`.
- `claude` CLI on `PATH`, authenticated, if your implementer preset/cycle
  includes `claude` or you use the default reviewer panel. The claude
  implementer preset uses `claude -p`
  with `--permission-mode acceptEdits --output-format stream-json --verbose`
  and a broad allowed-tools list (matches the sister `ralph-burning` project).
- `jq` on `PATH` if you use the default reviewer panel from a source checkout
  (Nix installs wrap it automatically). The default claude reviewer uses
  `claude -p` with `--output-format json` and pipes stdout through
  `jq -er 'if .is_error then error(.result // "claude reviewer returned is_error") else (.result // empty) end'`
  so findings text remains parseable on stdout and Claude errors or missing
  results fail the reviewer.
- `npx` on `PATH` plus Gemini credentials for the third default reviewer:
  either `GEMINI_API_KEY` in the environment or an existing OAuth login stored
  by `gemini-cli`. rb-lite grants the reviewer full tool access (shell exec,
  file ops) via a per-run policy file at `$RUN_DIR/gemini-policy.toml`; the
  reviewer prompt still says "Do not modify any files." — that prompt is the
  only restraint on writes, same trust model as `codex review`. The working
  directory must also be trusted by gemini-cli (one-time interactive `gemini`
  trust prompt, or `GEMINI_CLI_TRUST_WORKSPACE=true` in the environment), or
  the reviewer fails and the panel falls back to codex+claude. rb-lite
  intentionally does NOT pass `--skip-trust`, so a malicious in-repo
  `.gemini/settings.json` from an untrusted PR cannot inject hooks or MCP
  servers into the review. As a further safeguard, the default Gemini reviewer
  refuses to run when the repository has a local `@google/gemini-cli` package or
  `gemini` bin under `node_modules/` (which `npx` could prefer over the pinned
  package); it logs a refusal to stderr and the panel falls back to codex+claude.
  Write your own `.rb-lite-reviewers` if running a repo-local Gemini CLI is
  intentional.

You can override or replace either side — see "Configuration" below.

## What it does, in one diagram

```text
                 ┌───────────────────────────────────────────────────┐
                 │ rb-lite run --implementer codex --task "..."      │
                 └───────────────────────────┬───────────────────────┘
                                             │
                 ┌───────────────────────────▼───────────────────────┐
                 │ Implementer iteration loop                        │
                 │  • selected preset/cycle or --implement-cmd       │
                 │  • repeat until git state stops changing          │
                 └───────────────────────────┬───────────────────────┘
                                             │
                 ┌───────────────────────────▼───────────────────────┐
                 │ Review panel (concurrent)                         │
                 │  • codex review --base X                          │
                 │  • claude -p "<prompt>" --output-format json      │
                 │    | jq -er '<extract .result; fail on is_error>' │
                 │  • npx -y @google/gemini-cli --policy … -p "…"    │
                 │  • each writes review-round-N-K.md                │
                 └───────────────────────────┬───────────────────────┘
                                             │
                                             ▼
        clean (no P0/P1/P2)?  ──────► EXIT 0
        all reviewers failed?  ─────► EXIT 11
        max rounds hit?  ───────────► EXIT 12
        2 no-op rounds + findings? ─► EXIT 13 (consensus failure)
        otherwise: feed reviews to implementer, next round
```

## Usage

```bash
rb-lite run \
  --implementer codex \
  --task "Fix the next ready bead" \
  --base origin/main \
  --max-rounds 25 \
  --max-iters 25
```

Common flags (full list: `rb-lite --help`):

| Flag | Default | Purpose |
|---|---|---|
| `--task TEXT` / `--task-file PATH` | empty | Free-form task instruction appended to the implementer prompt |
| `--base REF` | `origin/master` | Git ref the reviewers diff against |
| `--max-rounds N` | 25 | Cap on implement→review cycles |
| `--max-iters N` | 25 | Cap on implementer iterations within a round |
| `--max-noop-rounds N` | 2 | Consecutive no-op implementer rounds before consensus-failure exit |
| `--min-findings-severity LEVEL` | `P2` | Lowest severity that triggers another round (`P0`/`P1`/`P2`/`P3`) |
| `--implement-timeout SECS` | 14400 | SIGTERM/SIGKILL each implementer iteration if it runs longer |
| `--reviewer-timeout SECS` | 1800 | SIGTERM/SIGKILL each reviewer if it runs longer; empty disables |
| `--implementer NAME[,NAME...]` | none | Select an implementer preset (`claude` or `codex`) or comma-separated preset cycle; required unless `--implement-cmd` or env equivalent is set |
| `--implement-cmd CMD` | none | Raw implementer subprocess escape hatch; takes precedence over presets |
| `--reviewers-file PATH` | `.rb-lite-reviewers` | Custom reviewer panel (one shell command per line) |
| `--branch NAME` | none | `git switch -c NAME` before starting |
| `--run-dir PATH` | `.rb-lite/runs/<id>` | Where to store run artifacts |

Most flags have a matching env var (`RB_LITE_BASE`, `RB_LITE_MAX_ROUNDS`, …);
precedence is CLI flag > env var > default. (`--task`, `--task-file`, and
`--branch` are CLI-only.)

## Run artifacts

Each run gets `.rb-lite/runs/<UTC-timestamp>-<pid>/` with:

- `implementer-round-N-iter-K.{stdout,stderr}` — every implementer call
- `reviewer-round-N-K.{stdout,stderr}` — raw output from each reviewer
- `review-round-N-K.md` — per-reviewer markdown that the implementer reads on
  the next round (one file per reviewer; the implementer is told via PROMPT
  to read each independently and weigh disagreements)
- `log.txt` — timestamped progress log

Progress lines are also mirrored to **stderr** in real time so long runs are
visible in the terminal. Suppress with `2>/dev/null` if you want quiet.

## Customizing the reviewer panel

The default panel is fine for most cases. To override, drop a
`.rb-lite-reviewers` file in your repo root with one shell command per line
(blank lines and `#` comments ignored):

```
# .rb-lite-reviewers
codex review --base "$BASE"
set -o pipefail; claude -p "Review the diff vs $BASE. Tag findings with P0/P1/P2/P3 severities. Output 'No findings.' if clean." --permission-mode acceptEdits --output-format json --allowedTools "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch,Task,TaskOutput,TaskStop,Monitor" | jq -er 'if .is_error then error(.result // "claude reviewer returned is_error") else (.result // empty) end'
npx -y @google/gemini-cli --policy "$RUN_DIR/gemini-policy.toml" --approval-mode yolo -p "Review the diff vs $BASE. Tag findings with P0/P1/P2/P3 severities. Output 'No findings.' if clean."
my-custom-linter --json | wrap-as-p-tags
```

Reviewers run **concurrently**, each gets `BASE`, `RUN_DIR`, `ROUND`,
`REVIEWER_INDEX` in env, and stdin closed. The default claude reviewer requires
`jq` because it extracts `.result` from `claude --output-format json` and fails
when Claude reports `is_error`. By default, each reviewer is wrapped in
`timeout` (default 30m); a timed-out reviewer counts as a failed reviewer and is
recorded in its per-reviewer markdown file, but does not abort the panel as long
as at least one reviewer succeeds.

### Reviewer contract

- Findings go on **stdout**. Stderr is treated as tool noise and excluded
  from the implementer feedback when the reviewer exits 0 (a stderr tail is
  appended only when a reviewer exits non-zero, for debugging).
- Severities tagged near the start of a finding line: `P2:`, `[P2]`,
  `**P2**:`, or e.g. `Issue 1 (P2):`. Incidental mentions in finding bodies
  are ignored.
- Exit `0` = real review; exit non-zero = tool failure (output may be
  partial or garbage). Findings detection ignores non-zero reviewers
  entirely. A linter that exits non-zero on findings must be wrapped:
  `mylinter || true`.
- Panel succeeds with **at least one** exit-0 reviewer; failed reviewers
  don't abort the run.

## Customizing the implementer

```bash
rb-lite run --implementer codex --task "..."
rb-lite run --implementer claude --task "..."
rb-lite run --implementer claude,codex --task "..."
rb-lite run --implement-cmd 'my-implementer "$PROMPT"' --task "..."
```

rb-lite has no default implementer. Choose `--implementer codex`,
`--implementer claude`, a comma-separated cycle such as
`--implementer claude,codex`, set `RB_LITE_IMPLEMENTER`, or provide a raw
command with `--implement-cmd` / `RB_LITE_IMPLEMENT_CMD`. With a cycle, round 1
uses the first preset; after each review round with actionable findings, the
next round advances to the next preset and wraps at the end. The cycle order is
exactly the order you wrote. Raw commands are used verbatim and never cycle.
Resolution order is `--implement-cmd`, `--implementer`,
`RB_LITE_IMPLEMENT_CMD`, then `RB_LITE_IMPLEMENTER`.

The claude implementer preset runs:

```bash
claude -p "$PROMPT" --permission-mode acceptEdits --output-format stream-json --verbose --allowedTools "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch,Task,TaskOutput,TaskStop,Monitor"
```

rb-lite ignores the implementer's stdout; the preset still runs Claude's agentic
editing loop in the working tree.

The implementer command receives:

| Env var | Meaning |
|---|---|
| `PROMPT` | Full prompt text including task and per-reviewer file paths |
| `REVIEW_FILES` | Newline-separated list of per-reviewer markdown paths (empty on round 1) |
| `RB_LITE_PREV_SESSION` | Session ID captured from the prior iteration's stderr (empty on iter 1; resets across rounds) |
| `RUN_DIR` | Absolute path to the run-artifact dir |
| `ROUND` / `ITERATION` | Current round and iteration numbers |

Implementers run with stdin closed. Custom implementers should read
`REVIEW_FILES` (or just rely on `PROMPT`, which enumerates the paths). The
legacy `REVIEW_FILE` (singular, combined-doc) env var was removed.

## Stop conditions and exit codes

| Code | Status | Meaning |
|---|---|---|
| `0`  | `clean` | Review panel reported no findings at or above severity floor |
| `2`  | `usage_error` | CLI parsing failure, invalid value, conflicting flags |
| `3`  | `env_error` | Not in git repo, missing tool, run-dir setup failure |
| `10` | `implementer_failed` | Implementer subprocess non-zero (incl. timeout 124/137) or max-iters without stabilizing. Transient provider errors (rate limit / overloaded / 5xx / network) are retried with backoff first — see `RB_LITE_API_RETRY_DELAYS` / `RB_LITE_API_MAX_RETRIES` |
| `11` | `review_panel_failed` | Zero reviewers exited 0 |
| `12` | `max_rounds_hit` | Hit `--max-rounds` before convergence |
| `13` | `consensus_failure` | Hit `--max-noop-rounds` consecutive no-op rounds with reviewers still finding things |
| `70` | `internal_error` | Internal invariant violation or unhandled shell failure |

## End-of-run JSON summary

Every exit (success or failure) prints one JSON object on a single line to
stdout, as the **last** line of output. Pipe to `jq` to consume:

```json
{"run_dir": "/path/.rb-lite/runs/...", "exit_code": 0, "status": "clean", "rounds": 3, "implementer_iterations": 5, "noop_rounds_streak": 0, "duration_secs": 712, "config": {"max_rounds": 25, "max_iters": 25, "max_noop_rounds": 2, "min_findings_severity": "P2", "implement_timeout_secs": 14400, "reviewer_timeout_secs": 1800}}
```

The human-readable `rb-lite clean after N round(s)` line is printed before
the JSON on success; failure messages still go to stderr.

## Configuration env vars

- `RB_LITE_BASE`
- `RB_LITE_MAX_ROUNDS`
- `RB_LITE_MAX_NOOP_ROUNDS`
- `RB_LITE_MAX_ITERS`
- `RB_LITE_IMPLEMENT_TIMEOUT`
- `RB_LITE_REVIEWER_TIMEOUT` (empty disables reviewer timeouts)
- `RB_LITE_IMPLEMENTER` (single preset or comma-separated preset cycle)
- `RB_LITE_IMPLEMENT_CMD`
- `RB_LITE_SESSION_REGEX`
- `RB_LITE_REVIEWERS_FILE`
- `RB_LITE_MIN_FINDINGS_SEVERITY`
- `RB_LITE_RUN_DIR`
- `RB_LITE_API_RETRY_DELAYS` (space-separated backoff seconds before retrying an implementer iteration that failed with a transient provider error; last value repeats; default `10 30 60`; structured `retry_after` values are used as a delay floor)
- `RB_LITE_API_MAX_RETRIES` (max transient-error retries per implementer iteration; default `10`; `0` disables)
- `RB_LITE_SCRUB_ENV` (space-separated env var names unset before any implementer/reviewer runs; default scrubs the Claude Code session/instance **identity** markers — `CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH`; auth and behavior flags — incl. `CLAUDE_CODE_RETRY_WATCHDOG`, claude's 429/529 capacity wait — are preserved; set empty to disable — see "Running under an agent")

## Running under an agent (nested Claude Code)

rb-lite is often driven by an orchestrating agent that is *itself* a Claude Code
session. Without care, the `claude` implementer/reviewer it spawns would inherit
that session's identity — `CLAUDE_CODE_SESSION_ID`, `CLAUDECODE`, … — and collide
with the parent session: the parent's stdio breaks while rb-lite waits on the
child, rb-lite exits without a JSON summary, and the child is orphaned.

rb-lite therefore scrubs those session/instance markers at startup so each spawned
`claude` starts a **fresh** session. Only **identity** markers are scrubbed.
**Auth is preserved** — `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, and
`ANTHROPIC_*` are never touched, so the fresh session reuses the existing
credentials — and so are **behavior flags** like `CLAUDE_CODE_RETRY_WATCHDOG`
(claude's indefinite wait on `429`/`529` capacity limits), so a nested child keeps
that resilience rather than falling back to rb-lite's bounded retries alone.
Outside a Claude Code session the markers are unset and this is a no-op. Override
the scrub list with `RB_LITE_SCRUB_ENV` (space-separated names), or set it empty to
disable.

## Transient implementer errors

When an implementer iteration exits non-zero because of a **transient provider
error** — an API rate limit (HTTP 429), an `overloaded`/529, Cloudflare 522, a
5xx, or a network blip — rb-lite retries the *same* iteration with backoff
instead of failing the round. These failures clear on their own, and a retry just
re-runs the same prompt — exactly what the normal stabilization loop already
does on every iteration — so retrying is almost always the right move. The
default backoff is `10s, 30s, 60s, 60s, …` (the last
`RB_LITE_API_RETRY_DELAYS` value repeats), up to `RB_LITE_API_MAX_RETRIES`
(default 10) retries per iteration. If provider output includes a structured
`retry_after` value, rb-lite uses it as a floor over the configured schedule. A
retry does not advance the iteration counter (`--max-iters`).

Only genuine transient errors are retried. A timeout (124), a SIGKILL (137, e.g.
`timeout --kill-after` escalating past a process that ignored SIGTERM), and any
non-transient failure are hangs/kills or real failures, not provider blips, so
they fail the round immediately.

## Development

```bash
# Enter a shell with bash, git, just, ripgrep
nix develop

# Run the smoke suite (fakes codex/claude/Gemini — no API credentials needed)
just test

# Full local gate (lint + smoke + nix flake check)
just check
```

The smoke tests cover the loop's behavior with fake implementer and reviewer
binaries on `PATH`. They do not exercise live codex/claude/Gemini.

## Notes

- `rb-lite` was largely written by `rb-lite` itself, dogfood-style: the
  implementer + reviewer panel iterated on its own source until each new
  feature reached the new severity floor or no-op-stop conditions. The git
  history shows each feature's dogfood signal in commit messages.
- Sister project: [`ralph-burning`](https://github.com/douglaz/ralph-burning)
  — same family of orchestration ideas, more substantial Rust implementation.
