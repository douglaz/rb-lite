#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=${TMPDIR:-/tmp}/rb-lite-tests.$$

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file=$1
  local pattern=$2
  [[ -f $file ]] || fail "missing file: $file"
  grep -Eq "$pattern" "$file" || fail "expected $file to match $pattern"
}

assert_equals() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ $expected == "$actual" ]] || fail "$label: expected $expected, got $actual"
}

new_repo() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  mkdir -p "$dir/bin" "$dir/tests"
  cp "$ROOT/bin/rb-lite" "$dir/bin/rb-lite"
  chmod +x "$dir/bin/rb-lite"
  (
    cd "$dir"
    git init -q
    git config user.email test@example.com
    git config user.name Test
    printf '.rb-lite/\n' >.gitignore
    printf 'base\n' >base.txt
    git add .gitignore base.txt
    git commit -qm base
  )
  printf '%s\n' "$dir"
}

write_fake() {
  local repo=$1
  local name=$2
  local body=$3
  mkdir -p "$repo/fakes"
  {
    printf '#!%s\n' "${BASH:-/usr/bin/env bash}"
    printf 'set -Eeuo pipefail\n'
    printf '%s\n' "$body"
  } >"$repo/fakes/$name"
  chmod +x "$repo/fakes/$name"
}

write_reviewers() {
  local repo=$1
  shift
  printf '%s\n' "$@" >"$repo/.rb-lite-reviewers"
}

run_rb_lite() {
  local repo=$1
  shift
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" "$repo/bin/rb-lite" "$@"
  )
}

test_implementer_stops_when_stable() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "changed\n" >changed.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "change once" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 2 "$(cat "$repo/.rb-lite/implementer-count")" "implementer call count"
  assert_file_contains "$repo/changed.txt" 'changed'
}

test_progress_log_mirrors_to_stderr() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/progress-stderr"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "progress stderr" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err

  assert_file_contains /tmp/rb-lite-test.err 'round 1 implementer iteration 1 starting'
  assert_file_contains /tmp/rb-lite-test.err 'round 1 implementer stabilized at iteration 1'
  assert_file_contains "$run_dir/log.txt" 'round 1 implementer iteration 1 starting'
}

test_p1_review_triggers_remediation_round() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ $PROMPT == *"Review files"* ]]; then
  printf "saw review\n" >remediated.txt
fi
if [[ -n ${REVIEW_FILES:-} ]]; then
  printf "%s\n" "$REVIEW_FILES" >env-review-files.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "\"Title\": \"[P1] fix the issue\"\n"
else
  printf "No findings\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "remediate review" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "remediation implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw review'
  assert_file_contains "$repo/env-review-files.txt" 'review-round-1-1\.md'
}

test_default_severity_floor_ignores_p3_only_review() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/p3-default-clean"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" fake-reviewer 'printf "P3: trailing whitespace nit in docs/readme.md\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "p3 should not loop by default" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "P3 default implementer count"
  assert_file_contains "$run_dir/log.txt" 'review panel clean \(floor P2\)'
}

test_default_severity_floor_ignores_p3_body_that_mentions_p2() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/p3-body-p2-default-clean"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" fake-reviewer 'printf "P3: clarify (P2) floor docs\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "p3 body mentions p2" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "P3 body P2 default implementer count"
  assert_file_contains "$run_dir/log.txt" 'review panel clean \(floor P2\)'
}

test_default_severity_floor_triggers_on_p2_review() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/p2-default-findings"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ $PROMPT == *"Review files"* ]]; then
  printf "saw P2 review\n" >remediated.txt
  printf "%s\n" "$PROMPT" >remediation-prompt.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P2 useful cleanup\n"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "p2 should loop by default" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "P2 default implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw P2 review'
  assert_file_contains "$repo/remediation-prompt.txt" 'Address the actionable P0/P1/P2 findings'
  if grep -q 'P0/P1/P2/P3 findings' "$repo/remediation-prompt.txt"; then
    fail "default remediation prompt should not tell implementer to address P3 findings"
  fi
  assert_file_contains "$run_dir/log.txt" 'actionable findings \(floor P2\)'
}

