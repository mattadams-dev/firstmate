#!/usr/bin/env bash
# tests/fm-rebirth.test.sh - session rebirth: the 200,000-token threshold
# machinery (bin/fm-rebirth-lib.sh, bin/fm-rebirth.sh, bin/fm-session-launch.sh).
#
# TWO GUARD-CLASS PROPERTIES, in both directions, because they fail differently:
#
#   A. A session past the threshold is marked rebirth-due WITHOUT anyone looking.
#      A mutant that lets one through breaks test_death_reading_marks_rebirth_due
#      and nothing else.
#
#   B. A rebirth NEVER happens mid-decision or with a pending composer. A mutant
#      that reborns anyway breaks test_arm_refuses_with_an_open_decision (or its
#      composer twin) and nothing else. This is the direction that would ship
#      looking correct: detection is easy to demonstrate, and choosing the wrong
#      moment is what actually loses work.
#
# THE READINGS ARE MEASURED, NOT INVENTED. tests/fixtures/rebirth/ holds two real
# specimens taken 2026-08-05 from live firstmate session transcripts, redacted to
# the provider's usage object and its envelope:
#   birth-weight.jsonl  61,602 tokens - a session's first turn, the ambient
#                       instruction floor no rebirth can go below.
#   at-death.jsonl      368,381 tokens - a session's final reading, 84% past the
#                       threshold, followed by its five real trailing non-usage
#                       lines.
# The pair is nearly 6x apart, so the threshold is exercised from both sides with
# data the fleet actually produced. docs/verification/session-rebirth.md records
# their provenance.
#
# THE COMPOSER IS READ THROUGH THE REAL CLASSIFIER. The quiescence tests drive
# bin/fm-tmux-lib.sh and bin/fm-composer-lib.sh for real behind a tmux shim that
# serves a canned pane, rather than stubbing the verdict. A stub can only confirm
# the assumption written into the stub, and the composer verdict is precisely the
# safety-critical judgement under test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-rebirth-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

FIXTURES="$ROOT/tests/fixtures/rebirth"
BIRTH="$FIXTURES/birth-weight.jsonl"
DEATH="$FIXTURES/at-death.jsonl"

# The measured constants. Named here so a fixture that silently changed shape
# fails loudly instead of quietly re-baselining the test to whatever it now says.
BIRTH_TOKENS=61602
DEATH_TOKENS=368381

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- harness ----------------------------------------------------------------

# new_home: a throwaway FM_HOME with an empty state dir.
new_home() {
  local root
  root=$(fm_test_tmproot fm-rebirth)
  mkdir -p "$root/state"
  printf '%s' "$root"
}

# A tmux shim serving a canned pane. The pane file holds the visible rows; the
# cursor sits on the last one, which is the composer row. `send-keys -l` writes
# into it and `Enter` clears it, so a submit that the pane accepts reads back
# `empty` exactly as a real one does.
install_tmux_shim() {  # <home> -> shim dir on stdout
  local home=$1 shim
  shim=$(fm_fakebin "$home")
  cat > "$shim/tmux" <<'SH'
#!/usr/bin/env bash
pane="$FM_TEST_PANE"
case "$1" in
  display-message)
    # cursor_y is zero-based: the last row of the canned pane.
    rows=$(wc -l < "$pane")
    printf '%s\n' "$(( rows - 1 ))"
    exit 0 ;;
  capture-pane)
    start=; end=
    while [ $# -gt 0 ]; do
      case "$1" in
        -S) start=$2; shift 2 ;;
        -E) end=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$start" = 0 ] || [ -z "$start" ]; then
      cat "$pane"
    else
      sed -n "$(( start + 1 ))p" "$pane"
    fi
    exit 0 ;;
  send-keys)
    shift
    target=; literal=0; text=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) text=$1; shift ;;
      esac
    done
    : "$target"
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$text" > "$pane"
      printf '%s\n' "$text" >> "$FM_TEST_TYPED"
    elif [ "$text" = Enter ]; then
      printf '\n' > "$pane"
      printf 'ENTER\n' >> "$FM_TEST_TYPED"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$shim/tmux"
  printf '%s' "$shim"
}

# set_pane <home> <row>: make the composer row read <row>.
set_pane() { printf '%s\n' "$2" > "$1/pane"; }

# rebirth <home> <args...>: run the real CLI against that home.
rebirth() {
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" \
  FM_TEST_PANE="$home/pane" \
  FM_TEST_TYPED="$home/typed" \
  FM_REBIRTH_BRIDGE="$home/bridge-recorder" \
  PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-rebirth.sh" "$@"
}

# A Bridge recorder standing in for bin/fm-bridge.sh. The ledger writer is
# exercised by its own suite; what matters here is that a verification result
# reaches it at all, and with which claim.
install_bridge_recorder() {  # <home>
  cat > "$1/bridge-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/bridge.log"
exit 0
SH
  chmod +x "$1/bridge-recorder"
}

# publish_relauncher <home> <pid>: register a launch wrapper in that home
# through the REAL writer, so the record's shape can never drift from what the
# proof reads. A pid whose identity cannot be read is refused by the writer, so
# this only ever registers a process that was genuinely alive when it ran.
publish_relauncher() {  # <home> <pid>
  FM_STATE_OVERRIDE="$1/state" bash -c \
    '. "$1"; . "$2"; fm_rebirth_publish_relauncher "$3" "$4"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-rebirth-lib.sh" "$1/state" "$2"
}

# pid_identity <home> <pid>: the fleet's own "is this pid still that process"
# primitive, read through the same library the machinery uses.
pid_identity() {  # <home> <pid>
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$2"
}

# hold_session_lock <home> <pid>: make <pid> this home's session-lock holder, the
# way bin/fm-lock.sh does - a bare pid in state/.lock.
hold_session_lock() {  # <home> <pid>
  printf '%s\n' "$2" > "$1/state/.lock"
}

