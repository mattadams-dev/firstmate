#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-freshness.sh, the fork freshness sweep.
#
# The sweep is guard-class: it exists because a standing rule enforced by human
# memory failed in both directions, so the instrument itself is held to the same
# both-directions standard here.
#
#   - The mutant that reports in-sync while a fork is behind breaks exactly
#     test_behind_creates_a_sync_task.
#   - The mutant that reports behind while a fork is level breaks exactly
#     test_in_sync_creates_no_task and test_ahead_only_creates_no_task.
#     "Always warn" is not a way to pass the first pair: a sweep that cries wolf
#     every run gets ignored, which is the same failure one mirror over.
#   - The mutant that collapses a failed reading into either direction breaks the
#     unknown suite, whose centre is test_outage_and_in_sync_are_distinguishable:
#     name the two world-states the reading claims to separate, and if a network
#     failure and a healthy in-sync fork print the same thing, the instrument is
#     fabricating.
#
# Every refusal shape has a fixture proving it fires: no gh at all, an
# enumeration that fails, a compare that fails, an unreadable upstream, and a
# payload that does not parse. Coverage has its own suite, because a fork the
# sweep silently skips is the failure the sweep was built to end: private repos,
# forks with no local clone, ignored forks and archived forks are all accounted
# for by name or by count, never dropped.
#
# The forge is faked, but the fake applies the script's real --jq filters with
# real jq to real JSON payloads, so a filter that stops matching GitHub's
# response shape fails here rather than in production.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SWEEP="$ROOT/bin/fm-fork-freshness.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-freshness)

# --- toolbox ----------------------------------------------------------------
#
# A PATH built from symlinks to the real tools, so a test can remove exactly one
# tool (gh) without also removing git, jq and coreutils - which on this machine
# can share one directory with it.

TOOLBOX="$TMP_ROOT/toolbox"
mkdir -p "$TOOLBOX"
for tool in bash sh git jq date tr cut sed awk cat mkdir rm rmdir sort grep head tail \
  mktemp uname stat ps kill sleep ln cp mv chmod chgrp basename dirname touch \
  timeout find wc readlink id env expr od shasum sha256sum flock getconf; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$real" "$TOOLBOX/$tool"
done

# --- fake forge -------------------------------------------------------------
#
# gh api <path> --jq <filter>            -> jq <filter> over fixtures/api_<key>.json
# gh repo list <owner> ... --jq <filter> -> jq <filter> over fixtures/repolist.json
# A <key>.fail file makes that exact call fail with its contents on stderr, the
# way an expired credential, a rate limit or an unreachable forge does.

install_fake_gh() {  # <bin-dir>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
sub=${1:-}
shift || true
filter=''
first=''
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) shift; filter=${1:-} ;;
    --limit|--json) shift ;;
    -*) : ;;
    *) [ -n "$first" ] || first=$1 ;;
  esac
  shift || true
done
case "$sub" in
  repo) key=repolist ;;
  api) key="api_$(printf '%s' "$first" | LC_ALL=C sed 's/[^A-Za-z0-9]\{1,\}/_/g')" ;;
  *) echo "fake gh: unsupported subcommand: $sub" >&2; exit 1 ;;
esac
if [ -f "$FM_TEST_GH_FIXTURES/$key.fail" ]; then
  cat "$FM_TEST_GH_FIXTURES/$key.fail" >&2
  exit 1
fi
if [ ! -f "$FM_TEST_GH_FIXTURES/$key.json" ]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
[ -n "$filter" ] || { cat "$FM_TEST_GH_FIXTURES/$key.json"; exit 0; }
jq -r "$filter" < "$FM_TEST_GH_FIXTURES/$key.json"
SH
  chmod +x "$1/gh"
}

install_fake_tasks_axi() {  # <bin-dir>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TASKS_LOG"
exit "${FM_TEST_TASKS_RC:-0}"
SH
  chmod +x "$1/tasks-axi"
}

# --- fixtures ---------------------------------------------------------------

