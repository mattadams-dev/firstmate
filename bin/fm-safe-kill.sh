#!/usr/bin/env bash
# fm-safe-kill.sh - the single owner of process termination in a firstmate home.
#
# Every kill firstmate performs goes through here. Nothing else in bin/ signals a
# process it did not itself fork, and bin/fm-arm-command-policy.mjs denies the
# harness the shell forms that would let an agent do it by hand.
#
# WHY THIS EXISTS, in one sentence: whether terminating a given process is safe
# was never something process inspection could establish, so that judgment must
# not be available.
#
# Two recorded specimens set the contract.
#
#   1. `kill -TERM 17907`, 2026-08-04. The operator resolved the pid, checked its
#      identity with `ps -p 17907 -o lstart=,cmd=`, walked its descendants with
#      pstree, confirmed no crewmate hung off it, and killed it. Every step was
#      performed correctly and the result was still wrong: 17907 was a live
#      firstmate session holding this home's session lock - the captain's own
#      other session. A better inspection would not have helped. This script
#      refuses that pid because it holds state/.lock and because no supervision
#      role lock names it, and no amount of process detail can overturn either.
#
#   2. A pattern census the same afternoon reported four supervise daemons where
#      zero existed. It matched each process's whole cmdline as a substring, so
#      it counted two live crewmates - whose launch briefs quote the very script
#      names on argv - and the inspecting shell itself, whose matching expression
#      contains the patterns it searches for. Pattern selection in this fleet is
#      not merely imprecise; it is biased toward the processes most involved in
#      the problem. That is why the ONLY selector accepted here is a pid that a
#      role lock already names, and why identity is compared as whole-cmdline
#      bytes rather than tested for containment.
#
# Authority comes from the lock, never from the process. --role names the
# supervision role whose lock must ALREADY name exactly this pid, publish this
# home, and match its published identity. The lock is what authorizes the kill;
# the process only has to still be the one the lock recorded. There is no
# lockless mode: "I am fairly sure this process is mine" is precisely the
# judgment the specimens above prove unsafe, so a target no role lock names
# escalates to a human instead.
#
# A script ending a child it forked itself does not come here - it uses the
# shell builtin on a pid it owns by construction, which is a different and
# genuinely verifiable relation. This helper exists for the case where the
# target's identity has to be established from a record.
#
# Refused in every mode, whatever a role lock says:
#   - this process, or any ancestor of it;
#   - the holder of the home's session lock (state/.lock);
#   - any live verified-harness process (a session, never a supervisor);
#   - pid 0 or 1;
#   - anything whose identity cannot be read.
#
# Outcomes are distinct and never collapsed:
#   0  signalled, and the process is confirmed gone
#   2  usage error
#   3  REFUSED - proven unsafe
#   4  REFUSED - cannot be proven safe (unknown is not a "no problem found")
#   5  signalled, still alive at the deadline
#   6  the target was already gone; nothing was signalled. Distinct from 3 and 4
#      on purpose: the goal state holds, but this did not bring it about
# Every non-zero outcome prints one escalation line on stderr and appends one
# record to state/.safe-kill.log. A caller must escalate rather than proceed.
#
# Usage:
#   bin/fm-safe-kill.sh --pid <pid> --role watcher|supervise-daemon
#                       --reason <text>
#                       [--signal TERM|INT|HUP|KILL] [--wait <secs>]
#                       [--state <dir>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

TARGET=
ROLE=
SIGNAL=TERM
REASON=
WAIT_SECS=${FM_SAFE_KILL_WAIT:-5}
STATE_ARG=

usage() {
  sed -n '2,68p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pid) [ "$#" -gt 1 ] || { echo "error: --pid requires a value" >&2; exit 2; }; TARGET=$2; shift 2 ;;
    --role) [ "$#" -gt 1 ] || { echo "error: --role requires a value" >&2; exit 2; }; ROLE=$2; shift 2 ;;
    --signal) [ "$#" -gt 1 ] || { echo "error: --signal requires a value" >&2; exit 2; }; SIGNAL=$2; shift 2 ;;
    --reason) [ "$#" -gt 1 ] || { echo "error: --reason requires a value" >&2; exit 2; }; REASON=$2; shift 2 ;;
    --wait) [ "$#" -gt 1 ] || { echo "error: --wait requires a value" >&2; exit 2; }; WAIT_SECS=$2; shift 2 ;;
    --state) [ "$#" -gt 1 ] || { echo "error: --state requires a value" >&2; exit 2; }; STATE_ARG=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$STATE_ARG" ] && STATE=$STATE_ARG
