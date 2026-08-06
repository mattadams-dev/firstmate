#!/usr/bin/env bash
# fm-rebirth-lib.sh - the single owner of session rebirth: what a session's
# context footprint IS, when it is over the line, when ending the session is
# safe, and what the successor inherits.
#
# WHY THIS EXISTS. Firstmate's own transcript is the largest single line in its
# per-turn context budget, and at heavy working rate the footprint grows about
# 93,000 provider tokens per hour - a rebirth due every two to three hours of a
# working day. A threshold a human has to notice is a convention, not a control,
# and the party asked to notice is precisely the one whose judgement degrades as
# the transcript grows. So the number is read by machinery instead.
#
# THE READING IS THE PROVIDER'S OWN COUNTER, NEVER FILE SIZE. The last non-
# sidechain line in the session transcript carrying a message.usage object holds
# what the provider actually billed for:
#     input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# The retired byte proxy needed two honesty caveats - transcript bytes
# over-counted persisted tool results and under-counted the system prompt - and
# both simply disappear here. Firstmate had told the captain it could not read
# its own context and would assert only bytes; that refusal was correct in
# spirit and wrong in fact. The counter is not reachable from inside the model,
# but it is written to the transcript every turn. An honest "unknown" still owes
# a search for the instrument.
#
# UNKNOWN IS A THIRD OUTCOME, never folded into either direction. A missing
# transcript, an absent usage line, a malformed counter, or no jq all read
# `unknown`. Unknown never marks a session rebirth-due (that would be a false
# alarm) and never records it as under threshold (that would be a false
# all-clear). It records `unknown`, which is what was observed.
#
# QUIESCENCE IS THE LOAD-BEARING WORD. Rebirth mid-decision or mid-delivery
# costs more than a large transcript does, so the moment is chosen from positive
# proof, never from the absence of a signal:
#   - the primary composer must be PROVEN empty by the shared classifier
#     (bin/fm-composer-lib.sh); pending, unknown, and unreadable are all unsafe;
#   - no task in this home may have an open decision, folded by the one owner of
#     that contract (status_open_decisions, bin/fm-classify-lib.sh);
#   - no escalation may be sitting undelivered in the away-mode buffer.
# Every refusal names its reason, because "not now" and "could not tell" are
# different answers and a caller that cannot distinguish them will eventually
# rebirth on the wrong one.
#
# THE SAME STANDARD APPLIES TO BOTH ENDS OF A REBIRTH. A due marker is proof
# about ONE session, so it is checked against the session running now - by its
# session id and by the session lock it held, never by its own existence; and
# nothing asks a session to exit until a live launch wrapper is proven to be
# waiting to bring one back. Both are positive proof, for the same reason
# quiescence is.
#
# TERMINATION IS NOT PART OF THIS. Nothing here ends a session. The exit is
# ASKED FOR through the harness's own exit command, typed into the composer this
# library just proved empty - which is why the composer read is load-bearing
# twice, as the proof and as the channel. bin/fm-safe-kill.sh refuses to signal
# a live harness session by design, and that refusal is correct: a session that
# ignores its exit command is a recorded, escalated failure here, never a kill.
#
# Environment:
#   FM_REBIRTH_THRESHOLD   provider-token threshold (default 200000)
#   FM_REBIRTH_ARM_TTL     seconds an armed rebirth stays valid (default 900)

# Re-sourcing is a cheap idempotent redefinition, matching bin/fm-composer-lib.sh.

FM_REBIRTH_THRESHOLD_DEFAULT=200000
FM_REBIRTH_ARM_TTL_DEFAULT=900

# fm_rebirth_threshold: the provider-token line a session may not sit past.
# 200,000 is the captain's number. A non-numeric or zero override is ignored
# rather than obeyed: a threshold that cannot be parsed must not silently become
# "rebirth on every turn" or "never rebirth".
fm_rebirth_threshold() {
  local t=${FM_REBIRTH_THRESHOLD:-$FM_REBIRTH_THRESHOLD_DEFAULT}
  case "$t" in
    ''|*[!0-9]*|0) t=$FM_REBIRTH_THRESHOLD_DEFAULT ;;
  esac
  printf '%s' "$t"
}

fm_rebirth_arm_ttl() {
  local t=${FM_REBIRTH_ARM_TTL:-$FM_REBIRTH_ARM_TTL_DEFAULT}
  case "$t" in
    ''|*[!0-9]*|0) t=$FM_REBIRTH_ARM_TTL_DEFAULT ;;
  esac
  printf '%s' "$t"
}

