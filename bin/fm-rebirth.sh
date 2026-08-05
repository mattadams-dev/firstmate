#!/usr/bin/env bash
# fm-rebirth.sh - the command surface over session rebirth.
#
# bin/fm-rebirth-lib.sh owns every decision this script drives; this file owns
# the argument handling, the endpoint resolution, and the one act nothing else
# performs: asking the primary session to exit at a proven-quiescent moment.
#
# The four parts of the machinery and who runs which:
#   1. detection    bin/fm-turnend-guard.sh, every turn end -> `record`
#   2. timing       bin/fm-supervise-daemon.sh, every housekeeping tick -> `arm`
#   3. execution    bin/fm-session-launch.sh, on session exit -> `claim`
#   4. orientation  bin/fm-session-start.sh prints the handoff, and the guard
#                   proves the premise on the successor's first turn -> `verify`
#
# Usage:
#   fm-rebirth.sh record --session <id> --transcript <path>
#       Read the provider's own token counter for that session and record it.
#       Prints "due", "under", or "unknown". Only "due" marks rebirth-due.
#
#   fm-rebirth.sh status
#       The last recorded reading, whether rebirth is due, and what an armed or
#       handed-off rebirth is waiting on. Read-only.
#
#   fm-rebirth.sh quiescent [--backend B --target T]
#       Whether ending the session right now is safe, and when it is not, what
#       is in the way. Exit 0 quiescent, 1 not. Read-only.
#
#   fm-rebirth.sh arm [--backend B --target T] [--harness H] [--dry-run]
#       Refuses unless rebirth is due AND the moment is quiescent. Records the
#       predecessor's number, then types the harness's own exit command into the
#       composer it just proved empty. Nothing is ever terminated here.
#
#   fm-rebirth.sh claim
#       Consume an armed rebirth: the launch wrapper's proof that this exit was
#       the machinery's and not the captain's. Exit 0 when a fresh armed record
#       was consumed into a handoff, 1 otherwise.
#
#   fm-rebirth.sh verify --session <id> --transcript <path>
#       Prove the premise: read the successor's own footprint and post the
#       comparison to the Bridge. A rebirth that does not verify its own premise
#       is a ritual, not a control.
#
# Environment: FM_REBIRTH_THRESHOLD, FM_REBIRTH_ARM_TTL (bin/fm-rebirth-lib.sh),
# FM_REBIRTH_BRIDGE (Bridge writer path; a test seam), FM_REBIRTH_VERIFY_TRIES
# (turn ends the successor's reading may stay unknown before that is reported as
# unknown rather than waited on forever; default 3).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BRIDGE="${FM_REBIRTH_BRIDGE:-$SCRIPT_DIR/fm-bridge.sh}"

# shellcheck source=bin/fm-rebirth-lib.sh
. "$SCRIPT_DIR/fm-rebirth-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-rebirth: %s\n' "$1" >&2; exit 2; }

SESSION=
TRANSCRIPT=
BACKEND=
TARGET=
HARNESS=
DRY_RUN=0