# write_due_marker <home> <session> <lock-pid>: the due marker as a reading by
# <session> while <lock-pid> held the session lock.
write_due_marker() {  # <home> <session> <lock-pid>
  printf 'session=%s\nts=2026-08-05T21:00:00-0700\ntokens=%s\nthreshold=200000\nlock_pid=%s\nlock_identity=%s\ntranscript=%s\n' \
    "$2" "$DEATH_TOKENS" "$3" "$(pid_identity "$1" "$3")" "$DEATH" > "$1/state/.rebirth-due"
}

# A home that is due, quiescent, and ready to arm. Every quiescence test starts
# from this and breaks exactly one thing, so a refusal can only come from the
# thing that test broke.
#
# The due marker is written DIRECTLY rather than by running the reader, and that
# is deliberate. It is the documented handover between detection and timing, and
# going through the reader here would make every timing test depend on the
# threshold comparison - so a detection regression would fail fifteen timing
# tests and look like a timing regression. The two halves of that handover are
# pinned from both sides instead, by test_death_reading_marks_rebirth_due (a
# reading past the line produces this marker) and test_arm_refuses_when_not_due
# (without it, nothing arms).
#
# The footprint record names the SAME session as the marker, and this test
# process holds the session lock the marker was written under, because that is
# what a session sitting over its own line looks like: the marker is a claim
# about the session whose reading produced it, never about the home.
#
# The relauncher is registered for this test process, which is genuinely alive
# for the length of the run. The proof is about a live wrapper, and a fabricated
# record could only confirm itself.
armable_home() {
  local home
  home=$(new_home)
  install_tmux_shim "$home" >/dev/null
  install_bridge_recorder "$home"
  hold_session_lock "$home" "$$"
  write_due_marker "$home" predecessor "$$"
  printf 'session=predecessor\nts=2026-08-05T21:00:00-0700\ntokens=%s\nthreshold=200000\nverdict=due\nlock_pid=%s\ntranscript=%s\n' \
    "$DEATH_TOKENS" "$$" "$DEATH" > "$home/state/.context-footprint"
  publish_relauncher "$home" "$$" \
    || fail "precondition: a live launch wrapper must be registerable in the test home"
  set_pane "$home" '❯'
  printf '%s' "$home"
}

arm() {  # <home> -> stdout of the arm attempt, status preserved
  local home=$1
  rebirth "$home" arm --backend tmux --target '%1' --harness claude
}

# --- Part 1: detection. The instrument reads itself. ------------------------

# GUARD A. The mutant this exists to kill: any change that lets a session past
# the threshold end a turn without being marked.
test_death_reading_marks_rebirth_due() {
  local home verdict
  home=$(new_home)
  verdict=$(rebirth "$home" record --session dying --transcript "$DEATH")
  [ "$verdict" = due ] || fail "a $DEATH_TOKENS-token session must read 'due', got '$verdict'"
  assert_present "$home/state/.rebirth-due" \
    "crossing the threshold must mark the session rebirth-due with nobody looking"
  assert_grep "tokens=$DEATH_TOKENS" "$home/state/.rebirth-due" \
    "the marker must carry the measured reading, not a rounded or recomputed one"
  pass "detection: a session at $DEATH_TOKENS provider tokens is marked rebirth-due unattended"
}

# GUARD A, the other side. A threshold that fires on a fresh session is not a
# threshold, and the floor is the hardest case because no rebirth can beat it.
test_birth_weight_never_marks_rebirth_due() {
  local home verdict
  home=$(new_home)
  verdict=$(rebirth "$home" record --session newborn --transcript "$BIRTH")
  [ "$verdict" = under ] || fail "a $BIRTH_TOKENS-token first turn must read 'under', got '$verdict'"
  assert_absent "$home/state/.rebirth-due" \
    "the ambient instruction floor must never be mistaken for a session worth ending"
  pass "detection: the $BIRTH_TOKENS-token birth weight is under threshold and marks nothing"
}

# Unknown is a third outcome. Collapsing it either way is the expensive lie: into
# 'due' it reborns healthy sessions, into 'under' it silently stops enforcing.
test_unknown_reading_is_neither_due_nor_under() {
  local home verdict empty
  home=$(new_home)
  verdict=$(rebirth "$home" record --session ghost --transcript "$home/absent.jsonl")
  [ "$verdict" = unknown ] || fail "a missing transcript must read 'unknown', got '$verdict'"
  assert_absent "$home/state/.rebirth-due" "an unreadable transcript must not raise a false alarm"
  assert_grep "verdict=unknown" "$home/state/.context-footprint" \
    "an unreadable transcript must be RECORDED as unknown, not left looking like a clean reading"

  # A transcript that exists but carries no usage line at all.
  empty=$home/no-usage.jsonl
  printf '{"type":"system","timestamp":"2026-08-05T00:00:00Z"}\n' > "$empty"
  verdict=$(rebirth "$home" record --session ghost2 --transcript "$empty")
  [ "$verdict" = unknown ] || fail "a transcript with no usage line must read 'unknown', got '$verdict'"
  assert_absent "$home/state/.rebirth-due" "no usable counter must not mark a session due"
  pass "detection: an unreadable or counter-less transcript reads unknown, marking neither direction"
}

# The measured specimen ends with five trailing system, bridge-session,
# last-prompt, and file-history-snapshot lines. A reader that trusts the last
# line of a transcript reads nothing at all.
test_reading_scans_past_trailing_non_message_lines() {
  local tokens
  tokens=$(fm_rebirth_footprint_read "$DEATH") \
    || fail "the measured specimen must yield a reading despite its five trailing non-usage lines"
  [ "$tokens" = "$DEATH_TOKENS" ] \
    || fail "expected the last usage line's $DEATH_TOKENS, got '$tokens'"
  pass "detection: the reading scans backwards past trailing non-message lines"
}