test_severity_detection_accepts_common_reviewer_tag_formats() {
  local repo sample
  local -a samples=(
    'P2: bare colon finding'
    '- **P2:** markdown-bold finding'
    '**P2**: markdown-bold finding'
    'P2 (nice-to-have): finding'
    '## P2: heading finding'
    'P2, comma finding'
    '`P2`: backtick finding'
    '(P2) parenthesized finding'
    'Issue 1 (P2): parenthesized issue finding'
  )

  for sample in "${samples[@]}"; do
    repo=$(new_repo)
    mkdir -p "$repo/.rb-lite"
    printf "%s\n" "$sample" >"$repo/.rb-lite/reviewer-output"
    write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
    write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  cat .rb-lite/reviewer-output
else
  printf "No findings.\n"
fi
'
    write_reviewers "$repo" fake-reviewer

    run_rb_lite "$repo" run --task "common severity format" --max-rounds 2 --max-iters 1 \
      --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

    assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
    assert_equals 2 "$(cat "$repo/.rb-lite/implementer-count")" "severity format '$sample' implementer count"
  done
}

test_min_findings_severity_p3_triggers_p3_review() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ $PROMPT == *"Review files"* ]]; then
  printf "saw P3 review\n" >remediated.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P3: strict nit\n"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "strict p3" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' --min-findings-severity P3 >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "P3 strict implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw P3 review'
}

test_env_min_findings_severity_p3_triggers_p3_review() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ $PROMPT == *"Review files"* ]]; then
  printf "saw env P3 review\n" >remediated.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P3: env strict nit\n"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_MIN_FINDINGS_SEVERITY=P3 "$repo/bin/rb-lite" run \
      --task "env strict p3" --max-rounds 2 --max-iters 2 \
      --implement-cmd 'fake-implementer'
  ) >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "env P3 implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw env P3 review'
}

test_cli_min_findings_severity_overrides_env() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/cli-floor-over-env"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" fake-reviewer 'printf "P3: env would loop, cli floor should not\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_MIN_FINDINGS_SEVERITY=P3 "$repo/bin/rb-lite" run \
      --task "cli floor wins" --max-rounds 2 --max-iters 1 \
      --implement-cmd 'fake-implementer' --min-findings-severity P2 --run-dir "$run_dir"
  ) >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "cli severity floor precedence count"
  assert_file_contains "$run_dir/log.txt" 'review panel clean \(floor P2\)'
}

test_min_findings_severity_p1_ignores_p2_review() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" fake-reviewer 'printf -- "- [P2] below this floor\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "p1 floor" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --min-findings-severity P1 >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "P1 floor implementer count"
}

test_min_findings_severity_p0_triggers_p0_review() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ $PROMPT == *"Review files"* ]]; then
  printf "saw P0 review\n" >remediated.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "1. [P0] critical issue\n"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "p0 floor" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' --min-findings-severity P0 >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "P0 floor implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw P0 review'
}

test_invalid_min_findings_severity_dies() {
  local repo status
  repo=$(new_repo)

  status=0
  run_rb_lite "$repo" run --task "invalid floor" --min-findings-severity P9 \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  [[ $status != 0 ]] || fail "invalid severity floor should fail rb-lite"
  assert_file_contains /tmp/rb-lite-test.err 'min-findings-severity must be one of P0, P1, P2, P3'
}

test_clean_review_exits_successfully() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "clean" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
}