# fm_rebirth_footprint_read <transcript-path>
# Prints the provider's context-token count for the session and returns 0, or
# prints nothing and returns 1 when the reading is genuinely unknown.
#
# Scans BACKWARDS because the last line of a transcript is routinely not a
# message at all: the measured specimen ended with five trailing system,
# bridge-session, last-prompt, and file-history-snapshot lines after its final
# usage line, so a reader that trusts the last line reads nothing.
#
# Sidechain lines are excluded. A subagent's usage object records the SUBAGENT's
# context, not this session's, so accepting one would report a small number for
# a large session - a false all-clear in the exact direction that loses work.
#
# A sum of zero is refused rather than reported: every real turn bills something,
# so a zero means the counters were absent or malformed, and "0 tokens" is a
# confident reading of a thing that was never observed.
# This runs at every turn end, and the file it reads is the thing that grows -
# a session worth rebirthing has a transcript in the tens of megabytes. So the
# tail is tried first, since the reading being looked for is by construction near
# the end, and only a tail that yields nothing falls back to the whole file. The
# window is bytes rather than lines because a single transcript line can be
# enormous. A window that starts mid-line simply fails to parse and is skipped.
FM_REBIRTH_TAIL_BYTES_DEFAULT=262144

fm_rebirth_footprint_scan() {  # reads JSONL on stdin -> tokens | nothing
  # grep pre-filters cheaply; jq sees reverse file order, so the FIRST value it
  # emits is the LAST valid reading, and head -1 stops the scan there.
  #
  # Each line is read as RAW TEXT and parsed on its own, so a line that is not
  # valid JSON costs that line and nothing else. Handed the stream directly, jq
  # aborts the whole scan at the first parse error instead - which would turn a
  # half-flushed final write into `unknown` for the rest of the session's life,
  # the mechanism silently ceasing to enforce with nobody watching.
  grep '"usage"' 2>/dev/null | jq -R -r '
      fromjson? // empty
    | select(type == "object")
    | select(.isSidechain != true)
    | .message.usage
    | select(type == "object")
    | [.input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens]
    | map(if . == null then 0 else . end)
    | select(all(type == "number"))
    | add
    | select(. > 0)
  ' 2>/dev/null | head -1
}

fm_rebirth_footprint_read() {  # <transcript-path> -> tokens (0) | nothing (1)
  local file=$1 total window
  [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  window=${FM_REBIRTH_TAIL_BYTES:-$FM_REBIRTH_TAIL_BYTES_DEFAULT}
  case "$window" in
    ''|*[!0-9]*|0) window=$FM_REBIRTH_TAIL_BYTES_DEFAULT ;;
  esac
  total=$(tail -c "$window" "$file" 2>/dev/null | tac 2>/dev/null | fm_rebirth_footprint_scan)
  case "$total" in
    ''|*[!0-9]*) total=$(tac "$file" 2>/dev/null | fm_rebirth_footprint_scan) ;;
  esac
  case "$total" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$total"
  return 0
}

# fm_rebirth_record_reading <state> <session-id> <transcript-path>
# The instrument reading itself, at a moment the caller already runs. Records
# what was observed and prints the verdict: due | under | unknown.
#
# Only `due` writes state/.rebirth-due, and `under` REMOVES it: a marker is a
# claim about a session that is over the line, and a fresh reading under the line
# supersedes it - whether it was left by this session or by a predecessor that is
# gone. `unknown` touches the marker in neither direction, because failing to
# read is not a reading under the line.
#
# The reading itself is recorded either way in state/.context-footprint, so an
# operator can see that the instrument ran and what it saw - including that it
# saw nothing.
#
# Every reading also records WHO TOOK IT: the session id, and the pid and process
# identity of the harness holding this home's session lock at that moment. Those
# three are what bind the due marker to a session below.
fm_rebirth_record_reading() {  # <state> <session-id> <transcript> -> due|under|unknown
  local state=$1 session=${2:-unknown} transcript=${3:-} threshold tokens verdict tmp
  local lock_pid lock_identity
  threshold=$(fm_rebirth_threshold)
  mkdir -p "$state" 2>/dev/null || { printf 'unknown'; return 1; }
  if tokens=$(fm_rebirth_footprint_read "$transcript"); then
    if [ "$tokens" -ge "$threshold" ]; then verdict=due; else verdict=under; fi
  else
    tokens=unknown
    verdict=unknown
  fi
  lock_pid=$(fm_rebirth_lock_holder "$state") || lock_pid=
  lock_identity=
  if [ -n "$lock_pid" ] && command -v fm_pid_identity >/dev/null 2>&1; then
    lock_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null || true)
  fi
  tmp="$state/.context-footprint.tmp.$$"
  if printf 'session=%s\nts=%s\ntokens=%s\nthreshold=%s\nverdict=%s\nlock_pid=%s\nlock_identity=%s\ntranscript=%s\n' \
      "$session" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tokens" "$threshold" "$verdict" \
      "$lock_pid" "$lock_identity" \
      "${transcript:-none}" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state/.context-footprint" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  if [ "$verdict" = due ]; then
    tmp="$state/.rebirth-due.tmp.$$"
    if printf 'session=%s\nts=%s\ntokens=%s\nthreshold=%s\nlock_pid=%s\nlock_identity=%s\ntranscript=%s\n' \
        "$session" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tokens" "$threshold" \
        "$lock_pid" "$lock_identity" \
        "${transcript:-none}" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$state/.rebirth-due" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  elif [ "$verdict" = under ]; then
    rm -f "$state/.rebirth-due" 2>/dev/null || true
  fi
  printf '%s' "$verdict"
  return 0
}