# The reader runs at Stop, against a file the harness is still writing, so its
# last line can be caught half-flushed. That line is the FIRST thing a backwards
# scan sees. A reader handed the stream directly aborts the whole scan on it and
# reports unknown - and would go on reporting unknown for the rest of the
# session's life, the mechanism ceasing to enforce with nobody watching.
test_a_malformed_trailing_line_never_blinds_the_reader() {
  local home torn tokens
  home=$(new_home)
  torn=$home/torn.jsonl
  cp "$DEATH" "$torn"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1' >> "$torn"
  tokens=$(fm_rebirth_footprint_read "$torn") \
    || fail "a half-written final line must cost that line, not the whole reading"
  [ "$tokens" = "$DEATH_TOKENS" ] \
    || fail "expected the last COMPLETE reading of $DEATH_TOKENS, got '$tokens'"
  pass "detection: a malformed line is skipped rather than ending the scan"
}

# A subagent's usage object records the SUBAGENT's context, not the session's.
# Accepting one reports a small number for a large session - a false all-clear in
# the exact direction that loses work. Built from the real specimen so the only
# difference from the passing case is the sidechain flag.
test_sidechain_usage_never_reports_the_session() {
  local home mixed tokens
  home=$(new_home)
  mixed=$home/mixed.jsonl
  cp "$DEATH" "$mixed"
  jq -c '.isSidechain = true
    | .message.usage.cache_read_input_tokens = 900
    | .message.usage.cache_creation_input_tokens = 0
    | .message.usage.input_tokens = 100' "$BIRTH" >> "$mixed"
  tokens=$(fm_rebirth_footprint_read "$mixed") \
    || fail "a transcript ending in a sidechain turn must still yield the session's own reading"
  [ "$tokens" = "$DEATH_TOKENS" ] \
    || fail "a subagent's 1000-token context must never be read as the session's; got '$tokens'"

  # And the divergence is real: without the sidechain flag that same trailing
  # line WOULD win, so this case cannot go quietly vacuous.
  local naive=$home/naive.jsonl
  cp "$DEATH" "$naive"
  jq -c '.isSidechain = false
    | .message.usage.cache_read_input_tokens = 900
    | .message.usage.cache_creation_input_tokens = 0
    | .message.usage.input_tokens = 100' "$BIRTH" >> "$naive"
  tokens=$(fm_rebirth_footprint_read "$naive")
  [ "$tokens" = 1000 ] \
    || fail "a non-sidechain trailing turn must win, or the sidechain case proves nothing; got '$tokens'"
  pass "detection: a sidechain turn's footprint is never mistaken for the session's own"
}

# Every real turn bills something, so a zero sum means the counters were absent
# or malformed. Reporting "0 tokens" would be a confident reading of a thing
# nothing observed - and 0 is under every threshold, so it silently disarms.
test_zero_counters_read_unknown_not_zero() {
  local home zeroed
  home=$(new_home)
  zeroed=$home/zeroed.jsonl
  jq -c '.message.usage.input_tokens = 0
    | .message.usage.cache_read_input_tokens = 0
    | .message.usage.cache_creation_input_tokens = 0' "$DEATH" > "$zeroed"
  fm_rebirth_footprint_read "$zeroed" >/dev/null \
    && fail "an all-zero usage object must read unknown, never a confident 0"
  pass "detection: all-zero counters read unknown rather than a silently disarming zero"
}

test_threshold_override_is_honoured_and_junk_is_not() {
  local tokens
  tokens=$(FM_REBIRTH_THRESHOLD=50000 fm_rebirth_threshold)
  [ "$tokens" = 50000 ] || fail "a numeric threshold override must be honoured, got '$tokens'"
  tokens=$(FM_REBIRTH_THRESHOLD=lots fm_rebirth_threshold)
  [ "$tokens" = 200000 ] || fail "an unparseable threshold must fall back to 200000, got '$tokens'"
  tokens=$(FM_REBIRTH_THRESHOLD=0 fm_rebirth_threshold)
  [ "$tokens" = 200000 ] \
    || fail "a zero threshold would rebirth every turn; it must fall back, got '$tokens'"
  pass "detection: the threshold honours a real override and refuses junk rather than obeying it"
}

# The reading runs at every turn end against the one file that grows without
# bound, so the tail is tried first. The fallback is what keeps that an
# optimisation rather than a correctness hole: a reading further back than the
# window must still be found, not silently reported as unknown.
test_a_reading_beyond_the_tail_window_is_still_found() {
  local home far tokens i
  home=$(new_home)
  far=$home/far.jsonl
  cp "$DEATH" "$far"
  i=0
  while [ "$i" -lt 400 ]; do
    printf '{"type":"system","pad":"%s"}\n' \
      'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >> "$far"
    i=$((i + 1))
  done
  # A window far smaller than the trailing padding: the tail alone yields nothing.
  tokens=$(FM_REBIRTH_TAIL_BYTES=4096 fm_rebirth_footprint_read "$far") \
    || fail "a reading further back than the tail window must still be found"
  [ "$tokens" = "$DEATH_TOKENS" ] \
    || fail "expected the whole-file fallback to return $DEATH_TOKENS, got '$tokens'"

  # And the divergence is real: with a window that DOES cover the reading, the
  # tail path returns it directly, so this case cannot go quietly vacuous.
  tokens=$(FM_REBIRTH_TAIL_BYTES=1000000 fm_rebirth_footprint_read "$far")
  [ "$tokens" = "$DEATH_TOKENS" ] || fail "the tail path must return the same reading, got '$tokens'"
  pass "detection: a reading beyond the bounded tail window is found by the whole-file fallback"
}

# --- Part 2: timing. Quiescence, in both directions. ------------------------

