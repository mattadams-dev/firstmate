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
#   - The mutant that answers "is a sync task open for this fork?" from the marker
#     file instead of the task system breaks exactly
#     test_closed_task_frees_a_behind_fork_to_queue_again and
#     test_absent_task_frees_a_behind_fork_to_queue_again: the instrument keeps
#     reading, and stops creating work, which is the same decay into "merely
#     warning" one indirection down. Its opposite - treating every marker as
#     spent - breaks test_repeat_sweep_creates_no_duplicate_task and
#     test_a_sync_under_way_keeps_its_guard, because a live task would be
#     duplicated on every sweep. The third world has its own case:
#     test_unreadable_task_state_neither_duplicates_nor_retires, where the two
#     cannot be told apart and the sweep is required to say so.
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
  timeout find wc readlink id env expr od shasum sha256sum flock getconf python3; do
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
#
# It answers `show <id>` too, in the installed CLI's shape: an indented
# `state: <queued|in_flight|done>` line at rc=0, and `code: NOT_FOUND` on
# STDOUT at rc=1 for a task the backlog does not have (verified against the
# installed tasks-axi 0.2.x - the error goes to stdout, not stderr). That is the
# call the sweep uses to tell an open sync task from one that closed, so a fake
# that answered only `add` would let the whole liveness question pass untested.
#
# `add` here is CREATE-ONLY, because the installed CLI's is: over an id that
# already exists it prints `already: true` and returns 0 having transitioned
# nothing (docs/verification/fork-freshness.md). An earlier fake modelled add as
# an upsert that also reopened, and that single permissive line is why a sweep
# printing `queued` over a task that stayed done passed this suite. A fake may
# only be as generous as the tool it stands in for; anywhere it is more
# generous, the difference ships.
#
# `reopen` is the primitive that does transition, and NOT_FOUND at rc=1 over an
# absent id. FM_TEST_TASKS_REOPEN_NOOP makes it report success while changing
# nothing - the exact false-success shape the remediation path must survive.
# FM_TEST_TASKS_HELD adds the orthogonal `held: yes` field to `show`, which the
# real CLI reports alongside `state: queued` rather than instead of it.
install_fake_tasks_axi() {  # <bin-dir>
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TASKS_LOG"
store=${FM_TEST_TASKS_STORE:-}
state_of() {
  [ -n "$store" ] && [ -f "$store" ] || return 0
  grep "^$1 " "$store" 2>/dev/null | tail -1 | cut -d' ' -f2
}
not_found() {
  printf 'error: "Task \\"%s\\" not found in this backlog"\ncode: NOT_FOUND\n' "$1"
  exit 1
}
if [ "${1:-}" = show ]; then
  id=${2:-}
  # FM_TEST_TASKS_SHOW_FAIL_FROM makes the Nth and later reads unreadable -
  # NOT absent, which is a different answer. The sweep reads the backlog twice
  # per episode, before and after the remediation, so a blanket failure would
  # only ever exercise the first; counting is what reaches the second.
  if [ -n "${FM_TEST_TASKS_SHOW_FAIL_FROM:-}" ]; then
    shows=0
    [ ! -f "$store.shows" ] || shows=$(cat "$store.shows")
    shows=$((shows + 1))
    printf '%s' "$shows" > "$store.shows"
    if [ "$shows" -ge "$FM_TEST_TASKS_SHOW_FAIL_FROM" ]; then
      printf 'error: "backlog could not be read"\ncode: EIO\n'
      exit 1
    fi
  fi
  state=$(state_of "$id")
  [ -n "$state" ] || not_found "$id"
  printf 'task:\n  id: %s\n  state: %s\n  held: %s\n  body: -\n' \
    "$id" "$state" "${FM_TEST_TASKS_HELD:-no}"
  exit 0
fi
if [ "${1:-}" = reopen ]; then
  id=${2:-}
  state=$(state_of "$id")
  [ -n "$state" ] || not_found "$id"
  if [ -z "${FM_TEST_TASKS_REOPEN_NOOP:-}" ] && [ -n "$store" ]; then
    printf '%s queued\n' "$id" >> "$store"
  fi
  printf 'ok: reopen %s -> Queued\n' "$id"
  exit "${FM_TEST_TASKS_REOPEN_RC:-0}"
fi
if [ "${1:-}" = update ]; then
  id=${2:-}
  state=$(state_of "$id")
  [ -n "$state" ] || not_found "$id"
  shift 2
  while [ "$#" -gt 0 ]; do
    case $1 in
      --body|--body-file|--title|--repo|--kind|--priority|--pr|--report)
        [ "$#" -ge 2 ] || { printf 'error: "%s needs a value"\n' "$1" >&2; exit 2; }
        shift 2 ;;
      --archive-body|--json) shift ;;
      *) printf 'error: "Unknown flag: %s"\n' "$1" >&2; exit 2 ;;
    esac
  done
  exit "${FM_TEST_TASKS_UPDATE_RC:-0}"
