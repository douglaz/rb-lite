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

require_timeout_with_kill_after() {
  command -v timeout >/dev/null \
    && timeout --kill-after=1s 1s true 2>/dev/null \
    || fail "timeout with --kill-after support is required for smoke tests (run via 'nix develop -c')"
}

assert_file_contains() {
  local file=$1
  local pattern=$2
  [[ -f $file ]] || fail "missing file: $file"
  grep -Eq "$pattern" "$file" || fail "expected $file to match $pattern"
}

assert_file_not_contains() {
  local file=$1
  local pattern=$2
  [[ -f $file ]] || fail "missing file: $file"
  ! grep -Eq "$pattern" "$file" || fail "expected $file not to match $pattern"
}

assert_last_stdout_summary() {
  local file=$1
  local status=$2
  local exit_code=$3
  local last

  [[ -f $file ]] || fail "missing file: $file"
  last=$(tail -n 1 "$file")
  [[ $last == \{*\} ]] || fail "last stdout line is not a JSON object: $last"
  printf '%s\n' "$last" | grep -Fq "\"status\": \"$status\"" \
    || fail "summary missing status $status: $last"
  printf '%s\n' "$last" | grep -Fq "\"exit_code\": $exit_code" \
    || fail "summary missing exit_code $exit_code: $last"
}

assert_no_stdout_summary() {
  local file=$1
  local last

  [[ -f $file ]] || fail "missing file: $file"
  last=$(tail -n 1 "$file")
  [[ $last != \{*\} ]] || fail "unexpected JSON summary line: $last"
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

write_fake_jq_result_extractor() {
  local repo=$1
  write_fake "$repo" jq '
expected="if .type == \"result\" then if ((.is_error // false) or (((.subtype // \"\") | tostring) | test(\"error|fail\"))) then error(.result // \"claude reviewer returned is_error\") else (.result // empty) end else empty end"
# The skeptical reviewer runs the same filter but names itself in the error message, so
# accept either. Anything else is still rejected: the point of pinning is that a reviewer
# silently changing its extraction cannot pass as working.
expected_skeptic=${expected/claude reviewer returned/skeptic reviewer returned}
if [[ ${1:-} != -er ]] || { [[ ${2:-} != "$expected" ]] && [[ ${2:-} != "$expected_skeptic" ]]; }; then
  printf "unexpected jq args: %s\n" "$*" >&2
  exit 94
fi
input=$(cat)
if [[ $input != *"\"type\":\"result\""* && $input != *"\"type\": \"result\""* ]]; then
  exit 4
fi
if [[ $input == *"\"is_error\":true"* || $input == *"\"is_error\": true"* || $input == *"\"subtype\":\"error"* || $input == *"\"subtype\":\"fail"* ]]; then
  result=${input#*\"result\":\"}
  result=${result%%\"*}
  printf "jq: error: %s\n" "$result" >&2
  exit 5
fi
result=${input#*\"result\":\"}
if [[ $result == "$input" ]]; then
  exit 4
fi
result=${result%%\"*}
printf "%s\n" "$result"
'
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

test_implementer_stdin_is_closed() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
if IFS= read -r line; then
  printf "unexpected stdin: %s\n" "$line" >&2
  exit 88
fi
printf "stdin closed\n" >.rb-lite/implementer-stdin
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  printf "should not reach implementer\n" | run_rb_lite "$repo" run \
    --task "stdin closed" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/implementer-stdin" 'stdin closed'
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

test_persistent_noop_implementer_consensus_failure_after_default_threshold() {
  local repo run_dir status
  local -a implementer_logs reviewer_logs
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/noop-stop"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "P1: persistent finding\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "persistent noop" --max-rounds 5 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  implementer_logs=("$run_dir"/implementer-round-*-iter-1.stdout)
  reviewer_logs=("$run_dir"/reviewer-round-*-1.stdout)
  assert_equals 13 "$status" "no-op consensus failure exit"
  assert_file_contains /tmp/rb-lite-test.out 'rb-lite consensus failure after 2 no-op implementer round'
  assert_file_contains /tmp/rb-lite-test.out 'reviewers still report findings'
  assert_last_stdout_summary /tmp/rb-lite-test.out consensus_failure 13
  assert_equals 2 "${#implementer_logs[@]}" "no-op stop implementer count"
  assert_equals 2 "${#reviewer_logs[@]}" "no-op stop reviewer count"
  assert_file_contains "$run_dir/log.txt" 'no-op implementer streak is 2'
}

test_max_rounds_hit_exits_12() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "P1: persistent finding\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "max rounds" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 12 "$status" "max rounds exit"
  assert_file_contains /tmp/rb-lite-test.err 'max rounds hit before review panel was clean'
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
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "P3 default floor implementer count"
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
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "P3 body P2 default floor implementer count"
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
  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "P2 default floor implementer count"
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

  assert_equals 2 "$status" "invalid severity floor exit"
  assert_file_contains /tmp/rb-lite-test.err 'min-findings-severity must be one of P0, P1, P2, P3'
  assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
}

test_help_output_does_not_emit_run_summary() {
  local status

  status=0
  "$ROOT/bin/rb-lite" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?
  assert_equals 0 "$status" "no-args usage exit"
  assert_file_contains /tmp/rb-lite-test.out '^Usage:'
  assert_no_stdout_summary /tmp/rb-lite-test.out

  status=0
  "$ROOT/bin/rb-lite" --help >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?
  assert_equals 0 "$status" "top-level help exit"
  assert_file_contains /tmp/rb-lite-test.out '^Usage:'
  assert_no_stdout_summary /tmp/rb-lite-test.out

  status=0
  "$ROOT/bin/rb-lite" run --help >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?
  assert_equals 0 "$status" "run help exit"
  assert_file_contains /tmp/rb-lite-test.out '^Usage:'
  assert_no_stdout_summary /tmp/rb-lite-test.out
}

test_run_dir_setup_failure_exits_3() {
  local repo status
  repo=$(new_repo)
  # Parent path is a regular file, so mkdir -p for the requested child fails.
  printf 'not a directory\n' >"$repo/not-a-dir"

  status=0
  run_rb_lite "$repo" run --task "bad run dir" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'printf noop' --run-dir "$repo/not-a-dir/child" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 3 "$status" "run-dir setup failure exit"
  assert_file_contains /tmp/rb-lite-test.err 'failed to create run directory'
  assert_last_stdout_summary /tmp/rb-lite-test.out env_error 3
}

test_run_log_setup_failure_exits_3() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/log-path-is-directory"
  mkdir -p "$run_dir/log.txt"

  status=0
  run_rb_lite "$repo" run --task "bad run log" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'printf noop' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 3 "$status" "run-log setup failure exit"
  assert_file_contains /tmp/rb-lite-test.err 'failed to initialize run log'
}

test_branch_creation_failure_exits_3() {
  local repo status
  repo=$(new_repo)
  git -C "$repo" branch rb-lite-existing

  status=0
  run_rb_lite "$repo" run --task "existing branch" --branch rb-lite-existing \
    --max-rounds 1 --max-iters 1 --implement-cmd 'printf noop' \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 3 "$status" "branch creation failure exit"
  assert_file_contains /tmp/rb-lite-test.err 'failed to create and switch to branch: rb-lite-existing'
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
  assert_last_stdout_summary /tmp/rb-lite-test.out clean 0
}

test_codex_implementer_preset_uses_noninteractive_codex_exec() {
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

  run_rb_lite "$repo" run --task "codex preset prompt marker" --max-rounds 2 --max-iters 4 \
    --implementer codex \
    >/tmp/rb-lite-test.out

  assert_equals 4 "$(cat "$repo/.rb-lite/codex-count")" "codex preset call count"
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-1-argc")" "codex preset arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-1-arg1")" "codex preset subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-1-arg2")" "codex preset approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-1-arg3")" "codex preset repo flag"
  assert_file_contains "$repo/.rb-lite/codex-1-arg4" 'Read AGENTS\.md'
  assert_file_contains "$repo/.rb-lite/codex-1-arg4" 'codex preset prompt marker'
  assert_equals 6 "$(cat "$repo/.rb-lite/codex-2-argc")" "resume codex arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-2-arg1")" "resume codex subcommand"
  assert_equals resume "$(cat "$repo/.rb-lite/codex-2-arg2")" "resume codex command"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-2-arg3")" "resume codex approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-2-arg4")" "resume codex repo flag"
  assert_equals "$uuid" "$(cat "$repo/.rb-lite/codex-2-arg5")" "resume codex session id"
  assert_file_contains "$repo/.rb-lite/codex-2-arg6" 'codex preset prompt marker'
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-3-argc")" "codex preset drops stale session arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-3-arg1")" "codex preset drops stale session subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-3-arg2")" "codex preset drops stale session approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-3-arg3")" "codex preset drops stale session repo flag"
  assert_file_contains "$repo/.rb-lite/codex-3-arg4" 'codex preset prompt marker'
  assert_equals 4 "$(cat "$repo/.rb-lite/codex-4-argc")" "codex preset round reset arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/codex-4-arg1")" "codex preset round reset subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/codex-4-arg2")" "codex preset round reset approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/codex-4-arg3")" "codex preset round reset repo flag"
  assert_file_contains "$repo/.rb-lite/codex-4-arg4" 'Review files'
}

