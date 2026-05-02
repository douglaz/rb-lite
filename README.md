# rb-lite

`rb-lite` is a small Bash CLI for the implement/review loop used in this repo:
run an implementer until the git diff stabilizes, run a lightweight review
panel, feed P0/P1/P2/P3 findings back into the implementer, and stop when the
panel is clean or a cap is reached.

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

The default implementer command is:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
```

Override it with `--implement-cmd` or `RB_LITE_IMPLEMENT_CMD`.

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
- `RB_LITE_MAX_ITERS`
- `RB_LITE_IMPLEMENT_CMD`
- `RB_LITE_REVIEWERS_FILE`
- `RB_LITE_RUN_DIR`

Run `bin/rb-lite --help` for the full option list.

## Tests

```bash
just test
```

The smoke tests use fake implementer and reviewer commands on `PATH`; they do
not require live model credentials.

Use `nix develop` to enter a shell with `just` and the basic development tools.
Run `just check` for the full local gate, including `nix flake check`.
