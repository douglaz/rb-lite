# rb-lite

`rb-lite` is a small Bash CLI for the implement/review loop used in this repo:
run an implementer until the git diff stabilizes, run a lightweight review
panel, trigger another implementer round on P0/P1/P2 findings by default, and
stop when the panel is clean or a cap is reached.

## Usage

```bash
bin/rb-lite run \
  --task "Fix the next ready bead" \
  --base origin/master \
  --max-rounds 25 \
  --max-iters 25
```

Artifacts are written under `.rb-lite/runs/<id>/` by default:

- implementer stdout/stderr for each iteration
- reviewer stdout/stderr for each reviewer and round
- `review-round-N-K.md` — one markdown file per reviewer per round, fed back
  to the implementer on the next round
- `log.txt`

Progress lines written to `log.txt` are also mirrored to stderr by default, so
long runs show round/iteration status in the terminal. Redirect stderr if you
want to suppress them.

The default implementer command is:

```bash
if [[ -n ${RB_LITE_PREV_SESSION:-} ]]; then
  codex exec resume --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$RB_LITE_PREV_SESSION" "$PROMPT"
else
  codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
fi
```

Within a single review round, rb-lite scans implementer stderr for a session ID
and exports it as `RB_LITE_PREV_SESSION` to the next implementer iteration; the
value resets at round boundaries or when stderr has no match. Override the
capture regex with `RB_LITE_SESSION_REGEX` when using a non-codex implementer
format, or set it empty to disable capture; the first capture group is used, or
the full match when no group is present. An empty capture leaves
`RB_LITE_PREV_SESSION` empty.

Override the implementer with `--implement-cmd` or `RB_LITE_IMPLEMENT_CMD`.
Use `--implement-timeout SECS` or `RB_LITE_IMPLEMENT_TIMEOUT` to cap each
implementer iteration; default is 14400 seconds (4 hours). The timeout uses GNU
coreutils `timeout`, sending SIGTERM at expiry and SIGKILL after a short grace
period if the implementer is still running.

By default, rb-lite only starts a remediation round when a successful reviewer
emits a P0, P1, or P2 finding. P3-only review output is treated as clean; this
is a deliberate behavior change to avoid late-stage nit ratchets. Use
`--min-findings-severity P3` or `RB_LITE_MIN_FINDINGS_SEVERITY=P3` to preserve
the old behavior. Valid levels are exactly `P0`, `P1`, `P2`, and `P3`.

To avoid spending repeated cycles on reviewer findings the implementer declines
to change, rb-lite stops with consensus failure after two consecutive no-op
implementer rounds that still produce actionable reviewer findings. Configure
this with `--max-noop-rounds N` or `RB_LITE_MAX_NOOP_ROUNDS`.

The default reviewer panel runs two reviewers concurrently:

- `codex review --base "$BASE"`
- `claude -p "<P0..P3 review prompt>" --permission-mode acceptEdits --allowedTools "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch,Task,TaskOutput,TaskStop,Monitor"` (matches the sibling ralph-burning project's claude backend config; the prompt's "Do not modify any files" line is the operative contract)

Both `codex` and `claude` must be on `PATH`. To override the panel, create a
`.rb-lite-reviewers` file with one shell command per line. Blank lines and lines
starting with `#` are ignored. The panel proceeds as long as at least one
reviewer exits 0; failed reviewers are tagged in their per-reviewer file but do
not abort the run. The run only aborts if every reviewer exits non-zero.

Each reviewer's output is written to its own `review-round-N-K.md` file. The
implementer receives the list via the `REVIEW_FILES` env var (newline-separated)
and is told via `PROMPT` to read each file independently — so it can weigh
disagreements between reviewers rather than seeing one merged blob.

**Reviewer contract**:

- A reviewer command must emit its review (any `P0`/`P1`/`P2`/`P3` findings,
  or `No findings.`) on **stdout**.
- Finding severities should be tagged near the start of each finding line, for
  example `P2:`, `[P2]`, `**P2**:`, or an issue heading like
  `Issue 1 (P2):`. Incidental mentions later in a finding body are ignored.
- Only findings at or above the configured severity floor trigger another
  implementer round. The default floor is `P2`, so P3-only output is clean
  unless `--min-findings-severity P3` or `RB_LITE_MIN_FINDINGS_SEVERITY=P3` is
  set.
- **Exit code semantics**: exit `0` = the tool succeeded and its stdout is the
  real review; exit non-zero = the tool itself failed and its output may be
  partial or garbage. Findings detection and the per-round implementer feed
  ignore non-zero reviewers entirely. A reviewer that uses non-zero exit codes
  semantically (e.g. a linter that exits `1` on findings) must be wrapped to
  exit `0`: `mylinter; true` or `mylinter || true`.
- Stderr is treated as tool/transcript noise and is excluded from the
  per-reviewer markdown when the reviewer exits 0 (this keeps codex's
  exec/transcript dumps off the loop). For reviewers that exit non-zero, the
  last 20 lines of stderr are appended to that reviewer's file as a debugging
  tail. Full per-reviewer stderr is always preserved on disk under
  `reviewer-round-N-K.stderr`.
- Reviewers are launched with stdin closed so `claude -p` does not stall
  waiting for input.

> **Breaking change**: prior versions exported a single `REVIEW_FILE` env var
> pointing at a combined `latest-review.md`. Both are gone. Custom
> `--implement-cmd` scripts must read `REVIEW_FILES` (newline-separated) or
> rely on the `PROMPT` text which already enumerates each path. Legacy
> wrappers using `set -u` and `REVIEW_FILE` will crash on the first
> implementer iteration and must be migrated.

## Configuration

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

Run `bin/rb-lite --help` for the full option list.

## Exit codes

- `0` - clean: review panel reported no findings at or above the configured severity floor.
- `2` - usage error: CLI parsing failure, invalid flag value, conflicting flags, or missing task file.
- `3` - environment/preflight error: not in a git repo, branch creation failure, unavailable GNU `timeout` when requested, or failed run-dir/log setup.
- `10` - implementer loop failed; rb-lite returns `10` for subprocess failures, timeouts that report `124` or `137`, or max implementer iterations before stabilization.
- `11` - review panel failed because zero reviewers exited `0`, including missing or failing reviewer commands.
- `12` - max rounds hit before the review panel was clean.
- `13` - consensus failure: max no-op rounds reached while reviewers still reported findings.
- `70` - internal rb-lite invariant or unexpected shell failure.

## Tests

```bash
just test
```

The smoke tests use fake implementer and reviewer commands on `PATH`; they do
not require live model credentials.

Use `nix develop` to enter a shell with `just` and the basic development tools.
Run `just check` for the full local gate, including `nix flake check`.