test_claude_implementer_preset_uses_headless_accept_edits() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" claude '
mkdir -p .rb-lite
printf "%s\n" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-}" >.rb-lite/claude-max-output-tokens
printf "%s\n" "$#" >.rb-lite/claude-argc
i=1
for arg in "$@"; do
  printf "%s\n" "$arg" >".rb-lite/claude-arg$i"
  i=$((i + 1))
done
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "claude preset task marker" --max-rounds 1 --max-iters 1 \
    --implementer claude >/tmp/rb-lite-test.out

  assert_equals 128000 "$(cat "$repo/.rb-lite/claude-max-output-tokens")" "claude preset max output tokens"
  assert_equals 9 "$(cat "$repo/.rb-lite/claude-argc")" "claude preset arg count"
  assert_equals -p "$(cat "$repo/.rb-lite/claude-arg1")" "claude prompt flag"
  assert_file_contains "$repo/.rb-lite/claude-arg2" 'claude preset task marker'
  assert_equals --permission-mode "$(cat "$repo/.rb-lite/claude-arg3")" "claude permission flag"
  assert_equals acceptEdits "$(cat "$repo/.rb-lite/claude-arg4")" "claude permission mode"
  assert_equals --output-format "$(cat "$repo/.rb-lite/claude-arg5")" "claude output-format flag"
  assert_equals stream-json "$(cat "$repo/.rb-lite/claude-arg6")" "claude output format"
  assert_equals --verbose "$(cat "$repo/.rb-lite/claude-arg7")" "claude verbose flag"
  assert_equals --allowedTools "$(cat "$repo/.rb-lite/claude-arg8")" "claude allowed-tools flag"
  assert_file_contains "$repo/.rb-lite/claude-arg9" 'Bash,Edit,Write,Read,Glob,Grep'
  if grep -q -- '--dangerously-skip-permissions' "$repo"/.rb-lite/claude-arg*; then
    fail "claude preset must not use --dangerously-skip-permissions"
  fi
}

test_missing_implementer_is_usage_error_with_summary() {
  local repo status
  repo=$(new_repo)

  status=0
  (
    cd "$repo"
    unset RB_LITE_IMPLEMENT_CMD RB_LITE_IMPLEMENTER
    PATH="$repo/fakes:$PATH" "$repo/bin/rb-lite" run --task "missing implementer" \
      --max-rounds 1 --max-iters 1
  ) >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 2 "$status" "missing implementer exit"
  assert_file_contains /tmp/rb-lite-test.err 'an implementer is required'
  assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
}

test_empty_cli_implement_cmd_is_usage_error_with_summary() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "empty raw command" --max-rounds 1 --max-iters 1 \
    --implement-cmd "" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 2 "$status" "empty implement-cmd exit"
  assert_file_contains /tmp/rb-lite-test.err 'implement-cmd was set to an empty command'
  assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
}

test_invalid_implementer_is_usage_error() {
  local repo status
  repo=$(new_repo)

  status=0
  run_rb_lite "$repo" run --task "invalid implementer" --implementer bogus \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 2 "$status" "invalid implementer exit"
  assert_file_contains /tmp/rb-lite-test.err 'implementer must be one of claude, codex'
  assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
}

test_invalid_env_implementer_is_usage_error() {
  local repo status
  repo=$(new_repo)

  status=0
  (
    cd "$repo"
    unset RB_LITE_IMPLEMENT_CMD
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENTER=bogus "$repo/bin/rb-lite" run \
      --task "invalid env implementer"
  ) >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 2 "$status" "invalid env implementer exit"
  assert_file_contains /tmp/rb-lite-test.err 'RB_LITE_IMPLEMENTER must be one of claude, codex'
  assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
}

test_env_implementer_codex_selects_codex_preset() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "%s\n" "$#" >.rb-lite/env-codex-argc
i=1
for arg in "$@"; do
  printf "%s\n" "$arg" >".rb-lite/env-codex-arg$i"
  i=$((i + 1))
done
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    unset RB_LITE_IMPLEMENT_CMD
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENTER=codex "$repo/bin/rb-lite" run \
      --task "env codex preset" --max-rounds 1 --max-iters 1
  ) >/tmp/rb-lite-test.out

  assert_equals 4 "$(cat "$repo/.rb-lite/env-codex-argc")" "env codex preset arg count"
  assert_equals exec "$(cat "$repo/.rb-lite/env-codex-arg1")" "env codex preset subcommand"
  assert_equals --dangerously-bypass-approvals-and-sandbox "$(cat "$repo/.rb-lite/env-codex-arg2")" "env codex preset approval flag"
  assert_equals --skip-git-repo-check "$(cat "$repo/.rb-lite/env-codex-arg3")" "env codex preset repo flag"
  assert_file_contains "$repo/.rb-lite/env-codex-arg4" 'env codex preset'
}

test_implementer_preset_cycle_advances_after_review_findings() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/preset-cycle"
  write_fake "$repo" claude '
mkdir -p .rb-lite
printf "claude:%s:%s\n" "$ROUND" "$ITERATION" >>.rb-lite/preset-cycle.log
if [[ $ITERATION == 1 ]]; then
  printf "claude round %s\n" "$ROUND" >"round-${ROUND}-implementer.txt"
fi
'
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "codex:%s:%s\n" "$ROUND" "$ITERATION" >>.rb-lite/preset-cycle.log
if [[ $ITERATION == 1 ]]; then
  printf "codex round %s\n" "$ROUND" >"round-${ROUND}-implementer.txt"
fi
'
  write_fake "$repo" fake-reviewer '
if (( ROUND < 3 )); then
  printf "P1: force another implementer round %s\n" "$ROUND"
else
  printf "No findings.\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "cycle presets" --max-rounds 3 --max-iters 2 \
    --implementer claude,codex --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 3 round'
  assert_last_stdout_summary /tmp/rb-lite-test.out clean 0
  assert_file_contains "$repo/.rb-lite/preset-cycle.log" '^claude:1:1$'
  assert_file_contains "$repo/.rb-lite/preset-cycle.log" '^codex:2:1$'
  assert_file_contains "$repo/.rb-lite/preset-cycle.log" '^claude:3:1$'
  assert_file_contains "$run_dir/log.txt" 'round 1 implementer preset: claude'
  assert_file_contains "$run_dir/log.txt" 'round 2 implementer preset: codex'
  assert_file_contains "$run_dir/log.txt" 'round 3 implementer preset: claude'
  if grep -Eq '^codex:1:|^claude:2:|^codex:3:' "$repo/.rb-lite/preset-cycle.log"; then
    fail "implementer preset cycle used the wrong preset for a round"
  fi
}

test_env_implementer_cycle_selects_first_preset() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "codex round %s\n" "$ROUND" >.rb-lite/env-cycle-codex-round
'
  write_fake "$repo" claude '
mkdir -p .rb-lite
printf "claude should not run\n" >.rb-lite/env-cycle-claude-ran
exit 91
'
  write_fake "$repo" fake-reviewer 'printf "No findings.\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    unset RB_LITE_IMPLEMENT_CMD
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENTER=codex,claude "$repo/bin/rb-lite" run \
      --task "env cycle" --max-rounds 1 --max-iters 1
  ) >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/env-cycle-codex-round" '^codex round 1$'
  [[ ! -e $repo/.rb-lite/env-cycle-claude-ran ]] || fail "env cycle should select codex for round 1"
}

test_invalid_implementer_lists_are_usage_errors() {
  local repo status value
  repo=$(new_repo)

  for value in "claude,,codex" "claude,bogus"; do
    status=0
    run_rb_lite "$repo" run --task "invalid implementer list" --implementer "$value" \
      >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

    assert_equals 2 "$status" "invalid implementer list '$value' exit"
    assert_file_contains /tmp/rb-lite-test.err 'implementer must be one of claude, codex'
    assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
  done

  for value in "claude,,codex" "claude,bogus"; do
    status=0
    (
      cd "$repo"
      unset RB_LITE_IMPLEMENT_CMD
      PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENTER=$value "$repo/bin/rb-lite" run \
        --task "invalid env implementer list"
    ) >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

    assert_equals 2 "$status" "invalid env implementer list '$value' exit"
    assert_file_contains /tmp/rb-lite-test.err 'RB_LITE_IMPLEMENTER must be one of claude, codex'
    assert_last_stdout_summary /tmp/rb-lite-test.out usage_error 2
  done
}