test_default_implementer_uses_noninteractive_codex_exec() {
  local repo uuid
  repo=$(new_repo)
  uuid=11111111-2222-3333-4444-555555555555
  write_fake "$repo" codex '
mkdir -p .rb-lite
count_file=.rb-lite/codex-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
prefix=.rb-lite/codex-$count
printf "%s\n" "$#" >"$prefix-argc"
i=1
for arg in "$@"; do
  printf "%s\n" "$arg" >"$prefix-arg$i"
  i=$((i + 1))
done
if (( count != 2 )); then
  printf "session id: 11111111-2222-3333-4444-555555555555\n" >&2
fi
if (( count == 1 )); then
  printf "changed once\n" >codex-changed.txt
elif (( count == 2 )); then
  printf "changed twice\n" >codex-changed.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/default-reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P1: force default command round reset check\n"
else
  printf "Clean review\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "default prompt marker" --max-rounds 2 --max-iters 4 \
    >/tmp/rb-lite-test.out

  assert_equals 4 "$(cat "$repo/.rb-lite/codex-count")" "default codex call count"
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-1-argc")" "default codex arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-1-arg1")" "default codex subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-1-arg2")" "default codex approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-1-arg3")" "default codex repo flag"
  assert_file_contains "$repo/.rb-lite/codex-1-arg4" 'Read AGENTS\.md'
  assert_file_contains "$repo/.rb-lite/codex-1-arg4" 'default prompt marker'
  assert_equals 6 "$(cat "$repo/.rb-lite/codex-2-argc")" "resume codex arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-2-arg1")" "resume codex subcommand"
  assert_equals resume "$(cat "$repo/.rb-lite/codex-2-arg2")" "resume codex command"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-2-arg3")" "resume codex approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-2-arg4")" "resume codex repo flag"
  assert_equals "$uuid" "$(cat "$repo/.rb-lite/codex-2-arg5")" "resume codex session id"
  assert_file_contains "$repo/.rb-lite/codex-2-arg6" 'default prompt marker'
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-3-argc")" "default codex drops stale session arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-3-arg1")" "default codex drops stale session subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-3-arg2")" "default codex drops stale session approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-3-arg3")" "default codex drops stale session repo flag"
  assert_file_contains "$repo/.rb-lite/codex-3-arg4" 'default prompt marker'
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-4-argc")" "default codex round reset arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-4-arg1")" "default codex round reset subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-4-arg2")" "default codex round reset approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-4-arg3")" "default codex round reset repo flag"
  assert_file_contains "$repo/.rb-lite/codex-4-arg4" 'Review files'
}

test_implementer_session_resume_resets_at_round_boundary() {
  local repo uuid
  repo=$(new_repo)
  uuid=11111111-2222-3333-4444-555555555555
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
printf "%s.%s:%s\n" "$ROUND" "$ITERATION" "${RB_LITE_PREV_SESSION:-}" >>.rb-lite/session-env.txt
printf "session id: 11111111-2222-3333-4444-555555555555\n" >&2
if [[ $ROUND == 1 && $ITERATION == 1 ]]; then
  printf "changed once\n" >changed.txt
fi
'
  write_fake "$repo" fake-reviewer '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P1: force a second round\n"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "session continuity" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/session-env.txt" '^1\.1:$'
  assert_file_contains "$repo/.rb-lite/session-env.txt" "^1\\.2:$uuid$"
  assert_file_contains "$repo/.rb-lite/session-env.txt" '^2\.1:$'
}

test_implementer_session_resume_picks_first_match() {
  local repo first second
  repo=$(new_repo)
  first=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  second=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
printf "%s.%s:%s\n" "$ROUND" "$ITERATION" "${RB_LITE_PREV_SESSION:-}" >>.rb-lite/session-env.txt
printf "session id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n" >&2
printf "echoed prompt: session id: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n" >&2
if [[ $ROUND == 1 && $ITERATION == 1 ]]; then
  printf "changed once\n" >changed.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings.\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "first match wins" --max-rounds 1 --max-iters 2 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/session-env.txt" "^1\\.2:$first$"
  if grep -q "$second" "$repo/.rb-lite/session-env.txt"; then
    fail "iter 2 captured the echoed/forged session id instead of the real header"
  fi
}

test_env_implement_cmd_override_still_wins() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" codex 'printf "default codex should not run\n" >&2; exit 44'
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
printf "env override\n" >.rb-lite/env-override
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENT_CMD='fake-implementer' "$repo/bin/rb-lite" run \
      --task "env override" --max-rounds 1 --max-iters 1
  ) >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/env-override" 'env override'
}

