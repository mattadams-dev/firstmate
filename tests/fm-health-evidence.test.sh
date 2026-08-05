#!/usr/bin/env bash
# tests/fm-health-evidence.test.sh - the wedge-alarm ratchet, both directions.
#
# The alarm must be able to count back down on PROVEN health, and it must never
# count down on anything else. Those are mirror-image failures: one leaves a
# healthy lane permanently under deep inspection, the other pardons the exact
# slow wedge the alarm exists to catch. Each gets its own fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-health-evidence-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-health-evidence-tests)

# shellcheck source=bin/fm-health-evidence-lib.sh
. "$LIB"

# Sets CMP_RC. Deliberately NOT a command substitution: fm_health_compare
# publishes FM_HEALTH_ADVANCED, and a subshell would swallow it - the same class
# of mistake as computing an identity inside one.
CMP_RC=0
compare() {  # <prev> <cur>
  CMP_RC=0
  fm_health_compare "$1" "$2" || CMP_RC=$?
}


# --- drivers -----------------------------------------------------------------
#
# Both drivers substitute exactly ONE thing: fm_health_target_pid, the backend
# call that resolves a pane to a process. Everything downstream of it runs for
# real - the /proc reads, the tree walk, the sample comparison - against a live
# process whose CPU genuinely advances. That is the difference between this and
# the version the review found vacuous, where a fake backend made the evidence
# unreadable and every assertion passed for a reason unrelated to its subject.
# The pane a driver observes. Each test picks the process that matches what it
# claims to be observing, because "frozen" and "advancing" must be properties of
# the subject rather than of how loaded the host happens to be.
#
# This defaulted to the test shell itself, which is a live process doing work:
# the frozen-pane assertions then passed only while the harness happened to burn
# less than one clock tick between two calls, and failed under a full-suite
# sweep. A test whose verdict depends on ambient load is not measuring what it
# says it measures.
PANE_PID=
BURNER_PID=
IDLE_PID=
start_panes() {
  bash -c 'while :; do :; done' >/dev/null 2>&1 &
  BURNER_PID=$!
  sleep 600 >/dev/null 2>&1 &
  IDLE_PID=$!
  PANE_PID=$IDLE_PID
}
stop_panes() {
  local p
  for p in "$BURNER_PID" "$IDLE_PID"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  BURNER_PID=
  IDLE_PID=
  PANE_PID=
}

# run_reset_driver <dir> <state> <win> <key> <rendered>
run_reset_driver() {
  local dir=$1 state=$2 win=$3 key=$4 rendered=$5
  cat > "$dir/reset-driver.sh" <<DRIVER
#!/usr/bin/env bash
set -u
STATE="$state"
. "$ROOT/bin/fm-health-evidence-lib.sh"
window_backend() { printf 'none\n'; }
fm_health_target_pid() { printf '%s\n' "\$FM_TEST_PANE_PID"; }
triage_log() { printf '%s\n' "\$*" >> "$state/.watch-triage.log"; }
$(sed -n '/^health_evidence_reset()/,/^}/p' "$ROOT/bin/fm-watch.sh")
health_evidence_reset "$win" "\$1" "$state/.stale-since-$key" "$state/.wedge-escalations-$key"
printf 'rc=%s\n' "\$?"
DRIVER
  chmod +x "$dir/reset-driver.sh"
  FM_TEST_PANE_PID="$PANE_PID" "$dir/reset-driver.sh" "$rendered"
}

# run_timer_driver <dir> <state> <win> <key> <subject> <rendered>
run_timer_driver() {
  local dir=$1 state=$2 win=$3 key=$4 subject=$5 rendered=$6
  cat > "$dir/timer-driver.sh" <<DRIVER
#!/usr/bin/env bash
set -u
STATE="$state"
STALE_ESCALATE_SECS=1
FM_WEDGE_DEMAND_INSPECT_COUNT=3
. "$ROOT/bin/fm-health-evidence-lib.sh"
window_backend() { printf 'none\n'; }
fm_health_target_pid() { printf '%s\n' "\$FM_TEST_PANE_PID"; }
triage_log() { printf '%s\n' "\$*" >> "$state/.watch-triage.log"; }
fm_wake_append() { return 0; }
wake() { printf 'woke: %s\n' "\$1"; }
$(sed -n '/^health_evidence_reset()/,/^}/p' "$ROOT/bin/fm-watch.sh")
$(sed -n '/^wedge_timer_check()/,/^}/p' "$ROOT/bin/fm-watch.sh")
wedge_timer_check "$win" "$state/.stale-since-$key" test-label "$state/.wedge-escalations-$key" "\$1" "\$2"
printf 'rc=%s\n' "\$?"
DRIVER
  chmod +x "$dir/timer-driver.sh"
  FM_TEST_PANE_PID="$PANE_PID" "$dir/timer-driver.sh" "$subject" "$rendered"
}

