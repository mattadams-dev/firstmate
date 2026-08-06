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
  local home="$TMP_ROOT/lock-record" out fakebin
  mkdir -p "$home/state"
  # The real fm-lock.sh needs a harness ancestor to resolve, and needs that
  # ancestor to read as Claude Code before it will record a session line at all.
  # Both are properties of whatever process happens to run this suite, so they
  # are supplied deterministically here - CI's runners have neither.
  fakebin=$(fm_fakebin "$home")
  write_fake_ps "$fakebin" 654321
  out=$(PATH="$fakebin:$PATH" run_lock "$home" sess-aaa) || fail "acquiring a free lock failed: $out"
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
  local home="$TMP_ROOT/lock-no-session" out fakebin
  mkdir -p "$home/state"
  # Same reason as above: the ancestry the real fm-lock.sh walks is supplied
  # rather than borrowed from whatever process runs this suite.
  fakebin=$(fm_fakebin "$home")
  write_fake_ps "$fakebin" 654321
  out=$(PATH="$fakebin:$PATH" run_lock "$home" '') \
    || fail "a harness publishing no session id could not acquire the lock: $out"
  [ "$(wc -l < "$home/state/.lock")" -eq 1 ] \
    || fail "a lock written without a session id gained a session line anyway"
  [ "$(PATH="$fakebin:$PATH" run_lock "$home" '' status)" != "lock: unreadable" ] \
    || fail "status could not read a pid-only lock"
  pass "lock: a harness publishing no session id still acquires, on the unchanged pid basis"
}

test_lock_ignores_an_inherited_session_id_on_another_harness() {
  local home="$TMP_ROOT/lock-inherited" fakebin out
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  # A non-Claude primary. Firstmate launches other harnesses from inside a
  # Claude tool call, so CLAUDE_CODE_SESSION_ID is inherited into this session's
  # environment while naming a session in a completely different home.
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
  888:comm=) printf '%s\n' /opt/kimi/bin/kimi ;;
  888:args=) printf '%s\n' kimi ;;
  888:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' 888 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" run_lock "$home" someone-elses-session) \
    || fail "a non-Claude primary could not acquire its lock: $out"
  [ "$(wc -l < "$home/state/.lock")" -eq 1 ] \
    || fail "a non-Claude primary recorded an inherited session id: $(sed -n 2p "$home/state/.lock")"
  pass "lock: a non-Claude primary does not record an inherited Claude session id"
}

# A bare-interpreter harness whose ARGUMENTS mention Claude. The provenance test
# is keyed on the harness script path, not on any occurrence of the string, so a
# `--model claude-...` flag must not make an OpenCode primary record the Claude
# session id it inherited from the tool call that launched it - while a genuine
# node-launched Claude Code install must still be recognized as one.
write_interpreter_ps() {  # <fakebin> <argv-string>
  local fakebin=$1 argv=$2
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
case "\$pid:\$field" in
  888:comm=) printf '%s\n' node ;;
  888:args=) printf '%s\n' '$argv' ;;
  888:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' 888 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_lock_ignores_a_claude_model_flag_on_a_bare_interpreter() {
  local home="$TMP_ROOT/lock-model-flag" fakebin out
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  write_interpreter_ps "$fakebin" \
    '/usr/bin/node /opt/opencode/bin/opencode --model claude-sonnet-4-20250514'
  out=$(PATH="$fakebin:$PATH" run_lock "$home" someone-elses-session) \
    || fail "a node-launched OpenCode primary could not acquire its lock: $out"
  [ "$(wc -l < "$home/state/.lock")" -eq 1 ] \
    || fail "a --model claude-... flag made an OpenCode primary record an inherited Claude session id: $(sed -n 2p "$home/state/.lock")"
  pass "lock: a Claude model flag on a bare-interpreter harness does not make it Claude Code"
}

