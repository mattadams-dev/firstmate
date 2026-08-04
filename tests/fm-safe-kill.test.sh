#!/usr/bin/env bash
# tests/fm-safe-kill.test.sh - the termination owner, proven in BOTH directions.
#
# The refusals matter, and so does the fact that a legitimate stop still works.
# A helper that refuses everything is the same failure as one that kills the
# wrong thing: supervision stops being recoverable, silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SAFE_KILL="$ROOT/bin/fm-safe-kill.sh"
TMP_ROOT=$(fm_test_tmproot fm-safe-kill-tests)

# A process that does nothing but stay alive until signalled. Its descriptors go
# to /dev/null: a background job that inherits a captured pipe keeps that pipe
# open, and the command substitution reading it would block for the sleep's full
# duration.
SLEEPER_PID=
start_sleeper() {
  sleep 300 >/dev/null 2>&1 &
  SLEEPER_PID=$!
}

run_safe_kill() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" FM_HOME="$state/.." "$SAFE_KILL" "$@" 2>&1
}

# Publish a role lock naming <pid>, exactly as a real supervisor's
# singleton-at-birth acquisition would.
publish_role_lock() {  # <state> <lockname> <role> <pid> [home]
  local state=$1 lockname=$2 role=$3 pid=$4 owner home identity
  home=${5:-$state/..}
  owner="$state/$lockname.owner.test"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$owner"
  printf '%s\n' "$pid" > "$owner/pid"
  printf '%s\n' "$role" > "$owner/role"
  printf '%s\n' "$home" > "$owner/fm-home"
  printf '%s\n' "$state" > "$owner/state"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$owner/watcher-path"
  printf '%s\n' "$identity" > "$owner/pid-identity"
  ln -sfn "$owner" "$state/$lockname"
}

is_alive() { kill -0 "$1" 2>/dev/null; }

new_state() {  # <name>
  local dir
  dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir/state"
}

# --- the recorded specimen ---------------------------------------------------
#
# `kill -TERM 17907`. The operator resolved the pid, confirmed its identity with
# ps, walked its descendants, and terminated it. Every step was performed
# correctly and the outcome was still wrong, because 17907 was the live
# firstmate session holding this home's lock. Reproduced here with a real
# process standing in for that session - and in the STRONGEST form: the watcher
# role lock also names it, so this proves the session-lock refusal outranks role
# authority rather than merely filling a gap where authority was absent.
test_refuses_the_session_lock_holder() {
  local state victim out rc=0
  state=$(new_state session-lock-holder)
  start_sleeper; victim=$SLEEPER_PID
  printf '%s\n' "$victim" > "$state/.lock"
  publish_role_lock "$state" .watch.lock watcher "$victim"
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "reclaim the home lock") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) for the session-lock holder, got $rc"
  printf '%s' "$out" | grep -F 'holds this home'"'"'s session lock' >/dev/null \
    || fail "refusal did not name the session lock (got: $out)"
  is_alive "$victim" || fail "the session-lock holder was terminated"
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "the incident's own specimen is refused: a pid holding the session lock is never terminated"
}

# The same specimen with a role lock ALSO present but naming someone else. The
# refusal must not become available just because some supervision lock exists.
test_refuses_when_the_role_lock_names_another_pid() {
  local state victim other out rc=0
  state=$(new_state role-lock-mismatch)
  start_sleeper; victim=$SLEEPER_PID
  start_sleeper; other=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$other"
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "stop the watcher") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) for a pid the lock does not name, got $rc"
  printf '%s' "$out" | grep -F "names pid $other, not pid $victim" >/dev/null \
    || fail "refusal did not report the lock/target mismatch (got: $out)"
  is_alive "$victim" || fail "a pid the watcher lock does not name was terminated"
  kill "$victim" "$other" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "a target chosen from something other than the lock is refused"
}