fi
if [ "${1:-}" = add ]; then
  shift
  case "${1:-}" in ''|-*) echo 'error: "add takes an id first"' >&2; exit 2 ;; esac
  added=$1
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
  # Create-only, exactly as installed: an id that already exists is left alone
  # and still reported at rc=0.
  if [ -n "$(state_of "$added")" ]; then
    printf 'ok: add %s already exists\nalready: true\n' "$added"
  # FM_TEST_TASKS_KILL_BEFORE_STORE is the caller dying with the backlog write
  # still in flight, so the task never lands. Plain FM_TEST_TASKS_KILL is the
  # caller dying immediately AFTER a write that did land.
  elif [ -n "${FM_TEST_TASKS_KILL_BEFORE_STORE:-}" ]; then
    :
  elif [ -n "$store" ] && [ "${FM_TEST_TASKS_RC:-0}" = 0 ]; then
    printf '%s queued\n' "$added" >> "$store"
  fi
fi
if [ -n "${FM_TEST_TASKS_KILL:-}${FM_TEST_TASKS_KILL_BEFORE_STORE:-}" ]; then
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

# count_retired <case> <id>: archived briefs standing in that task's directory.
count_retired() {
  find "$1/home/data/$2" -name 'brief.retired-*.md' 2>/dev/null | wc -l | tr -d ' '
}

# count_wakes <case> <key>: queued wake records carrying that key. The queue is
# <epoch>\t<seq>\t<kind>\t<key>\t<payload>, so the key is field 4.
count_wakes() {
  awk -F '\t' -v k="$2" 'NF >= 5 && $4 == k' "$1/home/state/.wake-queue" 2>/dev/null |
    wc -l | tr -d ' '
}

# bridge_state <case>: the one sanctioned fold over the ledger. Read through
# bin/fm-bridge-render.sh --state rather than by parsing the ledger here: a test
# with its own parser is a second opinion about the same record, and two folds
# can agree while both are wrong.
bridge_state() {
  FM_HOME="$1/home" PATH="$1/bin:$TOOLBOX" \
    "$ROOT/bin/fm-bridge-render.sh" --state 2>/dev/null
}

# count_open_asks <case> <title>: open Bridge rows under that exact title.
count_open_asks() {
  bridge_state "$1" | jq --arg t "$2" \
    '[.asks[] as $k | .items[$k].title | select(. == $t)] | length'
}

# count_bridge_records <case>: records the ledger actually holds, as the fold
# counts them.
#
# The row count alone cannot see a repeated ask: the fold derives an item's id
# from its title, so asking the same question ten times folds to ONE row while
# appending ten records to an append-only stream everyone audits. Counting rows
# would pass whether or not the sweep deduped. This is the raw-stream-against-
# folded-state comparison the renderer publishes `counts` for.
count_bridge_records() {
  bridge_state "$1" | jq '.counts.records'
}

# close_task <case> <id>: the backlog now reports that task done, which is what
# completing a sync looks like from the sweep's side.
close_task() {
  printf '%s done\n' "$2" >> "$1/tasks.store"
}

# drop_task <case> <id>: the backlog no longer has that task at all - pruned,
# archived, or written by a home that has since been rebuilt.
drop_task() {
  grep -v "^$2 " "$1/tasks.store" > "$1/tasks.store.next" 2>/dev/null || true
  mv -f "$1/tasks.store.next" "$1/tasks.store"
}

# assert_task_state <case> <id> <queued|in_flight|done|-> <message>: what the
# backlog ACTUALLY reports for that task afterwards, read the same way the sweep
# reads it, with "-" meaning the backlog has no such task.
#
# This is the assertion the remediation path turns on. A sweep that detects a
# stale state correctly and then fails to act on it still prints a reading, so
# asserting the reading alone cannot tell a queued task from a discarded call -
# `tasks-axi add` returns 0 either way. Every test that expects work to have been
# made to exist checks the post-state here as well as the words on stdout.
assert_task_state() {
  local dir=$1 id=$2 want=$3 msg=$4 got
  got=$(grep "^$id " "$dir/tasks.store" 2>/dev/null | tail -1 | cut -d' ' -f2)
  [ -n "$got" ] || got=-
  [ "$got" = "$want" ] ||
    fail "$msg (the backlog reports '$got', expected '$want')"
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
  : > "$dir/tasks.store"
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
    FM_TEST_TASKS_STORE="$dir/tasks.store" \
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
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the reading said queued while the backlog got no task; the word is only ever a confirmed one"
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
  assert_contains "$out" "repos=4 forks=3 swept=3 behind=1 undischarged=0 unknown=0 ignored=0" \
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
  # The short-circuit is only allowed over a task that is genuinely open, so the
  # reading has to name the evidence it short-circuited on.
  assert_contains "$second" "the backlog reports it queued" \
    "already queued named no open task; it may not be printed on the marker file alone"
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

test_interrupted_materialisation_never_strands_the_task() {
  local dir out rc=0 leftover
  dir=$(new_case)
  one_fork "$dir" behind 0 3

  # The task is the sweep's commit point, and it is created last precisely so an
  # interruption AT it cannot strand the rest. A run killed the instant the
  # backlog write lands has, by construction, already placed the brief, the wake
  # and the Bridge row - so the materialisation is complete, and the next sweep
  # has nothing left to do but recognise it.
  FM_TEST_TASKS_KILL=1 run_sweep "$dir" sweep --owner acme >/dev/null 2>&1 || true

  assert_grep "Sync acme/widget" "$dir/tasks.log" \
    "the interrupted run never reached the backlog step, so it proves nothing"
  leftover=$(find "$dir/home/data" -name '.brief.*' | wc -l)
  [ "$leftover" = 0 ] ||
    fail "an interrupted materialisation left $leftover half-written brief(s) behind"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the task landed without the instructions that must precede it"
  assert_grep "## Definition of done" "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the interrupted run left a half-written procedure, which is the one thing the atomic move exists to prevent"
  assert_present "$dir/home/state/.wake-queue" \
    "the task landed without the wake that must precede it - creating it last is what prevents exactly this"

  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind on the sweep after the interruption"
  assert_contains "$out" "already queued" \
    "the completed materialisation must be recognised, not repeated"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the recognised task must still be the one the interrupted run created"
  pass "fm-fork-freshness: an interruption at the commit point leaves a complete materialisation"
}

test_interruption_before_the_task_lands_is_completed_by_the_next_sweep() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3

  # The other side of the same window: the backlog write never landed, so the
  # work is still owed. Nothing on disk may suppress that - a brief and a wake
  # from the dead run are both standing, and the next sweep must still ask the
  # task system, find no task, and finish the job.
  FM_TEST_TASKS_KILL_BEFORE_STORE=1 run_sweep "$dir" sweep --owner acme >/dev/null 2>&1 || true

  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the interrupted run should still have placed the instructions"
  assert_present "$dir/home/state/.wake-queue" \
    "the interrupted run should still have raised the wake"
  assert_task_state "$dir" fm-sync-acme-widget - \
    "this case is only meaningful if the backlog write never landed"

  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind on the sweep after the interruption"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "a brief and a wake left by a dead run suppressed the sweep - only the task system may answer whether work is owed"
  assert_not_contains "$out" "already queued" \
    "the sweep read a standing brief as an existing task, which is the conflation this redesign removed"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the completing sweep did not actually create the task it reported"
  pass "fm-fork-freshness: a brief left by a dead run never stands in for the task itself"
}