test_implement_timeout_fails_stuck_iteration() {
  local repo run_dir sleep_pid status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/timeout-run"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
sleep 5 &
printf "%s\n" "$!" >.rb-lite/sleep-pid
wait "$!"
'

  status=0
  run_rb_lite "$repo" run --task "timeout" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --implement-timeout 1 --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  [[ $status != 0 ]] || fail "timed-out implementer should fail rb-lite"
  assert_file_contains /tmp/rb-lite-test.err 'implementer loop failed'
  assert_file_contains "$run_dir/log.txt" 'failed with exit 124'
  sleep_pid=$(cat "$repo/.rb-lite/sleep-pid")
  if kill -0 "$sleep_pid" 2>/dev/null; then
    fail "timed-out implementer left sleep running"
  fi
}

test_env_implement_timeout_fails_stuck_iteration() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/env-timeout-run"
  write_fake "$repo" fake-implementer 'sleep 5'

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENT_TIMEOUT=1 "$repo/bin/rb-lite" run \
      --task "env timeout" --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir"
  ) >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  [[ $status != 0 ]] || fail "env timed-out implementer should fail rb-lite"
  assert_file_contains /tmp/rb-lite-test.err 'implementer loop failed'
  assert_file_contains "$run_dir/log.txt" 'failed with exit 124'
}

test_cli_implement_timeout_overrides_invalid_env() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "No findings.\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENT_TIMEOUT=invalid "$repo/bin/rb-lite" run \
      --task "timeout precedence" --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --implement-timeout 1
  ) >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
}

test_implement_timeout_requires_gnu_timeout() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" timeout 'printf "not GNU timeout\n"'

  status=0
  run_rb_lite "$repo" run --task "timeout validation" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'printf noop' --implement-timeout 1 \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  [[ $status != 0 ]] || fail "non-GNU timeout should fail validation"
  assert_file_contains /tmp/rb-lite-test.err 'GNU coreutils timeout'
}

test_untracked_files_affect_stability() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "untracked\n" >untracked-result.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "Clean\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "untracked" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 2 "$(cat "$repo/.rb-lite/implementer-count")" "untracked stability count"
}

test_quoted_untracked_paths_affect_stability() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
path=$'"'"'quoted	path.txt'"'"'
if (( count == 1 )); then
  printf "untracked with tab\n" >"$path"
fi
'
  write_fake "$repo" fake-reviewer 'printf "Clean\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "quoted untracked" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 2 "$(cat "$repo/.rb-lite/implementer-count")" "quoted untracked stability count"
}

test_dirty_symlink_retarget_affects_stability() {
  local repo
  repo=$(new_repo)
  (
    cd "$repo"
    ln -s committed-target tracked-link
    git add tracked-link
    git commit -qm add-symlink
    rm -f tracked-link
    ln -s dirty-target-a tracked-link
  )
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  rm -f tracked-link
  ln -s dirty-target-b tracked-link
fi
'
  write_fake "$repo" fake-reviewer 'printf "Clean\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "retarget symlink" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 2 "$(cat "$repo/.rb-lite/implementer-count")" "dirty symlink retarget stability count"
}

test_rb_lite_artifacts_do_not_affect_stability() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "artifact %s\n" "$count" >.rb-lite/generated
'
  write_fake "$repo" fake-reviewer 'printf "Clean\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "artifacts" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "artifact stability count"
}

test_custom_run_dir_does_not_affect_stability() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/runtime-output"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "Clean\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "custom run dir" --max-rounds 1 --max-iters 3 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  [[ -f $run_dir/implementer-round-1-iter-1.stdout ]] || fail "missing custom run dir artifact"
  [[ ! -f $run_dir/implementer-round-1-iter-2.stdout ]] || fail "custom run dir artifact affected stability"
}