test_refuses_self_and_ancestor() {
  local state out rc=0
  state=$(new_state self-and-ancestor)
  out=$(run_safe_kill "$state" --pid "$$" --role watcher --reason "self") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) for an ancestor of the caller, got $rc"
  printf '%s' "$out" | grep -Fq 'ancestor of this process' \
    || printf '%s' "$out" | grep -Fq 'that is this process' \
    || fail "refusal did not name self/ancestry (got: $out)"
  pass "the caller's own process and its ancestors are refused"
}

# There is no lockless authority. A target no role lock names escalates, even
# when the caller is confident it started the process itself - that confidence is
# exactly what the specimens prove worthless.
test_requires_a_role() {
  local state victim out rc=0
  state=$(new_state no-role)
  start_sleeper; victim=$SLEEPER_PID
  out=$(run_safe_kill "$state" --pid "$victim" --reason "tidy up") || rc=$?
  [ "$rc" -eq 2 ] || fail "a kill with no role lock must be rejected outright, got $rc ($out)"
  printf '%s' "$out" | grep -Fq 'authorized only by a supervision role lock' \
    || fail "rejection did not explain that authority comes from a lock (got: $out)"
  is_alive "$victim" || fail "a target with no authorizing lock was terminated"
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "termination with no authorizing role lock is rejected"
}

test_refuses_when_no_role_lock_exists() {
  local state victim out rc=0
  state=$(new_state absent-role-lock)
  start_sleeper; victim=$SLEEPER_PID
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "stop the watcher") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) when no watcher lock exists, got $rc ($out)"
  printf '%s' "$out" | grep -Fq 'nothing authorizes ending pid' \
    || fail "refusal did not report the absent lock (got: $out)"
  is_alive "$victim" || fail "a target was terminated with no lock present"
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "a role with no lock in this home authorizes nothing"
}

test_refuses_a_reused_pid() {
  local state victim out rc=0
  state=$(new_state reused-pid)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$victim"
  # Rewrite the published identity so the live pid no longer matches what the
  # lock recorded: the pid was reused by an unrelated process.
  printf 'linux-starttime=1 cmdline-hex=00\n' > "$(readlink "$state/.watch.lock")/pid-identity"
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "stop the watcher") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) for a reused pid, got $rc"
  printf '%s' "$out" | grep -Fq 'the pid was reused' || fail "refusal did not name pid reuse (got: $out)"
  is_alive "$victim" || fail "a reused pid was terminated on a stale lock record"
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "a pid the lock no longer describes is refused as reused"
}

test_refuses_another_home() {
  local state victim out rc=0
  state=$(new_state other-home)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$victim" /some/other/home
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "stop the watcher") || rc=$?
  [ "$rc" -eq 3 ] || fail "expected a proven refusal (3) for another home's supervisor, got $rc"
  printf '%s' "$out" | grep -Fq "belongs to home /some/other/home" \
    || fail "refusal did not name the foreign home (got: $out)"
  is_alive "$victim" || fail "another home's supervisor was terminated"
  kill "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
  pass "a supervisor belonging to another home is refused"
}

# A lock predating the fm-home field records no home. That is not evidence of a
# foreign home, and refusing it would leave every pre-upgrade home unable to end
# its own supervisor - the can-never-recover direction of the same guard.
test_a_lock_without_a_recorded_home_still_authorizes() {
  local state victim out rc=0
  state=$(new_state legacy-lock-no-home)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$victim"
  rm -f "$(readlink "$state/.watch.lock")/fm-home"
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "stop a pre-upgrade watcher") || rc=$?
  [ "$rc" -eq 0 ] || fail "a lock with no recorded home refused an otherwise verified stop (rc=$rc): $out"
  is_alive "$victim" && fail "the helper reported an exit while the process was still running"
  wait "$victim" 2>/dev/null || true
  pass "a lock that records no home still authorizes its own home's stop"
}

test_refuses_pattern_selectors_at_the_interface() {
  local state rc
  state=$(new_state pattern-selector)
  for selector in 'fm-watch.sh' '-1' '%1' 'sleep'; do
    rc=0
    run_safe_kill "$state" --pid "$selector" --reason "pattern" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "selector '$selector' was not rejected as a usage error (got $rc)"
  done
  pass "the helper accepts only a plain pid, never a name, pattern, or process group"
}

