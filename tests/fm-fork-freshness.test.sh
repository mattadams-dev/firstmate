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
#   - The mutant that lets the idempotency guard outlive the episode that created
#     it breaks exactly test_guard_expires_once_the_fork_is_level_again: the
#     instrument keeps reading, and stops creating work, which is the same decay
#     into "merely warning" one indirection down. Its opposite - retiring the
#     guard on any level reading - breaks test_a_sync_under_way_keeps_its_guard.
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
# for by name or by count, never dropped. That suite also holds the ways coverage
# can be quietly incomplete rather than quietly wrong - a fork whose slug is a
# suffix of another's, a clone whose origin URL ends in a slash, and an
# enumeration that came back at its cap - and each has its opposite-direction
# case, because "declare coverage unknown every run" passes none of them.
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

# FM_TEST_TASKS_KILL stands in for the kill a bounded caller delivers mid-task:
# the backlog step signals the shell that invoked it and the one above that, so
# the materialisation stops between its first artifact and its last whichever
# way the shell laid the call out.
#
# The fake also holds the real CLI's argument contract - `add <id> "<title>"
# [flags]`, unknown flag means rc=2 - because a fake that exits 0 on any shape
# lets a call the installed tasks-axi refuses pass the whole suite, and the
# backlog item then goes missing only in production.
install_fake_tasks_axi() {  # <bin-dir>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TASKS_LOG"
if [ "${1:-}" = add ]; then
  shift
  case "${1:-}" in ''|-*) echo 'error: "add takes an id first"' >&2; exit 2 ;; esac
  shift
  case "${1:-}" in ''|-*) echo 'error: "add takes a title"' >&2; exit 2 ;; esac
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --body|--body-file|--kind|--repo|--pr|--report|--priority|--blocked-by|--prefix)
        [ "$#" -ge 2 ] || { printf 'error: "%s needs a value"\n' "$1" >&2; exit 2; }
        shift 2 ;;
      --start|--queue|--mint|--json) shift ;;
      *) printf 'error: "Unknown flag: %s"\n' "$1" >&2; exit 2 ;;
    esac
  done
fi
if [ -n "${FM_TEST_TASKS_KILL:-}" ]; then
  grandparent=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
  kill -TERM "$PPID" 2>/dev/null || true
  case "$grandparent" in
    ''|0|1) : ;;
    *) kill -TERM "$grandparent" 2>/dev/null || true ;;
  esac
  exit 1
fi
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