# fm_rebirth_lock_holder <state>
# The pid of the harness process holding this home's session lock, or nothing.
#
# state/.lock is a bare pid written by bin/fm-lock.sh, and it is the earliest
# durable boundary a new session crosses: the successor overwrites it as step one
# of its session-start block, long before it has ended a turn.
fm_rebirth_lock_holder() {  # <state> -> pid (0) | nothing (1)
  local pid
  pid=$(head -1 "$1/.lock" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$pid"
  return 0
}

# fm_rebirth_due_verdict <state>
# Prints `due`, `not-marked`, `stale`, `stale-lock`, or `unproven`, and returns 0
# only for `due`.
#
# A due marker is a claim about ONE session: the one whose own reading crossed
# the line. That the file exists proves nothing about the session running now,
# and the gap between those two is a FALSE SUCCESS - a successor armed on its
# predecessor's marker inherits a number it never carried and posts a verified
# success the rebirth never earned. A false success outranks a false failure
# because nothing prompts anyone to look.
#
# TWO BINDINGS, because the reading's own record is blind in exactly the window a
# rebirth creates. state/.context-footprint updates when a turn ENDS, so between
# a successor's launch and its first completed turn it still names the
# predecessor - and a successor sitting at an empty composer is precisely when
# the daemon finds the moment quiescent. So the marker also records who held the
# home's session LOCK when the reading was taken, and that holder must still hold
# it and still be the same process:
#
#   - a successor that has taken the lock makes the recorded pid wrong;
#   - a predecessor that died before the lock was reclaimed leaves its own pid in
#     the file, so the pid alone still matches - and its identity cannot be
#     re-read, which is what tells the two apart.
#
# Pid equality without identity cannot distinguish "the recording session is
# still running" from "it died and nothing has reclaimed the lock yet", so a
# marker carrying no identity is `unproven`, never `due`.
fm_rebirth_due_verdict() {  # <state> -> due (0) | not-marked|stale|stale-lock|unproven (1)
  local state=$1 marked running marked_pid lock_now marked_identity identity_now
  [ -f "$state/.rebirth-due" ] || { printf 'not-marked'; return 1; }
  marked=$(fm_rebirth_field "$state/.rebirth-due" session)
  running=$(fm_rebirth_field "$state/.context-footprint" session)
  case "$marked" in ''|unknown) printf 'unproven'; return 1 ;; esac
  case "$running" in ''|unknown) printf 'unproven'; return 1 ;; esac
  [ "$marked" = "$running" ] || { printf 'stale'; return 1; }

  marked_pid=$(fm_rebirth_field "$state/.rebirth-due" lock_pid)
  case "$marked_pid" in ''|*[!0-9]*) printf 'unproven'; return 1 ;; esac
  lock_now=$(fm_rebirth_lock_holder "$state") || { printf 'unproven'; return 1; }
  [ "$marked_pid" = "$lock_now" ] || { printf 'stale-lock'; return 1; }
  marked_identity=$(fm_rebirth_field "$state/.rebirth-due" lock_identity)
  [ -n "$marked_identity" ] || { printf 'unproven'; return 1; }
  command -v fm_pid_identity >/dev/null 2>&1 || { printf 'unproven'; return 1; }
  identity_now=$(fm_pid_identity "$marked_pid" 2>/dev/null || true)
  [ "$identity_now" = "$marked_identity" ] || { printf 'stale-lock'; return 1; }

  printf 'due'
  return 0
}

fm_rebirth_is_due() {  # <state>
  fm_rebirth_due_verdict "$1" >/dev/null
}

