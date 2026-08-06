#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
#
# The lock record is line-addressed (bin/fm-session-lock-lib.sh owns the format):
#   line 1  the harness (agent) process PID found by walking the shell's
#           ancestry, which lives as long as the firstmate session - unlike the
#           transient subshell PID of any one tool call, which is dead moments
#           after it is written. Other readers refuse to signal this pid, so it
#           stays line 1 and stays a pid.
#   line 2  session=<session-id>, when this session's id is observable. This is
#           the line ownership is decided from, because a process id cannot
#           survive the CLI/harness split (docs/verification/session-identity.md).
#
# A session reclaiming its OWN lock after its process identity changed is the
# case this exists to allow. Every other contended case still refuses: a live
# holder naming a different session, a live holder on a lock with no session
# record whose pid is not ours, and any lock this process cannot verify it wrote.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(fm_session_lock_pid "$STATE") || {
    echo "lock: unreadable"
    exit 0
  }
  # The session is APPENDED rather than folded into these lines. Both are read
  # by other suites and by operators scanning output; a reshaped message is a
  # silent break, while a suffix is not.
  old_session=$(fm_session_lock_session "$STATE") || old_session=
  suffix=
  [ -z "$old_session" ] || suffix=", session $old_session"
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old$suffix"
  else
    echo "lock: stale (pid $old dead or not a harness)$suffix"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
# An unobservable session id is not a failure to acquire: harnesses other than
# Claude Code publish no session id here, and refusing them would take the whole
# fleet read-only. It degrades to the pre-existing pid basis for THIS lock only,
# which is never weaker than what that home had before.
#
# The environment source is trusted only when the harness we resolved is
# genuinely Claude Code. FM_SESSION_ID stays trusted unconditionally because a
# caller setting it has already read the value from an authoritative payload.
my_session=$(fm_session_id_self) || my_session=
if [ -n "$my_session" ] && [ -z "${FM_SESSION_ID:-}" ] && ! fm_harness_pid_is_claude "$me"; then
  my_session=
fi
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(fm_session_lock_pid "$STATE") || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  old_session=$(fm_session_lock_session "$STATE") || old_session=
  if [ -n "$my_session" ] && [ -n "$old_session" ]; then
    # Both sides carry a session id, so the session id decides. A live holder
    # naming another session still refuses; our own session reclaims its lock
    # however far its process identity has drifted.
    if [ "$old_session" != "$my_session" ] && fm_harness_pid_alive "$old"; then
      echo "error: another live firstmate session holds the lock (session $old_session, pid $old); operate read-only until resolved" >&2
      exit 1
    fi
  elif [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    # Either side missing a session id falls back to the pid basis unchanged,
    # which refuses at least as often as the session basis would.
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ -n "$my_session" ]; then
  record=$(printf '%s\nsession=%s\n' "$me" "$my_session")
else
  record=$(printf '%s' "$me")
fi
if ! { printf '%s\n' "$record" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(fm_session_lock_pid "$STATE") || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
written_session=$(fm_session_lock_session "$STATE") || written_session=
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ] || [ "$written_session" != "$my_session" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if [ -n "$my_session" ]; then
  echo "lock acquired: harness pid $me, session $my_session"
else
  echo "lock acquired: harness pid $me"
fi