test_unknown_is_not_reported_as_success() {
  local state dead out rc=0
  state=$(new_state unknown-outcome)
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  out=$(run_safe_kill "$state" --pid "$dead" --role watcher --reason "stop something already gone") || rc=$?
  [ "$rc" -eq 4 ] || fail "a target that is not running must be an explicit unknown (4), got $rc"
  printf '%s' "$out" | grep -Fq 'no outcome is claimed' \
    || fail "the helper claimed an outcome it did not observe (got: $out)"
  pass "a target that is not running is reported as unknown, never as a completed stop"
}

# --- the mirror image: a legitimate recovery kill must still work -------------
test_authorized_supervisor_stop_succeeds() {
  local state victim out rc=0
  state=$(new_state authorized-stop)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$victim"
  out=$(run_safe_kill "$state" --pid "$victim" --role watcher --reason "operator-requested restart") || rc=$?
  [ "$rc" -eq 0 ] || fail "an authorized supervisor stop was refused (rc=$rc): $out"
  is_alive "$victim" && fail "the helper reported an exit while the process was still running"
  printf '%s' "$out" | grep -Fq 'exited after TERM' || fail "helper did not confirm the exit (got: $out)"
  wait "$victim" 2>/dev/null || true
  pass "a stop the watcher lock authorizes still succeeds"
}

test_daemon_role_stop_succeeds() {
  local state victim out rc=0
  state=$(new_state authorized-daemon-stop)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .supervise-daemon.lock supervise-daemon "$victim"
  out=$(run_safe_kill "$state" --pid "$victim" --role supervise-daemon --reason "away mode ending") || rc=$?
  [ "$rc" -eq 0 ] || fail "an authorized daemon stop was refused (rc=$rc): $out"
  is_alive "$victim" && fail "the helper reported an exit while the daemon was still running"
  wait "$victim" 2>/dev/null || true
  pass "a stop the daemon lock authorizes still succeeds"
}

test_every_outcome_is_recorded() {
  local state victim refused_pid
  state=$(new_state durable-record)
  start_sleeper; victim=$SLEEPER_PID
  publish_role_lock "$state" .watch.lock watcher "$victim"
  run_safe_kill "$state" --pid "$victim" --role watcher --reason "recorded stop" >/dev/null 2>&1 || true
  wait "$victim" 2>/dev/null || true
  start_sleeper; refused_pid=$SLEEPER_PID
  printf '%s\n' "$refused_pid" > "$state/.lock"
  publish_role_lock "$state" .watch.lock watcher "$refused_pid"
  run_safe_kill "$state" --pid "$refused_pid" --role watcher --reason "recorded refusal" >/dev/null 2>&1 || true
  kill "$refused_pid" 2>/dev/null || true
  wait "$refused_pid" 2>/dev/null || true
  [ -f "$state/.safe-kill.log" ] || fail "no durable record was written"
  grep -q 'outcome=exited' "$state/.safe-kill.log" || fail "the completed stop was not recorded"
  grep -q 'outcome=refused' "$state/.safe-kill.log" || fail "the refusal was not recorded"
  grep -q 'reason=recorded refusal' "$state/.safe-kill.log" || fail "the caller's reason was not recorded"
  pass "both the stop and the refusal leave a durable record"
}

test_refuses_the_session_lock_holder
test_refuses_when_the_role_lock_names_another_pid
test_refuses_self_and_ancestor
test_requires_a_role
test_refuses_when_no_role_lock_exists
test_refuses_a_reused_pid
test_refuses_another_home
test_a_lock_without_a_recorded_home_still_authorizes
test_refuses_pattern_selectors_at_the_interface
test_unknown_is_not_reported_as_success
test_authorized_supervisor_stop_succeeds
test_daemon_role_stop_succeeds
test_every_outcome_is_recorded
