#!/usr/bin/env bash
# tests/fm-session-identity.test.sh - session-id session-lock identity.
#
# This is GUARD-CLASS code, so every gate is tested in BOTH directions and the
# two directions are deliberately kept in separate tests:
#
#   REFUSE  - a session that does not own the home lock is refused, and every
#             uncertainty refuses. A mutant that weakens the comparison must
#             break one of these.
#   ADMIT   - a session that DOES own the home lock is never refused, including
#             after its process identity changed underneath it. A mutant that
#             refuses everything must break one of these instead.
#
# The second direction is not a nicety. A guard that refuses the legitimate case
# is the same failure one mirror over: it gets bypassed by the next person under
# time pressure, and then it protects nothing at all.
#
# docs/verification/session-identity.md carries the mutation table and the field
# measurements these fixtures were built from.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-identity)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Evaluate one library expression as session <id> ('' means a session whose id
# cannot be established). The ambient CLAUDE_CODE_SESSION_ID of whatever session
# runs this suite is stripped, so a real id can never leak in and accidentally
# satisfy a comparison these tests mean to fail.
as_session() {  # <session-id> <expression>
  local id=$1 expr=$2
  env -u CLAUDE_CODE_SESSION_ID -u FM_SESSION_ID \
    ${id:+FM_SESSION_ID="$id"} \
    bash -c ". \"\$0\"; $expr" "$LIB"
}

# A lock whose recorded pid is a live harness, without needing a real one: the
# fake ps reports the pid as a claude process and kill is stubbed. Used where a
# test must exercise the LIVE-holder branch rather than the stale one.
write_fake_ps() {  # <fakebin> <live-pid>
  local fakebin=$1 live=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
# pid 777 is the CALLER's own harness ancestor, so the ancestry walk resolves;
# $live is a second, unrelated harness that only the liveness predicate sees.
# The two are deliberately disjoint: that is the CLI/harness split in miniature.
case "\$pid:\$field" in
  $live:comm=|777:comm=) printf '%s\n' claude ;;
  $live:args=|777:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  $live:ppid=|777:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/some-tool.sh' ;;
  *:ppid=) printf '%s\n' 777 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# --- REFUSE: the identity comparison keeps refusing --------------------------

test_refuse_lock_naming_another_session() {
  local dir="$TMP_ROOT/refuse-other-session"
  mkdir -p "$dir/state"
  printf '12345\nsession=owner-aaa\n' > "$dir/state/.lock"
  if as_session intruder-bbb "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a session was admitted to a lock recorded for a DIFFERENT session"
  fi
  pass "identity: a lock recorded for another session refuses this one"
}

test_refuse_when_own_session_unestablishable() {
  local dir="$TMP_ROOT/refuse-no-self"
  mkdir -p "$dir/state"
  printf '12345\nsession=owner-aaa\n' > "$dir/state/.lock"
  if as_session '' "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a caller that cannot establish its own session id was admitted"
  fi
  pass "identity: a caller whose own session id is unestablishable refuses"
}

test_refuse_absent_and_malformed_locks() {
  local dir="$TMP_ROOT/refuse-malformed"
  mkdir -p "$dir/state"
  if as_session owner-aaa "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an absent lock was read as ownership"
  fi
  printf 'not-a-pid\nsession=owner-aaa\n' > "$dir/state/.lock"
  if as_session owner-aaa "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock whose pid line is not a pid was read as ownership"
  fi
  printf '\nsession=owner-aaa\n' > "$dir/state/.lock"
  if as_session owner-aaa "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock with an empty pid line was read as ownership"
  fi
  pass "identity: an absent lock and a malformed pid line both refuse"
}

