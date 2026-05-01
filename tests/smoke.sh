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
    printf '#!/usr/bin/env bash\n'
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
if [[ $PROMPT == *"Review file:"* ]]; then
  printf "saw review\n" >remediated.txt
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
  printf "P1: fix the issue\n"
else
  printf "No findings\n"
fi
'
  write_reviewers "$repo" fake-reviewer

  run_rb_lite "$repo" run --task "remediate review" --max-rounds 2 --max-iters 2 \
    --implement-cmd 'fake-implementer' >/tmp/rb-lite-test.out

  assert_equals 3 "$(cat "$repo/.rb-lite/implementer-count")" "remediation implementer count"
  assert_file_contains "$repo/remediated.txt" 'saw review'
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

test_reviewer_config_aggregates_multiple_outputs() {
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

  run_rb_lite "$repo" run --task "aggregate" --max-rounds 1 --max-iters 1 \
    --implement-cmd 'fake-implementer' --run-dir "$run_dir" >/tmp/rb-lite-test.out

  assert_file_contains "$run_dir/latest-review.md" 'reviewer one clean'
  assert_file_contains "$run_dir/latest-review.md" 'reviewer two clean'
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

mkdir -p "$TMP_ROOT"

test_implementer_stops_when_stable
test_p1_review_triggers_remediation_round
test_clean_review_exits_successfully
test_untracked_files_affect_stability
test_quoted_untracked_paths_affect_stability
test_dirty_symlink_retarget_affects_stability
test_rb_lite_artifacts_do_not_affect_stability
test_custom_run_dir_does_not_affect_stability
test_reviewer_config_aggregates_multiple_outputs
test_reviewer_exit_two_is_operational_failure

printf 'ok - smoke tests passed\n'
