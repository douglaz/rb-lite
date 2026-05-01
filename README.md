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
- `latest-review.md`
- `log.txt`

The default implementer command is:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
```

Override it with `--implement-cmd` or `RB_LITE_IMPLEMENT_CMD`.

The default reviewer is `codex review --base "$BASE"`. To use a panel, create a
`.rb-lite-reviewers` file with one shell command per line. Blank lines and lines
starting with `#` are ignored.

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
