# rb-lite

[![CI](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml)

A small Bash CLI that drives an **implement → review** loop using
[`codex`](https://github.com/openai/codex) and
[`claude`](https://docs.anthropic.com/claude/docs/claude-code) as the
implementer and reviewer panel. Repeatedly invokes the implementer until the
git diff stabilizes, runs codex + claude in parallel as a review panel, feeds
P0/P1/P2 findings back into the implementer, and stops when the panel is
clean, the implementer refuses to act on remaining findings, or a budget cap
is hit.

Entirely in shell, no daemons, no state DB, runs in any git repo.

## Quick start

You need a git working tree, the `codex` and `claude` CLIs on `PATH`
(authenticated to whichever backend you use), and `nix` with flakes enabled.

```bash
# Run the latest version straight from GitHub (no install)
nix run github:douglaz/rb-lite -- run \
  --task "Address whatever needs fixing on this branch" \
  --base origin/main
```

That single command:
1. Builds rb-lite from source (cached after first run)
2. Spawns codex as the implementer in your repo's working tree
3. Loops implementer ↔ panel-reviewer (codex + claude in parallel)
4. Stops when the panel reports no actionable findings, exits clean

Artifacts land in `.rb-lite/runs/<timestamp>-<pid>/`.

## Installing

Pick one:

```bash
# A) Run on demand without installing
nix run github:douglaz/rb-lite -- run --task "..." --base origin/main

# B) Install into your user profile
nix profile install github:douglaz/rb-lite
rb-lite run --task "..." --base origin/main

# C) Clone and run from source (if you want to hack on it)
git clone https://github.com/douglaz/rb-lite.git
cd rb-lite
bin/rb-lite run --task "..." --base origin/main
```

For (C), the script needs `bash`, `git`, and standard coreutils on `PATH`. (A)
and (B) wrap those dependencies via Nix automatically.

## Prerequisites

- A git repository (rb-lite refuses to run outside one).
- `codex` CLI on `PATH`, authenticated. The default implementer is
  `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"`,
  reusing the same session within a round when possible. The default reviewer
  panel includes `codex review`.
- `claude` CLI on `PATH`, authenticated. The default reviewer panel also
  includes `claude -p` running with `--permission-mode acceptEdits` and a
  broad allowed-tools list (matches the sister `ralph-burning` project).

You can override or replace either side — see "Configuration" below.

## What it does, in one diagram

```
                        ┌───────────────────────────────────┐
                        │ rb-lite run --task "..." --base X │
                        └────────────────┬──────────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │ Implementer iteration loop  │
                          │  • codex exec [resume ...]  │
                          │  • repeat until git state   │
                          │    stops changing           │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │ Review panel (concurrent)   │
                          │  • codex review --base X    │
                          │  • claude -p "<prompt>"     │
                          │  • each writes              │
                          │    review-round-N-K.md      │
                          └──────────────┬──────────────┘
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
| `--implement-cmd CMD` | codex shell | Override the implementer subprocess |
| `--reviewers-file PATH` | `.rb-lite-reviewers` | Custom reviewer panel (one shell command per line) |
| `--branch NAME` | none | `git switch -c NAME` before starting |
| `--run-dir PATH` | `.rb-lite/runs/<id>` | Where to store run artifacts |

Each flag has a matching env var (`RB_LITE_BASE`, `RB_LITE_MAX_ROUNDS`, …);
precedence is CLI flag > env var > default.

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
claude -p "Review the diff vs $BASE. Tag findings with P0/P1/P2/P3 severities. Output 'No findings.' if clean." --permission-mode acceptEdits --allowedTools "Bash,Edit,Write,Read,Glob,Grep"
my-custom-linter --json | wrap-as-p-tags
```

Reviewers run **concurrently**, each gets `BASE`, `RUN_DIR`, `ROUND`,
`REVIEWER_INDEX` in env, and stdin closed.

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
rb-lite run --implement-cmd 'my-implementer "$PROMPT"' --task "..."
```

The implementer command receives:

| Env var | Meaning |
|---|---|
| `PROMPT` | Full prompt text including task and per-reviewer file paths |
| `REVIEW_FILES` | Newline-separated list of per-reviewer markdown paths (empty on round 1) |
| `RB_LITE_PREV_SESSION` | Session ID captured from the prior iteration's stderr (empty on iter 1; resets across rounds) |
| `RUN_DIR` | Absolute path to the run-artifact dir |
| `ROUND` / `ITERATION` | Current round and iteration numbers |

Custom implementers should read `REVIEW_FILES` (or just rely on `PROMPT`,
which enumerates the paths). The legacy `REVIEW_FILE` (singular,
combined-doc) env var was removed.

## Stop conditions and exit codes

| Code | Status | Meaning |
|---|---|---|
| `0`  | `clean` | Review panel reported no findings at or above severity floor |
| `2`  | `usage_error` | CLI parsing failure, invalid value, conflicting flags |
| `3`  | `env_error` | Not in git repo, missing tool, run-dir setup failure |
| `10` | `implementer_failed` | Implementer subprocess non-zero (incl. timeout 124/137) or max-iters without stabilizing |
| `11` | `review_panel_failed` | Zero reviewers exited 0 |
| `12` | `max_rounds_hit` | Hit `--max-rounds` before convergence |
| `13` | `consensus_failure` | Hit `--max-noop-rounds` consecutive no-op rounds with reviewers still finding things |
| `70` | `internal_error` | Internal invariant violation or unhandled shell failure |

## End-of-run JSON summary

Every exit (success or failure) prints one JSON object on a single line to
stdout, as the **last** line of output. Pipe to `jq` to consume:

```json
{"run_dir": "/path/.rb-lite/runs/...", "exit_code": 0, "status": "clean", "rounds": 3, "implementer_iterations": 5, "noop_rounds_streak": 0, "duration_secs": 712, "config": {"max_rounds": 25, "max_iters": 25, "max_noop_rounds": 2, "min_findings_severity": "P2", "implement_timeout_secs": 14400}}
```

The human-readable `rb-lite clean after N round(s)` line is printed before
the JSON on success; failure messages still go to stderr.

## Configuration env vars

- `RB_LITE_BASE`
- `RB_LITE_MAX_ROUNDS`
- `RB_LITE_MAX_NOOP_ROUNDS`
- `RB_LITE_MAX_ITERS`
- `RB_LITE_IMPLEMENT_TIMEOUT`
- `RB_LITE_IMPLEMENT_CMD`
- `RB_LITE_SESSION_REGEX`
- `RB_LITE_REVIEWERS_FILE`
- `RB_LITE_MIN_FINDINGS_SEVERITY`
- `RB_LITE_RUN_DIR`

## Development

```bash
# Enter a shell with bash, git, just, ripgrep
nix develop

# Run the smoke suite (fakes codex/claude — no API credentials needed)
just test

# Full local gate (lint + smoke + nix flake check)
just check
```

The smoke tests cover the loop's behavior with fake implementer and reviewer
binaries on `PATH`. They do not exercise live codex/claude.

## Notes

- `rb-lite` was largely written by `rb-lite` itself, dogfood-style: the
  implementer + reviewer panel iterated on its own source until each new
  feature reached the new severity floor or no-op-stop conditions. The git
  history shows each feature's dogfood signal in commit messages.
- Sister project: [`ralph-burning`](https://github.com/douglaz/ralph-burning)
  — same family of orchestration ideas, more substantial Rust implementation.