test_cli_implement_cmd_takes_precedence_over_implementer() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "codex preset ran\n" >.rb-lite/codex-ran
exit 44
'
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
printf "raw command ran\n" >.rb-lite/raw-command-ran
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "raw command precedence" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --implementer codex >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/raw-command-ran" 'raw command ran'
  [[ ! -e $repo/.rb-lite/codex-ran ]] || fail "--implement-cmd should prevent codex preset from running"
}

test_env_implement_cmd_takes_precedence_over_env_implementer() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "env codex preset ran\n" >.rb-lite/env-codex-ran
exit 44
'
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
printf "env raw command ran\n" >.rb-lite/env-raw-command-ran
'
  write_fake "$repo" fake-reviewer 'printf "Clean review\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_IMPLEMENT_CMD='fake-implementer' RB_LITE_IMPLEMENTER=codex "$repo/bin/rb-lite" run \
      --task "env raw command precedence" --max-rounds 1 --max-iters 1
  ) >/tmp/rb-lite-test.out

  assert_file_contains "$repo/.rb-lite/env-raw-command-ran" 'env raw command ran'
  [[ ! -e $repo/.rb-lite/env-codex-ran ]] || fail "RB_LITE_IMPLEMENT_CMD should prevent RB_LITE_IMPLEMENTER preset from running"
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

  assert_equals 10 "$status" "timed-out implementer exit"
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

  assert_equals 10 "$status" "env timed-out implementer exit"
  assert_file_contains /tmp/rb-lite-test.err 'implementer loop failed'
  assert_file_contains "$run_dir/log.txt" 'failed with exit 124'
}

test_reviewer_timeout_fails_stuck_reviewer() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/reviewer-timeout-run"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fast-reviewer 'printf "Clean review\n"'
  write_fake "$repo" stuck-reviewer '
printf "stuck reviewer starting\n" >&2
sleep 5
'
  write_reviewers "$repo" fast-reviewer stuck-reviewer

  run_rb_lite "$repo" run --task "reviewer timeout" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --reviewer-timeout 1 --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_file_contains "$run_dir/review-round-1-1.md" 'Clean review'
  assert_file_contains "$run_dir/review-round-1-2.md" 'exit 124'
  assert_file_contains "$run_dir/review-round-1-2.md" 'stderr tail'
  assert_file_contains "$run_dir/review-round-1-2.md" 'stuck reviewer starting'
  assert_file_contains "$run_dir/log.txt" 'reviewer 2 failed with exit 124 .*timed out after 1s'
  assert_file_contains /tmp/rb-lite-test.out '"reviewer_timeout_secs": 1'
}

test_env_reviewer_timeout_fails_stuck_reviewer() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/env-reviewer-timeout-run"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fast-reviewer 'printf "Clean review\n"'
  write_fake "$repo" stuck-reviewer '
printf "env stuck reviewer starting\n" >&2
sleep 5
'
  write_reviewers "$repo" fast-reviewer stuck-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_REVIEWER_TIMEOUT=1 "$repo/bin/rb-lite" run \
      --task "env reviewer timeout" --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir"
  ) >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
  assert_file_contains "$run_dir/review-round-1-1.md" 'Clean review'
  assert_file_contains "$run_dir/review-round-1-2.md" 'exit 124'
  assert_file_contains "$run_dir/review-round-1-2.md" 'stderr tail'
  assert_file_contains "$run_dir/review-round-1-2.md" 'env stuck reviewer starting'
  assert_file_contains "$run_dir/log.txt" 'reviewer 2 failed with exit 124 .*timed out after 1s'
  assert_file_contains /tmp/rb-lite-test.out '"reviewer_timeout_secs": 1'
}

test_signal_summary_preserves_signal_exit_code() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/signal-run"
  write_fake "$repo" fake-implementer 'sleep 30'

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" timeout --preserve-status --kill-after=2s 1s \
      "$repo/bin/rb-lite" run --task "signal" --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir"
  ) >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 143 "$status" "signal termination exit"
  assert_last_stdout_summary /tmp/rb-lite-test.out internal_error 143
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

test_cli_reviewer_timeout_overrides_invalid_env() {
  local repo
  repo=$(new_repo)
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "No findings.\n"'
  write_reviewers "$repo" fake-reviewer

  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_REVIEWER_TIMEOUT=invalid "$repo/bin/rb-lite" run \
      --task "reviewer timeout precedence" --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --reviewer-timeout 1
  ) >/tmp/rb-lite-test.out

  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
}

test_implement_timeout_requires_kill_after_support() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" timeout '
if [[ ${1:-} == --kill-after* ]]; then
  printf "unsupported --kill-after\n" >&2
  exit 125
fi
if [[ ${1:-} == --version ]]; then
  printf "timeout (other coreutils) 1.0\n"
  exit 0