# --- health resets: each signal on its own -----------------------------------
#
# ANY ONE advancing is a healthy worker, because each signal sees through a
# blind spot of the others.
test_each_signal_alone_proves_health() {
  local rc
  compare 'rendered=aaa cpu=100 children=3' 'rendered=bbb cpu=100 children=3'; rc=$CMP_RC
  [ "$rc" = 0 ] || fail "rendered output advancing was not treated as health (rc=$rc)"
  [ "$FM_HEALTH_ADVANCED" = rendered ] || fail "advance was not attributed to rendered (got '$FM_HEALTH_ADVANCED')"

  compare 'rendered=aaa cpu=100 children=3' 'rendered=aaa cpu=117 children=3'; rc=$CMP_RC
  [ "$rc" = 0 ] || fail "CPU advancing behind a static pane was not treated as health (rc=$rc)"

  compare 'rendered=aaa cpu=100 children=1' 'rendered=aaa cpu=100 children=4'; rc=$CMP_RC
  [ "$rc" = 0 ] || fail "new live children behind a static pane were not treated as health (rc=$rc)"
  pass "each health signal alone resets the alarm, including behind a completely static pane"
}

# The measured specimen: a lane the instrument was calling a possible wedge
# while its CPU climbed 08:14 -> 08:31 under a bounded test sweep, with the pane
# frozen throughout.
test_the_measured_specimen_reads_as_health() {
  local before after rc
  before="rendered=$(printf 'static' | md5sum | cut -d' ' -f1) cpu=49400 children=7"
  after="rendered=$(printf 'static' | md5sum | cut -d' ' -f1) cpu=51100 children=7"
  compare "$before" "$after"; rc=$CMP_RC
  [ "$rc" = 0 ] || fail "the measured healthy-lane specimen did not read as health (rc=$rc)"
  [ "$FM_HEALTH_ADVANCED" = cpu ] || fail "specimen health was not attributed to CPU (got '$FM_HEALTH_ADVANCED')"
  pass "the measured healthy-lane specimen resets the alarm on CPU alone"
}

# --- the load-bearing constraint: time is never a signal ----------------------
test_a_frozen_lane_is_never_pardoned() {
  local frozen rc
  frozen='rendered=aaa cpu=100 children=3'
  compare "$frozen" "$frozen"; rc=$CMP_RC
  [ "$rc" = 1 ] || fail "a lane frozen on all three signals was not reported as no-evidence (rc=$rc)"
  [ -z "$FM_HEALTH_ADVANCED" ] || fail "a frozen lane reported an advance ('$FM_HEALTH_ADVANCED')"
  pass "a lane frozen on all three signals is never pardoned, however long it stays frozen"
}

# A shrinking tree is a restart or a reap, not work performed. Counting it as
# health would let a dying lane clear its own alarm.
test_a_receding_counter_is_not_health() {
  local rc
  compare 'rendered=aaa cpu=900 children=9' 'rendered=aaa cpu=400 children=2'; rc=$CMP_RC
  [ "$rc" = 1 ] || fail "a receding CPU/child count was treated as health (rc=$rc)"
  pass "a receding counter is not health"
}

