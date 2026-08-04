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
  mkdir -p "$state" "$dir/bin"
  win='lab:w1:p1'
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '9\n' > "$state/.wedge-escalations-$key"
  printf '1000\n' > "$state/.stale-since-$key"

  # A stand-in watcher context: only the pieces health_evidence_reset touches.
  cat > "$dir/driver.sh" <<DRIVER
#!/usr/bin/env bash
set -u
STATE="$state"
. "$LIB"
window_backend() { printf 'none\n'; }
triage_log() { printf '%s\n' "\$*" >> "$state/.watch-triage.log"; }
$(sed -n '/^health_evidence_reset()/,/^}/p' "$ROOT/bin/fm-watch.sh")
health_evidence_reset "$win" "\$1" "$state/.stale-since-$key" "$state/.wedge-escalations-$key"
printf 'rc=%s\n' "\$?"
DRIVER
  chmod +x "$dir/driver.sh"

  # First look: no predecessor sample, so the comparison is unknown and the
  # escalation count must survive untouched.
  rc=$("$dir/driver.sh" hash-one | sed -n 's/^rc=//p')
  [ "$rc" = 1 ] || fail "an unknown first sample reported a reset (rc=$rc)"
  [ "$(cat "$state/.wedge-escalations-$key")" = 9 ] \
    || fail "an unknown first sample cleared the escalation count"

  # Second look, same rendered hash and no readable process signals: still no
  # evidence, count still survives. This is the frozen case.
  rc=$("$dir/driver.sh" hash-one | sed -n 's/^rc=//p')
  [ "$rc" = 1 ] || fail "a frozen lane reported a reset (rc=$rc)"
  [ "$(cat "$state/.wedge-escalations-$key")" = 9 ] \
    || fail "a frozen lane cleared the escalation count"

  # Third look, rendered output advanced: proven health resets the ratchet.
  rc=$("$dir/driver.sh" hash-two | sed -n 's/^rc=//p')
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

test_each_signal_alone_proves_health
test_the_measured_specimen_reads_as_health
test_a_frozen_lane_is_never_pardoned
test_a_receding_counter_is_not_health
test_unreadable_signals_are_unknown
test_ratchet_resets_and_logs_the_transition