test_guard_expires_once_the_fork_is_level_again() {
  local dir out rc=0 retired brief
  dir=$(new_case)
  brief="$dir/home/data/fm-sync-acme-widget/brief.md"
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  assert_present "$brief" "the first episode created no sync task at all"

  # The fork goes level while the sync task is still open in the backlog. The
  # task is real work somebody still owes, so its instructions stay.
  compare_fixture "$dir" upstream/widget main acme main identical 0 0 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?
  expect_code 0 "$rc" "a fork level with its upstream must read clean"
  assert_contains "$out" "action=none" \
    "a level fork whose sync task is still open has nothing to retire"
  assert_present "$brief" \
    "an open sync task had its instructions retired out from under it"

  # The task is completed and closed. data/<id>/ is never deleted - teardown
  # keeps it as the task's evidence custodian - so a marker that meant only
  # "this file exists" now outlives the episode it belonged to.
  close_task "$dir" fm-sync-acme-widget
  rc=0
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 0 "$rc" "a level fork reads clean whatever happened to its marker"
  assert_contains "$out" "action=task fm-sync-acme-widget retired" \
    "the reading that found the marker spent did not retire it"
  assert_contains "$out" "RETIRED=brief.retired-" \
    "the retirement named no file, so a wrong retirement is undiscoverable afterwards"
  assert_contains "$out" "the backlog reports it done" \
    "the retirement recorded no reason for judging the marker spent"
  assert_absent "$brief" \
    "the spent marker is still in place, so the fork's next episode will report a task nobody created"
  retired=$(find "$dir/home/data/fm-sync-acme-widget" -name 'brief.retired-*.md' | wc -l)
  [ "$retired" = 1 ] ||
    fail "retirement must keep the brief as evidence, not delete it; found $retired retired brief(s)"

  # Weeks later, upstream moves and the same fork is behind again.
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
  pass "fm-fork-freshness: a marker no open task backs is retired, and the next episode is real"
}

test_closed_task_frees_a_behind_fork_to_queue_again() {
  local dir out rc=0 adds reopens
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  run_sweep "$dir" sweep --owner acme >/dev/null || true

  # The worker syncs, closes the task - and upstream moves again before any
  # reading catches the fork level. Waiting for behind=0 to expire the marker
  # never gets its chance here, which is the whole reason liveness is asked of
  # the task system rather than inferred from a transient reading.
  close_task "$dir" fm-sync-acme-widget
  compare_fixture "$dir" upstream/widget main acme main behind 0 14 >/dev/null
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind again and must not exit clean"
  assert_not_contains "$out" "already queued" \
    "the reading claimed a queued task over a backlog item that closed with the first episode"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "a fork behind with no open sync task must get a real new one"

  # The reading is not the result. A sweep that detects the closed task and then
  # fails to reopen it prints this same word, which is exactly how the third
  # finding shipped, so the post-state is asserted separately and in the
  # backlog's own terms.
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the reading said queued while the task stayed closed - the false success this redesign exists to remove"

  # And by the primitive that can actually do it. `add` cannot reopen anything:
  # over an existing id the installed CLI returns 0 having changed nothing, so a
  # second add here would be the defect wearing a passing test.
  reopens=$(grep -c '^reopen fm-sync-acme-widget' "$dir/tasks.log" || true)
  [ "$reopens" = 1 ] ||
    fail "the closed task must be reopened by the primitive that transitions it, found $reopens reopen(s)"
  adds=$(grep -c '^add fm-sync-acme-widget' "$dir/tasks.log" || true)
  [ "$adds" = 1 ] ||
    fail "add is create-only and must not be used to reopen; found $adds add(s) across two episodes"

  assert_contains "$out" "SUPERSEDED=brief.retired-" \
    "the replaced instructions were not named, so the previous episode's reading is undiscoverable"
  assert_contains "$out" "the backlog reports it done" \
    "the reading did not record why a new episode was started"
  assert_grep "behind 14, ahead 0" "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the fresh task still carries the first episode's reading"
  pass "fm-fork-freshness: a closed sync task is reopened, and the backlog proves it"
}