# new_case [--no-gh]: an isolated home plus a fake forge, echoing the case dir.
# mktemp, not a counter: new_case is called through a command substitution, so a
# counter would increment in a subshell and every case would silently reuse one
# directory - and a test would then inherit the previous test's sync task.
new_case() {
  local dir bin
  dir=$(mktemp -d "$TMP_ROOT/case-XXXXXX")
  bin="$dir/bin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/home/projects" "$dir/fixtures" "$bin"
  [ "${1:-}" = "--no-gh" ] || install_fake_gh "$bin"
  install_fake_tasks_axi "$bin"
  : > "$dir/gh.log"
  : > "$dir/tasks.log"
  printf '%s\n' "$dir"
}

# repolist <case> <json-array>: the authenticated repository list payload.
repolist() {
  printf '%s\n' "$2" > "$1/fixtures/repolist.json"
}

# repo_fixture <case> <owner/repo> <fork:true|false> <parent|-> <default-branch> [archived]
repo_fixture() {
  local dir=$1 slug=$2 fork=$3 parent=$4 branch=$5 archived=${6:-false} key parent_json
  key="api_$(printf 'repos/%s' "$slug" | LC_ALL=C sed 's/[^A-Za-z0-9]\{1,\}/_/g')"
  if [ "$parent" = - ]; then
    parent_json=null
  else
    parent_json="{\"full_name\":\"$parent\"}"
  fi
  cat > "$dir/fixtures/$key.json" <<JSON
{"full_name":"$slug","fork":$fork,"parent":$parent_json,"default_branch":"$branch","archived":$archived}
JSON
}

