#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session owns state/.lock, decided by session id
#     (bin/fm-session-lock-lib.sh). When the recorded owner's pid fails the
#     shared harness-liveness predicate, the hook delegates guarded recovery to
#     bin/fm-lock.sh and then re-verifies ownership. A live owner naming another
#     session, a missing lock, a malformed lock, or an unestablishable own
#     session id all still refuse, so a competing session never arms or rewakes.
#   - Recorded refusal: an identity refusal is an OUTCOME and is written as one.
#     It records epoch outcome "refused" and, once per episode, the failure
#     notice. A failed ACQUISITION of an unowned home records "acquire-failed"
#     instead, because those are different observed worlds; both are verified
#     failure episodes for the guard. Exiting 0 in silence here is what made the
#     turn-end guard's bounded fail-open unreachable: the guard advances on a
#     fresh epoch and keys its escape on a verified failure, so a refusal that
#     wrote nothing starved the very backstop built to survive an unavailable
#     auto-arm. An exit that changes nothing observable is indistinguishable
#     from an exit that never ran.
#   - A withheld outcome never clobbers a fresher one: the epoch ledger and the
#     failure notice belong to the HOME, so a bystander session's refusal must
#     not overwrite a fresh non-withheld epoch left by the session that owns it.
#     Doing so blocks the OWNER's turn and tells it to hand back a home it
#     already owns, which breaks the refusal bias from the other direction.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh in the FOREGROUND of
#     this hook-owned process tree (never shell &); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
OWNER_LOCK="$STATE/.claude-autoarm.lock"
EPOCH="$STATE/.claude-autoarm-epoch"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac
# The SAME freshness window the turn-end guard judges epoch recency by
# (bin/fm-turnend-guard.sh EPOCH_FRESH). It is read here so a withheld-outcome
# record can tell "the owner's epoch is still current" from "nothing current
# exists", using the reader's own definition of current rather than a second one.
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$EPOCH" 2>/dev/null || true
}

# May a WITHHELD-supervision outcome (refused, acquire-failed) be recorded now?
#
# The epoch ledger and the failure notice are the HOME's, shared by every
# session whose Stop fires here, and a withheld outcome is written by a session
# that deliberately holds no owner lock. So a bystander must never overwrite a
# fresher record left by the session that does own the home: doing so fails
# autoarm_owns_recovery for the owner, blocks the OWNER's turn, and tells it to
# hand back a home it already owns - the mirror image of the permissiveness this
# gate exists to prevent, and just as much a break of the refusal bias.
#
# A record is therefore withheld only against a NON-withheld outcome that is
# still fresh by the guard's own window. Everything else records normally, and
# withheld-over-withheld especially must: the bounded escape advances on fresh
# epochs, so a refusal that could not replace an equally-refusing epoch would
# make that escape unreachable again.
withheld_outcome_may_record() {
  local outcome age
  [ -e "$EPOCH" ] || return 0
  outcome=$(epoch_outcome)
  case "$outcome" in
    refused|acquire-failed) return 0 ;;
  esac
  age=$(fm_path_age "$EPOCH")
  case "$age" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$age" -lt "$EPOCH_FRESH" ] && return 1
  return 0
}

# Record one withheld-supervision outcome $1 and, once per episode, the operator
# notice built from the remaining arguments. Declining leaves the home's shared
# auto-arm state byte-for-byte unchanged, including the notice, because that
# notice also suppresses the legitimate owner's block-budget reset.
record_withheld_outcome() {  # <outcome> <notice-line>...
  local outcome=$1
  shift
  withheld_outcome_may_record || return 0
  write_epoch "$outcome"
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf '%s\n' "$@" >&2
    : > "$FAILURE_NOTICE" 2>/dev/null || true
  fi
}

# Consume the Stop payload once. The decisions below are state-based apart from
# the session id, which the payload is the authoritative source of; it is read
# whole so a slow writer can never wedge on a full pipe.
PAYLOAD=$(cat 2>/dev/null || true)

