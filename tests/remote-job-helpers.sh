#!/usr/bin/env bash
# tests/remote-job-helpers.sh - shared teardown for suites that launch a
# remote-job worker.
#
# Source this from a test file that starts bin/fm-remote-job-worker.sh:
#   # shellcheck source=tests/remote-job-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/remote-job-helpers.sh"
#
# It owns one contract: stopping a worker TREE and waiting for it before the
# directory that tree lives in is removed.
#
# This does not belong in tests/lib.sh, which states in its own header that it
# deliberately excludes behavior-specific lifecycle assumptions. It follows the
# same behavior-area pattern as tests/secondmate-helpers.sh and
# tests/wake-helpers.sh instead.
#
# Why the contract is needed. What these suites launch is worker_supervise_linux,
# not the worker itself: it respawns its --serve child whenever that child exits
# non-zero. Signalling only the pid recorded in worker.pid and deleting the tree
# in the same breath left the child's shutdown writing into a directory rm was
# already removing, which failed the shutdown, which is exactly the supervisor's
# respawn trigger - so the tree got rebuilt underneath the removal. That surfaces
# as "rm: cannot remove ...: Directory not empty", printed after the real
# message, so it reads as a second unrelated defect while burying the assertion
# that actually failed; and whatever rm did win left a live supervisor spinning
# in the runner. Two of the four suites leaked one on every passing run.

# fm_remote_job_fixture_worker_pid <pid> <worker-path>: true only when <pid> is
# BOTH live and running <worker-path>.
#
# A recorded pid is only a record: by teardown the process is often already gone
# and its number reused, so the file alone is never authority to signal. Callers
# pass their own mktemp-unique fixture worker path, so both facts checked here
# are self-owned and nothing outside the calling suite can be selected - the
# hazard tests/fm-remote-job.test.sh pins at "stale ownership is reclaimed
# without signaling a reused pid".
#
# The path must be an existing regular FILE, not merely non-empty. Trap bodies
# tolerate their root variable being unset so no call site depends on definition
# order under `set -u`, and when that fallback fires the argument collapses to a
# bare "/bin/fm-remote-job-worker.sh" - still non-empty, but no longer unique to
# the calling suite, so an argv substring match on it could select another
# suite's or another shard's worker. A collapsed path names no file, so refusing
# here selects nothing, which is the only safe answer.
fm_remote_job_fixture_worker_pid() { # <pid> <worker-path>
  local pid=${1:-} worker=${2:-}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$worker" ] || return 1
  case "$(ps -o args= -p "$pid" 2>/dev/null || true)" in
    *"$worker"*) return 0 ;;
  esac
  return 1
}

# fm_remote_job_stop_worker_tree <state-root> <worker-path>: stop the worker tree
# recorded in <state-root>/worker.pid, wait for it, and report to stderr when the
# stop could not be confirmed. The supervisor is reached structurally, as the
# parent of the recorded child.
#
# Always returns 0 so a caller using it from an EXIT trap under `set -e` cannot
# have the shell's exit status changed by teardown. That means the return value
# carries no outcome, so the outcome has to be observed and said out loud: after
# the bounded wait escalates to the uncatchable signal, both pids are re-tested
# and any that survive are named on stderr. A silent return here would let a
# caller's following `rm -rf` race a process nobody knows is still running, which
# is exactly how the "Directory not empty" removal failure reads as unrelated.
fm_remote_job_stop_worker_tree() { # <state-root> <worker-path>
  local state=$1 worker=$2 child supervisor unconfirmed _i
  child=
  if [ -f "$state/worker.pid" ]; then
    child=$(tr -d ' \n' < "$state/worker.pid" 2>/dev/null || true)
  fi
  fm_remote_job_fixture_worker_pid "$child" "$worker" || child=
  supervisor=
  if [ -n "$child" ]; then
    supervisor=$(ps -o ppid= -p "$child" 2>/dev/null | tr -d ' ' || true)
    fm_remote_job_fixture_worker_pid "$supervisor" "$worker" || supervisor=
  fi
  if [ -n "$supervisor" ]; then kill -TERM "$supervisor" 2>/dev/null || true; fi
  if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || true; fi
  for _i in $(seq 1 100); do
    if ! fm_remote_job_fixture_worker_pid "$supervisor" "$worker" &&
      ! fm_remote_job_fixture_worker_pid "$child" "$worker"; then
      return 0
    fi
    sleep 0.05
  done
  if [ -n "$supervisor" ]; then kill -KILL "$supervisor" 2>/dev/null || true; fi
  if [ -n "$child" ]; then kill -KILL "$child" 2>/dev/null || true; fi
  sleep 0.2
  unconfirmed=
  if fm_remote_job_fixture_worker_pid "$supervisor" "$worker"; then
    unconfirmed=$supervisor
  fi
  if fm_remote_job_fixture_worker_pid "$child" "$worker"; then
    unconfirmed="${unconfirmed:+$unconfirmed }$child"
  fi
  if [ -n "$unconfirmed" ]; then
    printf 'warning: could not confirm the worker tree under %s stopped; still present: %s\n' \
      "$state" "$unconfirmed" >&2
  fi
  return 0
}