# GUARD B, the one that would ship looking correct. An open decision is exactly
# the state where ending the session throws away the reasoning that was about to
# resolve it.
test_arm_refuses_with_an_open_decision() {
  local home out
  home=$(armable_home)
  printf 'working: started\nneeds-decision [key=api-shape]: two options\n' \
    > "$home/state/task-a.status"
  out=$(arm "$home") && fail "arm must refuse while a decision is still open: $out"
  assert_contains "$out" "a decision is still open" \
    "the refusal must name the open decision, not just decline"
  assert_absent "$home/state/.rebirth-armed" "a refused arm must leave no armed record"
  assert_absent "$home/typed" "a refused arm must type nothing into the session"
  pass "timing: a rebirth is refused while a decision is open, and nothing is typed"
}

# The paired positive. Without it the test above could pass because arm never
# works at all, and the guard would be vacuous.
test_arm_proceeds_once_the_decision_resolves() {
  local home out
  home=$(armable_home)
  printf 'working: started\nneeds-decision [key=api-shape]: two options\n' \
    > "$home/state/task-a.status"
  out=$(arm "$home") && fail "precondition: an open decision must block. got: $out"
  printf 'resolved [key=api-shape]: took the first\n' >> "$home/state/task-a.status"
  out=$(arm "$home") || fail "arm must proceed once the decision is resolved: $out"
  assert_present "$home/state/.rebirth-armed" "an accepted arm must record the predecessor"
  assert_grep "predecessor_tokens=$DEATH_TOKENS" "$home/state/.rebirth-armed" \
    "the armed record must carry the number the successor has to prove smaller"
  assert_grep "/exit" "$home/typed" \
    "arm must ask the session to exit through the harness's own exit command"
  pass "timing: the same home arms as soon as the decision resolves, typing the exit command"
}

# The status fold's load-bearing property. A later terminal line does not close
# an earlier decision, and a reader that only looks at the last status line would
# rebirth straight through this one.
test_a_later_terminal_line_does_not_clear_an_open_decision() {
  local home out
  home=$(armable_home)
  printf 'needs-decision [key=api-shape]: two options\ndone: shipped something else\n' \
    > "$home/state/task-a.status"
  out=$(arm "$home") \
    && fail "a 'done:' line after a needs-decision must not make the home look quiescent: $out"
  assert_contains "$out" "api-shape" \
    "the still-open decision must be named even though a terminal line follows it"
  pass "timing: a terminal status line after a needs-decision never clears it for rebirth"
}

# GUARD B's composer twin. Half-typed text in the composer is a human mid-thought
# or an injection mid-delivery; either way the session is not ownerless.
test_arm_refuses_a_pending_composer() {
  local home out
  home=$(armable_home)
  set_pane "$home" '❯ half a thought the captain was typing'
  out=$(arm "$home") && fail "arm must refuse a composer with pending text: $out"
  assert_contains "$out" "not proven empty" "the refusal must name the composer state"
  assert_absent "$home/state/.rebirth-armed" "a refused arm must leave no armed record"
  pass "timing: a rebirth is refused while the composer holds unsubmitted text"
}

# Unknown is not permission. A bare shell prompt means the agent has already
# exited to a dead shell, and an unreadable pane means nothing was proven at all.
test_arm_refuses_an_unproven_composer() {
  local home out
  home=$(armable_home)
  set_pane "$home" '$'
  out=$(arm "$home") \
    && fail "a bare shell prompt is a dead shell, not an empty agent composer: $out"
  assert_contains "$out" "not proven empty" \
    "an unprovable composer must refuse for the same reason a pending one does"
  pass "timing: an unproven composer refuses; only positive proof of empty is quiescent"
}

test_arm_refuses_without_an_endpoint() {
  local home out
  home=$(armable_home)
  out=$(FM_STATE_OVERRIDE="$home/state" FM_SUPERVISOR_TARGET='' FM_SUPERVISOR_BACKEND='' TMUX_PANE='' \
    "$ROOT/bin/fm-rebirth.sh" arm --harness claude) \
    && fail "arm must refuse when no endpoint can be resolved: $out"
  assert_contains "$out" "endpoint" "the refusal must say the endpoint could not be resolved"
  pass "timing: with no resolvable endpoint the composer is unprovable, so arm refuses"
}

test_arm_refuses_an_undelivered_escalation() {
  local home out
  home=$(armable_home)
  printf 'blocked: a crewmate needs help\n' > "$home/state/.subsuper-escalations"
  out=$(arm "$home") && fail "arm must refuse while an escalation is undelivered: $out"
  assert_contains "$out" "undelivered" "the refusal must name the undelivered escalation"
  pass "timing: a rebirth waits for a buffered escalation to be delivered first"
}

test_arm_refuses_when_not_due() {
  local home out
  home=$(new_home)
  install_tmux_shim "$home" >/dev/null
  set_pane "$home" '❯'
  # Perfectly quiescent, simply not marked. This is the other side of the
  # detection-to-timing handover: without the marker, nothing arms.
  out=$(arm "$home") && fail "arm must refuse a session that is not over the line: $out"
  assert_contains "$out" "not due" "the refusal must say the session is simply not due"
  pass "timing: a quiescent but under-threshold session is never reborn"
}

# Typing a guessed exit command into a live session is worse than not rebirthing.
test_arm_refuses_an_unverified_harness() {
  local home out
  home=$(armable_home)
  out=$(rebirth "$home" arm --backend tmux --target '%1' --harness someharness) \
    && fail "arm must refuse a harness with no verified exit command: $out"
  assert_contains "$out" "no verified exit command" "the refusal must name the missing fact"
  assert_absent "$home/typed" "nothing may be typed into a session whose exit path is unknown"
  pass "timing: an unverified harness refuses rather than guessing an exit command"
}