test_reviewer_config_writes_per_reviewer_files() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/custom-run"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" reviewer-one 'printf "reviewer one clean\n"'
  write_fake "$repo" reviewer-two 'printf "reviewer two clean\n"'
  {
    printf '# reviewer panel\n'
    printf 'reviewer-one\n'
    printf '\n'
    printf 'reviewer-two\n'
  } >"$repo/.rb-lite-reviewers"

  run_rb_lite "$repo" run --task "per-reviewer" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/review-round-1-1.md" 'reviewer one clean'
  assert_file_contains "$run_dir/review-round-1-2.md" 'reviewer two clean'
  if grep -q 'reviewer two clean' "$run_dir/review-round-1-1.md"; then
    fail "reviewer 1 file should not contain reviewer 2 output"
  fi
  [[ ! -e $run_dir/latest-review.md ]] || fail "latest-review.md should not exist (combined doc dropped)"
}

test_default_reviewer_panel_runs_codex_and_claude() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/default-panel"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" codex '
case "${1:-}" in
  review)
    printf "codex says clean\n"
    ;;
  *)
    printf "unexpected codex args: %s\n" "$*" >&2
    exit 99
    ;;
esac
'
  write_fake "$repo" claude '
mkdir -p .rb-lite
printf "%s\n" "$*" >.rb-lite/claude-args
printf "claude says clean\n"
'

  run_rb_lite "$repo" run --task "default panel" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/review-round-1-1.md" 'codex says clean'
  assert_file_contains "$run_dir/review-round-1-2.md" 'claude says clean'
  assert_file_contains "$repo/.rb-lite/claude-args" 'permission-mode acceptEdits'
  assert_file_contains "$repo/.rb-lite/claude-args" 'allowedTools'
  assert_file_contains "$repo/.rb-lite/claude-args" 'Bash,Edit,Write,Read,Glob,Grep'
  if grep -q 'dangerously-skip-permissions' "$repo/.rb-lite/claude-args"; then
    fail "default claude reviewer must not use --dangerously-skip-permissions"
  fi
  assert_file_contains "$repo/.rb-lite/claude-args" 'base ref '
}

test_reviewer_exit_two_is_operational_failure() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" failing-reviewer 'printf "tool failed without findings\n" >&2; exit 2'
  write_reviewers "$repo" failing-reviewer

  status=0
  run_rb_lite "$repo" run --task "reviewer fails" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  [[ $status != 0 ]] || fail "reviewer exit 2 should fail rb-lite"
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "reviewer failure implementer count"
  assert_file_contains /tmp/rb-lite-test.err 'review panel failed with exit 2'
}

test_reviewer_stderr_excluded_from_combined_when_clean() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/stderr-clean"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" noisy-reviewer '
printf "STDOUT_REVIEW_BODY\n"
printf "STDERR_NOISE_LINE_ALPHA\n" >&2
printf "STDERR_NOISE_LINE_BETA\n" >&2
'
  write_reviewers "$repo" noisy-reviewer

  run_rb_lite "$repo" run --task "stderr noise" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/review-round-1-1.md" 'STDOUT_REVIEW_BODY'
  if grep -q 'STDERR_NOISE_LINE' "$run_dir/review-round-1-1.md"; then
    fail "clean reviewer stderr leaked into per-reviewer file"
  fi
  assert_file_contains "$run_dir/reviewer-round-1-1.stderr" 'STDERR_NOISE_LINE_ALPHA'
}

test_failed_reviewer_path_omitted_from_review_files() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/failed-omitted"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if [[ -n ${REVIEW_FILES:-} ]]; then
  printf "%s\n" "$REVIEW_FILES" >round-${ROUND}-review-files.txt
fi
'
  write_fake "$repo" reviewer-a 'printf "command not found\n" >&2; exit 7'
  write_fake "$repo" reviewer-b '
mkdir -p .rb-lite
count_file=.rb-lite/reviewer-b-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "P1: real finding\n"
else
  printf "No findings.\n"
fi
'
  {
    printf "reviewer-a\n"
    printf "reviewer-b\n"
  } >"$repo/.rb-lite-reviewers"

  run_rb_lite "$repo" run --task "failed omitted" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 2 round'
  [[ -f $repo/round-2-review-files.txt ]] || fail "round-2 implementer did not see REVIEW_FILES"
  assert_file_contains "$repo/round-2-review-files.txt" 'review-round-1-2\.md'
  if grep -q 'review-round-1-1\.md' "$repo/round-2-review-files.txt"; then
    fail "REVIEW_FILES on round 2 should not include the failed reviewer's path"
  fi
}