fi
[[ $# -gt 0 ]] || exit 125
shift
exec "$@"
'

  status=0
  run_rb_lite "$repo" run --task "timeout validation" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'printf noop' --implement-timeout 1 \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 3 "$status" "timeout without --kill-after validation exit"
  assert_file_contains /tmp/rb-lite-test.err 'timeout'
  assert_file_contains /tmp/rb-lite-test.err '.*--kill-after'
}

test_implement_timeout_accepts_uutils_timeout() {
  local repo status
  repo=$(new_repo)
  write_fake "$repo" timeout '
if [[ ${1:-} == --version ]]; then
  printf "timeout (uutils coreutils) 0.8.0\n"
  exit 0
fi
if [[ ${1:-} == --kill-after=* ]]; then
  shift
fi
[[ $# -gt 0 ]] || exit 125
shift
exec "$@"
'
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "No findings.\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "timeout validation" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --implement-timeout 5 \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "uutils timeout validation exit"
  assert_file_contains /tmp/rb-lite-test.err 'round 1 implementer iteration 1 starting'
  assert_file_contains /tmp/rb-lite-test.out 'rb-lite clean after 1 round'
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

test_version_matches_flake_version() {
  # Two files carry the version. They drifted the moment --version was added (flake said
  # 0.1.0, the binary said 0.2.0), which would ship a derivation whose name disagrees with
  # the tool inside it. Asserted rather than remembered.
  local script_v flake_v
  script_v=$(sed -n 's/^RB_LITE_VERSION=\(.*\)$/\1/p' "$ROOT/bin/rb-lite")
  flake_v=$(sed -n 's/^ *version = "\(.*\)";$/\1/p' "$ROOT/flake.nix" | head -1)
  [ -n "$script_v" ] || fail "no RB_LITE_VERSION in bin/rb-lite"
  [ -n "$flake_v" ] || fail "no version in flake.nix"
  assert_equals "$script_v" "$flake_v" "bin/rb-lite and flake.nix version"
}

test_version_command_reports_a_version() {
  local repo out short_out status
  repo=$(new_repo)
  status=0
  out=$(run_rb_lite "$repo" --version 2>/dev/null) || status=$?
  assert_equals 0 "$status" "--version exit status"
  # A glob would accept "rb-lite 0abc.x.y" — [0-9]* matches any trailing characters.
  # Anchored regex, and -V must produce byte-identical output, not merely exit 0.
  [[ $out =~ ^rb-lite\ [0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "--version should print 'rb-lite <semver>', got: $out"
  # -V is the same command; callers script either.
  status=0
  short_out=$(run_rb_lite "$repo" -V 2>/dev/null) || status=$?
  assert_equals 0 "$status" "-V exit status"
  assert_equals "$out" "$short_out" "-V output matches --version"
}

test_default_reviewer_panel_runs_codex_and_claude() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/default-panel"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex '
mkdir -p .rb-lite
printf "%s\n" "$*" >.rb-lite/codex-args
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
  # Two default reviewers now shell out to claude concurrently, so the fake must not write
  # one shared args file: whichever finished last would win and the assertions below would
  # silently describe the wrong reviewer. Split by the skeptic's distinctive prompt.
  write_fake "$repo" claude '
mkdir -p .rb-lite
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "%s\n" "$*" >.rb-lite/claude-skeptic-args
  printf "{\"type\":\"system\",\"subtype\":\"init\"}\n"
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
  exit 0
fi
printf "%s\n" "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-}" >.rb-lite/claude-max-output-tokens
printf "%s\n" "$*" >.rb-lite/claude-args
printf "{\"type\":\"system\",\"subtype\":\"init\"}\n"
printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"claude says clean from stream-json\"}\n"
'
  # The default panel must not reach for npx at all. A fake that records being called is
  # how "Gemini was removed" is asserted rather than assumed.
  write_fake "$repo" npx '
mkdir -p .rb-lite
printf "%s\n" "$*" >.rb-lite/npx-was-invoked
printf "npx must not be invoked by the default panel\n" >&2
exit 97
'

  run_rb_lite "$repo" run --task "default panel" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/review-round-1-1.md" 'codex says clean'
  assert_file_contains "$run_dir/review-round-1-2.md" 'claude says clean from stream-json'
  # The skeptic is the third default. Both other reviewers hunt what is missing, so without
  # it every finding the panel can raise argues for adding something.
  assert_file_contains "$run_dir/review-round-1-3.md" 'No findings.'
  if [[ -e "$run_dir/review-round-1-4.md" ]]; then
    fail "default panel must be three reviewers, found a fourth"
  fi
  if [[ ! -e "$repo/.rb-lite/claude-skeptic-args" ]]; then
    fail "default panel did not run the skeptical reviewer"
  fi
  # The skeptic must be read-only and must not duplicate the defect reviewers' lens.
  assert_file_contains "$repo/.rb-lite/claude-skeptic-args" 'CUT'
  assert_file_contains "$repo/.rb-lite/claude-skeptic-args" \
    '[-][-]disallowedTools Edit,Write,NotebookEdit,Bash,WebSearch,WebFetch'
  if grep -qE '[-][-]allowedTools [^ ]*(Edit|Write|Bash)' "$repo/.rb-lite/claude-skeptic-args"; then
    fail "skeptical reviewer must not be granted Edit/Write/Bash"
  fi
  if [[ -e "$repo/.rb-lite/npx-was-invoked" ]]; then
    fail "default panel invoked npx: $(cat "$repo/.rb-lite/npx-was-invoked")"
  fi

  # Both models are pinned. Inheriting each CLI's default would let a weaker model satisfy
  # a panel the caller believes is running these two.
  assert_file_contains "$repo/.rb-lite/codex-args" 'model="gpt-5\.6-sol"'
  assert_file_contains "$repo/.rb-lite/claude-args" '[-][-]model claude-opus-5'

  assert_equals 128000 "$(cat "$repo/.rb-lite/claude-max-output-tokens")" "default claude reviewer max output tokens"
  # READ-ONLY reviewer. The prompt says "do not modify any files"; before this the tools
  # said otherwise — acceptEdits plus Edit/Write let a reviewer mutate the worktree while
  # the codex reviewer was reading it, so the two could review different trees and any edit
  # bypassed the implementer loop entirely.
  # --disallowedTools is the part that actually denies: restricting --allowedTools alone
  # produces zero denials, so dropping Edit/Write from that list would look right and
  # change nothing.
  assert_file_contains "$repo/.rb-lite/claude-args" '[-][-]disallowedTools'
  assert_file_contains "$repo/.rb-lite/claude-args" 'Edit,Write,NotebookEdit'
  if grep -q 'permission-mode acceptEdits' "$repo/.rb-lite/claude-args"; then
    fail "default claude REVIEWER must not run with acceptEdits (the implementer preset may)"
  fi
  if grep -qE '[-][-]allowedTools [^ ]*(Edit|Write)' "$repo/.rb-lite/claude-args"; then
    fail "default claude reviewer must not be granted Edit/Write"
  fi
  assert_file_contains "$repo/.rb-lite/claude-args" 'output-format stream-json'
  assert_file_contains "$repo/.rb-lite/claude-args" 'verbose'
  assert_file_contains "$repo/.rb-lite/claude-args" 'allowedTools'
  # Bash must be RESTRICTED, not merely present. Denying Edit/Write/NotebookEdit does not
  # make a reviewer read-only while it still holds unrestricted Bash: `sed -i`, `rm`, a
  # shell redirect or `git checkout` all write. Verified empirically that the pattern form
  # both permits `git diff` and blocks a redirect.
  # NO Bash at all. A restricted allowlist was not enough: Bash(git diff:*) still
  # authorized `git diff --output=FILE`, which git happily writes — demonstrated, not
  # theorised. The reviewer does not need a shell; rb-lite's own shell writes the diff
  # into RUN_DIR and the reviewer reads it.
  # NOTE ON THE PATTERNS: the fake records "$*", so the shell has already stripped the
  # quotes — a pattern containing a double quote can NEVER match here. The previous
  # unrestricted-Bash guard did contain quotes and was therefore vacuous: it passed whatever
  # the reviewer was granted. Verified against a real recorded args line before use.
  # Anchored on the leading `--`: "disallowedTools" CONTAINS "allowedTools", so an
  # unanchored pattern fires on the deny list and flags correct code.
  if grep -qE -- '--allowedTools [^ ]*Bash' "$repo/.rb-lite/claude-args"; then
    fail "default claude reviewer must not be granted Bash in any form"
  fi
  assert_file_contains "$repo/.rb-lite/claude-args" 'disallowedTools Edit,Write,NotebookEdit,Bash'
  assert_file_contains "$repo/.rb-lite/claude-args" 'reviewer-diff-round-'
  if grep -q 'dangerously-skip-permissions' "$repo/.rb-lite/claude-args"; then
    fail "default claude reviewer must not use --dangerously-skip-permissions"
  fi
  if grep -q '{"type"' "$run_dir/review-round-1-2.md"; then
    fail "default claude reviewer should write extracted result text, not raw stream JSON"
  fi
  assert_file_contains "$repo/.rb-lite/claude-args" 'base ref '
  # Verify-before-asserting guard: a reviewer must not claim an out-of-diff invariant is
  # violated without reading the code (prevents the cross-file false-positive echo chamber).
  # Rides on the claude default; `codex review` cannot take a custom prompt with --base.
  assert_file_contains "$repo/.rb-lite/claude-args" 'QUESTION not a finding'
}

test_default_claude_reviewer_is_error_is_operational_failure() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/default-claude-error"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "codex unavailable\n" >&2; exit 2'
  write_fake "$repo" claude 'printf "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"result\":\"claude reviewer hit max turns\"}\n"'

  status=0
  run_rb_lite "$repo" run --task "default claude reviewer error" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err \
    || status=$?

  assert_equals 11 "$status" "all-failed reviewer panel exit"
  assert_file_contains "$run_dir/review-round-1-2.md" 'Reviewer 2 \(exit 5'
  assert_file_contains "$run_dir/review-round-1-2.md" 'claude reviewer hit max turns'
  # Three by default now: codex, the claude defect reviewer, and the skeptic. Both claude
  # reviewers hit the same is_error fake, so the whole panel fails.
  assert_file_contains "$run_dir/log.txt" 'review panel failed: 0 of 3 reviewers succeeded'
  assert_last_stdout_summary /tmp/rb-lite-test.out review_panel_failed 11
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

  assert_equals 11 "$status" "review panel failure exit"
  assert_equals 1 "$(cat "$repo/.rb-lite/implementer-count")" "reviewer failure implementer count"
  assert_file_contains /tmp/rb-lite-test.err 'review panel failed with exit 2'
  assert_last_stdout_summary /tmp/rb-lite-test.out review_panel_failed 11
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
  assert_file_contains "$run_dir/log.txt" 'reviewer 1 failed with exit 3'
  assert_file_contains "$run_dir/log.txt" 'partial failures: 1 of 2 reviewers succeeded'
}

test_implementer_retries_transient_api_error() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/transient-run"
  # First attempt fails with a provider rate-limit error; the retry succeeds with
  # no change, so the iteration stabilizes. Two invocations: 1 failed + 1 retry.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "API Error: Server is temporarily limiting requests (not your usage limit) Rate limited\n"
  exit 1
fi
printf "ok\n"
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "transient retry" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out
  ) || status=$?

  assert_equals 0 "$status" "transient error should be retried into a clean run"
  assert_equals 2 "$(cat "$repo/.rb-lite/impl-attempts")" "implementer retried once after the transient error"
  assert_file_contains "$run_dir/log.txt" 'transient API error'
  assert_file_contains "$run_dir/log.txt" 'retry 1/'
  assert_last_stdout_summary /tmp/rb-lite-test.out clean 0
}

test_non_transient_failure_does_not_retry() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/real-fail-run"
  # A genuine implementer failure (no rate-limit signature) must fail fast, not retry.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "error: the build failed: missing semicolon\n" >&2
exit 1
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "real failure" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err
  ) || status=$?

  assert_equals 10 "$status" "a non-transient failure must fail the round"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "a non-transient failure must not be retried"
  assert_file_contains "$run_dir/log.txt" 'failed with exit 1'
  assert_last_stdout_summary /tmp/rb-lite-test.out implementer_failed 10
}

test_application_json_status_failure_does_not_retry() {
  local repo run_dir status out err
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/app-json-status-run"
  out=$(mktemp "$TMP_ROOT/rb-lite-test.out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/rb-lite-test.err.XXXXXX")
  # A real implementer failure may print application/test JSON. A generic
  # {"status":500} payload is not enough evidence of a provider outage.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "%s\n" "{\"status\":500,\"message\":\"unit test failed\"}" >&2
exit 1
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 RB_LITE_API_MAX_RETRIES=2 "$repo/bin/rb-lite" run \
      --task "application json failure" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >"$out" 2>"$err"
  ) || status=$?

  assert_equals 10 "$status" "application JSON status should not be treated as a provider transient"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "application JSON status failure must not be retried"
  assert_file_contains "$run_dir/log.txt" 'failed with exit 1'
  assert_last_stdout_summary "$out" implementer_failed 10
}