test_exit_commands_match_the_verified_adapters() {
  local h
  for h in claude opencode grok kimi; do
    [ "$(fm_rebirth_exit_command "$h")" = /exit ] || fail "$h's verified exit command is /exit"
  done
  for h in codex pi pi-signed; do
    [ "$(fm_rebirth_exit_command "$h")" = /quit ] || fail "$h's verified exit command is /quit"
  done
  fm_rebirth_exit_command unknown >/dev/null && fail "an unknown harness must have no exit command"
  pass "timing: the exit-command table matches the verified harness adapters"
}

# A handoff with no number in it is a rebirth nobody can check, so the refusal
# belongs at arm time rather than three steps later at verification.
test_arm_refuses_a_due_marker_with_no_reading() {
  local home out
  home=$(armable_home)
  write_due_marker "$home" predecessor "$$"
  sed -i "s/^tokens=.*/tokens=/" "$home/state/.rebirth-due"
  out=$(arm "$home") && fail "arm must refuse a due marker carrying no readable reading: $out"
  assert_contains "$out" "nothing to prove smaller" \
    "the refusal must say why an unreadable reading blocks the rebirth"
  assert_absent "$home/typed" "nothing may be typed for a rebirth whose premise cannot be stated"
  pass "timing: a due marker with no readable reading refuses instead of shipping an uncheckable handoff"
}

# THE FALSE SUCCESS. A marker is a claim about the session whose reading produced
# it. If mere existence counted, a session that crossed the line while the captain
# was present and then ended by hand would leave its marker behind, and the next
# session - at birth weight - would be armed on it, ending fine and posting
# "reborn: 61602 tokens, down from 368381" to the Bridge: a verified success for a
# rebirth that shed nothing. Nothing about that reading prompts anyone to look,
# which is why it outranks a false failure.
#
# The successor here reads `unknown` (its transcript is not there yet), so the
# marker is not cleared by the reading either - the case where only the binding
# stands between a stale marker and a false success.
test_a_marker_left_by_another_session_never_arms_this_one() {
  local home out
  home=$(armable_home)
  rebirth "$home" record --session successor --transcript "$home/absent.jsonl" >/dev/null
  assert_present "$home/state/.rebirth-due" \
    "precondition: an unknown reading must leave the predecessor's marker in place"
  out=$(arm "$home") \
    && fail "a marker left by a session that is gone must never arm this one: $out"
  assert_contains "$out" "session running now" \
    "the refusal must say the marker belongs to another session, not merely 'not due'"
  assert_absent "$home/typed" "nothing may be typed for a rebirth this session never earned"
  assert_absent "$home/state/.rebirth-armed" "a refused arm must leave no armed record"

  # The paired positive, in the same home: once THIS session's own reading is the
  # one over the line, the same marker arms. A guard that blocks the legitimate
  # case is one people switch off.
  rebirth "$home" record --session successor --transcript "$DEATH" >/dev/null
  out=$(arm "$home") || fail "a session marked due by its OWN reading must still arm: $out"
  assert_grep "predecessor_session=successor" "$home/state/.rebirth-armed" \
    "the armed record must name the session whose own reading crossed the line"
  pass "timing: a due marker binds to the session that earned it, and still arms that session"
}

# The other half of the binding: a reading under the line supersedes an older
# marker rather than leaving it to be found later. Unknown does neither, because
# failing to read is not a reading under the line.
test_an_under_reading_clears_a_stale_marker_and_unknown_does_not() {
  local home
  home=$(armable_home)
  rebirth "$home" record --session successor --transcript "$home/absent.jsonl" >/dev/null
  assert_present "$home/state/.rebirth-due" \
    "an unknown reading must not clear a marker; unknown is not a reading under the line"
  rebirth "$home" record --session successor --transcript "$BIRTH" >/dev/null
  assert_absent "$home/state/.rebirth-due" \
    "a reading under the line must retire the marker rather than leave it for a later session"
  pass "detection: an under-threshold reading clears a marker it supersedes, an unknown one leaves it alone"
}

# THE SUCCESSOR'S FIRST WINDOW, which is the window a rebirth itself creates. A
# successor that has come up but ended no turn has not written a footprint
# reading, so the marker's session id still matches - and a successor sitting at
# an empty composer is exactly when the daemon finds the moment quiescent. The
# session lock moves first: the successor takes it as step one of its
# session-start block, long before any turn of its own has ended.
test_a_marker_is_refused_once_a_successor_holds_the_session_lock() {
  local home out successor
  home=$(armable_home)
  sleep 30 &
  successor=$!
  hold_session_lock "$home" "$successor"
  out=$(arm "$home") \
    && fail "a marker must not be spent by a successor that has taken the lock: $out"
  assert_contains "$out" "session lock" "the refusal must name the lock that moved"
  assert_absent "$home/typed" "nothing may be typed for a marker this session did not earn"
  assert_absent "$home/state/.rebirth-armed" "a refused arm must leave no armed record"
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  # The paired positive: the session that earned the marker still holds the lock,
  # so it still arms. A guard that blocks the legitimate case gets switched off.
  hold_session_lock "$home" "$$"
  out=$(arm "$home") || fail "the session that earned the marker must still arm: $out"
  assert_grep "/exit" "$home/typed" "the legitimate case must still ask the session to exit"
  pass "timing: a due marker is spent only while its own session still holds the session lock"
}

# The half that pid equality alone cannot see. A session that died before
# anything reclaimed the lock leaves its OWN pid in the file, so the pid still
# matches - and its identity cannot be re-read, which is what tells "still
# running" apart from "gone, lock not yet reclaimed".
test_a_marker_whose_session_died_is_refused_though_the_lock_still_names_it() {
  local home out dead
  home=$(armable_home)
  sleep 30 &
  dead=$!
  hold_session_lock "$home" "$dead"
  write_due_marker "$home" predecessor "$dead"
  kill "$dead" 2>/dev/null || true
  wait "$dead" 2>/dev/null || true
  out=$(arm "$home") \
    && fail "a marker left by a session that is gone must not arm, lock pid or not: $out"
  assert_contains "$out" "no longer holds" \
    "the refusal must say the recording session no longer holds the lock"
  assert_absent "$home/typed" "nothing may be typed on behalf of a session that has exited"
  pass "timing: a lock pid that outlived its process is not proof the marker's session is running"
}

