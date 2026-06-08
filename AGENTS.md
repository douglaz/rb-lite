# AGENTS.md

This repository is intentionally small. Keep the implementation Bash-first and
avoid recreating ralph-burning's durable orchestration stack.

## Project Norms

- Implement `rb-lite` as a small Bash CLI, not Rust.
- Do not add rollback, checkpoint commit, hard reset, worktree recovery, daemon,
  PR automation, or persistent project/run database features.
- The useful scope is: run an implementer loop until the git diff stabilizes,
  run a lightweight final review panel, feed actionable review findings back
  into the next implementer round, and stop when clean or capped.
- There is no default implementer. Users must choose `--implementer claude`,
  `--implementer codex`, or provide a raw `--implement-cmd`.
- Prefer visible files and simple commands over hidden state. Runtime logs may
  live under `.rb-lite/`, and `.rb-lite/` must be ignored by git.
- Keep tests deterministic by using fake `codex`/`claude`/reviewer commands.
  Do not rely on live model credentials in tests.
- Use `just` for local task recipes instead of `make`.
- Verification should include `just test`, `nix build`, and `nix flake check`.
  Do not introduce a Rust crate or Cargo workflow.

## Reviewer Scope

Reviewers (codex review, claude -p, custom panel commands) must ignore changes
under `.rb-lite/`, `.ralph-burning/`, and `.git/ralph-burning-live/`. Those
paths hold runtime logs and orchestration state, not code under review — the
implementer's stability fingerprint already excludes them.