# FM_TEST_SWEEP_BIN runs a copied bin/ instead of the repo's, for the cases whose
# subject is what the sweep does when one of its sibling scripts is unavailable.
run_sweep() {  # <case> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_FIXTURES="$dir/fixtures" \
    FM_TEST_TASKS_LOG="$dir/tasks.log" \
    PATH="$dir/bin:$TOOLBOX" \
    "${FM_TEST_SWEEP_BIN:-$SWEEP}" "$@" 2>"$dir/stderr.log"
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
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "behind > 0 only reported; it must create the sync task"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the sync task carries no instructions"
  assert_grep "add fm-sync-acme-widget Sync acme/widget from " "$dir/tasks.log" \
    "the backlog call did not reach tasks-axi in the shape the CLI accepts"
  assert_not_contains "$out" "MANUAL=" \
    "a reading that says queued must have all four artifacts, not a manual hand-off"
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
  assert_absent "$dir/home/data/fm-sync-acme-widget" \
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
  assert_absent "$dir/home/data/fm-sync-acme-widget" "an ahead-only fork must not create a sync task"
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
  assert_absent "$dir/home/data/fm-sync-acme-widget" "an unknown reading must not create a task"
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
  assert_absent "$dir/home/data/fm-sync-acme-widget" "an unrecognised payload must not create a task"
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
  assert_absent "$dir/home/data/fm-sync-acme-widget" "an ignored fork must not create a task"
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

test_fork_named_inside_another_forks_slug_is_still_swept() {
  local dir out rc=0
  dir=$(new_case)
  # "me/firstmate" is a suffix of "acme/firstmate": a substring dedupe against
  # the owned enumeration drops the second fork with no line and no count, which
  # is the silent omission this whole sweep exists to end, reproduced inside it.
  repolist "$dir" '[{"nameWithOwner":"acme/firstmate","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"firstmate"},"defaultBranchRef":{"name":"main"}}]'
  printf 'me/firstmate\n' > "$dir/home/config/maintained-forks"
  repo_fixture "$dir" upstream/firstmate false - main
  repo_fixture "$dir" me/firstmate true up2/firstmate main
  repo_fixture "$dir" up2/firstmate false - main
  compare_fixture "$dir" upstream/firstmate main acme main identical 0 0 >/dev/null
  compare_fixture "$dir" up2/firstmate main me main behind 0 5 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the second fork is behind, so the sweep must not exit clean"
  printf '%s\n' "$out" | grep -q '^FORK_FRESHNESS: me/firstmate status=behind behind=5' ||
    fail "a fork whose slug is a suffix of an enumerated one was dropped without a line"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "forks=2" "the swallowed fork was missing from the coverage counts too"
  assert_present "$dir/home/data/fm-sync-me-firstmate/brief.md" \
    "the swallowed fork never got its sync task"
  pass "fm-fork-freshness: a fork whose slug is a suffix of another's is swept, not swallowed"
}

test_cloned_fork_with_a_trailing_slash_origin_is_swept() {
  local dir out rc=0
  dir=$(new_case)
  repolist "$dir" '[]'
  fm_git_init_commit "$dir/home/projects/tool"
  git -C "$dir/home/projects/tool" remote add origin 'https://github.com/other-org/tool/'
  repo_fixture "$dir" other-org/tool true upstream/tool main
  repo_fixture "$dir" upstream/tool false - main
  compare_fixture "$dir" upstream/tool main other-org main behind 0 4 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "a cloned fork that is behind must not exit clean"
  assert_contains "$out" "other-org/tool status=behind behind=4" \
    "a clone whose origin URL ends in a slash contributed no candidate at all"
  pass "fm-fork-freshness: a clone with a trailing-slash origin URL is still a candidate"
}

test_capped_enumeration_reads_unknown_coverage() {
  local dir out rc=0 now last
  dir=$(new_case)
  # The list came back at exactly the cap, so repositories exist that this run
  # never saw. Two clean readings do not make that a clean sweep.
  repolist "$dir" '[
    {"nameWithOwner":"acme/one","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"one"},"defaultBranchRef":{"name":"main"}},
    {"nameWithOwner":"acme/two","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"two"},"defaultBranchRef":{"name":"main"}}
  ]'
  repo_fixture "$dir" upstream/one false - main
  repo_fixture "$dir" upstream/two false - main
  compare_fixture "$dir" upstream/one main acme main identical 0 0 >/dev/null
  compare_fixture "$dir" upstream/two main acme main identical 0 0 >/dev/null
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"
  out=$(FM_FORK_FRESHNESS_NOW=$now FM_FORK_SWEEP_LIST_LIMIT=2 \
    run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 4 "$rc" "a sweep whose enumeration hit its cap must not exit clean"
  assert_contains "$out" "FORK_FRESHNESS_COVERAGE: status=unknown" \
    "a truncated enumeration must report coverage as unknown"
  assert_contains "$out" "cap" "the unknown coverage line does not name the cap it hit"
  assert_contains "$out" "swept=2" \
    "the readings it did take must still be reported alongside the unknown coverage"
  last=$(cat "$dir/home/state/.fork-freshness-last")
  [ "$last" != "$now" ] ||
    fail "a truncated sweep stamped itself complete, buying a week of silence over forks it never read"
  pass "fm-fork-freshness: an enumeration that hit its cap reads unknown and stays due"
}

test_full_enumeration_under_the_cap_reads_clean() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  out=$(FM_FORK_SWEEP_LIST_LIMIT=2 run_sweep "$dir" sweep --owner acme) || rc=$?

  # The other half of the cap check: a list that fits must not read as truncated,
  # or the sweep cries unknown every run and the distinction stops meaning anything.
  expect_code 0 "$rc" "a complete enumeration below the cap must exit clean"
  assert_not_contains "$out" "status=unknown" \
    "an enumeration that fit under the cap was reported as truncated"
  pass "fm-fork-freshness: an enumeration that fits under the cap reads clean"
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

test_registered_project_without_a_clone_is_swept() {
  local dir out rc=0
  dir=$(new_case)
  # A fork this home maintains per its own registry, that the owner enumeration
  # does not return and that this home has not cloned: covered by no other
  # source, so without the registry it gets no line, no unknown and no count.
  repolist "$dir" '[]'
  printf -- '- widget [no-mistakes] - the widget project (added 2026-07-01)\n' \
    > "$dir/home/data/projects.md"
  repo_fixture "$dir" acme/widget true upstream/widget main
  repo_fixture "$dir" upstream/widget false - main
  compare_fixture "$dir" upstream/widget main acme main behind 0 12 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "a registered fork that is behind must not exit clean"
  assert_contains "$out" "acme/widget status=behind behind=12" \
    "a fork registered in data/projects.md was omitted entirely"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the registered fork was read but got no sync task"
  pass "fm-fork-freshness: a fork registered in data/projects.md but not cloned here is swept"
}

test_registered_local_only_project_is_named_not_read() {
  local dir out rc=0
  dir=$(new_case)
  # A local-only project has no forge repository at all. Reading it would spend
  # an unknown on it every single sweep, and unknown coverage withholds the
  # completion stamp - a permanent false unknown the sweep could never clear.
  repolist "$dir" '[]'
  printf -- '- lab [local-only] - a local-only lab (added 2026-07-01)\n' \
    > "$dir/home/data/projects.md"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "a local-only project is not an unreadable fork"
  assert_contains "$out" "lab status=ignored" \
    "a registered local-only project must still be named, never dropped"
  assert_not_contains "$out" "status=unknown" \
    "a project with no forge repository was read as an unreadable one"
  assert_present "$dir/home/state/.fork-freshness-last" \
    "the sweep banked no completion stamp, so it stays due forever over a local-only project"
  pass "fm-fork-freshness: a registered local-only project is reported by name, not read as unknown"
}

test_owner_flag_without_a_value_is_refused_loudly() {
  local dir rc=0
  dir=$(new_case)
  one_fork "$dir" identical 0 0
  run_sweep "$dir" sweep --owner >/dev/null || rc=$?

  expect_code 2 "$rc" "a flag with no value must be refused like every other malformed option"
  assert_grep "--owner needs a login" "$dir/stderr.log" \
    "a malformed option exited with no diagnostic at all"
  rc=0
  run_sweep "$dir" sweep --owner= >/dev/null || rc=$?
  expect_code 2 "$rc" \
    "an empty --owner= must be refused, not silently swept against the default owner"
  pass "fm-fork-freshness: --owner with no value is refused loudly"
}

# --- the task the sweep creates ---------------------------------------------

test_same_named_forks_under_two_owners_get_two_tasks() {
  local dir out rc=0 tasks
  dir=$(new_case)
  repolist "$dir" '[{"nameWithOwner":"acme/widget","isFork":true,"isArchived":false,"parent":{"owner":{"login":"upstream"},"name":"widget"},"defaultBranchRef":{"name":"main"}}]'
  printf 'other-org/widget\n' > "$dir/home/config/maintained-forks"
  repo_fixture "$dir" upstream/widget false - main
  repo_fixture "$dir" other-org/widget true up2/widget main
  repo_fixture "$dir" up2/widget false - main
  compare_fixture "$dir" upstream/widget main acme main behind 0 3 >/dev/null
  compare_fixture "$dir" up2/widget main other-org main behind 0 9 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "two forks behind must not exit clean"
  # A bare fm-sync-<repo> id would make the second fork find the first fork's
  # task and report "already queued" - a silent omission dressed as idempotency.
  assert_contains "$out" "acme/widget status=behind behind=3" "the first fork was not read"
  assert_contains "$out" "other-org/widget status=behind behind=9" "the second fork was not read"
  assert_not_contains "$out" "already queued" \
    "a second fork sharing a repository name was mistaken for the first fork's task"
  tasks=$(find "$dir/home/data" -maxdepth 1 -name 'fm-sync-*' | wc -l)
  [ "$tasks" = 2 ] || fail "expected 2 sync tasks for 2 distinct forks, found $tasks"
  pass "fm-fork-freshness: two forks sharing a repository name get two distinct tasks"
}

test_sync_task_carries_the_proven_procedure() {
  local dir brief
  dir=$(new_case)
  one_fork "$dir" diverged 6 20
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  brief="$dir/home/data/fm-sync-acme-widget/brief.md"
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
  assert_contains "$second" "action=task fm-sync-acme-widget already queued" \
    "a repeat sweep must find the first sweep's task, not create another"
  out=$(find "$dir/home/data" -maxdepth 1 -name 'fm-sync-*' | wc -l)
  [ "$out" = 1 ] || fail "expected exactly 1 sync task after two sweeps, found $out"
  pass "fm-fork-freshness: repeating the sweep never creates a second task for one fork"
}

test_task_already_under_way_is_left_alone() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  fm_write_meta "$dir/home/state/fm-sync-acme-widget.meta" \
    "window=firstmate:fm-fm-sync-acme-widget" "kind=ship"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind"
  assert_contains "$out" "already under way" \
    "a sync already under way must be recognised, not duplicated"
  assert_absent "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "a sync already under way must not have its instructions rewritten"
  pass "fm-fork-freshness: a sync already under way is recognised and left alone"
}

test_interrupted_materialisation_leaves_no_guard() {
  local dir out rc=0 leftover
  dir=$(new_case)
  one_fork "$dir" behind 0 3

  # The brief is the idempotency guard, so a run cut short between its first
  # artifact and its last must leave no guard at all - otherwise the fork keeps
  # reading "already queued" over a task with no backlog item, no wake and no
  # Bridge row, forever, which is the silent omission wearing the guard's clothes.
  FM_TEST_TASKS_KILL=1 run_sweep "$dir" sweep --owner acme >/dev/null 2>&1 || true

  assert_grep "Sync acme/widget" "$dir/tasks.log" \
    "the interrupted run never reached the backlog step, so it proves nothing"
  assert_absent "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "an interrupted materialisation left the guard behind, and no later sweep will finish the task"
  assert_absent "$dir/home/state/.wake-queue" \
    "the interrupted run queued a wake it should never have reached"
  leftover=$(find "$dir/home/data" -name '.brief.*' | wc -l)
  [ "$leftover" = 0 ] ||
    fail "an interrupted materialisation left $leftover half-written brief(s) behind"

  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind on the sweep after the interruption"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "the sweep after an interrupted one must redo the whole materialisation"
  assert_not_contains "$out" "already queued" \
    "the sweep after an interrupted one found a guard the interrupted run should not have left"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the completing sweep left the task without its instructions"
  assert_present "$dir/home/state/.wake-queue" \
    "the completing sweep left the task without its wake entry"
  pass "fm-fork-freshness: an interrupted materialisation leaves no guard and the next sweep completes it"
}

test_guard_expires_once_the_fork_is_level_again() {
  local dir out rc=0 retired brief
  dir=$(new_case)
  brief="$dir/home/data/fm-sync-acme-widget/brief.md"
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  assert_present "$brief" "the first episode created no sync task at all"

  # The sync happens and the fork goes level. data/<id>/ is never deleted -
  # teardown keeps it as the task's evidence custodian - so a guard that means
  # only "this file exists" outlives the episode that created it, and the
  # instrument decays back into the warning it replaced.
  compare_fixture "$dir" upstream/widget main acme main identical 0 0 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "a fork level with its upstream again must read clean"
  assert_contains "$out" "action=task fm-sync-acme-widget retired" \
    "the reading that ended the episode did not retire its spent idempotency guard"
  assert_absent "$brief" \
    "the spent guard is still in place, so the fork's next episode will report a task nobody created"
  retired=$(find "$dir/home/data/fm-sync-acme-widget" -name 'brief.retired-*.md' | wc -l)
  [ "$retired" = 1 ] ||
    fail "retirement must keep the brief as evidence, not delete it; found $retired retired brief(s)"

  # Weeks later, upstream moves and the same fork is behind again. This is the
  # episode a lifetime-less guard swallows forever.
  compare_fixture "$dir" upstream/widget main acme main behind 0 50 >/dev/null
  rc=0
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind again and must not exit clean"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "the fork's second episode created no task"
  assert_not_contains "$out" "already queued" \
    "the second episode was reported as already queued over a task that closed with the first"
  assert_present "$brief" "the second episode left the task without instructions"
  assert_grep "behind 50, ahead 0" "$brief" \
    "the second episode's instructions still quote the first episode's reading"
  pass "fm-fork-freshness: the idempotency guard expires with its episode, so the next one is real"
}

test_a_sync_under_way_keeps_its_guard() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  fm_write_meta "$dir/home/state/fm-sync-acme-widget.meta" \
    "window=firstmate:fm-fm-sync-acme-widget" "kind=ship"
  # The worker has pushed the merge and the fork now reads level, but the task
  # is still open: retiring here would pull the instructions out from under a
  # worker still reading them.
  compare_fixture "$dir" upstream/widget main acme main identical 0 0 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "the fork is level"
  assert_contains "$out" "action=none" "a sync still under way is nothing to retire"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "a sync still under way had its instructions retired out from under it"
  pass "fm-fork-freshness: a sync still under way keeps its brief"
}

test_a_task_that_could_not_be_created_keeps_its_reason() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  # A directory where the brief belongs: every artifact up to the atomic move
  # happens, and the move itself cannot. With the backlog write failing too, the
  # composed line carries both the cause and the MANUAL marker - the two things
  # a generic "task NOT created" literal would overwrite.
  mkdir -p "$dir/home/data/fm-sync-acme-widget/brief.md/blocked"
  out=$(FM_TEST_TASKS_RC=1 run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind however its task ended"
  assert_contains "$out" "NOT created: instructions could not be placed" \
    "the reading dropped the reason its task could not be created"
  assert_contains "$out" "MANUAL=backlog" \
    "the reading dropped the marker naming the artifact nobody observed"
  pass "fm-fork-freshness: a task that could not be created keeps its reason and its MANUAL marker"
}

test_sync_brief_never_carries_a_remote_credential() {
  local dir brief
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  # A clone configured with an https token remote. The brief is durable and is
  # copied into the evidence repository at teardown, so a token interpolated
  # into it lands in another repository's history.
  fm_git_init_commit "$dir/home/projects/widget"
  git -C "$dir/home/projects/widget" remote add origin \
    'https://x-access-token:ghp_notarealtokenatall@github.com/acme/widget.git'
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  brief="$dir/home/data/fm-sync-acme-widget/brief.md"

  assert_present "$brief" "no instructions were written for the sync task"
  assert_no_grep "ghp_notarealtokenatall" "$brief" \
    "the brief carries the clone's credential into a durable, travelling artifact"
  assert_grep "github.com/acme/widget" "$brief" \
    "the remote hint was dropped entirely instead of being sanitised"
  pass "fm-fork-freshness: the sync brief carries the remote without its credentials"
}

test_wake_failure_is_reported_not_swallowed() {
  local dir out stderr rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  # An unwritable sequence file is a wake append that cannot happen.
  mkdir "$dir/home/state/.wake-queue.seq"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?
  stderr=$(cat "$dir/stderr.log")

  expect_code 3 "$rc" "the fork is behind regardless of where its notification went"
  assert_contains "$stderr" "WAKE_MANUAL:" \
    "a wake entry that could not be appended must say so rather than pass silently"
  assert_contains "$out" "MANUAL=wake" \
    "the reading claimed a queued task while one of its four artifacts was never observed"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "a failed wake must not cost the task its instructions"
  assert_grep "Sync acme/widget" "$dir/tasks.log" \
    "a failed wake must not cost the task its backlog item"
  pass "fm-fork-freshness: a wake append that fails is reported, not swallowed"
}

test_bridge_failure_is_reported_not_swallowed() {
  local dir root out stderr rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  root="$dir/root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  rm -f "$root/bin/fm-bridge.sh"
  out=$(FM_TEST_SWEEP_BIN="$root/bin/fm-fork-freshness.sh" \
    run_sweep "$dir" sweep --owner acme) || rc=$?
  stderr=$(cat "$dir/stderr.log")

  expect_code 3 "$rc" "the fork is behind regardless of where its Bridge row went"
  assert_contains "$stderr" "BRIDGE_MANUAL:" \
    "a Bridge ask that could not be raised must say so rather than pass silently"
  assert_contains "$out" "MANUAL=bridge" \
    "the reading claimed a queued task while the captain was never actually asked"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "a failed Bridge ask must not cost the task its instructions"
  pass "fm-fork-freshness: a Bridge ask that cannot be raised is reported, not swallowed"
}

test_backlog_failure_is_reported_not_swallowed() {
  local dir out stderr
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  out=$(FM_TEST_TASKS_RC=1 run_sweep "$dir" sweep --owner acme) || true
  stderr=$(cat "$dir/stderr.log")
  assert_contains "$stderr" "BACKLOG_MANUAL: add fm-sync-acme-widget" \
    "a backlog write that failed must say so rather than pass silently"
  assert_contains "$out" "MANUAL=backlog" \
    "the reading claimed a queued task while its backlog item was never observed"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
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
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
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

# The recorder also stands in for what a real sweep does to its caller: it can
# print a reading, write to stderr the way the backlog failure does, exit with
# any status, and hang. `exec sleep` rather than a plain sleep, so a bounded
# caller's timeout kills the process holding the pipe rather than orphaning it.
fake_root_with_recorder() {  # <case-dir> -> fake FM_ROOT
  local dir=$1 root="$1/root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-fork-freshness.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SWEEP_LOG"
[ -z "${FM_TEST_SWEEP_HANG:-}" ] || exec sleep "$FM_TEST_SWEEP_HANG"
[ -z "${FM_TEST_SWEEP_STDOUT:-}" ] || printf '%s\n' "$FM_TEST_SWEEP_STDOUT"
[ -z "${FM_TEST_SWEEP_STDERR:-}" ] || printf '%s\n' "$FM_TEST_SWEEP_STDERR" >&2
exit "${FM_TEST_SWEEP_RC:-0}"
SH
  chmod +x "$root/bin/fm-fork-freshness.sh"
  printf '%s\n' "$root"
}

run_bootstrap() {  # <case-dir> <fake-root> -> the digest on stdout
  local dir=$1 root=$2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$dir/home" FM_TEST_SWEEP_LOG="$dir/sweep.log" \
    PATH="$dir/bin:$PATH" \
    "$root/bin/fm-bootstrap.sh" 2>/dev/null || true
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

test_session_start_relays_everything_the_sweep_says() {
  local dir root out
  dir=$(new_case)
  root=$(fake_root_with_recorder "$dir")
  rmdir "$dir/home/projects"

  # The backlog failure goes to stderr because stdout carries the reading. If the
  # trigger drops stderr, the digest shows a queued sync task and nothing else,
  # and the captain tracks an item that is on no backlog.
  out=$(FM_TEST_SWEEP_RC=3 \
    FM_TEST_SWEEP_STDOUT='FORK_FRESHNESS: acme/widget status=behind behind=3 ahead=0 upstream=upstream/widget compare=main...main action=task fm-sync-acme-widget queued' \
    FM_TEST_SWEEP_STDERR='BACKLOG_MANUAL: add fm-sync-acme-widget to the backlog by hand' \
    run_bootstrap "$dir" "$root")

  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "the session-start digest lost the sweep's reading"
  assert_contains "$out" "BACKLOG_MANUAL: add fm-sync-acme-widget" \
    "a sync task whose backlog write failed reached the digest as a clean queued task"
  pass "fm-fork-freshness: session start relays the sweep's backlog failure, not only its reading"
}

test_session_start_never_prints_a_crashed_sweep_as_a_quiet_one() {
  local dir root quiet crashed
  dir=$(new_case)
  root=$(fake_root_with_recorder "$dir")
  rmdir "$dir/home/projects"

  # The two world-states: the sweep was not due (silence is the correct reading)
  # and the sweep died before taking one (silence would be a fabrication).
  quiet=$(run_bootstrap "$dir" "$root")
  crashed=$(FM_TEST_SWEEP_RC=1 run_bootstrap "$dir" "$root")

  assert_not_contains "$quiet" "FORK_FRESHNESS" \
    "a sweep that was not due must add nothing to the digest"
  assert_contains "$crashed" "FORK_FRESHNESS_COVERAGE: status=unknown" \
    "a sweep that crashed without a reading printed exactly what a not-due sweep prints"
  pass "fm-fork-freshness: a crashed sweep and a not-due sweep never read the same at session start"
}

test_pr_check_bounds_the_freshness_reading() {
  local dir root out started elapsed
  dir=$(new_case)
  root=$(fake_root_with_recorder "$dir")
  : > "$dir/sweep.log"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
SH
  chmod +x "$dir/bin/gh"
  fm_write_meta "$dir/home/state/task-b.meta" \
    "window=firstmate:fm-task-b" "endpoint_task_id=task-b" "worktree=$dir/wt" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes"
  chmod 0600 "$dir/home/state/task-b.meta"

  # A forge that accepts the connection and never answers must cost a reading,
  # not the task: the merge watch is already armed by the time this runs.
  started=$SECONDS
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$dir/home" FM_TEST_SWEEP_LOG="$dir/sweep.log" \
    FM_TEST_SWEEP_HANG=20 FM_FORK_SWEEP_PR_TIMEOUT=1 \
    PATH="$dir/bin:$PATH" \
    "$root/bin/fm-pr-check.sh" task-b https://github.com/acme/widget/pull/9 2>/dev/null) || true
  elapsed=$((SECONDS - started))

  [ "$elapsed" -lt 15 ] ||
    fail "a stalled freshness reading hung the PR-ready path for ${elapsed}s"
  assert_contains "$out" "armed: state/task-b.check.sh" \
    "a stalled freshness reading cost the merge watch its arming"
  assert_contains "$out" "acme/widget status=unknown" \
    "a freshness reading that timed out reported nothing at all"
  pass "fm-fork-freshness: a stalled pre-PR reading is bounded and reads unknown"
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
test_fork_named_inside_another_forks_slug_is_still_swept
test_cloned_fork_with_a_trailing_slash_origin_is_swept
test_capped_enumeration_reads_unknown_coverage
test_full_enumeration_under_the_cap_reads_clean
test_configured_extra_fork_outside_enumeration_is_swept
test_registered_project_without_a_clone_is_swept
test_registered_local_only_project_is_named_not_read
test_owner_flag_without_a_value_is_refused_loudly
test_same_named_forks_under_two_owners_get_two_tasks
test_sync_task_carries_the_proven_procedure
test_behind_queues_a_wake
test_repeat_sweep_creates_no_duplicate_task
test_task_already_under_way_is_left_alone
test_interrupted_materialisation_leaves_no_guard
test_guard_expires_once_the_fork_is_level_again
test_a_sync_under_way_keeps_its_guard
test_a_task_that_could_not_be_created_keeps_its_reason
test_sync_brief_never_carries_a_remote_credential
test_wake_failure_is_reported_not_swallowed
test_bridge_failure_is_reported_not_swallowed
test_backlog_failure_is_reported_not_swallowed
test_if_due_is_silent_inside_the_interval
test_if_due_runs_once_the_interval_elapsed
test_incomplete_sweep_does_not_bank_a_week_of_silence
test_check_is_silent_for_a_repository_that_is_not_a_fork
test_check_reports_a_fork_that_is_behind
test_check_cannot_read_reads_unknown
test_pr_check_takes_the_reading_before_a_fork_pr
test_pr_check_bounds_the_freshness_reading
test_session_start_sweep_runs_and_detect_only_skips_it
test_session_start_relays_everything_the_sweep_says
test_session_start_never_prints_a_crashed_sweep_as_a_quiet_one