# Asking a session to exit with nothing behind it to relaunch costs the home its
# primary session: the daemon keeps running with only a dead shell to inject
# into, and escalations buffer until a human comes back. That is the decapitation
# this machinery exists to make survivable, so the relauncher is proven exactly
# like every other precondition.
test_arm_refuses_without_a_proven_relauncher() {
  local home out
  home=$(armable_home)
  rm -f "$home/state/.session-launcher"
  out=$(arm "$home") && fail "arm must refuse when nothing is proven to relaunch the session: $out"
  assert_contains "$out" "launch wrapper" "the refusal must name the missing relauncher"
  assert_absent "$home/typed" "nothing may be typed when no session would come back"
  assert_absent "$home/state/.rebirth-armed" "a refused arm must leave no armed record"

  # The paired positive: a real live wrapper is not refused. Without this the
  # guard could pass by refusing everything.
  publish_relauncher "$home" "$$" || fail "precondition: the relauncher must be registerable"
  out=$(arm "$home") || fail "a home with a live launch wrapper must still arm: $out"
  assert_grep "/exit" "$home/typed" "the legitimate case must still ask the session to exit"
  pass "timing: arm refuses without a proven relauncher and proceeds with one"
}

# A home with no registered relauncher can never rebirth, however far past the
# line it goes. Reporting that only in the daemon log is the alarm-chain failure
# this whole task exists to remove: the mechanism is off and the only witness is
# a file nobody reads. It goes to the Bridge, where the captain already looks -
# once per episode, not once a tick, and afresh when it happens again.
test_an_unrebirthable_home_is_reported_to_the_bridge() {
  local home
  home=$(armable_home)
  rm -f "$home/state/.session-launcher"
  arm "$home" >/dev/null && fail "precondition: a home with no relauncher must refuse"
  assert_grep "rebirth is disabled" "$home/bridge.log" \
    "a home that can never rebirth must reach the Bridge, not only the daemon log"
  [ "$(grep -c "rebirth is disabled" "$home/bridge.log")" -eq 1 ] \
    || fail "the first refusal must post exactly one note"

  # Once per episode: the daemon retries every tick, and the captain must not be
  # handed the same note a minute apart forever.
  arm "$home" >/dev/null && fail "precondition: the second attempt must still refuse"
  [ "$(grep -c "rebirth is disabled" "$home/bridge.log")" -eq 1 ] \
    || fail "a repeated refusal must not post a second note in the same episode"

  # The episode ends when a wrapper is registered, and the home arms normally.
  publish_relauncher "$home" "$$" || fail "precondition: the relauncher must be registerable"
  arm "$home" >/dev/null || fail "a home with a live wrapper must arm rather than report"

  # And a LATER episode is reported afresh, or the dedupe would silence the
  # second occurrence permanently.
  rm -f "$home/state/.rebirth-armed" "$home/state/.session-launcher"
  arm "$home" >/dev/null && fail "precondition: the home must refuse again once the wrapper is gone"
  [ "$(grep -c "rebirth is disabled" "$home/bridge.log")" -eq 2 ] \
    || fail "a fresh episode must be reported again, not suppressed by the first note"
  pass "timing: a home that cannot rebirth is reported to the Bridge once per episode"
}

# A record is not a wrapper. The pid it names has to be running right now, and
# it has to still be the process that wrote the record.
test_arm_refuses_a_relauncher_that_is_gone() {
  local home out pid
  home=$(armable_home)
  sleep 30 &
  pid=$!
  publish_relauncher "$home" "$pid" || fail "precondition: a live pid must be registerable"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  out=$(arm "$home") && fail "a registration for a dead wrapper must not arm a rebirth: $out"
  assert_contains "$out" "no longer running" "the refusal must say the registered wrapper is gone"
  assert_absent "$home/typed" "nothing may be typed on the strength of a wrapper that has exited"
  pass "timing: a launch-wrapper record whose process has exited is not proof of a relaunch"
}

# --- Part 3: execution. Relaunch, and nothing terminated. -------------------

# A wrapper that relaunches on any exit would fight the captain closing their own
# session. `claim` is the only thing that tells the two apart.
test_wrapper_exits_with_the_session_when_no_rebirth_was_armed() {
  local home out status
  home=$(new_home)
  out=$(FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    "$ROOT/bin/fm-session-launch.sh" -- false 2>&1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "the wrapper must exit with the session's own status, got $status"
  assert_not_contains "$out" "relaunching" "no rebirth was armed, so nothing may be relaunched"
  pass "execution: an ordinary session exit passes straight through, unrelaunched"
}

# The other end of the relauncher proof: the wrapper is what makes that proof
# true, and it must be true WHILE the session runs - the only moment an arm can
# happen - and false again once the wrapper is gone.
test_the_wrapper_registers_itself_while_the_session_runs() {
  local home
  home=$(new_home)
  cat > "$home/session" <<SH
#!/usr/bin/env bash
cp "$home/state/.session-launcher" "$home/launcher-seen" 2>/dev/null || true
printf '%s\n' "\$PPID" > "$home/wrapper-pid"
exit 0
SH
  chmod +x "$home/session"
  FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    "$ROOT/bin/fm-session-launch.sh" -- "$home/session" >/dev/null 2>&1
  assert_present "$home/launcher-seen" \
    "the wrapper must be registered before the session it launches can be asked to exit"
  assert_grep "pid=$(cat "$home/wrapper-pid")" "$home/launcher-seen" \
    "the record must name the wrapper's own pid, so the proof can be checked against a live process"
  assert_grep "identity=" "$home/launcher-seen" \
    "the record must publish the holder identity, or pid reuse cannot be ruled out"
  assert_absent "$home/state/.session-launcher" \
    "a wrapper that has gone home must not leave a registration behind it"
  pass "execution: the launch wrapper registers itself while the session runs and withdraws on exit"
}

test_wrapper_relaunches_exactly_once_per_armed_rebirth() {
  local home runs out
  home=$(armable_home)
  runs=$home/runs
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  # A session that ends immediately. The wrapper must relaunch it once - the
  # armed record is consumed - and then stop, because the second exit claims
  # nothing.
  cat > "$home/session" <<SH
#!/usr/bin/env bash
echo run >> "$runs"
exit 0
SH
  chmod +x "$home/session"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    "$ROOT/bin/fm-session-launch.sh" --min-uptime 0 -- "$home/session" 2>&1)
  [ "$(wc -l < "$runs")" -eq 2 ] \
    || fail "expected exactly one relaunch (2 runs), got $(wc -l < "$runs"): $out"
  assert_present "$home/state/.rebirth-handoff" \
    "the relaunch must leave the successor its predecessor's number"
  assert_absent "$home/state/.rebirth-armed" "claiming a rebirth must consume the armed record"
  assert_absent "$home/state/.rebirth-due" "a claimed rebirth clears the due marker"
  pass "execution: an armed rebirth relaunches the session exactly once"
}

