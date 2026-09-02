# rb-lite

[![CI](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml/badge.svg)](https://github.com/douglaz/rb-lite/actions/workflows/ci.yml)

A small Bash CLI that drives an **implement → review** loop using an explicit
`claude`/`codex` implementer preset, a preset cycle, or a custom command. It
uses codex and [`claude`](https://docs.anthropic.com/claude/docs/claude-code) as
the default reviewer panel — two defect reviewers plus a skeptic that hunts
over-specification — with all models pinned. Repeatedly invokes the
implementer until the git diff stabilizes, runs the reviewer panel in parallel, feeds
gating findings back into the implementer, and stops when no defect reviewer gates a round,
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
3. Loops implementer ↔ panel-reviewer (codex + claude + a claude skeptic)
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
  panel includes `codex review`. The default reviewer pins `gpt-5.6-sol`, so
  your codex CLI has to be able to select it — **verified working on 0.146.0**.
  The `gpt-5.6` family first appears in codex release notes at `rust-v0.143.0`
  (2026-07-08), but those entries describe the Amazon Bedrock catalog, so they do
  not establish the floor for the default path; check your CLI rather than trust a
  version number. If it cannot select the model that reviewer fails and the panel
  proceeds on the remaining ones — a degraded panel, logged as
  `N of 3 reviewers succeeded`, not a hard error.
- `claude` CLI on `PATH`, authenticated, if your implementer preset/cycle
  includes `claude` or you use the default reviewer panel. The claude
  implementer preset uses `--permission-mode acceptEdits --output-format
  stream-json --verbose` with a broad allowed-tools list (matches the sister
  `ralph-burning` project).
  Built-in Claude calls force `CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000`.
- `jq` on `PATH` if you use the default reviewer panel from a source checkout
  (Nix installs wrap it automatically). The default claude reviewer uses
  `--output-format stream-json --verbose` and pipes stdout through `jq` to
  extract the final result event, so findings text remains parseable on stdout
  and Claude errors or missing results fail the reviewer.

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
                 │  • codex review --base X          (defects)       │
                 │  • claude -p "<defect prompt>" | jq -er '<result>' │
                 │  • claude -p "<over-spec prompt>" (skeptic)       │
                 │  • each writes review-round-N-K.md                │
                 └───────────────────────────┬───────────────────────┘
                                             │
                                             ▼
  clean (no gating finding)?  ──────► EXIT 0
        no defect reviewer survived? ► EXIT 11
        max rounds hit?  ───────────► EXIT 12
        2 no-op rounds + findings? ─► EXIT 13 (consensus failure)
        over --max-production-lines? ► EXIT 14 (budget exceeded)
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
| `--min-findings-severity LEVEL` | `P2` | Lowest **defect-reviewer** severity that triggers another round (`P0`/`P1`/`P2`/`P3`); the skeptic is advisory at every floor |
| `--implement-timeout SECS` | 14400 | SIGTERM/SIGKILL each implementer iteration if it runs longer |
| `--reviewer-timeout SECS` | 1800 | SIGTERM/SIGKILL each reviewer if it runs longer; empty disables |
| `--implementer NAME[,NAME...]` | none | Select an implementer preset (`claude` or `codex`) or comma-separated preset cycle; required unless `--implement-cmd` or env equivalent is set |
| `--implement-cmd CMD` | none | Raw implementer subprocess escape hatch; takes precedence over presets |
| `--reviewers-file PATH` | `.rb-lite-reviewers` | Custom **gating** panel (one shell command per line); replaces the built-in defect reviewers. Skeptics are a separate axis and are not affected |
| `--skeptics-file PATH` | `.rb-lite-skeptics` | Custom **advisory** panel; their findings inform rounds that happen but never start one. Falls back to the built-in skeptic |
| `--no-skeptic` | off | Drop skeptics entirely, built-in or supplied |
| `--max-production-lines N` | none | Exit `14` once added lines exceed N (test/fixture paths excluded) |
| `--budget-exclude GLOB` | test/fixture globs | Path excluded from the budget count; first use replaces the built-in list |
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

The default Claude reviewer has **no shell**: it gets `Read,Glob,Grep` plus web tools, and
`--disallowedTools "Edit,Write,NotebookEdit,Bash"`. Restricting `--allowedTools` alone
does not deny anything, so the explicit deny list is what enforces it.

Denying only the editing tools was not enough. A reviewer holding `Bash` can write —
`sed -i`, `rm`, a redirect, `git checkout` — and even an allowlist as narrow as
`Bash(git diff:*)` still permits `git diff --output=FILE`, which git creates. So the
reviewer gets no shell at all, and rb-lite writes the diff it needs to
`$RUN_DIR/reviewer-diff-round-$ROUND.patch` for it to `Read`.

That matters because a reviewer that can write would let one panel member mutate the
worktree while the other reads it — the two would then review different trees — and its
edits would bypass the implementer loop. The implementer preset is a different command and
keeps its write access, because writing is its job.

`rb-lite --version` prints the version. A build that answers `unknown command: --version`
predates this read-only panel, which is the signal a caller should use to require it.

## Customizing the reviewer panel

The default panel is three reviewers: `codex review`, a `claude` reviewer hunting
defects, and a `claude` skeptic hunting over-specification. The first two look for
what is missing; the skeptic is the only one that can argue for removing something,
which is what keeps a run from ratcheting. `--no-skeptic` drops it.

Skeptics are **advisory**: their findings reach the implementer in every round the
defect reviewers keep alive, and are always written to the run dir, but they never
start a round of their own and never block a clean verdict. The built-in skeptic's
prompt tags every finding `P2` and the default floor is `P2`, so without this it could
not let a run converge at all — across eight runs of one 2026-08 drive the panel went
clean zero times and every run ended at max-rounds, escalating to a human. A reviewer
whose job is to argue for less work must not be the reason more work happens. When a
skeptic reports and no gating finding meets the floor, the log says so and points at that
round's review files — stated as the floor test it performed, not as an absence, because a
raised floor also excludes a gating reviewer's lower-severity finding. Skeptics are matched across `P0`–`P3` rather than through the floor, so
raising the floor does not also hide the fact that one spoke.

The panel has **two axes, in two files**, because rb-lite cannot tell a skeptic from a
defect reviewer by looking at it — both are opaque shell commands emitting
severity-tagged lines, so identity has to be declared rather than inferred.

| file | role | findings |
| --- | --- | --- |
| `.rb-lite-reviewers` | gating | start rounds |
| `.rb-lite-skeptics` | advisory | inform rounds that happen; never start one |

**Upgrading from 0.4.x or earlier:** if you followed the old advice and pasted a skeptic
into `.rb-lite-reviewers`, **move that line to `.rb-lite-skeptics`**. Left where it is it
is a gating reviewer — its findings start rounds, and with your defect reviewers clean it
drives the run to `consensus_failure` (13) — and you now also get the built-in skeptic
alongside it. rb-lite warns when it spots one there. Custom panels that never carried a
skeptic need no change, but will gain the built-in one; `--no-skeptic` opts out.

Either file falls back to its built-in default when absent, empty, or comments-only. So
supplying a gating panel **keeps** your counter-pressure, and a skeptic you declare is
advisory the same way the built-in one is. Before the split, `--reviewers-file` replaced
both: overriding silently deleted the skeptic, and the documented workaround — carrying a
skeptic into the reviewers file — made it gating again and drove clean runs to
`consensus_failure`.

One shell command per line (blank lines and `#` comments ignored):

> **Upgrading from a version with the Gemini reviewer:** `$RUN_DIR/gemini-policy.toml`
> is no longer generated, because it existed only for the default Gemini reviewer that
> has been removed. A custom `.rb-lite-reviewers` line that passes
> `--policy "$RUN_DIR/gemini-policy.toml"` will now point at a file that does not
> exist. Drop that reviewer, or write your own policy file and reference that instead.
> Left unchanged it fails at run time — the panel still proceeds on whichever reviewers
> succeed, so the symptom is a quieter panel and a `N of M reviewers succeeded` line in
> the log, not an error.

```
# .rb-lite-reviewers
codex review --base "$BASE" -c 'model="gpt-5.6-sol"'
set -o pipefail; { git diff "$BASE" || printf "%s\n" "rb-lite: could not compute a diff against $BASE"; } >"$RUN_DIR/reviewer-diff-round-$ROUND.patch" 2>&1; CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000 claude -p "Review the diff vs $BASE. The diff is in $RUN_DIR/reviewer-diff-round-$ROUND.patch — read that file first; if it holds an rb-lite error instead of a diff, report that as P1 and do not call the change clean. Tag findings with P0/P1/P2/P3 severities. Output 'No findings.' if clean." --model claude-opus-5 --output-format stream-json --verbose --allowedTools "Read,Glob,Grep,WebSearch,WebFetch" --disallowedTools "Edit,Write,NotebookEdit,Bash" | jq -er 'if .type == "result" then if ((.is_error // false) or (((.subtype // "") | tostring) | test("error|fail"))) then error(.result // "claude reviewer returned is_error") else (.result // empty) end else empty end'
my-custom-linter --json | wrap-as-p-tags
```

Reviewers run **concurrently**, each gets `BASE`, `RUN_DIR`, `ROUND`,
`REVIEWER_INDEX` in env, and stdin closed. The default claude reviewer requires
`jq` because it extracts the final result event from
`claude --output-format stream-json` and fails when Claude reports `is_error` or
an error/failure subtype. By default, each reviewer is wrapped in
`timeout` (default 30m); a timed-out reviewer counts as a failed reviewer and is
recorded in its per-reviewer markdown file, but does not abort the panel as long
as at least one **defect** reviewer succeeds.

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
- Panel succeeds with **at least one exit-0 defect reviewer**; failed reviewers
  don't abort the run. Skeptics succeeding *alone* is a failed panel (exit `11`) — they
  are forbidden from reporting defects, so a verdict carrying only their votes would
  mean nothing looked for bugs. This is counted, not position-matched, so it holds for
  any number of skeptics.

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
CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000 claude -p "$PROMPT" --permission-mode acceptEdits --output-format stream-json --verbose --allowedTools "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch,Task,TaskOutput,TaskStop,Monitor"
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

### The implementer may challenge the panel

The default implementer prompt treats reviewer findings as **hypotheses, not
orders**. The implementer is told to decline a finding when it's a false positive
or **over-specification** (it adds mechanism, hardening, config, or abstraction
that no real correctness, security, or data-loss requirement needs), and to
record a reasoned rejection in `challenges-round-$ROUND.md` under the run dir
instead of implementing it. This is deliberate counter-pressure: the reviewer
panel only ever pushes toward *adding*, so without it a "simple" change ratchets
into speculative hardening over successive rounds.

A round where the implementer declines the remaining findings with documented
reasons is a legitimate outcome, not a stall. If it persists for
`--max-noop-rounds`, rb-lite still exits `13` (`consensus_failure`) — read the
`challenges-round-*.md` files and the latest review to decide whether you side
with the implementer (accept the run) or the panel (apply the fix yourself). A
custom `--implement-cmd` that uses `$PROMPT` receives these instructions too; a
wrapper that ignores or replaces `$PROMPT` is responsible for equivalent
challenge behavior.

Every round's decisions are recorded, not just its rejections: the implementer
writes one line per finding in `challenges-round-$ROUND.md`, each beginning with
`ACCEPTED`, `DECLINED`, or `DEFERRED`. rb-lite counts those lines and reports them
per round in the log and in the exit summary (`findings_accepted`,
`findings_declined`, `findings_deferred`, `rejections_total`,
`rejections_by_round`).

**Zero rejections is a red flag, and rb-lite says so.** After three consecutive
rounds in which the implementer declined and deferred nothing while the panel kept
reporting findings, the run log carries a one-time warning. Accepting every finding
is how a bounded change grows into speculative hardening: each accepted finding
adds mechanism, and that mechanism becomes the next round's review surface. The
warning is a signal, not a stop — rb-lite keeps going.

Counter-pressure on the *reviewer* side is on by default: the built-in panel
includes a skeptical reviewer that hunts over-specification and tags findings
`CUT` / `SIMPLIFY` / `DEFER`, so the panel is not composed solely of reviewers that
push toward adding. It is advisory — it informs rounds that happen, and never causes
one. Drop it with `--no-skeptic` for a small, already-bounded bead.
A caller-supplied `.rb-lite-reviewers` replaces only the gating reviewers; declare
advisory ones in `.rb-lite-skeptics`. See "Customizing the reviewer panel."

### Budgets stop the run

`--max-production-lines N` fails the run with exit `14` once added lines in the diff
against `--base` exceed `N`. Test and fixture paths are excluded by default
(`*.test`, `*_test.*`, `test/*`, `tests/*`, `fixtures/*` and their nested forms),
because a budget that counts tests is met by deleting coverage. Paths that git C-quotes
— TAB, newline, quote, backslash, or non-ASCII — are decoded before the globs are applied,
so an excluded file with an unusual name is still excluded. Override the
exclusions with `--budget-exclude GLOB` (repeatable); the first use *replaces* the
built-in list rather than extending it.

A budget is a stop, not a retry target. rb-lite reports the count, the limit, and
the five largest contributing files, then exits — it never continues with a larger
number. If the change genuinely cannot fit, that is a signal to re-shape the work
or re-derive the baseline, not to raise `N`.

## Stop conditions and exit codes

| Code | Status | Meaning |
|---|---|---|
| `0`  | `clean` | No **defect** reviewer reported a finding at or above the severity floor. The built-in skeptic is advisory, so a clean run may still carry its findings — `clean` means nothing gated the round, not finding-free |
| `2`  | `usage_error` | CLI parsing failure, invalid value, conflicting flags |
| `3`  | `env_error` | Not in git repo, missing tool, run-dir setup failure |
| `10` | `implementer_failed` | Implementer subprocess non-zero (incl. timeout 124/137) or max-iters without stabilizing. Transient provider errors (rate limit / overloaded / 5xx / network) are retried with backoff first — see `RB_LITE_API_RETRY_DELAYS` / `RB_LITE_API_MAX_RETRIES` |
| `11` | `review_panel_failed` | No **gating** reviewer exited 0 — either none succeeded, or only advisory skeptics did, which is not a review |
| `12` | `max_rounds_hit` | Hit `--max-rounds` before convergence |
| `13` | `consensus_failure` | Hit `--max-noop-rounds` consecutive no-op rounds with reviewers still finding things |
| `14` | `budget_exceeded` | Added production lines exceeded `--max-production-lines` |
| `70` | `internal_error` | Internal invariant violation or unhandled shell failure |

## End-of-run JSON summary

Every exit (success or failure) prints one JSON object on a single line to
stdout, as the **last** line of output. Pipe to `jq` to consume:

```json
{"run_dir": "/path/.rb-lite/runs/...", "exit_code": 0, "status": "clean", "rounds": 3, "implementer_iterations": 5, "noop_rounds_streak": 0, "findings_accepted": 9, "findings_declined": 2, "findings_deferred": 1, "rejections_total": 3, "rejections_by_round": [0,2,1], "production_lines_added": 184, "duration_secs": 712, "config": {"max_rounds": 25, "max_iters": 25, "max_noop_rounds": 2, "max_production_lines": 300, "min_findings_severity": "P2", "implement_timeout_secs": 14400, "reviewer_timeout_secs": 1800}}
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
- `RB_LITE_REVIEWERS_FILE` (gating panel)
- `RB_LITE_SKEPTICS_FILE` (advisory panel; independent of the gating file, and dropped entirely by `--no-skeptic`)
- `RB_LITE_MIN_FINDINGS_SEVERITY`
- `RB_LITE_RUN_DIR`
- `RB_LITE_API_RETRY_DELAYS` (space-separated backoff seconds before retrying an implementer iteration that failed with a transient provider error; last value repeats; default `10 30 60`; structured `retry_after` values are used as a delay floor)
- `RB_LITE_API_MAX_RETRIES` (max transient-error retries per implementer iteration; default `10`; `0` disables)
- `RB_LITE_SCRUB_ENV` (space-separated env var names unset before any implementer/reviewer runs; default scrubs the Claude Code session/instance **identity** markers — `CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH`; auth and behavior flags — incl. `CLAUDE_CODE_RETRY_WATCHDOG`, claude's 429/529 capacity wait — are preserved; built-in Claude commands explicitly set `CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000`; set empty to disable scrubbing — see "Running under an agent")

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
that resilience rather than falling back to rb-lite's bounded retries alone. The
built-in Claude implementer and reviewer also set
`CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000` explicitly.
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