[ -n "$TARGET" ] || { echo "error: --pid is required" >&2; exit 2; }
[ -n "$REASON" ] || { echo "error: --reason is required" >&2; exit 2; }
[ -n "$ROLE" ] || { echo "error: --role is required; termination is authorized only by a supervision role lock" >&2; exit 2; }
case "$TARGET" in
  ''|*[!0-9]*) echo "error: --pid must be a plain positive pid, never a pattern, name, or process group" >&2; exit 2 ;;
esac
case "$WAIT_SECS" in
  ''|*[!0-9]*) echo "error: --wait must be whole seconds" >&2; exit 2 ;;
esac
case "$SIGNAL" in
  TERM|INT|HUP|KILL) ;;
  *) echo "error: --signal must be TERM, INT, HUP, or KILL" >&2; exit 2 ;;
esac
case "$ROLE" in
  watcher|supervise-daemon) ;;
  *) echo "error: --role must be watcher or supervise-daemon" >&2; exit 2 ;;
esac

role_lock() {  # <role>
  case "$1" in
    watcher) printf '%s/.watch.lock\n' "$STATE" ;;
    supervise-daemon) printf '%s/.supervise-daemon.lock\n' "$STATE" ;;
  esac
}

LOG="$STATE/.safe-kill.log"
LOG_MAX_BYTES=${FM_SAFE_KILL_LOG_MAX_BYTES:-131072}
LOG_KEEP_LINES=${FM_SAFE_KILL_LOG_KEEP_LINES:-500}

clean_field() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-400; }

# The record is written for every outcome, including the refusals. An instrument
# that only records what it did leaves the far more interesting question - what
# it was asked to do and declined - answerable from nothing.
record() {  # <outcome> <detail>
  local size tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'ts=%s caller_pid=%s target=%s role=%s signal=%s outcome=%s reason=%s detail=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${BASHPID:-$$}" "$TARGET" "${ROLE:-none}" "$SIGNAL" \
    "$1" "$(clean_field "$REASON")" "$(clean_field "$2")" >> "$LOG" 2>/dev/null || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -ge "$LOG_MAX_BYTES" ] || return 0
  tmp="$LOG.tmp.$$"
  tail -n "$LOG_KEEP_LINES" "$LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

refuse() {  # <exit-code> <detail>
  record refused "$2"
  printf 'fm-safe-kill: REFUSED to signal pid %s: %s\n' "$TARGET" "$2" >&2
  printf 'fm-safe-kill: escalate this instead of working around it; no supervisor is ever repaired by ending a process this refused.\n' >&2
  exit "$1"
}

# --- universal refusals, evaluated before any role authority ------------------

[ "$TARGET" -gt 1 ] || refuse 3 "pid $TARGET is not an ordinary process"

SELF=${BASHPID:-$$}
[ "$TARGET" != "$SELF" ] || refuse 3 "that is this process"

# Ancestry: an agent that ends its own ancestor takes down the session issuing
# the command, which is how a supervision repair becomes a session outage.
ancestor_walk_ok=1
probe=$SELF
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
  probe=$(ps -o ppid= -p "$probe" 2>/dev/null | tr -d ' ')
  case "$probe" in
    ''|*[!0-9]*) ancestor_walk_ok=0; break ;;
  esac
  [ "$probe" -gt 1 ] || break
  [ "$probe" != "$TARGET" ] || refuse 3 "that is an ancestor of this process"
done
[ "$ancestor_walk_ok" -eq 1 ] || refuse 4 "this process's ancestry could not be resolved, so 'not an ancestor' is unproven"

# Already gone is its own outcome, not a refusal. Collapsing it into 4 made every
# caller read "the goal state already holds" as "the stop was never authorized":
# the watcher is one-shot and exits the moment an actionable wake arrives, so it
# can exit inside the window between a caller's liveness check and this one, and
# --restart then hard-failed on a watcher that had simply finished. Exit 6 says
# what was observed - the process is not running and nothing was signalled here -
# and leaves the caller to decide whether that satisfies it.
if ! fm_pid_alive "$TARGET"; then
  record already-gone "target was not running; nothing was signalled"
  printf 'fm-safe-kill: pid %s was already gone; nothing was signalled\n' "$TARGET" >&2
  exit 6