# The SESSION is never terminated. bin/fm-safe-kill.sh refuses to signal a live
# harness session by design, so a rebirth that needed one would be a rebirth that
# could not happen - the exit is asked for through the composer instead.
test_the_rebirth_path_never_terminates_the_session() {
  local home runs
  home=$(armable_home)
  runs=$home/runs
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  cat > "$home/session" <<SH
#!/usr/bin/env bash
echo run >> "$runs"
exit 0
SH
  chmod +x "$home/session"
  FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    "$ROOT/bin/fm-session-launch.sh" --min-uptime 0 -- "$home/session" >/dev/null 2>&1
  assert_absent "$home/state/.safe-kill.log" \
    "with no watcher lock in the home there is nothing to retire, so nothing may be signalled"
  pass "execution: a rebirth cycle with no watcher to retire signals nothing at all"
}

# A watcher armed by the dying session outlives it, keeps its beacon fresh, and
# keeps the home's watcher lock - so the successor reads supervision as healthy
# while that watcher's eventual wake is addressed to a session that is gone.
# Retiring it is the one termination in the path, and it goes through the helper
# with the pid the LOCK names, never one this wrapper picked by inspection.
test_the_predecessor_watcher_is_retired_through_the_helper() {
  local home runs args
  home=$(armable_home)
  runs=$home/runs
  args=$home/safe-kill-args
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  mkdir -p "$home/state/.watch.lock"
  printf '4242\n' > "$home/state/.watch.lock/pid"
  cat > "$home/safe-kill" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$args"
exit 0
SH
  chmod +x "$home/safe-kill"
  cat > "$home/session" <<SH
#!/usr/bin/env bash
echo run >> "$runs"
exit 0
SH
  chmod +x "$home/session"
  FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    FM_SESSION_LAUNCH_SAFE_KILL="$home/safe-kill" \
    "$ROOT/bin/fm-session-launch.sh" --min-uptime 0 -- "$home/session" >/dev/null 2>&1
  assert_present "$args" "the predecessor watcher must be retired through the termination helper"
  assert_grep "--pid 4242" "$args" "the pid must come from the watcher lock, not from process inspection"
  assert_grep "--role watcher" "$args" "authority must be claimed from the watcher role lock"
  assert_grep "--reason" "$args" "every termination must carry the reason it was given"
  pass "execution: the predecessor's watcher is retired through the termination helper, by the pid its lock names"
}

# A refusal is escalated, not worked around. The wrapper must not retry, must not
# signal anything itself, and must still bring the home back up - leaving it with
# no session at all would be worse than leaving a watcher it could not end.
test_a_refused_watcher_retirement_is_escalated_not_worked_around() {
  local home runs calls out
  home=$(armable_home)
  runs=$home/runs
  calls=$home/safe-kill-calls
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  mkdir -p "$home/state/.watch.lock"
  printf '4242\n' > "$home/state/.watch.lock/pid"
  cat > "$home/safe-kill" <<SH
#!/usr/bin/env bash
echo call >> "$calls"
exit 3
SH
  chmod +x "$home/safe-kill"
  cat > "$home/session" <<SH
#!/usr/bin/env bash
echo run >> "$runs"
exit 0
SH
  chmod +x "$home/session"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_SESSION_LAUNCH_REBIRTH="$ROOT/bin/fm-rebirth.sh" \
    FM_SESSION_LAUNCH_SAFE_KILL="$home/safe-kill" \
    "$ROOT/bin/fm-session-launch.sh" --min-uptime 0 -- "$home/session" 2>&1)
  [ "$(wc -l < "$calls")" -eq 1 ] \
    || fail "a refusal must not be retried; the helper was called $(wc -l < "$calls") times"
  assert_contains "$out" "could not be retired" "the refusal must be reported, not swallowed"
  [ "$(wc -l < "$runs")" -eq 2 ] \
    || fail "the home must still come back up; leaving it with no session is worse than a stray watcher"
  pass "execution: a refused watcher retirement is reported and left alone, and the home still comes back up"
}

test_claim_is_single_shot() {
  local home
  home=$(armable_home)
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  rebirth "$home" claim || fail "the first claim must succeed"
  rebirth "$home" claim && fail "a second claim must not consume the same rebirth twice"
  pass "execution: an armed rebirth can be claimed exactly once"
}