test_lock_records_a_node_launched_claude_install() {
  local home="$TMP_ROOT/lock-node-claude" fakebin out
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  # The mirror direction: tightening the provenance test must not stop a real
  # node-launched Claude Code from recording its own session.
  write_interpreter_ps "$fakebin" \
    '/usr/bin/node /home/u/.local/share/claude/versions/2.1.223/cli.js --resume'
  out=$(PATH="$fakebin:$PATH" run_lock "$home" sess-node) \
    || fail "a node-launched Claude Code primary could not acquire its lock: $out"
  [ "$(sed -n 2p "$home/state/.lock")" = "session=sess-node" ] \
    || fail "a node-launched Claude Code primary recorded no session: got '$(sed -n 2p "$home/state/.lock")'"
  pass "lock: a node-launched Claude Code install still records its own session id"
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

# --- the refusal record is the HOME's, so it may not clobber a fresher one ----
#
# Both directions again, and deliberately in separate tests. The epoch ledger and
# the failure notice are shared by every session whose Stop fires in this home,
# and a refusing session holds no owner lock, so the two failures are:
#
#   CLOBBER  - a bystander's refusal overwrites the OWNER's fresh record, which
#              then blocks the owner's own turn and tells it to hand back a home
#              it already owns. Not more permissive, but just as much a break of
#              the refusal bias, arriving from the mirror direction.
#   SILENCE  - a refusal that owes a record fails to write one, which starves the
#              guard's bounded escape exactly as the 2026-08-05 deadlock did.

test_refusal_does_not_clobber_a_fresher_owner_epoch() {
  local dir out status other fakebin before after
  dir=$(install_autoarm_home "$TMP_ROOT/refusal-no-clobber")
  bash -c 'sleep 30; :' &
  other=$!
  fakebin=$(fm_fakebin "$dir")
  write_fake_ps "$fakebin" "$other"
  printf '%s\nsession=owner-aaa\n' "$other" > "$dir/state/.lock"
  # The OWNER's own auto-arm has just recorded a fresh rewake for this event
  # epoch; a bystander session's Stop then fires into the same home.
  printf 'epoch=41 owner_pid=%s outcome=rewake updated_at=%s\n' "$other" "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
  before=$(cksum < "$dir/state/.claude-autoarm-epoch")
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" intruder-bbb); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  after=$(cksum < "$dir/state/.claude-autoarm-epoch")
  expect_code 0 "$status" "a declined refusal must still exit 0"
  [ "$before" = "$after" ] \
    || fail "a bystander refusal overwrote the owner's fresher epoch, which blocks the OWNER's next turn: now $(cat "$dir/state/.claude-autoarm-epoch")"
  # The notice matters as much as the epoch: it is what suppresses the owner's
  # block-budget reset in bin/fm-turnend-guard.sh.
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || fail "a bystander refusal raised the notice that suppresses the owner's budget reset"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed supervision for a session it does not own"
  pass "refusal: a bystander refusal declines to clobber the owner's fresher non-refused epoch"
}

test_refusal_still_records_over_a_refused_or_stale_epoch() {
  local dir out status other fakebin seq
  dir=$(install_autoarm_home "$TMP_ROOT/refusal-records-over")
  bash -c 'sleep 30; :' &
  other=$!
  fakebin=$(fm_fakebin "$dir")
  write_fake_ps "$fakebin" "$other"
  printf '%s\nsession=owner-aaa\n' "$other" > "$dir/state/.lock"
  # Refusal over an EQUALLY-refusing epoch. This is the load-bearing half: the
  # guard's bounded escape advances on fresh epochs, so a refusal that could not
  # replace a refusal would make that escape unreachable again.
  printf 'epoch=7 owner_pid=1 outcome=refused updated_at=%s\n' "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" intruder-bbb); status=$?
  expect_code 0 "$status" "a recorded refusal must not force a continuation"
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$dir/state/.claude-autoarm-epoch")
  [ "$seq" = 8 ] \
    || fail "a refusal did not advance an equally-refusing epoch: $(cat "$dir/state/.claude-autoarm-epoch")"
  grep -q 'outcome=refused' "$dir/state/.claude-autoarm-epoch" \
    || fail "refusal-over-refusal lost the outcome: $(cat "$dir/state/.claude-autoarm-epoch")"
  # Refusal over a STALE non-refused epoch. Staleness is exactly what makes the
  # other session's record no longer current, so the refusal owes its own again.
  rm -f "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=20 owner_pid=1 outcome=rewake updated_at=1\n' \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" intruder-bbb); status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "a recorded refusal must not force a continuation"
  grep -q 'outcome=refused' "$dir/state/.claude-autoarm-epoch" \
    || fail "a refusal did not record over a STALE non-refused epoch: $(cat "$dir/state/.claude-autoarm-epoch")"
  [ -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || fail "a refusal over a stale epoch raised no operator notice"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed supervision for a session it does not own"
  pass "refusal: a refusal still records over an equally-refusing or stale epoch"
}

# --- a failed ACQUISITION is a different observed world from a refusal --------