fi

TARGET_IDENTITY=$(fm_pid_identity "$TARGET") \
  || refuse 4 "pid $TARGET's identity could not be read, so it cannot be matched against any record"

# The captain's session. This is the specimen refusal: `kill -TERM 17907` failed
# a real identity check and a real ancestry check and was still wrong, because
# 17907 was the process holding this lock.
# Read line 1 through the lock-record owner, never the whole file: the record
# carries a session line below the pid, and reading the file whole would make
# this comparison silently stop matching - turning the specimen refusal into
# permission to signal the captain's own session.
SESSION_LOCK_PID=$(fm_session_lock_pid "$STATE" 2>/dev/null || true)
case "$SESSION_LOCK_PID" in
  ''|*[!0-9]*) ;;
  *) [ "$SESSION_LOCK_PID" != "$TARGET" ] || refuse 3 "pid $TARGET holds this home's session lock; it is a firstmate session, not a supervisor" ;;
esac

if fm_harness_pid_alive "$TARGET" 2>/dev/null; then
  refuse 3 "pid $TARGET is a live agent session; sessions are never terminated by firstmate"
fi

# --- authority --------------------------------------------------------------

LOCK=$(role_lock "$ROLE")
[ -e "$LOCK" ] || [ -L "$LOCK" ] \
  || refuse 3 "no $ROLE lock exists in this home, so nothing authorizes ending pid $TARGET"
LOCK_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
case "$LOCK_PID" in
  ''|*[!0-9]*) refuse 4 "the $ROLE lock does not name a readable holder" ;;
esac
[ "$LOCK_PID" = "$TARGET" ] \
  || refuse 3 "the $ROLE lock names pid $LOCK_PID, not pid $TARGET; the target was chosen from something other than the lock"
# A lock recording a DIFFERENT home is proof this supervisor is not ours.
# A lock recording NO home is not: supervision locks live inside the state
# directory they govern, so reaching this one already means operating on that
# fleet, and locks written before the field existed carry no home at all.
# Refusing those would leave every pre-upgrade home unable to end its own
# daemon - the can-never-recover direction.
LOCK_HOME=$(cat "$LOCK/fm-home" 2>/dev/null || true)
if [ -n "$LOCK_HOME" ] && [ "$LOCK_HOME" != "$FM_HOME" ]; then
  refuse 3 "the $ROLE lock belongs to home $LOCK_HOME, not $FM_HOME; another home's supervisor is never this home's to end"
fi
LOCK_IDENTITY=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
[ -n "$LOCK_IDENTITY" ] \
  || refuse 4 "the $ROLE lock publishes no holder identity, so pid reuse cannot be ruled out"
[ "$LOCK_IDENTITY" = "$TARGET_IDENTITY" ] \
  || refuse 3 "pid $TARGET is no longer the process the $ROLE lock recorded; the pid was reused"
AUTHORITY="$ROLE lock in $FM_HOME names pid $TARGET with a matching identity"

# --- signal, then verify rather than assume ----------------------------------

kill -"$SIGNAL" "$TARGET" 2>/dev/null || {
  record failed "signal $SIGNAL could not be delivered"
  printf 'fm-safe-kill: could not deliver %s to pid %s (%s)\n' "$SIGNAL" "$TARGET" "$AUTHORITY" >&2
  exit 4
}

deadline=$(( $(date +%s) + WAIT_SECS ))
while fm_pid_alive "$TARGET"; do
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 0.1
done

if fm_pid_alive "$TARGET"; then
  record signalled-still-alive "$AUTHORITY; still running after ${WAIT_SECS}s"
  printf 'fm-safe-kill: pid %s was sent %s but is still running after %ss; this is not a completed stop\n' \
    "$TARGET" "$SIGNAL" "$WAIT_SECS" >&2
  exit 5
fi

record exited "$AUTHORITY"
printf 'fm-safe-kill: pid %s exited after %s (%s)\n' "$TARGET" "$SIGNAL" "$AUTHORITY"
exit 0