# This session's id, from the Stop payload first and the injected environment
# second. Both name the same session; the payload is preferred because it is
# authoritative even where the environment is not propagated to hooks. An
# unresolvable id is left empty, and the shared identity contract then refuses.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  PAYLOAD_SESSION=$(printf '%s' "$PAYLOAD" | jq -r '
    if (type == "object") and ((.session_id | type) == "string") then .session_id else empty end
  ' 2>/dev/null || true)
  if fm_session_id_valid "${PAYLOAD_SESSION:-}"; then
    export FM_SESSION_ID="$PAYLOAD_SESSION"
  fi
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its harness pid in .lock. Use the
# shared liveness predicate to recognize only that stale-owner case.
#
# Classify here but act later: the mutating claim AND the refusal record both
# wait for the unchanged AFK and need gates below, so an idle or away home stays
# byte-for-byte inert. A refusal only blocks the operator when supervision is
# actually needed, and that is exactly when it must be recorded.
RECOVER_SESSION_LOCK=0
REFUSAL=
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(fm_session_lock_pid "$STATE") || LOCK_PID=
  LOCK_SESSION=$(fm_session_lock_session "$STATE") || LOCK_SESSION=
  if [ -z "$LOCK_PID" ]; then
    REFUSAL="this home's session lock is missing or malformed, so no session can be proven to own it"
  elif fm_harness_pid_alive "$LOCK_PID"; then
    if [ -n "$LOCK_SESSION" ]; then
      REFUSAL="this home's session lock is held by session $LOCK_SESSION (live harness pid $LOCK_PID) and this session is not it"
    else
      REFUSAL="this home's session lock is held by live harness pid $LOCK_PID, records no session, and this session is not in its ancestry"
    fi
  else
    RECOVER_SESSION_LOCK=1
  fi
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- recorded refusal ---------------------------------------------------------
# Supervision is needed and this session may not provide it. Refusing is correct
# and stays correct; recording the refusal is what keeps the guard's bounded
# escape reachable instead of theoretical. No owner lock is claimed: holding it
# would tell the turn-end guard that recovery is under way, which is the one
# thing a refusal must never claim.
if [ -n "$REFUSAL" ]; then
  record_withheld_outcome refused \
    "$(printf 'firstmate watcher auto-arm REFUSED - %s.' "$REFUSAL")" \
    'Supervision is needed here but this session may not arm it, so the home is unsupervised until the lock owner returns or its session lock is reacquired. This refusal is deliberate: firstmate never arms, rewakes, or ends a session on behalf of a session it cannot prove it is.'
  exit 0
fi

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
#
# A failed acquisition is recorded as acquire-failed, NOT as refused: another
# session owning this home and this session being unable to take an unowned home
# are different observed worlds, and reporting the second as the first sends the
# operator to reacquire a lock whose acquisition just failed. Both outcomes are
# accepted by the guard's failure_episode_verified and both raise the
# one-per-episode notice, so the bounded escape stays reachable on either path
# rather than being starved under a new name.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  if ! "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1; then
    record_withheld_outcome acquire-failed \
      'firstmate watcher auto-arm could not ACQUIRE this home - the recorded session-lock owner failed the harness-liveness check, and reacquiring the lock through bin/fm-lock.sh failed.' \
      'Supervision is needed here but this session could not take the home, so it stays unsupervised. The reacquisition was already attempted and failed: investigate why bin/fm-lock.sh cannot write or verify state/.lock rather than retrying it by hand.'
    exit 0
  fi
  if ! fm_session_lock_owned_by_self "$STATE"; then
    record_withheld_outcome acquire-failed \
      'firstmate watcher auto-arm could not ACQUIRE this home - the session lock was reclaimed, but this session still cannot prove it owns the lock afterwards.' \
      'Supervision is needed here but this session could not take the home, so it stays unsupervised. The reacquisition was already attempted and failed: investigate why bin/fm-lock.sh cannot write or verify state/.lock rather than retrying it by hand.'
    exit 0
  fi
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner foregrounds the arm and translates its close; every other firing exits
# 0 so one watcher cycle maps to at most one exit-2 rewake.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# NO shell &: this hook process tree is the harness-owned lifecycle. The arm
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
OUT=
ACTIONABLE=0
HEALTHY=0
attempt=0
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ -n "$OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 || true
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 || true
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  if fm_failure_episode_reset "$STATE"; then
    write_epoch clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  [ -e "$FAILURE_ALARM" ] && exit 0
  exit 2
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  write_epoch failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  write_epoch rewake
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop.
if [ ! -e "$FAILURE_NOTICE" ]; then
  write_epoch failed
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  : > "$FAILURE_NOTICE" 2>/dev/null || true
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
write_epoch failed-suppressed
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 2