# compare_fixture <case> <upstream> <up-branch> <fork-owner> <fork-branch> <status> <ahead> <behind>
compare_fixture() {
  local dir=$1 up=$2 up_branch=$3 fork_owner=$4 fork_branch=$5 status=$6 ahead=$7 behind=$8 key
  key="api_$(printf 'repos/%s/compare/%s:%s...%s:%s' \
    "$up" "${up%%/*}" "$up_branch" "$fork_owner" "$fork_branch" |
    LC_ALL=C sed 's/[^A-Za-z0-9]\{1,\}/_/g')"
  cat > "$dir/fixtures/$key.json" <<JSON
{"status":"$status","ahead_by":$ahead,"behind_by":$behind}
JSON
  printf '%s\n' "$dir/fixtures/$key"
}

# one_fork <case> <status> <ahead> <behind>: the whole happy-path fixture set for
# a single owned fork, acme/widget forked from upstream/widget.
one_fork() {
  local dir=$1 status=$2 ahead=$3 behind=$4
  repolist "$dir" '[{"nameWithOwner":"acme/widget","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"widget"},"defaultBranchRef":{"name":"main"}}]'
  repo_fixture "$dir" upstream/widget false - main
  compare_fixture "$dir" upstream/widget main acme main "$status" "$ahead" "$behind" >/dev/null
}

run_sweep() {  # <case> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_FIXTURES="$dir/fixtures" \
    FM_TEST_TASKS_LOG="$dir/tasks.log" \
    PATH="$dir/bin:$TOOLBOX" \
    "$SWEEP" "$@" 2>"$dir/stderr.log"
}

# --- the reading, both directions -------------------------------------------

test_behind_creates_a_sync_task() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "a fork behind its upstream must not exit clean"
  assert_contains "$out" "acme/widget status=behind behind=3 ahead=0" \
    "the reading did not report the fork as behind"
  assert_contains "$out" "action=task fm-sync-widget queued" \
    "behind > 0 only reported; it must create the sync task"
  assert_present "$dir/home/data/fm-sync-widget/brief.md" \
    "the sync task carries no instructions"
  assert_contains "$out" "behind=1 " "the coverage line lost the behind count"
  pass "fm-fork-freshness: behind > 0 creates the sync task and refuses to exit clean"
}

test_in_sync_creates_no_task() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "a fork level with its upstream must exit clean"
  assert_contains "$out" "acme/widget status=in-sync behind=0 ahead=0" \
    "a level fork did not read as in-sync"
  assert_contains "$out" "action=none" "a level fork must produce no action"
  assert_absent "$dir/home/data/fm-sync-widget" \
    "a level fork must not create a sync task - crying wolf every run is the same failure"
  assert_absent "$dir/home/state/.wake-queue" "a level fork must not wake anyone"
  pass "fm-fork-freshness: a level fork creates nothing and stays quiet"
}

test_ahead_only_creates_no_task() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" ahead 2 0
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "a fork only ahead of its upstream is not behind"
  assert_contains "$out" "status=ahead behind=0 ahead=2" "the ahead-only reading was wrong"
  assert_absent "$dir/home/data/fm-sync-widget" "an ahead-only fork must not create a sync task"
  pass "fm-fork-freshness: a fork that is only ahead creates no sync task"
}

test_divergence_is_reported_in_both_directions() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" diverged 6 20
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "a diverged fork is behind and must not exit clean"
  # "behind 20, ahead 6, diverged" is actionable; a single number is not.
  assert_contains "$out" "status=diverged behind=20 ahead=6" \
    "divergence must name both directions and be called diverged"
  pass "fm-fork-freshness: divergence is reported in both directions and named"
}

# --- unknown: a check that cannot run is not a check that passed -------------

test_compare_failure_reads_unknown() {
  local dir out rc=0 key reading
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  key=$(compare_fixture "$dir" upstream/widget main acme main identical 0 0)
  rm -f "$key.json"
  printf 'gh: API rate limit exceeded (HTTP 403)\n' > "$key.fail"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 4 "$rc" "an unreadable comparison must not exit clean"
  assert_contains "$out" "acme/widget status=unknown" "a failed comparison must read unknown"
  assert_contains "$out" "rate limit" "the unknown reading did not carry its reason"
  # The fork's own line, not the coverage line, which counts forks rather than
  # commits: the reading must carry no commit count it never measured.
  reading=$(printf '%s\n' "$out" | grep '^FORK_FRESHNESS: acme/widget')
  assert_not_contains "$reading" "behind=" \
    "an unknown reading carries no behind count - that number was never measured"
  assert_not_contains "$reading" "ahead=" \
    "an unknown reading carries no ahead count - that number was never measured"
  assert_absent "$dir/home/data/fm-sync-widget" "an unknown reading must not create a task"
  pass "fm-fork-freshness: a rate-limited comparison reads unknown, with no fabricated counts"
}

test_outage_and_in_sync_are_distinguishable() {
  local dir_ok dir_bad healthy outage key rc=0
  dir_ok=$(new_case)
  one_fork "$dir_ok" identical 0 0
  healthy=$(run_sweep "$dir_ok" sweep --owner acme) || rc=$?
  expect_code 0 "$rc" "the healthy world must exit clean"

  dir_bad=$(new_case)
  one_fork "$dir_bad" identical 0 0
  key=$(compare_fixture "$dir_bad" upstream/widget main acme main identical 0 0)
  rm -f "$key.json"
  printf 'gh: dial tcp: lookup api.github.com: no such host\n' > "$key.fail"
  rc=0
  outage=$(run_sweep "$dir_bad" sweep --owner acme) || rc=$?
  expect_code 4 "$rc" "the outage world must not exit clean"

  # The mechanical test: name the two world-states the reading distinguishes.
  # If an unreachable forge and a healthy level fork print the same thing,
  # anything stronger than "unknown" is fabrication.
  [ "$healthy" != "$outage" ] ||
    fail "an unreachable forge and a healthy in-sync fork produced identical output"
  assert_not_contains "$outage" "in-sync" "an unreachable forge must never read as in-sync"
  assert_contains "$healthy" "in-sync" "a healthy level fork must read as in-sync"
  pass "fm-fork-freshness: an outage and a healthy in-sync fork are never the same reading"
}

test_missing_gh_reads_unknown_coverage() {
  local dir out rc=0
  dir=$(new_case --no-gh)
  one_fork "$dir" identical 0 0
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 4 "$rc" "a sweep with no forge client must not exit clean"
  assert_contains "$out" "FORK_FRESHNESS_COVERAGE: status=unknown" \
    "with no forge client the sweep must report unknown coverage"
  assert_not_contains "$out" "in-sync" "a sweep that could not run must claim nothing"
  pass "fm-fork-freshness: no forge client reads as unknown coverage, not as a clean sweep"
}

test_enumeration_failure_reads_unknown_coverage() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 5
  rm -f "$dir/fixtures/repolist.json"
  printf 'gh: HTTP 401: Bad credentials\n' > "$dir/fixtures/repolist.fail"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 4 "$rc" "an unlistable account must not exit clean"
  assert_contains "$out" "FORK_FRESHNESS_COVERAGE: status=unknown" \
    "a failed enumeration must report unknown coverage"
  assert_contains "$out" "Bad credentials" "the unknown coverage did not carry its reason"
  assert_not_contains "$out" "swept=" \
    "a sweep that could not enumerate must not report a swept count"
  pass "fm-fork-freshness: an expired credential reads as unknown coverage"
}

test_unreadable_upstream_reads_unknown() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  rm -f "$dir/fixtures/api_repos_upstream_widget.json"
  printf 'gh: Not Found (HTTP 404)\n' > "$dir/fixtures/api_repos_upstream_widget.fail"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 4 "$rc" "an unreadable upstream must not exit clean"
  assert_contains "$out" "acme/widget status=unknown" \
    "an upstream that cannot be read must make the fork unknown, not in-sync"
  assert_contains "$out" "upstream upstream/widget could not be read" \
    "the unknown reading did not name the unreadable upstream"
  pass "fm-fork-freshness: a renamed or deleted upstream reads unknown"
}

test_unparseable_payload_reads_unknown() {
  local dir out rc=0 key
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  key=$(compare_fixture "$dir" upstream/widget main acme main identical 0 0)
  printf '{"status":"who knows","ahead_by":null,"behind_by":null}\n' > "$key.json"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 4 "$rc" "an unrecognised payload must not exit clean"
  assert_contains "$out" "status=unknown" "an unrecognised compare payload must read unknown"
  assert_absent "$dir/home/data/fm-sync-widget" "an unrecognised payload must not create a task"
  pass "fm-fork-freshness: a compare payload the sweep cannot parse reads unknown"
}

# --- coverage: a fork that is not checked is never simply absent -------------

test_private_and_uncloned_forks_are_covered() {
  local dir out rc=0
  dir=$(new_case)
  # Three forks: one public with a clone, one private, one with no clone at all -
  # the shape that made a clone-driven sweep miss a fork that was 28 behind.
  repolist "$dir" '[
    {"nameWithOwner":"acme/widget","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"widget"},"defaultBranchRef":{"name":"main"}},
    {"nameWithOwner":"acme/hidden","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"hidden"},"defaultBranchRef":{"name":"main"}},
    {"nameWithOwner":"acme/orphan","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"orphan"},"defaultBranchRef":{"name":"main"}},
    {"nameWithOwner":"acme/own-work","isFork":false,"isArchived":false,"parent":null,"defaultBranchRef":{"name":"main"}}
  ]'
  repo_fixture "$dir" upstream/widget false - main
  repo_fixture "$dir" upstream/hidden false - main
  repo_fixture "$dir" upstream/orphan false - main
  compare_fixture "$dir" upstream/widget main acme main identical 0 0 >/dev/null
  compare_fixture "$dir" upstream/hidden main acme main identical 0 0 >/dev/null
  compare_fixture "$dir" upstream/orphan main acme main behind 0 28 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the uncloned fork is behind, so the sweep must not exit clean"
  assert_contains "$out" "acme/hidden status=" "a private fork was not swept"
  assert_contains "$out" "acme/orphan status=behind behind=28" \
    "a fork with no local clone was not swept - the exact silent omission this replaces"
  assert_contains "$out" "repos=4 forks=3 swept=3 behind=1 unknown=0 ignored=0" \
    "the coverage line does not account for every candidate"
  pass "fm-fork-freshness: private forks and forks with no local clone are covered"
}

test_coverage_counts_match_the_readings() {
  local dir out rc=0 emitted behind_lines
  dir=$(new_case)
  repolist "$dir" '[
    {"nameWithOwner":"acme/one","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"one"},"defaultBranchRef":{"name":"main"}},
    {"nameWithOwner":"acme/two","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"two"},"defaultBranchRef":{"name":"main"}}
  ]'
  repo_fixture "$dir" upstream/one false - main
  repo_fixture "$dir" upstream/two false - main
  compare_fixture "$dir" upstream/one main acme main behind 0 4 >/dev/null
  compare_fixture "$dir" upstream/two main acme main behind 0 9 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  # A count computed where the readings cannot reach it is the same class of
  # lie as a fabricated reading: this pins swept/behind against the lines.
  emitted=$(printf '%s\n' "$out" | grep -c '^FORK_FRESHNESS: acme/' || true)
  behind_lines=$(printf '%s\n' "$out" | grep -c 'status=behind' || true)
  [ "$emitted" = 2 ] || fail "expected 2 fork readings, got $emitted"
  [ "$behind_lines" = 2 ] || fail "expected 2 behind readings, got $behind_lines"
  assert_contains "$out" "swept=2 behind=2" \
    "the coverage counts do not match the readings actually emitted"
  expect_code 3 "$rc" "two forks behind must not exit clean"
  pass "fm-fork-freshness: the coverage counts match the readings emitted"
}

test_ignored_forks_are_reported_not_omitted() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  printf 'widget\n' > "$dir/home/config/fork-sweep-ignore"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "an ignored fork leaves nothing behind to report"
  assert_contains "$out" "acme/widget status=ignored" \
    "an ignored fork must still be named - skipping it silently is the omission failure"
  assert_contains "$out" "ignored=1" "the coverage line did not count the ignored fork"
  assert_absent "$dir/home/data/fm-sync-widget" "an ignored fork must not create a task"
  pass "fm-fork-freshness: an ignored fork is reported by name, never omitted"
}

test_archived_forks_are_reported_as_ignored() {
  local dir out rc=0
  dir=$(new_case)
  repolist "$dir" '[{"nameWithOwner":"acme/widget","isFork":true,"isArchived":true,"parent":{"owner":{"login":"upstream"},"name":"widget"},"defaultBranchRef":{"name":"main"}}]'
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "an archived fork is not actionable"
  assert_contains "$out" "acme/widget status=ignored reason=archived fork" \
    "an archived fork must be named with its reason"
  pass "fm-fork-freshness: an archived fork is reported with its reason"
}

test_configured_extra_fork_outside_enumeration_is_swept() {
  local dir out rc=0
  dir=$(new_case)
  repolist "$dir" '[]'
  printf 'other-org/tool\n' > "$dir/home/config/maintained-forks"
  repo_fixture "$dir" other-org/tool true upstream/tool trunk
  repo_fixture "$dir" upstream/tool false - trunk
  compare_fixture "$dir" upstream/tool trunk other-org trunk behind 0 7 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "a configured maintained fork that is behind must not exit clean"
  assert_contains "$out" "other-org/tool status=behind behind=7" \
    "a maintained fork owned by another account was not swept"
  assert_contains "$out" "compare=trunk...trunk" "the sweep assumed a branch name instead of reading it"
  pass "fm-fork-freshness: a configured fork outside the owner's account is swept"
}

# --- the task the sweep creates ---------------------------------------------

test_sync_task_carries_the_proven_procedure() {
  local dir brief
  dir=$(new_case)
  one_fork "$dir" diverged 6 20
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  brief="$dir/home/data/fm-sync-widget/brief.md"
  assert_present "$brief" "no instructions were written for the sync task"

  assert_grep "Never through a PR" "$brief" \
    "the instructions omit the rule that a sync is not a pull request"
  assert_grep "merge commit" "$brief" "the instructions omit the true merge commit"
  assert_grep "gh repo sync" "$brief" \
    "the instructions omit that gh repo sync is known-broken on workflow commits"
  assert_grep "SSH alias" "$brief" "the instructions omit the SSH alias remote form"
  assert_grep "retired, not conditioned" "$brief" \
    "the instructions do not retire the old fast-forward procedure"
  assert_grep "behind 20, ahead 6" "$brief" \
    "the instructions do not carry the reading that opened the task"
  pass "fm-fork-freshness: the sync task carries the proven procedure and its reading"
}

test_behind_queues_a_wake() {
  local dir
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  assert_present "$dir/home/state/.wake-queue" "a fork behind queued no notification"
  assert_grep "fork-freshness" "$dir/home/state/.wake-queue" \
    "the queued notification does not name the freshness result"
  pass "fm-fork-freshness: a fork behind queues a durable notification"
}

test_repeat_sweep_creates_no_duplicate_task() {
  local dir out rc=0 second
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  second=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind on the second sweep"
  assert_contains "$second" "action=task fm-sync-widget already queued" \
    "a repeat sweep must find the first sweep's task, not create another"
  out=$(find "$dir/home/data" -maxdepth 1 -name 'fm-sync-*' | wc -l)
  [ "$out" = 1 ] || fail "expected exactly 1 sync task after two sweeps, found $out"
  pass "fm-fork-freshness: repeating the sweep never creates a second task for one fork"
}

test_task_already_under_way_is_left_alone() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  fm_write_meta "$dir/home/state/fm-sync-widget.meta" \
    "window=firstmate:fm-fm-sync-widget" "kind=ship"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind"
  assert_contains "$out" "already under way" \
    "a sync already under way must be recognised, not duplicated"
  assert_absent "$dir/home/data/fm-sync-widget/brief.md" \
    "a sync already under way must not have its instructions rewritten"
  pass "fm-fork-freshness: a sync already under way is recognised and left alone"
}

test_backlog_failure_is_reported_not_swallowed() {
  local dir stderr
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  FM_TEST_TASKS_RC=1 run_sweep "$dir" sweep --owner acme >/dev/null || true
  stderr=$(cat "$dir/stderr.log")
  assert_contains "$stderr" "BACKLOG_MANUAL: add fm-sync-widget" \
    "a backlog write that failed must say so rather than pass silently"
  assert_present "$dir/home/data/fm-sync-widget/brief.md" \
    "a failed backlog write must not cost the task its instructions"
  pass "fm-fork-freshness: a backlog write that fails is reported, not swallowed"
}

# --- cadence ----------------------------------------------------------------

test_if_due_is_silent_inside_the_interval() {
  local dir out rc=0 now
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  now=1800000000
  printf '%s\n' "$((now - 86400))" > "$dir/home/state/.fork-freshness-last"
  out=$(FM_FORK_FRESHNESS_NOW=$now run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 0 "$rc" "a sweep that is not due must exit clean"
  [ -z "$out" ] || fail "a sweep that is not due must print nothing, got: $out"
  pass "fm-fork-freshness: --if-due is silent inside the interval"
}

test_if_due_runs_once_the_interval_elapsed() {
  local dir out rc=0 now
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"
  out=$(FM_FORK_FRESHNESS_NOW=$now run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 3 "$rc" "a due sweep that finds a fork behind must not exit clean"
  assert_contains "$out" "status=behind" "the due sweep took no reading"
  assert_grep "$now" "$dir/home/state/.fork-freshness-last" \
    "a completed sweep did not record its completion"
  pass "fm-fork-freshness: --if-due runs once the interval has elapsed"
}

test_incomplete_sweep_does_not_bank_a_week_of_silence() {
  local dir now last rc=0
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  rm -f "$dir/fixtures/repolist.json"
  printf 'gh: HTTP 503: upstream unavailable\n' > "$dir/fixtures/repolist.fail"
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"
  FM_FORK_FRESHNESS_NOW=$now run_sweep "$dir" sweep --if-due --owner acme >/dev/null || rc=$?

  expect_code 4 "$rc" "an incomplete sweep must not exit clean"
  last=$(cat "$dir/home/state/.fork-freshness-last")
  [ "$last" != "$now" ] ||
    fail "a sweep that determined nothing recorded itself as complete, buying a week of silence"
  pass "fm-fork-freshness: an incomplete sweep stays due instead of banking silence"
}

# --- the single-repository reading used before a fork PR ---------------------

test_check_is_silent_for_a_repository_that_is_not_a_fork() {
  local dir out rc=0
  dir=$(new_case)
  repo_fixture "$dir" acme/own-work false - main
  out=$(run_sweep "$dir" check acme/own-work) || rc=$?

  expect_code 0 "$rc" "a repository with no upstream has no freshness problem"
  [ -z "$out" ] || fail "a non-fork must produce no freshness noise, got: $out"
  pass "fm-fork-freshness: check stays silent for a repository that is not a fork"
}

test_check_reports_a_fork_that_is_behind() {
  local dir out rc=0
  dir=$(new_case)
  repo_fixture "$dir" acme/widget true upstream/widget main
  repo_fixture "$dir" upstream/widget false - main
  compare_fixture "$dir" upstream/widget main acme main behind 0 20 >/dev/null
  out=$(run_sweep "$dir" check acme/widget) || rc=$?

  expect_code 3 "$rc" "a fork behind must not read clean before its PR"
  assert_contains "$out" "acme/widget status=behind behind=20" \
    "the pre-PR reading did not report the fork as behind"
  assert_present "$dir/home/data/fm-sync-widget/brief.md" \
    "the pre-PR reading only reported; it must create the sync task too"
  pass "fm-fork-freshness: check reports a behind fork and creates its sync task"
}

test_check_cannot_read_reads_unknown() {
  local dir out rc=0
  dir=$(new_case)
  printf 'gh: HTTP 401: Bad credentials\n' > "$dir/fixtures/api_repos_acme_widget.fail"
  out=$(run_sweep "$dir" check acme/widget) || rc=$?

  expect_code 4 "$rc" "an unreadable repository must not read clean before a PR"
  assert_contains "$out" "status=unknown" \
    "a repository that could not be read must be unknown, not treated as a non-fork"
  pass "fm-fork-freshness: check reads unknown when it cannot tell whether the repo is a fork"
}

# --- trigger wiring ---------------------------------------------------------
#
# Both triggers the rule names must fire it. These prove the call happens
# through the real caller, with a recorder standing in for the sweep.

fake_root_with_recorder() {  # <case-dir> -> fake FM_ROOT
  local dir=$1 root="$1/root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-fork-freshness.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SWEEP_LOG"
exit 0
SH
  chmod +x "$root/bin/fm-fork-freshness.sh"
  printf '%s\n' "$root"
}

test_pr_check_takes_the_reading_before_a_fork_pr() {
  local dir root log
  dir=$(new_case)
  root=$(fake_root_with_recorder "$dir")
  log="$dir/sweep.log"
  : > "$log"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
SH
  chmod +x "$dir/bin/gh"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$dir/wt" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$dir/home/state/task-a.meta"

  # The full PATH here, not the toolbox: these two tests drive the real callers
  # end to end, and those reach for far more of the system than the sweep does.
  FM_ROOT_OVERRIDE="$root" FM_HOME="$dir/home" FM_TEST_SWEEP_LOG="$log" \
    PATH="$dir/bin:$PATH" \
    "$root/bin/fm-pr-check.sh" task-a https://github.com/acme/widget/pull/7 \
    >/dev/null 2>&1 || true

  assert_grep "check acme/widget" "$log" \
    "recording a fork PR did not take the freshness reading the rule requires"
  pass "fm-fork-freshness: recording a PR takes the reading before the fork PR is acted on"
}

test_session_start_sweep_runs_and_detect_only_skips_it() {
  local dir root log
  dir=$(new_case)
  root=$(fake_root_with_recorder "$dir")
  log="$dir/sweep.log"
  rmdir "$dir/home/projects"

  : > "$log"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$dir/home" FM_TEST_SWEEP_LOG="$log" \
    PATH="$dir/bin:$PATH" FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$root/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
  [ ! -s "$log" ] ||
    fail "a read-only session must not run the scheduled sweep: $(cat "$log")"

  : > "$log"
  FM_ROOT_OVERRIDE="$root" FM_HOME="$dir/home" FM_TEST_SWEEP_LOG="$log" \
    PATH="$dir/bin:$PATH" "$root/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
  assert_grep "sweep --if-due" "$log" \
    "the scheduled half of the rule never fires at a locked session start"
  pass "fm-fork-freshness: the scheduled sweep runs at session start and never in a read-only session"
}

test_behind_creates_a_sync_task
test_in_sync_creates_no_task
test_ahead_only_creates_no_task
test_divergence_is_reported_in_both_directions
test_compare_failure_reads_unknown
test_outage_and_in_sync_are_distinguishable
test_missing_gh_reads_unknown_coverage
test_enumeration_failure_reads_unknown_coverage
test_unreadable_upstream_reads_unknown
test_unparseable_payload_reads_unknown
test_private_and_uncloned_forks_are_covered
test_coverage_counts_match_the_readings
test_ignored_forks_are_reported_not_omitted
test_archived_forks_are_reported_as_ignored
test_configured_extra_fork_outside_enumeration_is_swept
test_sync_task_carries_the_proven_procedure
test_behind_queues_a_wake
test_repeat_sweep_creates_no_duplicate_task
test_task_already_under_way_is_left_alone
test_backlog_failure_is_reported_not_swallowed
test_if_due_is_silent_inside_the_interval
test_if_due_runs_once_the_interval_elapsed
test_incomplete_sweep_does_not_bank_a_week_of_silence
test_check_is_silent_for_a_repository_that_is_not_a_fork
test_check_reports_a_fork_that_is_behind
test_check_cannot_read_reads_unknown
test_pr_check_takes_the_reading_before_a_fork_pr
test_session_start_sweep_runs_and_detect_only_skips_it