test_a_remediation_that_does_not_transition_is_never_reported_as_queued() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  close_task "$dir" fm-sync-acme-widget
  compare_fixture "$dir" upstream/widget main acme main behind 0 14 >/dev/null

  # The acceptance test the third finding earned. A guard that detects a stale
  # state correctly and then fails to act on it is not half-working: it is a
  # false-success generator, and a false success outranks a false failure here
  # because nothing prompts a look.
  #
  # So the remediation is made to report success while transitioning nothing -
  # the exact shape `tasks-axi add` has over an existing id - and the reading
  # must still refuse to say queued.
  out=$(FM_TEST_TASKS_REOPEN_NOOP=1 run_sweep "$dir" sweep --owner acme) || rc=$?

  assert_task_state "$dir" fm-sync-acme-widget "done" \
    "this case is only meaningful while the task stays closed"
  assert_not_contains "$out" "action=task fm-sync-acme-widget queued" \
    "the sweep printed queued over a task that never left done - exit status was treated as a result"
  assert_contains "$out" "NOT queued" \
    "a remediation that changed nothing must say so on the reading"
  assert_contains "$out" "the backlog reports it done" \
    "the reading must name the state actually found, not just that something failed"
  assert_contains "$out" "MANUAL=" \
    "a reading nobody can act on without a hand must be marked for one"
  assert_grep "TASK_MANUAL:" "$dir/stderr.log" \
    "a task that could not be queued raised no operator line"
  pass "fm-fork-freshness: a remediation that transitions nothing is never read as queued"
}

test_unreadable_post_state_reads_unknown_rather_than_queued() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 21

  # The third world. The task may or may not have been created and the sweep
  # cannot tell, so it may print neither definite word: naming the two states a
  # reading is meant to distinguish and finding that both produce it is the test
  # for fabrication, and "queued" would fail it here.
  out=$(FM_TEST_TASKS_SHOW_FAIL_FROM=2 run_sweep "$dir" sweep --owner acme) || rc=$?

  assert_not_contains "$out" "action=task fm-sync-acme-widget queued" \
    "an unconfirmable post-state was reported as a definite success"
  assert_not_contains "$out" "NOT queued" \
    "an unconfirmable post-state was reported as a definite failure"
  assert_contains "$out" "queue-state unknown" \
    "an unreadable post-state must read as unknown, in those words"
  assert_grep "TASK_UNCONFIRMED:" "$dir/stderr.log" \
    "an unconfirmable remediation raised no operator line"
  pass "fm-fork-freshness: a post-state that cannot be read is unknown, not queued and not failed"
}

test_a_held_task_is_open_work_and_is_not_duplicated() {
  local dir out rc=0 adds
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  run_sweep "$dir" sweep --owner acme >/dev/null || true

  # Hold is an orthogonal field, not a state: the CLI reports a held task as
  # `state: queued` with `held: yes`, and there is no state named `held`
  # anywhere in it. A held sync task is therefore open work somebody has paused
  # on purpose, and raising a second one over it would be the duplicate the
  # short-circuit exists to prevent.
  compare_fixture "$dir" upstream/widget main acme main behind 0 30 >/dev/null
  out=$(FM_TEST_TASKS_HELD=yes run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind"
  assert_contains "$out" "already queued" \
    "a held sync task is open work and must short-circuit, not raise a second episode"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "a held task must be left exactly as it was found"
  adds=$(grep -c '^add fm-sync-acme-widget' "$dir/tasks.log" || true)
  [ "$adds" = 1 ] || fail "a held task was duplicated; found $adds add(s)"
  pass "fm-fork-freshness: a held sync task is open work, not a state the sweep invents"
}

test_reopen_is_never_called_on_an_open_task() {
  local dir reopens
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  run_sweep "$dir" sweep --owner acme >/dev/null || true

  # `reopen` moves Done OR In flight back to Queued, so calling it on work a
  # crewmate already holds would pull that work back to the queue underneath
  # them. It is reachable only from a confirmed closed reading.
  printf '%s in_flight\n' fm-sync-acme-widget >> "$dir/tasks.store"
  compare_fixture "$dir" upstream/widget main acme main behind 0 30 >/dev/null
  run_sweep "$dir" sweep --owner acme >/dev/null || true

  assert_task_state "$dir" fm-sync-acme-widget in_flight \
    "an in-flight sync task was pulled back to the queue underneath its worker"
  reopens=$(grep -c '^reopen fm-sync-acme-widget' "$dir/tasks.log" || true)
  [ "$reopens" = 0 ] ||
    fail "reopen was called on an open task $reopens time(s); it may only follow a confirmed closed reading"
  pass "fm-fork-freshness: reopen is reachable only from a confirmed closed reading"
}

test_absent_task_frees_a_behind_fork_to_queue_again() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  # The backlog no longer has the task at all - pruned, or written by a home
  # since rebuilt. Nothing open backs the marker either way.
  drop_task "$dir" fm-sync-acme-widget
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "a marker backed by no task at all still suppressed the work it was tracking"
  assert_contains "$out" "the backlog has no such task" \
    "the reading did not record why a new episode was started"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the reading said queued over a backlog the task had been dropped from"
  pass "fm-fork-freshness: a marker the backlog has no task for is retired, not honoured"
}