test_application_api_error_522_line_does_not_retry() {
  local repo run_dir status out err
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/app-api-error-522-run"
  out=$(mktemp "$TMP_ROOT/rb-lite-test.out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/rb-lite-test.err.XXXXXX")
  # Application/test output may contain an "API error" line number. A bare 522
  # there is not enough evidence of an HTTP 522 or Cloudflare provider timeout.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "API error line 522: validation failed\n" >&2
exit 1
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 RB_LITE_API_MAX_RETRIES=2 "$repo/bin/rb-lite" run \
      --task "application api error line" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >"$out" 2>"$err"
  ) || status=$?

  assert_equals 10 "$status" "application API error line 522 should not be treated as a provider transient"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "application API error line 522 must not be retried"
  assert_file_contains "$run_dir/log.txt" 'failed with exit 1'
  assert_last_stdout_summary "$out" implementer_failed 10
}

test_application_connection_timeout_failure_does_not_retry() {
  local repo run_dir status out err
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/app-connection-timeout-run"
  out=$(mktemp "$TMP_ROOT/rb-lite-test.out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/rb-lite-test.err.XXXXXX")
  # A local app/database connection timeout is a real implementer failure, even
  # when the app logs it as {"error":"connection_timeout"}.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "database connection timeout\n" >&2
printf "%s\n" "{\"error\":\"connection_timeout\"}" >&2
exit 1
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 RB_LITE_API_MAX_RETRIES=2 "$repo/bin/rb-lite" run \
      --task "application connection timeout" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >"$out" 2>"$err"
  ) || status=$?

  assert_equals 10 "$status" "application connection timeout should not be treated as a provider transient"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "application connection timeout failure must not be retried"
  assert_file_contains "$run_dir/log.txt" 'failed with exit 1'
  assert_last_stdout_summary "$out" implementer_failed 10
}

test_transient_retries_are_bounded() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/bounded-run"
  # Always transient: the run gives up after RB_LITE_API_MAX_RETRIES retries.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "Error: 429 Too Many Requests - rate limit exceeded\n" >&2
exit 1
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 RB_LITE_API_MAX_RETRIES=2 "$repo/bin/rb-lite" run \
      --task "bounded retries" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err
  ) || status=$?

  assert_equals 10 "$status" "exhausted transient retries must fail the round"
  assert_equals 3 "$(cat "$repo/.rb-lite/impl-attempts")" "1 initial attempt plus 2 bounded retries"
  assert_file_contains "$run_dir/log.txt" 'retry 2/2'
  assert_last_stdout_summary /tmp/rb-lite-test.out implementer_failed 10
}

test_implementer_retries_bare_http_status_error() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/bare-http-run"
  # A bare numeric HTTP status with no named phrase (e.g. "HTTP 500 Internal
  # Server Error") is still a retryable transient error.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "Request failed: HTTP 500 Internal Server Error\n" >&2
  exit 1
fi
printf "ok\n"
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "bare http status" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out
  ) || status=$?

  assert_equals 0 "$status" "a bare HTTP 5xx should be retried into a clean run"
  assert_equals 2 "$(cat "$repo/.rb-lite/impl-attempts")" "bare HTTP 5xx retried once"
  assert_file_contains "$run_dir/log.txt" 'transient API error'
  assert_last_stdout_summary /tmp/rb-lite-test.out clean 0
}

test_implementer_retries_cloudflare_522_and_honors_retry_after() {
  local repo run_dir status out expected_delays
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/cloudflare-522-run"
  out=$(mktemp "$TMP_ROOT/rb-lite-test.out.XXXXXX")
  # Anthropic may surface Cloudflare 522 origin timeouts as structured JSON with
  # retryable=true and retry_after=120. rb-lite should treat the Cloudflare 522
  # payload as transient and use retry_after/retry-after as the backoff floor.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "%s\n" "{\"status\":522,\"retryable\":true,\"retry_after\":120,\"cloudflare_error\":true}" >&2
  exit 1
fi
if (( count == 2 )); then
  printf "%s\n" "{\"cloudflare_error\":true,\"error_code\":522,\"retryable\":true,\"retry-after\":121}" >&2
  exit 1
fi
printf "ok\n"
'
  write_fake "$repo" sleep '
mkdir -p .rb-lite
printf "%s\n" "$*" >>.rb-lite/slept-delays
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "cloudflare 522 retry" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >"$out"
  ) || status=$?

  assert_equals 0 "$status" "Cloudflare 522 should be retried into a clean run"
  assert_equals 3 "$(cat "$repo/.rb-lite/impl-attempts")" "Cloudflare 522 retried until the provider recovered"
  expected_delays=$'120\n121'
  assert_equals "$expected_delays" "$(cat "$repo/.rb-lite/slept-delays")" "provider retry_after should be used as the retry delay floor"
  assert_file_contains "$run_dir/log.txt" 'transient API error'
  assert_file_contains "$run_dir/log.txt" 'provider retry_after 120s'
  assert_file_contains "$run_dir/log.txt" 'provider retry_after 121s'
  assert_last_stdout_summary "$out" clean 0
}

test_unrelated_stdout_retry_after_is_ignored() {
  local repo run_dir status out expected_delays
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/unrelated-stdout-retry-after-run"
  out=$(mktemp "$TMP_ROOT/rb-lite-test.out.XXXXXX")
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
if (( count == 1 )); then
  printf "%s\n" "{\"fixture\":true,\"retry_after\":999,\"message\":\"connection refused\"}"
  printf "Error: 429 Too Many Requests - rate limit exceeded\n" >&2
  exit 1
fi
printf "ok\n"
'
  write_fake "$repo" sleep '
mkdir -p .rb-lite
printf "%s\n" "$*" >>.rb-lite/slept-delays
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=7 RB_LITE_API_MAX_RETRIES=1 "$repo/bin/rb-lite" run \
      --task "unrelated stdout retry after" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >"$out"
  ) || status=$?

  expected_delays='7'
  assert_equals 0 "$status" "transient stderr failure should retry into a clean run"
  assert_equals 2 "$(cat "$repo/.rb-lite/impl-attempts")" "transient stderr failure retried once"
  assert_equals "$expected_delays" "$(cat "$repo/.rb-lite/slept-delays")" "stdout fixture retry_after must not override provider backoff"
  assert_file_contains "$run_dir/log.txt" 'retry 1/1 in 7s'
  assert_file_not_contains "$run_dir/log.txt" 'provider retry_after 999s'
  assert_last_stdout_summary "$out" clean 0
}

test_sigkilled_implementer_is_not_retried() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/sigkill-run"
  # A SIGKILL (exit 137, e.g. timeout --kill-after) is a hang/kill, not a
  # transient API error — it must not be retried even if its output happened to
  # contain a transient marker.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "connection timed out\n" >&2
exit 137
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "sigkill" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err
  ) || status=$?

  assert_equals 10 "$status" "a SIGKILLed implementer must fail the round"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "a SIGKILLed (137) implementer must not be retried"
  assert_last_stdout_summary /tmp/rb-lite-test.out implementer_failed 10
}

test_exit_124_is_not_retried_without_timeout() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/exit124-run"
  # Exit 124 is the timeout convention regardless of whether rb-lite set a
  # timeout — it must not be retried even with no --implement-timeout and a
  # transient marker in the output.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
count_file=.rb-lite/impl-attempts
count=0
[[ -f $count_file ]] && count=$(cat "$count_file")
count=$((count + 1))
printf "%s\n" "$count" >"$count_file"
printf "connection timed out\n" >&2
exit 124
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_API_RETRY_DELAYS=0 "$repo/bin/rb-lite" run \
      --task "exit124" --max-rounds 1 --max-iters 3 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err
  ) || status=$?

  assert_equals 10 "$status" "an exit-124 implementer must fail the round"
  assert_equals 1 "$(cat "$repo/.rb-lite/impl-attempts")" "exit 124 must not be retried even without --implement-timeout"
  assert_last_stdout_summary /tmp/rb-lite-test.out implementer_failed 10
}

test_scrubs_inherited_claude_code_session_env() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/scrub-run"
  # When the orchestrator is itself a Claude Code session it exports
  # CLAUDE_CODE_SESSION_ID / CLAUDECODE; the spawned implementer must NOT inherit
  # them (it would collide with the parent session and crash rb-lite). Dump the
  # implementer's environment and assert those markers were scrubbed.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