# --- unknown is neither health nor alarm -------------------------------------
test_unreadable_signals_are_unknown() {
  local rc
  compare 'rendered=? cpu=? children=?' 'rendered=? cpu=? children=?'; rc=$CMP_RC
  [ "$rc" = 2 ] || fail "wholly unreadable samples were not reported as unknown (rc=$rc)"
  compare '' 'rendered=aaa cpu=1 children=1'; rc=$CMP_RC
  [ "$rc" = 2 ] || fail "a first sample with no predecessor was not unknown (rc=$rc)"
  # A partially readable sample is still decidable on the part that is readable.
  compare 'rendered=aaa cpu=? children=?' 'rendered=bbb cpu=? children=?'; rc=$CMP_RC
  [ "$rc" = 0 ] || fail "a readable component was ignored because its siblings were unreadable (rc=$rc)"
  pass "unknown is reported as unknown, and never collapsed into health or alarm"
}

# --- the end-to-end ratchet, through the watcher's own reset path ------------
#
# Drives bin/fm-watch.sh's health_evidence_reset directly with a fake backend so
# the sampling, the reset, and the logged transition are exercised together.
test_ratchet_resets_and_logs_the_transition() {
  local dir state key win rc log
  dir="$TMP_ROOT/ratchet"
  state="$dir/state"
  mkdir -p "$state"
  win='lab:w1:p1'
  key=$(printf '%s' "$win" | tr ':/.' '___')
  PANE_PID=$IDLE_PID   # a genuinely frozen pane: alive, consuming no CPU
  printf '9\n' > "$state/.wedge-escalations-$key"
  printf '1000\n' > "$state/.stale-since-$key"

  # First look: no predecessor sample, so the comparison is unknown and the
  # escalation count must survive untouched.
  rc=$(run_reset_driver "$dir" "$state" "$win" "$key" hash-one | sed -n 's/^rc=//p')
  [ "$rc" = 1 ] || fail "an unknown first sample reported a reset (rc=$rc)"
  [ "$(cat "$state/.wedge-escalations-$key")" = 9 ] \
    || fail "an unknown first sample cleared the escalation count"

  # Second look, same rendered hash and no readable process signals: still no
  # evidence, count still survives. This is the frozen case.
  rc=$(run_reset_driver "$dir" "$state" "$win" "$key" hash-one | sed -n 's/^rc=//p')
  [ "$rc" = 1 ] || fail "a frozen lane reported a reset (rc=$rc)"
  [ "$(cat "$state/.wedge-escalations-$key")" = 9 ] \
    || fail "a frozen lane cleared the escalation count"

  # Third look, rendered output advanced: proven health resets the ratchet.
  rc=$(run_reset_driver "$dir" "$state" "$win" "$key" hash-two | sed -n 's/^rc=//p')
  [ "$rc" = 0 ] || fail "advancing output did not reset the ratchet (rc=$rc)"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "the escalation count survived proven health"
  [ ! -e "$state/.stale-since-$key" ] || fail "the wedge timer survived proven health"

  log=$(cat "$state/.watch-triage.log" 2>/dev/null || true)
  case "$log" in
    *"wedge escalation reset by proven health"*"escalation 9 -> 0"*"advanced: rendered"*) ;;
    *) fail "the reset transition was not logged reconstructably (got: $log)" ;;
  esac
  pass "proven health resets the ratchet and the transition is logged with its prior count"
}