test_recovery_failure_records_a_distinct_outcome() {
  local dir out status fakebin
  dir=$(install_autoarm_home "$TMP_ROOT/acquire-failed")
  fakebin=$(fm_fakebin "$dir")
  # No harness anywhere in the ancestry, so the delegated bin/fm-lock.sh cannot
  # resolve one and the reacquisition fails. The recorded owner is demonstrably
  # dead, so this is NOT "another session owns this home": it is an unowned home
  # this session could not take, and telling the operator to reacquire the lock
  # would send them after something that was just attempted and failed.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' bash ;;
  args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '9999999\nsession=dead-owner\n' > "$dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" run_autoarm "$dir" sess-bbb); status=$?
  expect_code 0 "$status" "a failed acquisition must not force a continuation"
  [ ! -e "$dir/state/arm-ran" ] || fail "the hook armed after failing to acquire the home"
  grep -q 'outcome=acquire-failed' "$dir/state/.claude-autoarm-epoch" 2>/dev/null \
    || fail "a failed acquisition was not recorded distinctly from a refusal: $(cat "$dir/state/.claude-autoarm-epoch" 2>/dev/null || echo '<no epoch at all>')"
  # Without the notice the guard's failure_episode_verified never passes, so the
  # bounded escape is starved exactly as it was before the recorded refusal.
  [ -e "$dir/state/.claude-autoarm-failure-notified" ] \
    || fail "a failed acquisition raised no operator notice, so the bounded escape stays starved"
  assert_contains "$out" 'ACQUIRE' "the notice must name what was actually observed"
  pass "acquisition failure: recorded as its own outcome with its own notice, not as a refusal"
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
  # The LAST message before the session is allowed to end blind must describe
  # what was observed. Nothing was retried and the hook is not broken here.
  assert_contains "$out" 'REFUSED this home' "the terminal message must name the refusal it observed"
  assert_not_contains "$out" 'exhausted its bounded retries' \
    "the terminal message blamed retries that never ran"
  assert_not_contains "$out" 'diagnose the automatic Stop-hook' \
    "the terminal message sent the operator after a hook that is working"
  [ -e "$dir/state/.claude-autoarm-failure-alarmed" ] \
    || fail "the escape fired without arming the alarm that bounds it to one per episode"
  pass "recorded refusal: a refused epoch spends the block budget and then reaches the bounded escape"
}

# Stand in for the auto-arm that could not TAKE an unowned home: one fresh
# acquire-failed epoch per Stop event, distinct from the refusal above.
write_acquire_failed_epoch() {  # <dir> <seq>
  printf 'epoch=%s owner_pid=1 outcome=acquire-failed updated_at=%s\n' "$2" "$(date +%s)" \
    > "$1/state/.claude-autoarm-epoch"
  : > "$1/state/.claude-autoarm-failure-notified"
}

test_recovery_failure_reaches_the_bounded_escape() {
  local dir seq out status escaped=0
  dir=$(install_guard_home "$TMP_ROOT/escape-acquire-failed")
  for seq in 1 2 3 4 5; do
    write_acquire_failed_epoch "$dir" "$seq"
    out=$(run_guard "$dir"); status=$?
    if [ "$status" -eq 0 ]; then
      escaped=$seq
      break
    fi
    [ "$status" -eq 2 ] || fail "turn $seq: unexpected guard status $status"
    assert_contains "$out" 'could not ACQUIRE' \
      "turn $seq: the block must report a failed acquisition, not an absent auto-arm"
    assert_not_contains "$out" 'REFUSED' \
      "turn $seq: a failed acquisition must not be reported as another session owning the home"
  done
  [ "$escaped" -ne 0 ] \
    || fail "a recorded acquisition failure never reached the bounded escape across five turns"
  [ "$escaped" -gt 1 ] || fail "the escape fired on the first turn; the block budget was not spent at all"
  assert_contains "$out" 'SUPERVISION IS GENUINELY DOWN' "the escape must announce itself loudly"
  assert_contains "$out" 'could not ACQUIRE' "the terminal message must describe the world that was observed"
  assert_not_contains "$out" 'exhausted its bounded retries' \
    "the terminal message blamed retries that never ran"
  [ -e "$dir/state/.claude-autoarm-failure-alarmed" ] \
    || fail "the escape fired without arming the alarm that bounds it to one per episode"
  pass "acquisition failure: an acquire-failed epoch spends the block budget and then reaches the bounded escape"
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
test_lock_ignores_an_inherited_session_id_on_another_harness
test_lock_ignores_a_claude_model_flag_on_a_bare_interpreter
test_lock_records_a_node_launched_claude_install
test_safe_kill_still_refuses_the_lock_holder
test_identity_refusal_is_recorded
test_refusal_record_waits_for_the_need_gate
test_refusal_does_not_clobber_a_fresher_owner_epoch
test_refusal_still_records_over_a_refused_or_stale_epoch
test_recovery_failure_records_a_distinct_outcome
test_recorded_refusal_reaches_the_bounded_escape
test_recovery_failure_reaches_the_bounded_escape
test_silent_refusal_freezes_the_escape