test_an_expired_arm_is_not_claimable() {
  local home
  home=$(armable_home)
  FM_REBIRTH_ARM_TTL=1 arm "$home" >/dev/null || fail "precondition: the home must arm"
  sleep 2
  FM_STATE_OVERRIDE="$home/state" FM_REBIRTH_ARM_TTL=1 "$ROOT/bin/fm-rebirth.sh" claim 2>/dev/null \
    && fail "a stale armed record must not relaunch a session hours after the fact"
  assert_absent "$home/state/.rebirth-armed" "an expired arm must be withdrawn, not left to rot"
  pass "execution: an armed rebirth the session ignored expires instead of firing later"
}

# A continuation flag would restore the very transcript the rebirth exists to
# shed, so it is refused at startup where the fix is one edit away.
test_wrapper_refuses_a_continuation_flag() {
  local home out
  home=$(new_home)
  out=$(FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-session-launch.sh" -- true --continue 2>&1) \
    && fail "a continuation flag must be refused: $out"
  assert_contains "$out" "resume the transcript" "the refusal must say why the flag defeats rebirth"
  pass "execution: the wrapper refuses a launch command that would resume the old transcript"
}

# --- Part 4: orientation. The premise is proved, not assumed. ---------------

test_successor_proves_its_footprint_smaller() {
  local home out
  home=$(armable_home)
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  rebirth "$home" claim || fail "precondition: the rebirth must be claimable"
  out=$(rebirth "$home" verify --session successor --transcript "$BIRTH") \
    || fail "verification must succeed on a genuinely smaller successor: $out"
  assert_grep "$BIRTH_TOKENS" "$home/bridge.log" \
    "the successor's own reading must reach the Bridge"
  assert_grep "$DEATH_TOKENS" "$home/bridge.log" \
    "the comparison must name the predecessor's number too, or it proves nothing"
  assert_absent "$home/state/.rebirth-handoff" "a verified rebirth closes its handoff"
  pass "orientation: the successor's footprint is measured and posted against its predecessor's"
}

# The reading the whole mechanism exists to take. A rebirth that did not shrink
# anything must be as loud as one that did.
test_a_rebirth_that_did_not_shrink_is_reported_as_a_failure() {
  local home out
  home=$(armable_home)
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  rebirth "$home" claim || fail "precondition: the rebirth must be claimable"
  out=$(rebirth "$home" verify --session successor --transcript "$DEATH")
  assert_grep "did not reduce" "$home/bridge.log" \
    "a successor no smaller than its predecessor must be reported as a failed premise"
  pass "orientation: a rebirth that did not reduce the footprint is reported, not swallowed"
}

# Unknown after a bounded wait is reported as unknown. Deleting the handoff
# quietly would leave an unchecked rebirth looking exactly like a verified one.
test_an_unreadable_successor_is_reported_as_unknown() {
  local home attempt
  home=$(armable_home)
  arm "$home" >/dev/null || fail "precondition: the home must arm"
  rebirth "$home" claim || fail "precondition: the rebirth must be claimable"
  for attempt in 1 2 3; do
    FM_REBIRTH_VERIFY_TRIES=3 FM_STATE_OVERRIDE="$home/state" \
      FM_REBIRTH_BRIDGE="$home/bridge-recorder" \
      "$ROOT/bin/fm-rebirth.sh" verify --session "successor-$attempt" \
        --transcript "$home/never-written.jsonl" >/dev/null 2>&1 || true
  done
  assert_grep "unverified" "$home/bridge.log" \
    "an unreadable successor must be reported as unverified, never quietly dropped"
  assert_absent "$home/state/.rebirth-handoff" \
    "the handoff must close after the bounded wait rather than retry forever"
  pass "orientation: an unverifiable premise is reported as unknown after a bounded wait"
}

test_death_reading_marks_rebirth_due
test_birth_weight_never_marks_rebirth_due
test_unknown_reading_is_neither_due_nor_under
test_reading_scans_past_trailing_non_message_lines
test_a_malformed_trailing_line_never_blinds_the_reader
test_sidechain_usage_never_reports_the_session
test_zero_counters_read_unknown_not_zero
test_threshold_override_is_honoured_and_junk_is_not
test_a_reading_beyond_the_tail_window_is_still_found
test_arm_refuses_with_an_open_decision
test_arm_proceeds_once_the_decision_resolves
test_a_later_terminal_line_does_not_clear_an_open_decision
test_arm_refuses_a_pending_composer
test_arm_refuses_an_unproven_composer
test_arm_refuses_without_an_endpoint
test_arm_refuses_an_undelivered_escalation
test_arm_refuses_when_not_due
test_arm_refuses_an_unverified_harness
test_exit_commands_match_the_verified_adapters
test_arm_refuses_a_due_marker_with_no_reading
test_a_marker_left_by_another_session_never_arms_this_one
test_an_under_reading_clears_a_stale_marker_and_unknown_does_not
test_a_marker_is_refused_once_a_successor_holds_the_session_lock
test_a_marker_whose_session_died_is_refused_though_the_lock_still_names_it
test_arm_refuses_without_a_proven_relauncher
test_an_unrebirthable_home_is_reported_to_the_bridge
test_arm_refuses_a_relauncher_that_is_gone
test_wrapper_exits_with_the_session_when_no_rebirth_was_armed
test_the_wrapper_registers_itself_while_the_session_runs
test_wrapper_relaunches_exactly_once_per_armed_rebirth
test_the_rebirth_path_never_terminates_the_session
test_the_predecessor_watcher_is_retired_through_the_helper
test_a_refused_watcher_retirement_is_escalated_not_worked_around
test_claim_is_single_shot
test_an_expired_arm_is_not_claimable
test_wrapper_refuses_a_continuation_flag
test_successor_proves_its_footprint_smaller
test_a_rebirth_that_did_not_shrink_is_reported_as_a_failure
test_an_unreadable_successor_is_reported_as_unknown

echo "# fm-rebirth.test.sh: all assertions passed"