test_refuse_unreadable_session_line() {
  local dir="$TMP_ROOT/refuse-bad-session"
  mkdir -p "$dir/state"
  # A session line that cannot be a session id must not be normalized into one,
  # and must not silently demote the lock to the legacy ancestry basis either -
  # that would be a downgrade any writer could trigger.
  printf '12345\nsession=owner aaa\n' > "$dir/state/.lock"
  if as_session 'owner aaa' "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a malformed session line was matched instead of refused"
  fi
  printf '12345\nsession=\n' > "$dir/state/.lock"
  if as_session '' "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an empty session line was matched instead of refused"
  fi
  pass "identity: a malformed or empty session line refuses rather than matching"
}

# --- ADMIT: the legitimate session is never refused ---------------------------

test_admit_same_session_across_changed_process_identity() {
  local dir="$TMP_ROOT/admit-deadlock-specimen"
  mkdir -p "$dir/state"
  # THE SPECIMEN. In the 2026-08-05 deadlock the lock held pid 3638271 - the
  # captain's own live CLI - while the same session's harness ran as pid 849887
  # behind a bg-pty-host, on ancestry the CLI could not be reached from. Neither
  # process appears in the other's ancestry here either: the fake ps reports a
  # tree containing NEITHER pid, so an ancestry-based answer is impossible and
  # only the session id can decide.
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  write_fake_ps "$fakebin" 3638271
  printf '3638271\nsession=84f6cde6\n' > "$dir/state/.lock"
  PATH="$fakebin:$PATH" as_session 84f6cde6 "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the lock's OWN session was refused because its process identity changed - this is the deadlock"
  pass "identity: a session owns its lock across a changed process identity"
}

test_admit_legacy_session_less_lock_by_ancestry() {
  local dir="$TMP_ROOT/admit-legacy"
  local fakebin got
  mkdir -p "$dir/state"
  fakebin=$(fm_fakebin "$dir")
  # A tree whose harness ancestor is discoverable from the caller, so the legacy
  # basis has something to resolve.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  555:comm=) printf '%s\n' claude ;;
  555:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  555:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=) printf '%s\n' 555 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '555\n' > "$dir/state/.lock"
  got=$(PATH="$fakebin:$PATH" as_session '' "fm_session_lock_session '$dir/state' || echo NONE")
  [ "$got" = NONE ] || fail "a session-less lock reported a session id: got '$got'"
  # A lock written before this contract must be neither newly refused nor newly
  # admitted: the legacy ancestry basis still decides it, in both directions.
  PATH="$fakebin:$PATH" as_session '' "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "a session-less lock refused the session in its own ancestry, breaking pre-contract homes"
  printf '999\n' > "$dir/state/.lock"
  if PATH="$fakebin:$PATH" as_session '' "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a session-less lock admitted a session outside its ancestry"
  fi
  pass "identity: a lock recording no session is still decided by the legacy ancestry basis, both ways"
}

# --- the lock record: bin/fm-lock.sh -----------------------------------------

run_lock() {  # <home> <session-id> [arg]
  local home=$1 id=$2
  shift 2
  env -u CLAUDE_CODE_SESSION_ID -u FM_SESSION_ID \
    ${id:+CLAUDE_CODE_SESSION_ID="$id"} \
    FM_HOME="$home" bash "$ROOT/bin/fm-lock.sh" "$@" 2>&1
}

test_lock_records_pid_then_session() {
  local home="$TMP_ROOT/lock-record" out
  mkdir -p "$home/state"
  out=$(run_lock "$home" sess-aaa) || fail "acquiring a free lock failed: $out"
  [ "$(sed -n 2p "$home/state/.lock")" = "session=sess-aaa" ] \
    || fail "the lock did not record the session on line 2: got '$(sed -n 2p "$home/state/.lock")'"
  case "$(sed -n 1p "$home/state/.lock")" in
    ''|*[!0-9]*) fail "line 1 of the lock is not a pid: '$(sed -n 1p "$home/state/.lock")'" ;;
  esac
  [ "$(wc -l < "$home/state/.lock")" -eq 2 ] || fail "the lock record grew beyond its two lines"
  assert_contains "$out" 'sess-aaa' "acquisition should name the session it recorded"
  pass "lock: records the harness pid on line 1 and the session on line 2"
}