fm_rebirth_field() {  # <record-file> <key> -> value
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# fm_rebirth_open_decisions <state>
# Every still-open decision across this home's tasks, one "<task>: <verb> <key>"
# line each. Folded by status_open_decisions, the ONE owner of the status-fold
# contract - a later terminal status line never clears an open decision, which is
# exactly the case a naive last-line read would rebirth straight through.
#
# The caller must have sourced bin/fm-classify-lib.sh. When it has not, this
# refuses rather than reporting an empty set: "no decisions found" and "I have no
# way to look" must never produce the same answer.
fm_rebirth_open_decisions() {  # <state> -> lines (0) | nothing (1 = cannot tell)
  local state=$1 f task summary key verb
  command -v status_open_decisions >/dev/null 2>&1 || return 1
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task=${task%.status}
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ -n "$key" ] || continue
      printf '%s: %s [key=%s] %s\n' "$task" "$verb" "$key" "$summary"
    done < <(status_open_decisions "$f")
  done
  return 0
}

# fm_rebirth_quiescence <state> <backend> <target>
# Prints `quiescent`, or `<reason>` naming what is in the way, and returns 0/1.
#
# The order is deliberate: the cheapest durable reads run before the pane reads,
# so a home with an open decision never pays for a capture.
#
# The caller must have sourced bin/fm-classify-lib.sh (decision fold) and
# bin/fm-backend.sh (composer/busy primitives).
fm_rebirth_quiescence() {  # <state> <backend> <target> -> quiescent|<reason>
  local state=$1 backend=$2 target=$3 open composer

  if [ -s "$state/.subsuper-escalations" ]; then
    printf 'an escalation is still undelivered in the away-mode buffer'
    return 1
  fi

  if ! open=$(fm_rebirth_open_decisions "$state"); then
    printf 'the open-decision fold is unavailable, so "no decision is open" cannot be proven'
    return 1
  fi
  if [ -n "$open" ]; then
    printf 'a decision is still open: %s' "$(printf '%s' "$open" | tr '\n' ';')"
    return 1
  fi

  if [ -z "$backend" ] || [ -z "$target" ]; then
    printf 'no primary session endpoint is known, so the composer cannot be read'
    return 1
  fi
  if ! command -v fm_backend_composer_state >/dev/null 2>&1; then
    printf 'the composer reader is unavailable, so an empty composer cannot be proven'
    return 1
  fi
  if command -v fm_backend_busy_state >/dev/null 2>&1 \
    && [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" = busy ]; then
    printf 'the primary session is mid-turn'
    return 1
  fi
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  if [ "$composer" != empty ]; then
    printf 'the composer is not proven empty (state=%s)' "${composer:-unreadable}"
    return 1
  fi

  printf 'quiescent'
  return 0
}

# --- the relauncher, proven the same way everything else here is -------------
#
# Asking a session to exit is only half a rebirth. Nothing about the exit
# establishes that anything will bring a session back, and the two outcomes are
# not comparable: refusing costs a delayed rebirth, while proceeding with no
# relauncher costs the home its primary session entirely - the daemon left
# injecting into a dead shell and escalations buffering until a human returns,
# which is the exact decapitation this machinery exists to make survivable.
#
# So the launch wrapper registers itself, and `arm` requires that record to
# describe a process that is running NOW - held to the same standard as the due
# marker, the quiescence read, the verified exit command, and the readable
# reading. Documentation telling an operator to use the wrapper is guidance, not
# proof.

# fm_rebirth_publish_relauncher <state> <pid>
# The wrapper's own registration. The identity is published alongside the pid
# because a pid outlives its process: a record naming a number nobody can tie
# back to the wrapper that wrote it is not proof of anything.
#
# The caller must have sourced bin/fm-wake-lib.sh (fm_pid_identity).
fm_rebirth_publish_relauncher() {  # <state> <pid>
  local state=$1 pid=$2 identity tmp
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  command -v fm_pid_identity >/dev/null 2>&1 || return 1
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  mkdir -p "$state" 2>/dev/null || return 1
  tmp="$state/.session-launcher.tmp.$$"
  printf 'pid=%s\nts=%s\nidentity=%s\n' \
    "$pid" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$identity" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$state/.session-launcher" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # A wrapper is now registered, so the episode the alarm reported is over and a
  # later one is reported afresh rather than suppressed by a marker nobody
  # remembers writing.
  rm -f "$state/.rebirth-relauncher-alarmed" 2>/dev/null || true
  return 0
}

# fm_rebirth_release_relauncher <state> <pid>
# Withdraw a registration this pid owns. A wrapper that dies without getting
# here leaves a record that no longer describes a live process, which the proof
# below already refuses - so this is hygiene, never the guard.
fm_rebirth_release_relauncher() {  # <state> <pid>
  local state=$1 pid=$2
  [ "$(fm_rebirth_field "$state/.session-launcher" pid)" = "$pid" ] || return 0
  rm -f "$state/.session-launcher" 2>/dev/null || true
  return 0
}

# fm_rebirth_relauncher_proof <state>
# Prints the live wrapper's pid and returns 0, or prints what could not be
# proven and returns 1. Every refusal names its own reason, because "nobody is
# there to relaunch" and "I could not tell" are different answers.
#
# The caller must have sourced bin/fm-wake-lib.sh. When it has not, this refuses
# rather than passing: "no wrapper is running" and "I have no way to look" must
# never produce the same answer, and neither of them is permission.
fm_rebirth_relauncher_proof() {  # <state> -> pid (0) | reason (1)
  local state=$1 record pid recorded current
  record="$state/.session-launcher"
  if [ ! -f "$record" ]; then
    printf 'no launch wrapper is registered in this home, so nothing is proven to bring a session back (start the session through bin/fm-session-launch.sh)'
    return 1
  fi
  pid=$(fm_rebirth_field "$record" pid)
  case "$pid" in
    ''|*[!0-9]*)
      printf 'the launch-wrapper record names no readable pid'
      return 1 ;;
  esac
  if ! command -v fm_pid_alive >/dev/null 2>&1 || ! command -v fm_pid_identity >/dev/null 2>&1; then
    printf 'the pid helpers are unavailable, so a live launch wrapper cannot be proven'
    return 1
  fi
  if ! fm_pid_alive "$pid"; then
    printf 'the launch wrapper (pid %s) is no longer running, so this session would not come back' "$pid"
    return 1
  fi
  if command -v fm_pid_is_zombie >/dev/null 2>&1 && fm_pid_is_zombie "$pid"; then
    printf 'the launch wrapper (pid %s) is a zombie and can never relaunch anything' "$pid"
    return 1
  fi
  recorded=$(fm_rebirth_field "$record" identity)
  if [ -z "$recorded" ]; then
    printf 'the launch-wrapper record publishes no holder identity, so pid reuse cannot be ruled out'
    return 1
  fi
  current=$(fm_pid_identity "$pid" 2>/dev/null)
  if [ -z "$current" ] || [ "$current" != "$recorded" ]; then
    printf 'pid %s is not the launch wrapper that registered it, so no relaunch is proven' "$pid"
    return 1
  fi
  printf '%s' "$pid"
  return 0
}