env > .rb-lite/impl-env
printf "done\n"
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" \
      CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=parent-collision \
      CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXECPATH=/x/claude \
      CLAUDE_CODE_RETRY_WATCHDOG=1 \
      "$repo/bin/rb-lite" run --task scrub --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/dev/null
  ) || status=$?

  assert_equals 0 "$status" "a no-op implementer run is clean"
  assert_file_not_contains "$repo/.rb-lite/impl-env" '^CLAUDE_CODE_SESSION_ID=' "the parent session id is scrubbed from the implementer env"
  assert_file_not_contains "$repo/.rb-lite/impl-env" '^CLAUDECODE=' "the CLAUDECODE marker is scrubbed from the implementer env"
  assert_file_contains "$repo/.rb-lite/impl-env" '^CLAUDE_CODE_RETRY_WATCHDOG=1$' "the retry watchdog (a behavior flag, not an identity marker) is preserved"
}

test_env_scrub_can_be_disabled() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/noscrub-run"
  # RB_LITE_SCRUB_ENV= (empty) opts out of scrubbing entirely.
  write_fake "$repo" fake-implementer '
mkdir -p .rb-lite
env > .rb-lite/impl-env
printf "done\n"
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  (
    cd "$repo"
    PATH="$repo/fakes:$PATH" RB_LITE_SCRUB_ENV='' CLAUDE_CODE_SESSION_ID=keepme \
      "$repo/bin/rb-lite" run --task noscrub --max-rounds 1 --max-iters 1 \
      --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/dev/null
  ) || status=$?

  assert_equals 0 "$status" "a no-op implementer run is clean"
  assert_file_contains "$repo/.rb-lite/impl-env" '^CLAUDE_CODE_SESSION_ID=keepme$' "RB_LITE_SCRUB_ENV= leaves the inherited env untouched"
}

assert_summary_field() {
  local file=$1
  local field=$2
  local expected=$3
  local last

  [[ -f $file ]] || fail "missing file: $file"
  last=$(tail -n 1 "$file")
  printf '%s\n' "$last" | grep -Fq "\"$field\": $expected" \
    || fail "summary field $field should be $expected: $last"
}

test_dispositions_are_counted_and_reported() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/dispositions"
  # Every disposition form the prompt allows (bare, bulleted, numbered, emphasised) plus
  # two prose decoys that mention a disposition mid-sentence. Only a line whose first WORD
  # is a disposition may count, or the totals inflate with every finding that discusses
  # a rejection.
  write_fake "$repo" fake-implementer '
mkdir -p "$RUN_DIR"
cat >"$RUN_DIR/challenges-round-$ROUND.md" <<"EOF"
# Round decisions

ACCEPTED reviewer asked for input validation on the id argument
- DECLINED reviewer wants a retry loop; no data-loss case, only an inconvenience
1. DEFERRED reviewer wants a second store backend; no consumer needs one yet
**DECLINED** reviewer wants a lock; the caller already serializes at the boundary

The reviewer DECLINED to justify finding 3, so we asked for evidence.
Nothing here was DEFERRED to a follow-up bead.
EOF
printf "work\n" >work.txt
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "count dispositions" --max-rounds 1 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/log.txt" 'round 1 dispositions: 1 accepted, 2 declined, 1 deferred'
  assert_summary_field /tmp/rb-lite-test.out findings_accepted 1
  assert_summary_field /tmp/rb-lite-test.out findings_declined 2
  assert_summary_field /tmp/rb-lite-test.out findings_deferred 1
  assert_summary_field /tmp/rb-lite-test.out rejections_total 3
  assert_summary_field /tmp/rb-lite-test.out rejections_by_round '[3]'
}

test_missing_challenges_file_counts_zero() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/no-challenges"
  write_fake "$repo" fake-implementer 'printf "work\n" >work.txt'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "no challenges file" --max-rounds 1 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  # A round that received no findings has nothing to decide; that is not an error.
  assert_file_contains "$run_dir/log.txt" 'round 1 dispositions: 0 accepted, 0 declined, 0 deferred'
  assert_summary_field /tmp/rb-lite-test.out rejections_total 0
}

test_zero_rejections_warns_once_after_threshold() {
  local repo run_dir status warn_count
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/unchallenged"
  # Changes state every round so the no-op consensus stop cannot fire first, and never
  # records a rejection: the implementer accepts everything the panel says.
  write_fake "$repo" fake-implementer 'printf "round\n" >"round-$ROUND.txt"'
  write_fake "$repo" fake-reviewer 'printf "P1 there is always one more edge case\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "unchallenged panel" --max-rounds 5 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out || status=$?

  assert_equals 12 "$status" "unchallenged run still ends on max rounds"
  warn_count=$(grep -c 'WARNING: 3 rounds with zero declined or deferred findings' "$run_dir/log.txt" || true)
  assert_equals 1 "$warn_count" "zero-rejection warning fires exactly once"
  # Round 1 runs with no review input, so it cannot decline anything and must not count.
  assert_file_not_contains "$run_dir/log.txt" 'WARNING: 4 rounds with zero declined'
}

test_declining_a_finding_resets_the_warning_streak() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/challenged"
  # Decline in round 3 ONLY. Rounds 2 and 3 build a streak of 1 then reset it; rounds 4
  # and 5 rebuild to 2. The threshold is 3, so a correct reset means no warning — whereas
  # declining every round would pass even if the streak never incremented at all.
  write_fake "$repo" fake-implementer '
mkdir -p "$RUN_DIR"
printf "round\n" >"round-$ROUND.txt"
if [[ ${ROUND:-0} == 3 ]]; then
  printf "DECLINED over-specification: nothing breaks without it\n" >"$RUN_DIR/challenges-round-$ROUND.md"
fi
'
  write_fake "$repo" fake-reviewer 'printf "P1 there is always one more edge case\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "challenged panel" --max-rounds 5 --max-iters 2 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out || status=$?

  assert_equals 12 "$status" "challenged run still ends on max rounds"
  assert_file_not_contains "$run_dir/log.txt" 'WARNING: [0-9]* rounds with zero declined'
}

test_production_budget_stops_the_run() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget"
  # Staged so it appears in `git diff --base`, which is what the reviewers see too.
  write_fake "$repo" fake-implementer '
if [[ ! -f big.txt ]]; then
  for i in $(seq 1 500); do printf "line %s\n" "$i" >>big.txt; done
  git add big.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "over budget" --max-rounds 2 --max-iters 2 --base HEAD \
    --max-production-lines 100 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 14 "$status" "production budget exit"
  assert_last_stdout_summary /tmp/rb-lite-test.out budget_exceeded 14
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 500
  assert_file_contains /tmp/rb-lite-test.out 'production budget exceeded: 500 added lines against a budget of 100'
  # Naming the biggest contributor is the difference between a usable stop and a number.
  assert_file_contains /tmp/rb-lite-test.out 'big\.txt'
  assert_file_contains "$run_dir/log.txt" 'production line budget: 100'
  # A budget must stop the run, not merely annotate it: the panel never ran.
  if [[ -e "$run_dir/review-round-1-1.md" ]]; then
    fail "budget stop must precede the review panel"
  fi
}

test_production_budget_excludes_tests_by_default() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-tests"
  # A budget that counts tests is met by deleting coverage. 500 test lines plus 10
  # production lines must pass a budget of 100.
  write_fake "$repo" fake-implementer '
if [[ ! -f tests/huge.test ]]; then
  mkdir -p tests
  for i in $(seq 1 500); do printf "assert %s\n" "$i" >>tests/huge.test; done
  for i in $(seq 1 10); do printf "code %s\n" "$i" >>small.txt; done
  git add tests/huge.test small.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "test lines are free" --max-rounds 1 --max-iters 2 --base HEAD \
    --max-production-lines 100 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out || status=$?

  assert_equals 0 "$status" "test lines excluded from the budget"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 10
}

test_budget_exclude_overrides_defaults() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-override"
  write_fake "$repo" fake-implementer '
if [[ ! -f tests/huge.test ]]; then
  mkdir -p tests
  for i in $(seq 1 500); do printf "assert %s\n" "$i" >>tests/huge.test; done
  git add tests/huge.test
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "explicit excludes replace defaults" --max-rounds 1 \
    --max-iters 2 --base HEAD --max-production-lines 100 --budget-exclude 'vendor/*' \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  # The built-in test excludes are replaced, not merged, so the .test file now counts.
  assert_equals 14 "$status" "overridden excludes drop the built-in test globs"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 500
}

test_no_budget_flag_means_no_limit() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/no-budget"
  write_fake "$repo" fake-implementer '
if [[ ! -f big.txt ]]; then
  for i in $(seq 1 500); do printf "line %s\n" "$i" >>big.txt; done
  git add big.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "no budget" --max-rounds 1 --max-iters 2 --base HEAD \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out || status=$?

  assert_equals 0 "$status" "absent budget imposes no limit"
  assert_file_not_contains "$run_dir/log.txt" 'production line budget'
}