test_failed_reviewer_stdout_p_token_does_not_trigger_round() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/stdout-pseudofinding"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" failing-reviewer 'printf "usage: reviewer [P0|P1|P2|P3]\n"; exit 5'
  write_fake "$repo" passing-reviewer 'printf "No findings.\n"'
  {
    printf 'failing-reviewer\n'
    printf 'passing-reviewer\n'
  } >"$repo/.rb-lite-reviewers"

  run_rb_lite "$repo" run --task "stdout p-token" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "stdout p-token implementer count"
}

test_failed_reviewer_stderr_p_token_does_not_trigger_round() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/stderr-pseudofinding"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" failing-reviewer 'printf "usage: reviewer [P0|P1|P2|P3]\n" >&2; exit 4'
  write_fake "$repo" passing-reviewer 'printf "No findings.\n"'
  {
    printf 'failing-reviewer\n'
    printf 'passing-reviewer\n'
  } >"$repo/.rb-lite-reviewers"

  run_rb_lite "$repo" run --task "stderr p-token" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "stderr p-token implementer count"
  assert_file_contains "$run_dir/review-round-1-1.md" 'usage: reviewer'
}

test_partial_reviewer_failure_does_not_abort() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/partial-failure"
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/implementer-count
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
'
  write_fake "$repo" failing-reviewer 'printf "boom\n" >&2; exit 3'
  write_fake "$repo" passing-reviewer 'printf "passing reviewer clean\n"'
  {
    printf 'failing-reviewer\n'
    printf 'passing-reviewer\n'
  } >"$repo/.rb-lite-reviewers"

  run_rb_lite "$repo" run --task "partial failure" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_file_contains "$run_dir/review-round-1-2.md" 'passing reviewer clean'
  assert_file_contains "$run_dir/review-round-1-1.md" 'exit 3 — output may be partial'
  assert_file_contains "$run_dir/review-round-1-1.md" 'stderr tail'
  assert_file_contains "$run_dir/review-round-1-1.md" 'boom'
  assert_file_contains "$run_dir/log.txt" 'partial failures: 1 of 2 reviewers succeeded'
}

mkdir -p "$TMP_ROOT"

test_implementer_stops_when_stable
test_progress_log_mirrors_to_stderr
test_p1_review_triggers_remediation_round
test_default_severity_floor_ignores_p3_only_review
test_default_severity_floor_ignores_p3_body_that_mentions_p2
test_default_severity_floor_triggers_on_p2_review
test_severity_detection_accepts_common_reviewer_tag_formats
test_min_findings_severity_p3_triggers_p3_review
test_env_min_findings_severity_p3_triggers_p3_review
test_cli_min_findings_severity_overrides_env
test_min_findings_severity_p1_ignores_p2_review
test_min_findings_severity_p0_triggers_p0_review
test_invalid_min_findings_severity_dies
test_clean_review_exits_successfully
test_default_implementer_uses_noninteractive_codex_exec
test_implementer_session_resume_resets_at_round_boundary
test_implementer_session_resume_picks_first_match
test_env_implement_cmd_override_still_wins
test_implement_timeout_fails_stuck_iteration
test_env_implement_timeout_fails_stuck_iteration
test_cli_implement_timeout_overrides_invalid_env
test_implement_timeout_requires_gnu_timeout
test_untracked_files_affect_stability
test_quoted_untracked_paths_affect_stability
test_dirty_symlink_retarget_affects_stability
test_rb_lite_artifacts_do_not_affect_stability
test_custom_run_dir_does_not_affect_stability
test_reviewer_config_writes_per_reviewer_files
test_default_reviewer_panel_runs_codex_and_claude
test_reviewer_exit_two_is_operational_failure
test_reviewer_stderr_excluded_from_combined_when_clean
test_failed_reviewer_path_omitted_from_review_files
test_failed_reviewer_stdout_p_token_does_not_trigger_round
test_failed_reviewer_stderr_p_token_does_not_trigger_round
test_partial_reviewer_failure_does_not_abort

printf 'ok - smoke tests passed\n'
