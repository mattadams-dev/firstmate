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
  grep '"usage"' 2>/dev/null | jq -r '
      select(type == "object")
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
# Only `due` writes state/.rebirth-due. The reading itself is recorded either
# way in state/.context-footprint, so an operator can see that the instrument
# ran and what it saw - including that it saw nothing.
fm_rebirth_record_reading() {  # <state> <session-id> <transcript> -> due|under|unknown
  local state=$1 session=${2:-unknown} transcript=${3:-} threshold tokens verdict tmp
  threshold=$(fm_rebirth_threshold)
  mkdir -p "$state" 2>/dev/null || { printf 'unknown'; return 1; }
  if tokens=$(fm_rebirth_footprint_read "$transcript"); then
    if [ "$tokens" -ge "$threshold" ]; then verdict=due; else verdict=under; fi
  else
    tokens=unknown
    verdict=unknown
  fi
  tmp="$state/.context-footprint.tmp.$$"
  if printf 'session=%s\nts=%s\ntokens=%s\nthreshold=%s\nverdict=%s\ntranscript=%s\n' \
      "$session" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tokens" "$threshold" "$verdict" \
      "${transcript:-none}" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state/.context-footprint" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  if [ "$verdict" = due ]; then
    tmp="$state/.rebirth-due.tmp.$$"
    if printf 'session=%s\nts=%s\ntokens=%s\nthreshold=%s\ntranscript=%s\n' \
        "$session" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$tokens" "$threshold" \
        "${transcript:-none}" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$state/.rebirth-due" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  printf '%s' "$verdict"
  return 0
}

fm_rebirth_is_due() {  # <state>
  [ -f "$1/.rebirth-due" ]
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