# fm_rebirth_exit_command <harness>
# The command that asks a primary session to exit cleanly through its OWN exit
# path. Verified per harness in .agents/skills/harness-adapters/SKILL.md, which
# remains the agent-facing owner of these facts; this table is the machine-
# readable form, the same split bin/fm-busy-lib.sh already uses for busy
# signatures. An unverified harness returns nothing and fails, because typing a
# guessed command into a live session is worse than not rebirthing.
fm_rebirth_exit_command() {  # <harness> -> command (0) | nothing (1)
  case "$1" in
    claude|opencode|grok|kimi) printf '/exit' ;;
    codex|pi|pi-signed) printf '/quit' ;;
    *) return 1 ;;
  esac
  return 0
}

# fm_rebirth_arm_record <state> <session> <tokens> <threshold> <harness> <backend> <target>
# The single durable record of an armed rebirth. Written before the exit is
# asked for, so a session that dies to anything at all still leaves the
# successor its predecessor's number to prove smaller.
fm_rebirth_arm_record() {
  local state=$1 session=$2 tokens=$3 threshold=$4 harness=$5 backend=$6 target=$7 tmp
  mkdir -p "$state" 2>/dev/null || return 1
  tmp="$state/.rebirth-armed.tmp.$$"
  printf 'predecessor_session=%s\narmed_ts=%s\narmed_epoch=%s\npredecessor_tokens=%s\nthreshold=%s\nharness=%s\nbackend=%s\ntarget=%s\n' \
    "$session" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date +%s)" "$tokens" "$threshold" \
    "$harness" "$backend" "$target" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$state/.rebirth-armed" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# fm_rebirth_arm_is_fresh <state>
# An armed rebirth expires. A session that never acted on its exit command must
# not be relaunched by a wrapper hours later on the strength of a stale file.
fm_rebirth_arm_is_fresh() {  # <state>
  local state=$1 armed now ttl
  armed=$(fm_rebirth_field "$state/.rebirth-armed" armed_epoch)
  case "$armed" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  ttl=$(fm_rebirth_arm_ttl)
  [ $(( now - armed )) -lt "$ttl" ]
}