test_invalid_production_budget_is_usage_error() {
  local repo status
  repo=$(new_repo)
  status=0
  run_rb_lite "$repo" run --task t --max-production-lines 0 \
    --implement-cmd 'true' >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?
  assert_equals 2 "$status" "zero production budget is a usage error"
  assert_file_contains /tmp/rb-lite-test.err 'must be a positive integer'
}

test_no_skeptic_returns_the_two_reviewer_panel() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/no-skeptic"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "codex says clean\n"'
  write_fake "$repo" claude '
mkdir -p .rb-lite
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "%s\n" "$*" >.rb-lite/skeptic-ran
fi
printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"claude says clean\"}\n"
'

  run_rb_lite "$repo" run --task "no skeptic" --max-rounds 1 --max-iters 1 --no-skeptic \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/log.txt" 'review panel starting with 2 reviewer\(s\)'
  if [[ -e "$repo/.rb-lite/skeptic-ran" ]]; then
    fail "--no-skeptic must not run the skeptical reviewer"
  fi
}

test_skeptic_findings_alone_do_not_extend_the_run() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/skeptic-advisory"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "No findings.\n"'
  # Only the skeptic reports, at the P2 its prompt hardcodes. At the default P2 floor this
  # used to keep the loop running to max-rounds, so every run ended in an escalation.
  write_fake "$repo" claude '
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"P2: CUT the retry wrapper\"}\n"
else
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
fi
'

  run_rb_lite "$repo" run --task "advisory skeptic" --max-rounds 4 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out
  local rc=$?

  (( rc == 0 )) || fail "skeptic-only findings must still converge (exit $rc)"
  assert_file_contains "$run_dir/log.txt" 'review panel clean'
  # Converging must not mean discarding: the opinion is named, with its file.
  assert_file_contains "$run_dir/log.txt" 'only the skeptical reviewer has findings'
  assert_file_contains "$run_dir/log.txt" 'at the P2 floor'
  assert_file_contains "$run_dir/log.txt" 'advisory and do not extend the run'
  if grep -q 'round 2 implementer' "$run_dir/log.txt"; then
    fail "skeptic-only findings must not start another round"
  fi
}

test_skeptic_is_still_announced_at_a_raised_floor() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/skeptic-raised-floor"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "No findings.\n"'
  write_fake "$repo" claude '
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"P2: CUT the retry wrapper\"}\n"
else
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
fi
'

  run_rb_lite "$repo" run --task "raised floor skeptic" --max-rounds 1 --max-iters 1 \
    --min-findings-severity P1 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out

  # The skeptic is detected against a fixed P2 pattern, not through the floor. Routing it
  # through the floor would hide it at P0/P1 and drop the advisory line exactly where a
  # raised floor makes the opinion most likely to go unread.
  assert_file_contains "$run_dir/log.txt" 'only the skeptical reviewer has findings'
  assert_file_contains "$run_dir/log.txt" 'at the P1 floor'
}

test_defect_findings_still_extend_the_run_with_a_skeptic_present() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/skeptic-not-masking"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  # The defect reviewer reports; making the skeptic advisory must not swallow this.
  write_fake "$repo" codex 'printf "P1: the parser drops the last row\n"'
  write_fake "$repo" claude '
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"P2: CUT the retry wrapper\"}\n"
else
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
fi
'

  run_rb_lite "$repo" run --task "real defect" --max-rounds 2 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out || true

  assert_file_contains "$run_dir/log.txt" 'reported actionable findings'
  if grep -q 'only the skeptical reviewer has findings' "$run_dir/log.txt"; then
    fail "a real defect finding must not be reported as skeptic-only"
  fi
}

test_reviewers_file_panel_is_not_given_a_skeptic() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/custom-no-skeptic"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "custom panel" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  # A caller-supplied panel is the caller's; injecting into it would silently change a
  # configured review contract.
  assert_file_contains "$run_dir/log.txt" 'review panel starting with 1 reviewer\(s\)'
}

test_budget_refuses_an_undiffable_base() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-bad-base"
  write_fake "$repo" fake-implementer 'printf "work\n" >work.txt'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "bad base" --max-rounds 1 --max-iters 2 \
    --base origin/does-not-exist --max-production-lines 10 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  # Silently measuring zero would leave the budget armed-looking and inert, which is the
  # failure the budget exists to prevent. Refuse instead.
  assert_equals 3 "$status" "an undiffable base with a budget is an environment error"
  assert_file_contains /tmp/rb-lite-test.err 'needs a diffable [-][-]base'
}

test_budget_charges_a_rename_to_its_destination_path() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-rename"
  # git --numstat abbreviates this as `tests/{old.test => new.test}`. Parsing that as
  # `new.test}` makes the tests/* exclusion miss it, and the run fails on a moved test.
  write_fake "$repo" fake-implementer '
if [[ ! -f tests/new.test ]]; then
  mkdir -p tests
  for i in $(seq 1 400); do printf "assert %s\n" "$i" >>tests/old.test; done
  git add tests/old.test
  git -c user.email=t@e -c user.name=T commit -qm addtest
  git mv tests/old.test tests/new.test
  for i in $(seq 1 200); do printf "assert extra %s\n" "$i" >>tests/new.test; done
  # NOT `git add -A`: new_repo leaves bin/rb-lite and fakes/ untracked in the worktree,
  # and staging those would charge ~1300 unrelated lines to the budget under test.
  git add tests/new.test
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "renamed test file" --max-rounds 1 --max-iters 2 --base HEAD \
    --max-production-lines 100 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "a renamed test file stays excluded from the budget"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 0
}

test_skeptic_alone_is_not_a_reviewed_panel() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/skeptic-only"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  # Both defect reviewers die; only the skeptic answers, and it says the change is minimal.
  write_fake "$repo" codex 'printf "codex unavailable\n" >&2; exit 2'
  write_fake "$repo" claude '
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
  exit 0
fi
printf "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"result\":\"defect reviewer hit max turns\"}\n"
'

  status=0
  run_rb_lite "$repo" run --task "skeptic only" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  # The skeptic is forbidden from reporting defects, so its lone success means nothing
  # looked for bugs. Reporting `clean` here would be an unreviewed exit 0.
  assert_equals 11 "$status" "a skeptic-only success is a failed panel"
  assert_file_contains "$run_dir/log.txt" 'only the skeptical reviewer succeeded'
  assert_last_stdout_summary /tmp/rb-lite-test.out review_panel_failed 11
}

test_defect_reviewer_alone_still_clears_the_panel() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/defect-only"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "codex unavailable\n" >&2; exit 2'
  # Mirror image: the skeptic dies, one defect reviewer survives. That IS a reviewed
  # change, and must still be able to go clean — the guard above must not over-reach.
  write_fake "$repo" claude '
if printf "%s" "$*" | grep -q "OVER-SPECIFICATION"; then
  printf "skeptic unavailable\n" >&2
  exit 2
fi
printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"
'

  status=0
  run_rb_lite "$repo" run --task "defect only" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "one surviving defect reviewer still clears"
  assert_file_contains "$run_dir/log.txt" '1 of 3 reviewers succeeded'
}

test_supplied_panel_keeps_the_at_least_one_rule() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/supplied-panel"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake "$repo" dead-reviewer 'printf "gone\n" >&2; exit 2'
  write_fake "$repo" live-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" dead-reviewer live-reviewer

  status=0
  run_rb_lite "$repo" run --task "supplied panel" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  # A supplied panel's members are opaque — rb-lite cannot know which is a skeptic — so
  # the original at-least-one rule must be untouched there.
  assert_equals 0 "$status" "a supplied panel is unaffected by the skeptic rule"
}

test_p1_floor_warns_that_it_silences_defect_p2s() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/floor-skeptic"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "codex says clean\n"'
  write_fake "$repo" claude 'printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"'

  status=0
  run_rb_lite "$repo" run --task "raised floor" --max-rounds 1 --max-iters 1 \
    --min-findings-severity P1 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  # A raised floor now silences only the defect reviewers' P2s; the skeptic is advisory
  # at every floor. The warning must say that, so nobody raises the floor believing they
  # are trading away counter-pressure they never had at P2 either.
  assert_equals 0 "$status" "a raised floor still runs"
  assert_file_contains "$run_dir/log.txt" 'ignores P2 findings from the defect reviewers'
  assert_file_contains "$run_dir/log.txt" 'advisory at every floor'
}

test_default_floor_does_not_warn_about_the_skeptic() {
  local repo run_dir
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/floor-default"
  write_fake "$repo" fake-implementer 'printf "noop\n"'
  write_fake_jq_result_extractor "$repo"
  write_fake "$repo" codex 'printf "codex says clean\n"'
  write_fake "$repo" claude 'printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"No findings.\"}\n"'

  run_rb_lite "$repo" run --task "default floor" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_not_contains "$run_dir/log.txt" 'filters out the skeptical reviewer'
}