# --- the alarm-reset boundary, as a fixture rather than a comment ------------
#
# The seam has one reset RULE and two applications with disjoint subjects. That
# separation is the reason they are two functions instead of one, so it is
# proven here: each reset is driven with the other's state present and must
# leave it untouched. Without this, "genuinely different seams" is a claim in a
# comment that nothing enforces.
test_the_two_resets_do_not_touch_each_others_state() {
  local dir state key win
  dir="$TMP_ROOT/boundary"
  state="$dir/state"
  mkdir -p "$state"
  win='lab:w1:p1'
  key=$(printf '%s' "$win" | tr ':/.' '___')
  PANE_PID=$BURNER_PID

  # Both alarms raised at once.
  printf '4\n' > "$state/.wedge-escalations-$key"
  printf '1000\n' > "$state/.stale-since-$key"
  : > "$state/.turnend-claude-blocks"
  : > "$state/.claude-autoarm-failure-notified"
  : > "$state/.claude-autoarm-failure-alarmed"

  # Upstream's home-level reset must not reach into one pane's wedge state.
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_failure_episode_reset "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$state" \
    || fail "the failure-episode reset did not run"
  [ ! -e "$state/.turnend-claude-blocks" ] || fail "the failure-episode reset did not clear its own state"
  [ -e "$state/.wedge-escalations-$key" ] \
    || fail "the failure-episode reset cleared a pane's wedge ratchet, which is not its subject"
  [ -e "$state/.stale-since-$key" ] \
    || fail "the failure-episode reset cleared a pane's wedge timer, which is not its subject"

  # And this lane's pane-level reset must not reach into the home's episode.
  : > "$state/.turnend-claude-blocks"
  : > "$state/.claude-autoarm-failure-notified"
  : > "$state/.claude-autoarm-failure-alarmed"
  run_reset_driver "$dir" "$state" "$win" "$key" hash-one >/dev/null
  run_reset_driver "$dir" "$state" "$win" "$key" hash-two >/dev/null
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "the health reset did not clear its own state"
  [ -e "$state/.turnend-claude-blocks" ] \
    || fail "the health reset cleared the home's guard budget, which is not its subject"
  [ -e "$state/.claude-autoarm-failure-notified" ] \
    || fail "the health reset cleared a failure-episode record, which is not its subject"
  [ -e "$state/.claude-autoarm-failure-alarmed" ] \
    || fail "the health reset cleared the attended-alarm record, which is not its subject"
  pass "each reset clears only its own alarm's state and leaves the other's untouched"
}

# --- the busy alarm must still be able to sound ------------------------------
#
# This is the defect the review caught and the reason the earlier version of
# this suite was worthless on it: the fake backend made cpu and children
# unreadable, so the comparison went unknown for a reason unrelated to the
# scoping it claimed to prove, and it passed either way. Here the process
# signals ARE readable and advancing, which is what a busy pane looks like, and
# the busy alarm must escalate anyway.
test_a_busy_pane_still_escalates_while_its_cpu_advances() {
  local dir state key win before after
  dir="$TMP_ROOT/busy-escalates"
  state="$dir/state"
  mkdir -p "$state"
  win='lab:w2:p2'
  key=$(printf '%s' "$win" | tr ':/.' '___')
  PANE_PID=$BURNER_PID   # a genuinely busy pane: CPU advances between samples

  # A readable, advancing process signal - the exact evidence that would reset a
  # liveness alarm - with the rendered pane frozen.
  before="rendered=frozen cpu=1000 children=4"
  after="rendered=frozen cpu=1900 children=4"
  compare "$before" "$after"
  [ "$CMP_RC" = 0 ] || fail "the fixture is not exercising real advancing evidence (rc=$CMP_RC)"

  printf '2\n' > "$state/.wedge-escalations-$key"
  printf '1000\n' > "$state/.stale-since-$key"
  # A PREDECESSOR sample is seeded directly, with a CPU figure the live burner
  # has long since passed. Without it neither call below can compare anything,
  # and the assertion would pass because the evidence was unknown rather than
  # because the subject gate held - the exact vacuity the review caught the
  # first time. With it, any call that samples WILL see advancing CPU.
  printf 'rendered=frozen cpu=1 children=1\n' > "$state/.health-sample-$key"
  run_timer_driver "$dir" "$state" "$win" "$key" turn-completion frozen >/dev/null
  [ -e "$state/.wedge-escalations-$key" ] \
    || fail "the busy alarm was reset by evidence of movement, so it can never escalate"

  # The identical setup under the liveness subject DOES reset. That is what makes
  # the assertion above about the subject rather than about missing evidence.
  printf 'rendered=frozen cpu=1 children=1\n' > "$state/.health-sample-$key"
  printf '1000\n' > "$state/.stale-since-$key"
  run_timer_driver "$dir" "$state" "$win" "$key" liveness frozen >/dev/null
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the liveness alarm did not reset on the same evidence, so the fixture proves nothing"
  pass "movement resets the liveness alarm and never the busy turn-completion alarm"
}

start_panes
test_each_signal_alone_proves_health
test_the_measured_specimen_reads_as_health
test_a_frozen_lane_is_never_pardoned
test_a_receding_counter_is_not_health
test_unreadable_signals_are_unknown
test_ratchet_resets_and_logs_the_transition
test_the_two_resets_do_not_touch_each_others_state
test_a_busy_pane_still_escalates_while_its_cpu_advances
stop_panes