test_unreadable_task_state_neither_duplicates_nor_retires() {
  local dir out stderr rc=0 adds
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  run_sweep "$dir" sweep --owner acme >/dev/null || true

  # No task system to ask. An open sync task and one that closed months ago now
  # look identical, so the sweep may neither duplicate live work nor retire a
  # marker that may still be doing its job - and it may not stay quiet about it.
  rm -f "$dir/bin/tasks-axi"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?
  stderr=$(cat "$dir/stderr.log")

  expect_code 3 "$rc" "the fork is behind whatever the backlog could say"
  assert_contains "$stderr" "TASK_UNKNOWN:" \
    "a liveness question that could not be answered passed silently"
  assert_contains "$out" "not queued" \
    "the reading claimed a state of the sync task that was never read"
  assert_absent "$dir/home/state/fm-sync-acme-widget.meta" "no worker was ever spawned here"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "instructions whose task state is unknown were filed away anyway"
  [ -z "$(find "$dir/home/data/fm-sync-acme-widget" -name 'brief.retired-*.md')" ] ||
    fail "an unreadable task state must retire nothing"
  adds=$(grep -c '^add fm-sync-acme-widget' "$dir/tasks.log" || true)
  [ "$adds" = 1 ] || fail "expected no second backlog item, found $adds add(s)"
  pass "fm-fork-freshness: an unreadable task state duplicates nothing, retires nothing, and says so"
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
  local dir out stderr rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  # A directory where the brief belongs: the atomic move cannot land, so there
  # are no usable instructions. Instructions come before the task now, so this
  # stops there rather than queueing work nobody could execute - and it must say
  # which of the several ways it stopped, not a generic "NOT queued".
  mkdir -p "$dir/home/data/fm-sync-acme-widget/brief.md/blocked"
  out=$(run_sweep "$dir" sweep --owner acme) || rc=$?
  stderr=$(cat "$dir/stderr.log")

  expect_code 3 "$rc" "the fork is behind however its task ended"
  assert_contains "$out" "NOT queued: instructions could not be placed" \
    "the reading dropped the reason its task could not be created"
  assert_grep "TASK_MANUAL:" "$dir/stderr.log" \
    "a task withheld for want of instructions raised no operator line"
  assert_contains "$stderr" "instructions could not be placed" \
    "the operator line dropped the reason the task was withheld"
  assert_task_state "$dir" fm-sync-acme-widget - \
    "a task was queued against instructions that could not be written"

  # The fork's behind reading still goes out. Withholding the task is not the
  # same as withholding the alarm.
  assert_contains "$out" "acme/widget status=behind behind=3" \
    "a local write failure swallowed the reading that the fork is behind"
  pass "fm-fork-freshness: a task that could not be created keeps its reason and reports the fork anyway"
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
  assert_contains "$stderr" "TASK_MANUAL: acme/widget is behind but sync task fm-sync-acme-widget" \
    "a backlog write that failed must say so rather than pass silently"
  assert_contains "$out" "MANUAL=backlog" \
    "the reading claimed a queued task while its backlog item was never observed"
  assert_contains "$out" "NOT queued" \
    "a backlog write that failed still read as a queued task"
  assert_task_state "$dir" fm-sync-acme-widget - \
    "this case is only meaningful while the backlog write actually fails"
  assert_present "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "a failed backlog write must not cost the task its instructions"
  pass "fm-fork-freshness: a backlog write that fails is reported, not swallowed"
}

# A retry an hour later, which is what the retry floor actually produces. The
# clock is advanced explicitly rather than left to run at machine speed: the
# brief stamps a fresh observation time on every attempt, so two sweeps inside
# one minute would carry the SAME timestamp and every accumulation test below
# would pass whether or not the comparison excludes it. Modelling the real
# spacing is what makes these tests able to fail.
retry_sweep() {  # <case> <hours-from-base> [args...]
  local dir=$1 hours=$2
  shift 2
  FM_FORK_FRESHNESS_NOW=$((1800000000 + hours * 3600)) run_sweep "$dir" "$@"
}