test_budget_excludes_a_non_ascii_test_path() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-quotepath"
  # git's default core.quotePath=true C-quotes any path with a non-ASCII byte:
  #   200\t0\t"tests/t\303\253st.test"
  # The leading quote makes every exclusion glob miss, so the excluded test file is
  # charged to the budget and stops a legitimate run — and a budget stop is by design
  # not retryable, so the false trip is expensive.
  # $'...' so the name is real UTF-8; a plain "\xc3" would be literal backslashes, which
  # is a different (and far rarer) quoting case than the one being tested.
  write_fake "$repo" fake-implementer '
name="tests/$(printf "t\xc3\xabst.test")"
if [[ ! -f $name ]]; then
  mkdir -p tests
  for i in $(seq 1 200); do printf "assert %s\n" "$i" >>"$name"; done
  git add -- "$name"
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "non-ascii test path" --max-rounds 1 --max-iters 2 --base HEAD \
    --max-production-lines 100 --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "a non-ascii test path stays excluded from the budget"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 0
}

test_undiffable_base_error_names_the_git_cause() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-why"
  write_fake "$repo" fake-implementer 'printf "work\n" >work.txt'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "bad base cause" --max-rounds 1 --max-iters 2 \
    --base origin/does-not-exist --max-production-lines 10 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 3 "$status" "an undiffable base is still an environment error"
  # "git diff failed" without the reason leaves the operator guessing between an
  # ambiguous ref, an unfetched remote, and a corrupt object.
  assert_file_contains /tmp/rb-lite-test.err 'unknown revision|ambiguous argument|bad revision|not a valid object'
}

test_budget_exclude_matches_a_collapsed_rename_path() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-collapse"
  # git elides an emptied directory component as `vendor/{sub => }/lib.txt`. Naive
  # concatenation yields `vendor//lib.txt`, which a wildcard-free exclusion misses --
  # and the over-budget report then prints a path that is not in the repo.
  write_fake "$repo" fake-implementer '
if [[ ! -f vendor/lib.txt ]]; then
  mkdir -p vendor/sub
  for i in $(seq 1 300); do printf "vendored %s\n" "$i" >>vendor/sub/lib.txt; done
  git add vendor/sub/lib.txt
  git -c user.email=t@e -c user.name=T commit -qm addvendor
  git mv vendor/sub/lib.txt vendor/lib.txt
  for i in $(seq 1 300); do printf "more %s\n" "$i" >>vendor/lib.txt; done
  git add -- vendor/lib.txt
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "collapsed rename" --max-rounds 1 --max-iters 2 --base HEAD \
    --max-production-lines 100 --budget-exclude 'vendor/lib.txt' \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" \
    >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "an exact exclusion matches a collapsed rename destination"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 0
}

test_budget_excludes_c_quoted_special_paths() {
  local repo run_dir status
  repo=$(new_repo)
  run_dir="$repo/.rb-lite/budget-quoted"
  # git C-quotes any path it cannot emit literally -- TAB and newline here -- even with
  # core.quotePath off. The leading quote defeats every exclusion glob, so an excluded
  # test file gets charged and hard-stops a run that should pass.
  write_fake "$repo" fake-implementer '
tab=$(printf "tests/a\tb.test")
nl=$(printf "tests/line\nbreak.test")
if [[ ! -f $tab ]]; then
  mkdir -p tests
  for i in $(seq 1 200); do printf "assert %s\n" "$i" >>"$tab"; done
  for i in $(seq 1 200); do printf "assert %s\n" "$i" >>"$nl"; done
  git add -- "$tab" "$nl"
fi
'
  write_fake "$repo" fake-reviewer 'printf "No findings\n"'
  write_reviewers "$repo" fake-reviewer

  status=0
  run_rb_lite "$repo" run --task "tab and newline test paths" --max-rounds 1 --max-iters 2 \
    --base HEAD --max-production-lines 100 --implement-cmd 'fake-implementer' \
    --run-dir "$run_dir" >/tmp/rb-lite-test.out 2>/tmp/rb-lite-test.err || status=$?

  assert_equals 0 "$status" "C-quoted test paths stay excluded from the budget"
  assert_summary_field /tmp/rb-lite-test.out production_lines_added 0
}

mkdir -p "$TMP_ROOT"
require_timeout_with_kill_after

test_implementer_stops_when_stable
test_implementer_stdin_is_closed
test_progress_log_mirrors_to_stderr
test_implementer_retries_transient_api_error
test_non_transient_failure_does_not_retry
test_application_json_status_failure_does_not_retry
test_application_api_error_522_line_does_not_retry
test_application_connection_timeout_failure_does_not_retry
test_transient_retries_are_bounded
test_implementer_retries_bare_http_status_error
test_implementer_retries_cloudflare_522_and_honors_retry_after
test_unrelated_stdout_retry_after_is_ignored
test_sigkilled_implementer_is_not_retried
test_exit_124_is_not_retried_without_timeout
test_scrubs_inherited_claude_code_session_env
test_env_scrub_can_be_disabled
test_p1_review_triggers_remediation_round
test_persistent_noop_implementer_consensus_failure_after_default_threshold
test_max_rounds_hit_exits_12
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
test_help_output_does_not_emit_run_summary
test_run_dir_setup_failure_exits_3
test_run_log_setup_failure_exits_3
test_branch_creation_failure_exits_3
test_clean_review_exits_successfully
test_codex_implementer_preset_uses_noninteractive_codex_exec
test_claude_implementer_preset_uses_headless_accept_edits
test_missing_implementer_is_usage_error_with_summary
test_empty_cli_implement_cmd_is_usage_error_with_summary
test_invalid_implementer_is_usage_error
test_invalid_env_implementer_is_usage_error
test_env_implementer_codex_selects_codex_preset
test_implementer_preset_cycle_advances_after_review_findings
test_env_implementer_cycle_selects_first_preset
test_invalid_implementer_lists_are_usage_errors
test_cli_implement_cmd_takes_precedence_over_implementer
test_env_implement_cmd_takes_precedence_over_env_implementer
test_implementer_session_resume_resets_at_round_boundary
test_implementer_session_resume_picks_first_match
test_env_implement_cmd_override_still_wins
test_implement_timeout_fails_stuck_iteration
test_env_implement_timeout_fails_stuck_iteration
test_reviewer_timeout_fails_stuck_reviewer
test_env_reviewer_timeout_fails_stuck_reviewer
test_signal_summary_preserves_signal_exit_code
test_cli_implement_timeout_overrides_invalid_env
test_cli_reviewer_timeout_overrides_invalid_env
test_implement_timeout_requires_kill_after_support
test_implement_timeout_accepts_uutils_timeout
test_untracked_files_affect_stability
test_quoted_untracked_paths_affect_stability
test_dirty_symlink_retarget_affects_stability
test_rb_lite_artifacts_do_not_affect_stability
test_custom_run_dir_does_not_affect_stability
test_reviewer_config_writes_per_reviewer_files
test_version_matches_flake_version
test_version_command_reports_a_version
test_default_reviewer_panel_runs_codex_and_claude
test_default_claude_reviewer_is_error_is_operational_failure
test_reviewer_exit_two_is_operational_failure
test_reviewer_stderr_excluded_from_combined_when_clean
test_failed_reviewer_path_omitted_from_review_files
test_failed_reviewer_stdout_p_token_does_not_trigger_round
test_failed_reviewer_stderr_p_token_does_not_trigger_round
test_partial_reviewer_failure_does_not_abort
test_dispositions_are_counted_and_reported
test_missing_challenges_file_counts_zero
test_zero_rejections_warns_once_after_threshold
test_declining_a_finding_resets_the_warning_streak
test_production_budget_stops_the_run
test_production_budget_excludes_tests_by_default
test_budget_exclude_overrides_defaults
test_no_budget_flag_means_no_limit
test_invalid_production_budget_is_usage_error
test_no_skeptic_returns_the_two_reviewer_panel
test_skeptic_findings_alone_do_not_extend_the_run
test_skeptic_is_still_announced_at_a_raised_floor
test_defect_findings_still_extend_the_run_with_a_skeptic_present
test_reviewers_file_panel_is_not_given_a_skeptic
test_budget_refuses_an_undiffable_base
test_budget_charges_a_rename_to_its_destination_path
test_skeptic_alone_is_not_a_reviewed_panel
test_defect_reviewer_alone_still_clears_the_panel
test_supplied_panel_keeps_the_at_least_one_rule
test_p1_floor_warns_that_it_silences_defect_p2s
test_default_floor_does_not_warn_about_the_skeptic
test_budget_excludes_a_non_ascii_test_path
test_undiffable_base_error_names_the_git_cause
test_budget_exclude_matches_a_collapsed_rename_path
test_budget_excludes_c_quoted_special_paths

printf 'ok - smoke tests passed\n'