test_lock_is_reacquired_by_its_own_session() {
  local home="$TMP_ROOT/lock-reacquire" out status other fakebin
  mkdir -p "$home/state"
  # THE DEADLOCK, at the acquisition boundary. The recorded holder must be a
  # process that is ALIVE and that reads as a real harness - in the field it was
  # the captain's own live `claude` CLI - because a dead or non-harness holder
  # takes the ordinary stale-takeover path and proves nothing about identity.
  # The session id on the lock is ours; only the process identity moved.
  bash -c 'sleep 30; :' &
  other=$!
  fakebin=$(fm_fakebin "$home")
  write_fake_ps "$fakebin" "$other"
  printf '%s\nsession=sess-aaa\n' "$other" > "$home/state/.lock"
  out=$(PATH="$fakebin:$PATH" run_lock "$home" sess-aaa); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$status" -eq 0 ] \
    || fail "a session could not reacquire its OWN lock while a live process held its old identity - this is the deadlock: $out"
  [ "$(sed -n 2p "$home/state/.lock")" = "session=sess-aaa" ] \
    || fail "reacquisition lost the session record"
  [ "$(sed -n 1p "$home/state/.lock")" != "$other" ] \
    || fail "reacquisition left the superseded process identity on the lock"
  pass "lock: a session reacquires its own lock while a live process still holds its old identity"
}

test_lock_refuses_a_different_live_session() {
  local home="$TMP_ROOT/lock-refuse" out status other
  mkdir -p "$home/state"
  # A real live process that the harness-liveness predicate accepts. bash -c
  # with a trailing no-op keeps a shell (not an exec'd sleep) as the process.
  bash -c 'sleep 30; :' &
  other=$!
  # Name it as the holder, and give the holder a different session.
  printf '%s\nsession=sess-other\n' "$other" > "$home/state/.lock"
  # Shadow the liveness check's view so this ordinary shell reads as a harness.
  local fakebin
  fakebin=$(fm_fakebin "$home")
  write_fake_ps "$fakebin" "$other"
  out=$(PATH="$fakebin:$PATH" run_lock "$home" sess-mine); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 1 "$status" "acquisition must refuse while another live session holds the lock"
  assert_contains "$out" 'another live firstmate session' "the refusal must name the conflict"
  [ "$(sed -n 2p "$home/state/.lock")" = "session=sess-other" ] \
    || fail "the refused acquisition overwrote the live holder's record"
  pass "lock: a live holder naming another session is refused, and its record is left intact"
}

test_lock_without_a_session_id_stays_on_the_pid_basis() {
  local home="$TMP_ROOT/lock-no-session" out
  mkdir -p "$home/state"
  out=$(run_lock "$home" '') || fail "a harness publishing no session id could not acquire the lock: $out"
  [ "$(wc -l < "$home/state/.lock")" -eq 1 ] \
    || fail "a lock written without a session id gained a session line anyway"
  [ "$(run_lock "$home" '' status)" != "lock: unreadable" ] || fail "status could not read a pid-only lock"
  pass "lock: a harness publishing no session id still acquires, on the unchanged pid basis"
}

# --- line 1 stays a pid: bin/fm-safe-kill.sh ----------------------------------

test_safe_kill_still_refuses_the_lock_holder() {
  local home="$TMP_ROOT/safe-kill" out status target
  mkdir -p "$home/state"
  bash -c 'sleep 30; :' &
  target=$!
  # The trap this fixture exists for: fm-safe-kill.sh once read the lock file
  # WHOLE. Adding the session line would have made that read stop matching any
  # pid, silently turning its refusal into permission to signal a live session.
  printf '%s\nsession=sess-aaa\n' "$target" > "$home/state/.lock"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-safe-kill.sh" \
    --pid "$target" --role watcher --reason 'session-identity fixture' 2>&1); status=$?
  kill "$target" 2>/dev/null || true
  wait "$target" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "safe-kill signalled the session-lock holder: $out"
  assert_contains "$out" 'holds this home' "safe-kill must refuse ON THE LOCK, not incidentally on some later check"
  pass "safe-kill: still refuses the lock's pid once the record carries a session line"
}

