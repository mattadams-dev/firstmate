#!/usr/bin/env bash
# fm-session-launch.sh - run a firstmate primary session under a wrapper that
# relaunches it fresh when the session ends because a rebirth was armed.
#
# Start the captain's session through this instead of running the harness
# directly:
#     bin/fm-session-launch.sh -- claude
# Everything after `--` is the launch command, run verbatim in the foreground so
# the harness owns the terminal exactly as it does unwrapped. When the session
# ends for any ordinary reason the wrapper exits with the harness's own status
# and gets out of the way. It relaunches on exactly one condition: a rebirth was
# armed at a proven-quiescent moment and this exit is that rebirth.
#
# WHY THE LOOP IS HERE AND NOT IN THE SESSION. A session cannot restart itself:
# by the time the context is worth shedding, the process holding it is the one
# that would have to act. Something outside it has to survive the exit, and the
# smallest something is the shell that launched it.
#
# THE SESSION IS NEVER TERMINATED, and that is a design commitment rather than
# an omission. The rebirth is ASKED FOR - bin/fm-rebirth.sh types the harness's
# own exit command into a composer it has proven empty - so by the time this
# wrapper runs, the session has already ended itself. bin/fm-safe-kill.sh, the
# fleet's single owner of termination, REFUSES to signal a live harness session,
# and that refusal is right: whether ending a given process is safe was never
# something process inspection could establish. A session that ignores its exit
# command therefore produces an armed record that expires and a rebirth the
# daemon re-attempts on its next tick - never a kill, never a pattern match,
# never a judgement made by looking at a process.
#
# ONE PROCESS DOES HAVE TO GO, and it goes through that helper. A watcher armed
# by the dying session outlives it: it is still alive, still refreshing its
# beacon, and still holding the home's watcher lock - so the successor's turn-end
# guard reads supervision as healthy and does not arm its own, while the wake
# that watcher eventually produces is addressed to a session that no longer
# exists. Retiring it is exactly the case the helper was built for: the target is
# named by state/.watch.lock rather than chosen by this script, its identity is
# verified against what that lock recorded, and every refusal is recorded and
# escalated. A pid this wrapper picked by looking at processes would be the
# unsafe judgement the helper exists to make unavailable.
#
# A refusal is escalated, never worked around. This wrapper does not retry it,
# does not fall back to a signal of its own, and does not go looking for another
# pid - but it does still relaunch, because leaving the home with no session at
# all is worse than leaving behind a watcher this was not authorised to end, and
# the successor's own supervision reconciles that on its first turn.
#
# THE COMMAND MUST START A FRESH SESSION. A resume or continue flag would bring
# back the very transcript the rebirth exists to shed, so it is refused here at
# startup, where the fix is one edit away, rather than discovered hours later as
# a rebirth that changed nothing.
#
# Options (before --):
#   --max-rebirths N   stop relaunching after N rebirths in one wrapper run
#                      (default 24; a working day at one rebirth every two to
#                      three hours is well under this)
#   --min-uptime S     a rebirth claimed by a session that lived less than S
#                      seconds counts as a fast exit; two consecutive fast exits
#                      stop the loop (default 60)
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_SESSION_LAUNCH_REBIRTH (the
# bin/fm-rebirth.sh path) and FM_SESSION_LAUNCH_SAFE_KILL (the
# bin/fm-safe-kill.sh path). The last two are test seams; production always
# resolves them to the real scripts, and the helper - not this wrapper - owns the
# verified-identity decision either way.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REBIRTH="${FM_SESSION_LAUNCH_REBIRTH:-$SCRIPT_DIR/fm-rebirth.sh}"
SAFE_KILL="${FM_SESSION_LAUNCH_SAFE_KILL:-$SCRIPT_DIR/fm-safe-kill.sh}"

MAX_REBIRTHS=24
MIN_UPTIME=60

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-session-launch: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --max-rebirths) [ $# -gt 1 ] || die "--max-rebirths requires a value"; MAX_REBIRTHS=$2; shift 2 ;;
    --min-uptime) [ $# -gt 1 ] || die "--min-uptime requires a value"; MIN_UPTIME=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "unknown option: $1 (the launch command goes after --)" ;;
  esac
done

case "$MAX_REBIRTHS" in ''|*[!0-9]*) die "--max-rebirths must be a whole number" ;; esac
case "$MIN_UPTIME" in ''|*[!0-9]*) die "--min-uptime must be whole seconds" ;; esac
[ $# -gt 0 ] || die "no launch command given; run it as: $(basename "$0") -- <command> [args...]"
command -v "$1" >/dev/null 2>&1 || die "launch command not found: $1"

# A continuation flag defeats the whole mechanism, so it is refused before the
# first launch rather than after the first pointless rebirth.
for arg in "$@"; do
  case "$arg" in
    --continue|--resume|-c|-r|--fork-session)
      die "the launch command carries '$arg', which would resume the transcript a rebirth exists to shed; launch a fresh session instead" ;;
  esac
done

mkdir -p "$STATE" 2>/dev/null || true

# retire_predecessor_watcher: end the watcher the dying session armed, using the
# ONLY selector the termination helper accepts - a pid the home's watcher lock
# already names. This wrapper reads the lock and passes the pid through; every
# judgement about whether that pid is safe to signal stays in the helper.
#
# Outcomes, distinguished rather than collapsed: 0 is retired, 6 is already gone
# (the common case - the watcher usually dies with the session that forked it),
# and everything else is a refusal or an unfinished stop that gets reported and
# left alone.
retire_predecessor_watcher() {
  local pid status
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  "$SAFE_KILL" --pid "$pid" --role watcher --state "$STATE" \
    --reason "the session that armed this watcher was reborn, so its wake has nowhere to be delivered" \
    >/dev/null 2>&1
  status=$?
  case "$status" in
    0|6) return 0 ;;
    *)
      printf 'fm-session-launch: the predecessor watcher (pid %s) could not be retired (fm-safe-kill exit %s); relaunching anyway, and the successor reconciles supervision on its first turn. See %s/.safe-kill.log.\n' \
        "$pid" "$status" "$STATE" >&2
      return 0
      ;;
  esac
}

rebirths=0
fast_exits=0
while :; do
  started=$(date +%s)
  "$@"
  status=$?
  lived=$(( $(date +%s) - started ))

  # `claim` is the ONLY thing that distinguishes a rebirth from the captain
  # closing their session. It consumes a fresh armed record and returns non-zero
  # for every other exit, so an ordinary quit is never second-guessed into a
  # relaunch.
  if ! "$REBIRTH" claim; then
    exit "$status"
  fi

  rebirths=$(( rebirths + 1 ))
  if [ "$lived" -lt "$MIN_UPTIME" ]; then
    fast_exits=$(( fast_exits + 1 ))
  else
    fast_exits=0
  fi

  if [ "$fast_exits" -ge 2 ]; then
    printf 'fm-session-launch: two consecutive sessions claimed a rebirth after less than %ss; stopping rather than looping. The last session exited with status %s.\n' \
      "$MIN_UPTIME" "$status" >&2
    exit "$status"
  fi
  if [ "$rebirths" -gt "$MAX_REBIRTHS" ]; then
    printf 'fm-session-launch: %s rebirths in one wrapper run exceeds --max-rebirths; stopping rather than looping.\n' \
      "$rebirths" >&2
    exit "$status"
  fi

  retire_predecessor_watcher
  printf 'fm-session-launch: rebirth %s - relaunching a fresh session. The predecessor'\''s footprint is recorded for the successor to prove smaller.\n' \
    "$rebirths" >&2
done