[ $# -gt 0 ] || { usage; exit 2; }
COMMAND=$1
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ $# -gt 1 ] || die "--session requires a value"; SESSION=$2; shift 2 ;;
    --transcript) [ $# -gt 1 ] || die "--transcript requires a value"; TRANSCRIPT=$2; shift 2 ;;
    --backend) [ $# -gt 1 ] || die "--backend requires a value"; BACKEND=$2; shift 2 ;;
    --target) [ $# -gt 1 ] || die "--target requires a value"; TARGET=$2; shift 2 ;;
    --harness) [ $# -gt 1 ] || die "--harness requires a value"; HARNESS=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The primary session's endpoint. The daemon knows its own supervisor target and
# passes it explicitly; a hand-run invocation falls back to the same environment
# the daemon discovers from. There is no scan and no guess: an endpoint that
# cannot be resolved makes quiescence unprovable, which is a refusal, not a
# default.
resolve_endpoint() {
  [ -n "$BACKEND" ] || BACKEND=${FM_SUPERVISOR_BACKEND:-}
  [ -n "$TARGET" ] || TARGET=${FM_SUPERVISOR_TARGET:-}
  if [ -z "$BACKEND" ] && [ -n "$TARGET" ]; then
    BACKEND=$(fm_backend_name 2>/dev/null || printf 'tmux')
  fi
  if [ -z "$TARGET" ] && [ -n "${TMUX_PANE:-}" ]; then
    TARGET=$TMUX_PANE
    [ -n "$BACKEND" ] || BACKEND=tmux
  fi
}

case "$COMMAND" in
  record)
    [ -n "$TRANSCRIPT" ] || die "record requires --transcript"
    fm_rebirth_record_reading "$STATE" "${SESSION:-unknown}" "$TRANSCRIPT"
    printf '\n'
    ;;

  status)
    if [ -f "$STATE/.context-footprint" ]; then
      printf 'last reading:\n'
      sed 's/^/  /' "$STATE/.context-footprint"
    else
      printf 'last reading: none recorded yet (no turn has ended in this home since the instrument was installed)\n'
    fi
    printf 'threshold: %s provider tokens\n' "$(fm_rebirth_threshold)"
    if fm_rebirth_is_due "$STATE"; then
      printf 'rebirth: DUE since %s at %s tokens\n' \
        "$(fm_rebirth_field "$STATE/.rebirth-due" ts)" \
        "$(fm_rebirth_field "$STATE/.rebirth-due" tokens)"
    else
      printf 'rebirth: not marked due\n'
    fi
    if [ -f "$STATE/.rebirth-armed" ]; then
      if fm_rebirth_arm_is_fresh "$STATE"; then
        printf 'armed: yes, waiting for the session to exit (armed %s)\n' \
          "$(fm_rebirth_field "$STATE/.rebirth-armed" armed_ts)"
      else
        printf 'armed: EXPIRED - the exit was asked for at %s and the session did not end\n' \
          "$(fm_rebirth_field "$STATE/.rebirth-armed" armed_ts)"
      fi
    fi
    if [ -f "$STATE/.rebirth-handoff" ]; then
      printf 'handoff: predecessor %s at %s tokens, awaiting the successor'\''s own reading\n' \
        "$(fm_rebirth_field "$STATE/.rebirth-handoff" predecessor_session)" \
        "$(fm_rebirth_field "$STATE/.rebirth-handoff" predecessor_tokens)"
    fi
    ;;

  quiescent)
    resolve_endpoint
    reason=$(fm_rebirth_quiescence "$STATE" "$BACKEND" "$TARGET") && rc=0 || rc=1
    printf '%s\n' "$reason"
    exit "$rc"
    ;;

  arm)
    if ! fm_rebirth_is_due "$STATE"; then
      printf 'not armed: rebirth is not due\n'
      exit 1
    fi
    if [ -f "$STATE/.rebirth-armed" ] && fm_rebirth_arm_is_fresh "$STATE"; then
      printf 'not armed: a rebirth is already armed and waiting for the session to exit\n'
      exit 1
    fi
    resolve_endpoint
    if ! reason=$(fm_rebirth_quiescence "$STATE" "$BACKEND" "$TARGET"); then
      printf 'not armed: %s\n' "$reason"
      exit 1
    fi
    [ -n "$HARNESS" ] || HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
    if ! EXIT_CMD=$(fm_rebirth_exit_command "$HARNESS"); then
      printf 'not armed: no verified exit command for harness %s; typing a guessed command into a live session is worse than not rebirthing\n' "$HARNESS"
      exit 1
    fi
    TOKENS=$(fm_rebirth_field "$STATE/.rebirth-due" tokens)
    THRESHOLD=$(fm_rebirth_field "$STATE/.rebirth-due" threshold)
    PREV=$(fm_rebirth_field "$STATE/.rebirth-due" session)
    # Refuse here rather than shipping a handoff with no number in it. The
    # successor's whole obligation is to prove that number smaller, and a
    # rebirth whose premise cannot be stated is one nobody can check.
    case "$TOKENS" in
      ''|*[!0-9]*)
        printf 'not armed: the due marker carries no readable reading, so the successor would have nothing to prove smaller\n'
        exit 1
        ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would arm: %s at %s tokens, exit command %s into %s %s\n' \
        "$PREV" "$TOKENS" "$EXIT_CMD" "$BACKEND" "$TARGET"
      exit 0
    fi
    # The record is written BEFORE the exit is asked for. A session that dies to
    # anything at all between here and its next turn still leaves the successor
    # the number it has to prove smaller.
    fm_rebirth_arm_record "$STATE" "$PREV" "$TOKENS" "$THRESHOLD" \
      "$HARNESS" "$BACKEND" "$TARGET" \
      || { printf 'not armed: the armed record could not be written\n'; exit 1; }
    # The submit primitive ECHOES its verdict and returns 0 either way, exactly
    # as the away-mode injector reads it: a non-zero status is not the failure
    # signal, an unsubmitted composer is. Only an `empty` composer after Enter
    # proves the exit command was actually taken.
    VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$EXIT_CMD" 3 1 1 2>/dev/null)
    if [ "$VERDICT" = empty ]; then
      printf 'armed: asked %s to exit (%s) at %s tokens; the launch wrapper relaunches on exit\n' \
        "$HARNESS" "$EXIT_CMD" "$TOKENS"
      exit 0
    fi
    # The exit could not be delivered. Nothing is terminated in response: the
    # armed record is withdrawn, and the next tick re-evaluates from scratch.
    rm -f "$STATE/.rebirth-armed" 2>/dev/null || true
    printf 'not armed: the exit command was not accepted by %s %s (submit verdict=%s)\n' \
      "$BACKEND" "$TARGET" "${VERDICT:-unreadable}"
    exit 1
    ;;

  claim)
    [ -f "$STATE/.rebirth-armed" ] || exit 1
    if ! fm_rebirth_arm_is_fresh "$STATE"; then
      rm -f "$STATE/.rebirth-armed" 2>/dev/null || true
      printf 'expired: an armed rebirth went stale without the session exiting\n' >&2
      exit 1
    fi
    {
      printf 'relaunched_ts=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
      printf 'verify_attempts=0\n'
    } >> "$STATE/.rebirth-armed" 2>/dev/null || true
    # One rename moves the record from "armed" to "handed off", so the consume is
    # atomic and a second wrapper cannot claim the same rebirth twice.
    mv -f "$STATE/.rebirth-armed" "$STATE/.rebirth-handoff" 2>/dev/null || exit 1
    rm -f "$STATE/.rebirth-due" 2>/dev/null || true
    exit 0
    ;;

  verify)
    [ -f "$STATE/.rebirth-handoff" ] || exit 1
    [ -n "$TRANSCRIPT" ] || die "verify requires --transcript"
    PREV_TOKENS=$(fm_rebirth_field "$STATE/.rebirth-handoff" predecessor_tokens)
    PREV_SESSION=$(fm_rebirth_field "$STATE/.rebirth-handoff" predecessor_session)
    TRIES=$(fm_rebirth_field "$STATE/.rebirth-handoff" verify_attempts)
    case "$TRIES" in ''|*[!0-9]*) TRIES=0 ;; esac
    # A handoff whose predecessor number is unreadable cannot support a
    # comparison. Say that, rather than comparing against an empty string.
    case "$PREV_TOKENS" in
      ''|*[!0-9]*)
        "$BRIDGE" note --project firstmate \
          --title "session rebirth premise unverifiable: the predecessor's footprint was not recorded" \
          --body "A rebirth handoff for $PREV_SESSION carried no readable predecessor reading, so there is no number for the successor to prove smaller." \
          --quiet 2>/dev/null || true
        rm -f "$STATE/.rebirth-handoff" 2>/dev/null || true
        printf 'unverifiable: the handoff carries no readable predecessor reading\n'
        exit 1
        ;;
    esac
    MAX_TRIES=${FM_REBIRTH_VERIFY_TRIES:-3}
    case "$MAX_TRIES" in ''|*[!0-9]*|0) MAX_TRIES=3 ;; esac
    if NOW_TOKENS=$(fm_rebirth_footprint_read "$TRANSCRIPT"); then
      if [ "$NOW_TOKENS" -lt "$PREV_TOKENS" ]; then
        BODY=$(printf 'The successor came up at %s provider tokens against the predecessor'\''s %s, so the rebirth did what it claimed. Threshold %s.' \
          "$NOW_TOKENS" "$PREV_TOKENS" "$(fm_rebirth_threshold)")
        TITLE="session reborn: $NOW_TOKENS tokens, down from $PREV_TOKENS"
      else
        # The premise FAILED. This is the reading the whole mechanism exists to
        # take, so it is reported as loudly as a success, never swallowed.
        BODY=$(printf 'The successor came up at %s provider tokens against the predecessor'\''s %s - the rebirth did NOT reduce the footprint. Investigate before trusting the threshold machinery.' \
          "$NOW_TOKENS" "$PREV_TOKENS")
        TITLE="session rebirth did not reduce the footprint: $NOW_TOKENS vs $PREV_TOKENS"
      fi
      "$BRIDGE" note --project firstmate --title "$TITLE" --body "$BODY" --quiet 2>/dev/null || true
      rm -f "$STATE/.rebirth-handoff" 2>/dev/null || true
      printf '%s\n' "$TITLE"
      exit 0
    fi
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
      # Unknown after a bounded wait is reported as unknown. Deleting the handoff
      # quietly would leave a rebirth whose premise nobody ever checked looking
      # exactly like one that was verified.
      "$BRIDGE" note --project firstmate \
        --title "session rebirth premise unverified: the successor's own footprint could not be read" \
        --body "Predecessor $PREV_SESSION was reborn at $PREV_TOKENS provider tokens, but the successor's transcript yielded no usable reading in $TRIES turn ends. The rebirth happened; whether it helped is unknown." \
        --quiet 2>/dev/null || true
      rm -f "$STATE/.rebirth-handoff" 2>/dev/null || true
      printf 'unverified: no usable reading after %s attempts\n' "$TRIES"
      exit 1
    fi
    sed -i.bak "s/^verify_attempts=.*/verify_attempts=$TRIES/" "$STATE/.rebirth-handoff" 2>/dev/null || true
    rm -f "$STATE/.rebirth-handoff.bak" 2>/dev/null || true
    printf 'pending: the successor has not produced a readable footprint yet (attempt %s of %s)\n' "$TRIES" "$MAX_TRIES"
    exit 1
    ;;

  *)
    usage
    exit 2
    ;;
esac
exit 0