# --- the refusal branch records its refusal ----------------------------------

install_autoarm_home() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/state" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  for f in fm-claude-stop-autoarm.sh fm-lock.sh fm-primary-scope-lib.sh \
    fm-supervision-lib.sh fm-wake-lib.sh fm-session-lock-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # An arm wrapper that would leave a trace if it ever ran. It must not.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/arm-ran"
printf 'heartbeat\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  : > "$dir/state/task.meta"
  printf '%s\n' "$dir"
}

run_autoarm() {  # <dir> <payload-session>
  local dir=$1 id=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"session_id":"%s"}' "$id" \
    | env -u CLAUDE_CODE_SESSION_ID -u FM_SESSION_ID \
      FM_HOME="$home" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1
}

test_identity_refusal_is_recorded() {
  local dir out status other fakebin
  dir=$(install_autoarm_home "$TMP_ROOT/refusal-recorded")
  bash -c 'sleep 30; :' &
  other=$!
  fakebin=$(fm_fakebin "$dir")
  write_fake_ps "$fakebin" "$other"
  # A live holder that names a DIFFERENT session than the Stop payload does.
  printf '%s\nsession=owner-aaa\n' "$other" > "$dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" intruder-bbb); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "an identity refusal must not force a continuation"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed supervision for a session it does not own"
  [ "$(sed -n 2p "$dir/state/.lock")" = "session=owner-aaa" ] \
    || fail "the refusing hook overwrote the owner's lock record"
  # THE CAPTAIN'S FIXTURE. A refusal is an outcome. Exiting 0 having written
  # nothing is what made the turn-end guard's escape unreachable, because the
  # escape is keyed on evidence the silent branch never produced.
  grep -q 'outcome=refused' "$dir/state/.claude-autoarm-epoch" 2>/dev/null \
    || fail "the identity refusal wrote no refused epoch: $(cat "$dir/state/.claude-autoarm-epoch" 2>/dev/null || echo '<no epoch at all>')"
  [ -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || fail "the identity refusal raised no operator notice"
  assert_contains "$out" 'REFUSED' "the refusal must name itself"
  assert_contains "$out" 'owner-aaa' "the refusal must name the session that does own the home"
  pass "refusal: an identity refusal is recorded as an outcome instead of exiting 0 in silence"
}

test_refusal_record_waits_for_the_need_gate() {
  local dir out status other fakebin
  dir=$(install_autoarm_home "$TMP_ROOT/refusal-idle")
  rm -f "$dir/state/task.meta"
  bash -c 'sleep 30; :' &
  other=$!
  fakebin=$(fm_fakebin "$dir")
  write_fake_ps "$fakebin" "$other"
  printf '%s\nsession=owner-aaa\n' "$other" > "$dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" intruder-bbb); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "an idle home must stay inert"
  # Recording a refusal is owed only when the refusal actually withholds
  # something. An idle home is not blocked by it, so it stays byte-for-byte
  # inert - otherwise every Stop of every unowned idle home churns state and
  # raises a notice nobody needs.
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] \
    || fail "an idle home recorded a refusal that withheld nothing"
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || fail "an idle home raised an operator notice"
  pass "refusal: an idle home records nothing, because its refusal withholds nothing"
}

# --- the recorded refusal keeps the guard's escape reachable ------------------
#
# The captain's acceptance fixture: prove the refusal branch RECORDS its refusal
# and that the record is load-bearing. Both worlds are run, because the value of
# the record is only visible against the world without it.