test_a_repeated_undischarged_sweep_accumulates_nothing() {
  local dir out rc=0 asks
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  retry_sweep "$dir" 0 sweep --owner acme >/dev/null || true
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "this case starts from a real first episode, so that must have landed"

  # The backlog is pruned and its writes now fail persistently - an unwritable
  # store, a full disk, a home since rebuilt - and the fork moves once. Every
  # sweep from here reads behind, finds no task, fails to create one, and comes
  # back at the retry floor rather than the weekly cadence, because withholding
  # the completion stamp is what the previous round made it do.
  #
  # So the retry is the common case, and the question is what a hundred of them
  # leave behind. One changed reading may supersede the standing brief once; the
  # attempts after it must add nothing at all, or an unattended broken backlog
  # buries the very record SUPERSEDED= exists to keep findable.
  drop_task "$dir" fm-sync-acme-widget
  compare_fixture "$dir" upstream/widget main acme main behind 0 9 >/dev/null
  FM_TEST_TASKS_RC=1 retry_sweep "$dir" 1 sweep --owner acme >/dev/null || true
  FM_TEST_TASKS_RC=1 retry_sweep "$dir" 2 sweep --owner acme >/dev/null || true
  out=$(FM_TEST_TASKS_RC=1 retry_sweep "$dir" 3 sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind on every one of these sweeps"
  assert_contains "$out" "NOT queued" \
    "this case is only meaningful while the sweeps really do stay undischarged"
  assert_task_state "$dir" fm-sync-acme-widget - \
    "this case is only meaningful while the backlog write keeps failing"

  [ "$(count_retired "$dir" fm-sync-acme-widget)" = 1 ] ||
    fail "three undischarged sweeps left $(count_retired "$dir" fm-sync-acme-widget) archived brief(s); one changed reading supersedes once, and the retries after it must archive nothing"
  [ "$(count_wakes "$dir" fm-sync-acme-widget)" = 1 ] ||
    fail "three undischarged sweeps queued $(count_wakes "$dir" fm-sync-acme-widget) wake entries for one unconsumed condition"
  asks=$(count_open_asks "$dir" "acme/widget is behind upstream/widget")
  [ "$asks" = 1 ] ||
    fail "three undischarged sweeps left $asks open Bridge rows for one unresolved condition"
  [ "$(count_bridge_records "$dir")" = 1 ] ||
    fail "three undischarged sweeps appended $(count_bridge_records "$dir") records to the Bridge ledger; they fold to one row, but the raw stream still grows once per retry"
  pass "fm-fork-freshness: a repeated undischarged sweep adds nothing to what the first one raised"
}

test_an_unchanged_condition_supersedes_nothing_and_says_so() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  retry_sweep "$dir" 0 sweep --owner acme >/dev/null || true
  drop_task "$dir" fm-sync-acme-widget

  # The archive skip has to be PROVEN to fire, because the shape that fails
  # silently here is the dangerous one: write_sync_brief stamps a fresh
  # observation time into the brief on every attempt, so a whole-file comparison
  # would find these two runs different and skip nothing, while still looking
  # exactly like a working check. The retry is therefore taken an hour later,
  # with a genuinely different timestamp and nothing else changed, which is the
  # only spacing at which this test can fail.
  out=$(FM_TEST_TASKS_RC=1 retry_sweep "$dir" 1 sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is still behind"
  [ "$(count_retired "$dir" fm-sync-acme-widget)" = 0 ] ||
    fail "a re-sweep of an unchanged condition archived a brief that superseded nothing - the comparison is not excluding the per-attempt timestamp"
  assert_not_contains "$out" "SUPERSEDED=" \
    "the reading claimed it superseded a brief while leaving that brief exactly where it was"
  assert_grep "behind 3, ahead 0" "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the standing brief must still carry the reading it was written for"
  pass "fm-fork-freshness: an unchanged condition supersedes nothing and claims nothing"
}

test_a_changed_condition_still_supersedes_and_still_raises() {
  local dir out rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  retry_sweep "$dir" 0 sweep --owner acme >/dev/null || true
  close_task "$dir" fm-sync-acme-widget

  # The other direction, and without it the idempotence tests above would all
  # pass for an implementation that never archives and never raises anything.
  # Upstream moved, so the standing instructions now name the wrong reading and a
  # real new episode is starting: the brief must be filed away under its stamped
  # name and the reading must say which file it kept.
  compare_fixture "$dir" upstream/widget main acme main behind 0 41 >/dev/null
  out=$(retry_sweep "$dir" 1 sweep --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind by more than it was"
  assert_contains "$out" "SUPERSEDED=brief.retired-" \
    "a genuinely changed reading must still name the brief it filed away"
  [ "$(count_retired "$dir" fm-sync-acme-widget)" = 1 ] ||
    fail "a changed reading archived $(count_retired "$dir" fm-sync-acme-widget) briefs; the idempotence must not swallow a real new episode"
  assert_grep "behind 41, ahead 0" "$dir/home/data/fm-sync-acme-widget/brief.md" \
    "the standing brief still carries the superseded reading rather than the new one"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "the new episode's task was never actually reopened"
  pass "fm-fork-freshness: a changed condition still supersedes its brief and still raises the work"
}

test_an_unconfirmable_retry_accumulates_nothing_either() {
  local dir asks
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  retry_sweep "$dir" 0 sweep --owner acme >/dev/null || true
  drop_task "$dir" fm-sync-acme-widget

  # The other undischarged path that rewrites the brief: the attempt runs and its
  # post-state cannot be read back, so the sweep reports neither success nor
  # failure and comes back at the retry floor exactly as the confirmed-failure
  # path does. It must accumulate exactly as little.
  FM_TEST_TASKS_SHOW_FAIL_FROM=2 retry_sweep "$dir" 1 sweep --owner acme >/dev/null || true
  rm -f "$dir/tasks.store.shows"
  FM_TEST_TASKS_SHOW_FAIL_FROM=2 retry_sweep "$dir" 2 sweep --owner acme >/dev/null || true

  [ "$(count_retired "$dir" fm-sync-acme-widget)" = 0 ] ||
    fail "unconfirmable retries left $(count_retired "$dir" fm-sync-acme-widget) archived brief(s) over one unchanged condition"
  [ "$(count_wakes "$dir" fm-sync-acme-widget)" = 1 ] ||
    fail "unconfirmable retries queued $(count_wakes "$dir" fm-sync-acme-widget) wake entries for one unconsumed condition"
  asks=$(count_open_asks "$dir" "acme/widget is behind upstream/widget")
  [ "$asks" = 1 ] ||
    fail "unconfirmable retries left $asks open Bridge rows for one unresolved condition"
  [ "$(count_bridge_records "$dir")" = 1 ] ||
    fail "unconfirmable retries appended $(count_bridge_records "$dir") records to the Bridge ledger over one unresolved condition"
  pass "fm-fork-freshness: an unconfirmable retry accumulates no more than a confirmed-failed one"
}

test_an_unreadable_liveness_retry_still_touches_nothing() {
  local dir asks
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  retry_sweep "$dir" 0 sweep --owner acme >/dev/null || true

  # The third undischarged path returns before it reaches any artifact at all,
  # and that must stay true rather than becoming true by accident: with no task
  # system to ask, repeated sweeps may not archive, rewrite, re-wake or re-raise
  # anything, because they cannot tell an open sync task from one that closed.
  rm -f "$dir/bin/tasks-axi"
  retry_sweep "$dir" 1 sweep --owner acme >/dev/null || true
  retry_sweep "$dir" 2 sweep --owner acme >/dev/null || true

  [ "$(count_retired "$dir" fm-sync-acme-widget)" = 0 ] ||
    fail "a sweep that could not read liveness archived a brief anyway"
  [ "$(count_wakes "$dir" fm-sync-acme-widget)" = 1 ] ||
    fail "a sweep that could not read liveness queued $(count_wakes "$dir" fm-sync-acme-widget) wake entries"
  asks=$(count_open_asks "$dir" "acme/widget is behind upstream/widget")
  [ "$asks" = 1 ] ||
    fail "a sweep that could not read liveness left $asks open Bridge rows"
  [ "$(count_bridge_records "$dir")" = 1 ] ||
    fail "a sweep that could not read liveness appended $(count_bridge_records "$dir") records to the Bridge ledger"
  pass "fm-fork-freshness: an unreadable liveness reading keeps touching nothing on every retry"
}

test_a_stale_task_body_is_reported_not_just_marked() {
  local dir out stderr rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  run_sweep "$dir" sweep --owner acme >/dev/null || true
  close_task "$dir" fm-sync-acme-widget
  compare_fixture "$dir" upstream/widget main acme main behind 0 30 >/dev/null

  # The reopen lands but the body refresh does not, so the task is genuinely
  # open and owed while still describing the episode that closed. Every other
  # step that needs a hand says so on stderr by construction; a marker whose
  # meaning appears nowhere is one an operator cannot act on.
  out=$(FM_TEST_TASKS_UPDATE_RC=1 run_sweep "$dir" sweep --owner acme) || rc=$?
  stderr=$(cat "$dir/stderr.log")

  expect_code 3 "$rc" "the fork is behind whatever its task body says"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "this case is only meaningful while the reopen itself succeeded"
  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "an open task whose body is merely stale is still queued work"
  assert_contains "$out" "MANUAL=note" \
    "the reading dropped the marker for a body that still holds the previous reading"
  assert_contains "$stderr" "NOTE_MANUAL:" \
    "a stale task body was marked on the reading with no operator line to act on"
  assert_contains "$stderr" "behind 30" \
    "the operator line dropped the reading the body should have been refreshed to"
  pass "fm-fork-freshness: a task body left holding the previous episode is reported, not just marked"
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

test_a_behind_fork_nothing_tracks_does_not_bank_a_week_of_silence() {
  local dir out now last rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"

  # The other half of the stamp's meaning, and the silent one. Coverage here is
  # fully determined - the forge answered, the fork is behind - but there is no
  # task system to make the sync exist in, so the sweep creates nothing and this
  # fork ends the run with nothing carrying it. Stamping that as a completed
  # sweep would go quiet for the whole cadence over an untracked behind fork,
  # which is a false success and therefore worse than the failure it hides.
  rm -f "$dir/bin/tasks-axi"
  out=$(FM_FORK_FRESHNESS_NOW=$now run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind whatever the backlog could say"
  assert_contains "$out" "undischarged=1" \
    "the coverage line did not account for a behind fork the sweep left untracked"
  assert_task_state "$dir" fm-sync-acme-widget - \
    "this case is only meaningful while no task was created"
  last=$(cat "$dir/home/state/.fork-freshness-last")
  [ "$last" != "$now" ] ||
    fail "a sweep that left a behind fork untracked recorded itself as complete, buying a week of silence"

  # And it comes back behind the retry floor rather than the weekly cadence:
  # the next due check, once the floor has passed, takes the reading again.
  out=$(FM_FORK_FRESHNESS_NOW=$((now + 3601)) run_sweep "$dir" sweep --if-due --owner acme) ||
    true
  assert_contains "$out" "status=behind" \
    "the sweep went quiet for the week instead of staying due behind its retry floor"
  pass "fm-fork-freshness: a behind fork nothing tracks leaves the sweep due"
}

test_an_unconfirmable_task_does_not_bank_a_week_of_silence() {
  local dir now last rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 21
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"

  # The post-attempt case: the sweep tried, and then could not read back whether
  # it worked. It refuses to call that reading queued, so it may not turn around
  # and bank it as a completed sweep either - the stamp would be asserting
  # exactly the success the reading declined to assert.
  FM_TEST_TASKS_SHOW_FAIL_FROM=2 FM_FORK_FRESHNESS_NOW=$now \
    run_sweep "$dir" sweep --if-due --owner acme >/dev/null || rc=$?

  expect_code 3 "$rc" "the fork is behind however its task ended"
  last=$(cat "$dir/home/state/.fork-freshness-last")
  [ "$last" != "$now" ] ||
    fail "a sweep that could not confirm its own task recorded itself as complete"
  pass "fm-fork-freshness: a task that could not be confirmed leaves the sweep due"
}

test_a_task_confirmed_not_open_does_not_bank_a_week_of_silence() {
  local dir out now last rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"

  # The third way a behind fork ends untracked: the post-state WAS read and it
  # says the task is not there. That is a determinate failure to discharge, and
  # it withholds the stamp for the same reason the two unreadable cases do.
  out=$(FM_TEST_TASKS_RC=1 FM_FORK_FRESHNESS_NOW=$now \
    run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 3 "$rc" "the fork is behind however its task ended"
  assert_contains "$out" "NOT queued" \
    "this case is only meaningful while the reading refuses to say queued"
  assert_contains "$out" "undischarged=1" \
    "a confirmed-not-open task left the coverage line reading like a discharged sweep"
  last=$(cat "$dir/home/state/.fork-freshness-last")
  [ "$last" != "$now" ] ||
    fail "a sweep whose task was confirmed absent recorded itself as complete"
  pass "fm-fork-freshness: a task confirmed not open leaves the sweep due"
}

test_a_behind_fork_with_its_task_open_banks_a_complete_sweep() {
  local dir out now rc=0
  dir=$(new_case)
  one_fork "$dir" behind 0 3
  now=1800000000
  printf '%s\n' "$((now - 8 * 86400))" > "$dir/home/state/.fork-freshness-last"

  # The anti-cry-wolf direction of the same rule, and the reason the stamp is
  # keyed on discharge rather than on `behind > 0`: a fork that is behind with a
  # confirmed-open task carrying it IS a complete sweep. Withholding the stamp
  # here would make the sweep re-run every hour for as long as any fork is
  # behind, which is a different way of stopping the instrument distinguishing
  # anything.
  out=$(FM_FORK_FRESHNESS_NOW=$now run_sweep "$dir" sweep --if-due --owner acme) || rc=$?

  expect_code 3 "$rc" "a fork behind its upstream must not exit clean"
  assert_contains "$out" "undischarged=0" \
    "a behind fork whose task was created and confirmed open was counted as undischarged"
  assert_task_state "$dir" fm-sync-acme-widget queued \
    "this case is only meaningful while the task really is open"
  assert_grep "$now" "$dir/home/state/.fork-freshness-last" \
    "a behind fork whose sync task is open and tracked is a complete sweep and must stamp"
  pass "fm-fork-freshness: a behind fork whose task is confirmed open stamps a complete sweep"
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
    FM_TEST_SWEEP_STDERR='TASK_MANUAL: acme/widget is behind but sync task fm-sync-acme-widget did not create' \
    run_bootstrap "$dir" "$root")

  assert_contains "$out" "action=task fm-sync-acme-widget queued" \
    "the session-start digest lost the sweep's reading"
  assert_contains "$out" "TASK_MANUAL: acme/widget is behind but sync task fm-sync-acme-widget" \
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
test_interrupted_materialisation_never_strands_the_task
test_interruption_before_the_task_lands_is_completed_by_the_next_sweep
test_guard_expires_once_the_fork_is_level_again
test_closed_task_frees_a_behind_fork_to_queue_again
test_a_remediation_that_does_not_transition_is_never_reported_as_queued
test_unreadable_post_state_reads_unknown_rather_than_queued
test_a_held_task_is_open_work_and_is_not_duplicated
test_reopen_is_never_called_on_an_open_task
test_absent_task_frees_a_behind_fork_to_queue_again
test_unreadable_task_state_neither_duplicates_nor_retires
test_a_sync_under_way_keeps_its_guard
test_a_task_that_could_not_be_created_keeps_its_reason
test_sync_brief_never_carries_a_remote_credential
test_wake_failure_is_reported_not_swallowed
test_bridge_failure_is_reported_not_swallowed
test_backlog_failure_is_reported_not_swallowed
test_a_repeated_undischarged_sweep_accumulates_nothing
test_an_unchanged_condition_supersedes_nothing_and_says_so
test_a_changed_condition_still_supersedes_and_still_raises
test_an_unconfirmable_retry_accumulates_nothing_either
test_an_unreadable_liveness_retry_still_touches_nothing
test_a_stale_task_body_is_reported_not_just_marked
test_if_due_is_silent_inside_the_interval
test_if_due_runs_once_the_interval_elapsed
test_incomplete_sweep_does_not_bank_a_week_of_silence
test_a_behind_fork_nothing_tracks_does_not_bank_a_week_of_silence
test_an_unconfirmable_task_does_not_bank_a_week_of_silence
test_a_task_confirmed_not_open_does_not_bank_a_week_of_silence
test_a_behind_fork_with_its_task_open_banks_a_complete_sweep
test_check_is_silent_for_a_repository_that_is_not_a_fork
test_check_reports_a_fork_that_is_behind
test_check_cannot_read_reads_unknown
test_pr_check_takes_the_reading_before_a_fork_pr
test_pr_check_bounds_the_freshness_reading
test_session_start_sweep_runs_and_detect_only_skips_it
test_session_start_relays_everything_the_sweep_says
test_session_start_never_prints_a_crashed_sweep_as_a_quiet_one
