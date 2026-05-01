# rb-lite implementation prompt

## Problem Description

Build `rb-lite`: a deliberately small Bash implementation of the only workflow
we actually need from ralph-burning.

The target workflow is:

1. Run an implementer agent repeatedly until the repository diff stops changing.
2. Run a final review panel.
3. If any reviewer reports P0/P1/P2/P3 findings, feed the combined review back
   into the implementer loop.
4. Stop when the final review panel is clean, or when configured caps are hit.

This should be a compact, inspectable Bash tool. Do not recreate durable project
records, rollback points, checkpoint commits, daemon leases, worktree recovery,
PR automation, milestone tracking, structured JSON payload contracts, or a Rust
crate.

The implementation should live in `~/rb-lite`.

## Implementation Hints

- Create an executable Bash CLI at `bin/rb-lite`.
- Add a short `README.md`, a `justfile` with `just test`, a `flake.nix`,
  deterministic smoke tests under `tests/`, and a `.gitignore` that ignores
  `.rb-lite/`.
- Use `set -Eeuo pipefail`, arrays, quoted variables, and predictable temp/log
  paths.
- Default to operating on the current git repository.
- Store run artifacts under `.rb-lite/runs/<timestamp-or-id>/`, including:
  - implementer stdout/stderr per iteration
  - reviewer stdout/stderr per reviewer per round
  - a combined `latest-review.md`
  - a simple text log
- Do not commit automatically. Do not run `git reset`, `git checkout --`,
  `git clean`, or any destructive rollback command.
- It is acceptable to create a branch only if the user explicitly passes a
  branch option; otherwise run on the current branch.
- Detect implementer stability by fingerprinting git state before and after an
  implementer invocation. Include tracked, staged, unstaged, and untracked file
  content. Exclude `.git/`, `.rb-lite/`, and `.ralph-burning/`.
- The default implementer command should be
  `codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"`,
  but make it configurable without editing the script.
- The default implementer prompt should say:

```text
Read AGENTS.md if present. If a review file is provided, address the findings
in that review. Otherwise implement the requested work. Stop when no code or
test changes are needed.
```

- Support a user-supplied task prompt via either a command-line flag or prompt
  file. The active review file path should be included in the implementer prompt
  on remediation rounds.
- Implement a lightweight review panel:
  - default reviewer command: `codex review --base <base>`
  - default base ref: `origin/master`, configurable by flag/env
  - support multiple reviewer commands from a simple config file such as
    `.rb-lite-reviewers`, one shell command per line, with blank lines and `#`
    comments ignored
  - run reviewers concurrently
  - save each reviewer output
  - combine all reviewer outputs into `latest-review.md`
  - consider the panel clean when no combined output contains a P0/P1/P2/P3
    severity marker
- Keep the review panel intentionally simple. Do not implement voting, arbiter
  tie-breaking, quorum math, or reviewer amendment routing in this first version.
- Provide clear exit codes:
  - `0`: review panel clean
  - nonzero: implementer/reviewer command failed, max rounds hit, not in a git
    repo, invalid options, or other operational error
- Provide `bin/rb-lite --help` with the important flags and env vars.

Suggested CLI shape:

```bash
bin/rb-lite run \
  --task "Fix the next ready bead" \
  --base origin/master \
  --max-rounds 25 \
  --max-iters 25
```

Useful env/config knobs:

- `RB_LITE_BASE`
- `RB_LITE_MAX_ROUNDS`
- `RB_LITE_MAX_ITERS`
- `RB_LITE_IMPLEMENT_CMD`
- `RB_LITE_REVIEWERS_FILE`
- `RB_LITE_RUN_DIR`

Tests should use fake commands on `PATH`, not live `codex`. At minimum, cover:

- implementer loop stops when the fake implementer no longer changes files
- a P1 review finding triggers another implementer round
- a clean review exits successfully
- untracked files affect the stability fingerprint
- `.rb-lite/` runtime artifacts do not affect stability
- reviewer config supports multiple reviewer commands and aggregates outputs

## IMPORTANT: Exclude orchestration state from review scope

Files under `.ralph-burning/` are live orchestration state and MUST NOT be
reviewed or flagged. Only review source code under `src/`, `tests/`, `docs/`,
and config files.

For this Bash-only repo, `bin/` is application source and must be reviewed.
Also ignore `.git/ralph-burning-live/` and `.rb-lite/` runtime output.

## Acceptance Criteria

- `bin/rb-lite --help` works.
- `just test` passes and runs deterministic tests without live model credentials.
- `nix build` and `nix flake check` pass.
- The project remains Bash-only. Do not add Rust or Cargo just to satisfy a
  generic Rust workflow.
- The implementation contains no rollback, checkpoint commit, hard reset,
  worktree recovery, daemon, PR automation, milestone, or durable project
  database feature.
- The review panel supports multiple reviewer commands running concurrently and
  aggregates P0/P1/P2/P3 findings into the next implementer round.