install_guard_home() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/state" "$dir/bin" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  for f in fm-turnend-guard.sh fm-supervision-instructions.sh fm-harness.sh \
    fm-operational-input.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-supervision-instructions.sh" \
    "$dir/bin/fm-harness.sh" "$dir/bin/fm-operational-input.sh"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  : > "$dir/state/task.meta"
  printf '%s\n' "$dir"
}

run_guard() {  # <dir>
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  printf '{"session_id":"sess-aaa","stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" --claude 2>&1
}

# Stand in for the refusing auto-arm: one fresh refused epoch per Stop event,
# exactly what bin/fm-claude-stop-autoarm.sh now writes on an identity refusal.
write_refused_epoch() {  # <dir> <seq>
  printf 'epoch=%s owner_pid=1 outcome=refused updated_at=%s\n' "$2" "$(date +%s)" \
    > "$1/state/.claude-autoarm-epoch"
  : > "$1/state/.claude-autoarm-failure-notified"
}

test_recorded_refusal_reaches_the_bounded_escape() {
  local dir seq out status escaped=0
  dir=$(install_guard_home "$TMP_ROOT/escape-recorded")
  for seq in 1 2 3 4 5; do
    write_refused_epoch "$dir" "$seq"
    out=$(run_guard "$dir"); status=$?
    if [ "$status" -eq 0 ]; then
      escaped=$seq
      break
    fi
    [ "$status" -eq 2 ] || fail "turn $seq: unexpected guard status $status"
    assert_contains "$out" 'REFUSED' "turn $seq: the block must report a refusal, not an absent auto-arm"
  done
  [ "$escaped" -ne 0 ] || fail "a recorded refusal never reached the bounded escape across five turns"
  [ "$escaped" -gt 1 ] || fail "the escape fired on the first turn; the block budget was not spent at all"
  assert_contains "$out" 'SUPERVISION IS GENUINELY DOWN' "the escape must announce itself loudly"
  [ -e "$dir/state/.claude-autoarm-failure-alarmed" ] \
    || fail "the escape fired without arming the alarm that bounds it to one per episode"
  pass "recorded refusal: a refused epoch spends the block budget and then reaches the bounded escape"
}

test_silent_refusal_freezes_the_escape() {
  local dir turn out status
  dir=$(install_guard_home "$TMP_ROOT/escape-silent")
  # The world before this change, reproduced from the measurement: the refusing
  # branch exits 0 having written nothing, so the epoch stays frozen at a stale
  # rewake and no failure is ever notified. Measured on 2026-08-05 as
  # count=1 / epoch=1778 / outcome=rewake / notified=no, unchanged across three
  # consecutive blocks.
  printf 'epoch=1778 owner_pid=1 outcome=rewake updated_at=1\n' \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  for turn in 1 2 3 4 5; do
    out=$(run_guard "$dir"); status=$?
    [ "$status" -eq 2 ] \
      || fail "turn $turn: a silent refusal reached an escape it must not have (status $status): $out"
  done
  [ "$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")" = 1 ] \
    || fail "the frozen-epoch world did not reproduce: the block counter moved"
  [ ! -e "$dir/state/.claude-autoarm-failure-alarmed" ] \
    || fail "an unrecorded refusal armed the escape"
  pass "recorded refusal: without the record the counter freezes and the escape stays unreachable"
}

test_refuse_lock_naming_another_session
test_refuse_when_own_session_unestablishable
test_refuse_absent_and_malformed_locks
test_refuse_unreadable_session_line
test_admit_same_session_across_changed_process_identity
test_admit_legacy_session_less_lock_by_ancestry
test_lock_records_pid_then_session
test_lock_is_reacquired_by_its_own_session
test_lock_refuses_a_different_live_session
test_lock_without_a_session_id_stays_on_the_pid_basis
test_safe_kill_still_refuses_the_lock_holder
test_identity_refusal_is_recorded
test_refusal_record_waits_for_the_need_gate
test_recorded_refusal_reaches_the_bounded_escape
test_silent_refusal_freezes_the_escape
