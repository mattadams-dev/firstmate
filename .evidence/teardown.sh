#!/usr/bin/env bash
# Teardown probe: does tests/fm-remote-job.test.sh's EXIT trap race the worker
# tree it is trying to remove?
#
# The trap is:  kill "$(cat worker.pid)" ; rm -rf -- "$TMP_ROOT"
# It signals the recorded --serve child and immediately removes the tree, with no
# wait for the child's shutdown or for the Linux restart supervisor above it.
# This probe reproduces that exact shape and reports whether rm fails.
#
# Usage: teardown.sh <shutdown-delay-seconds>   (stands in for a loaded runner)
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
DELAY=${1:-0}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-teardown.XXXXXX")
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.local/bin"

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
# Perturb the shutdown path only: make the child slow to finish exiting, which is
# what a loaded runner does to it.
if [ "$DELAY" != 0 ]; then
  perl -0pi -e "s/(\n  worker_stop_active_execution \|\| \{)/\n  sleep $DELAY\$1/" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
  grep -q "sleep $DELAY" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" || { echo "injection failed"; exit 2; }
fi
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
SUPERVISOR_PID=$!
for _ in $(seq 1 200); do [ -f "$STATE_ROOT/worker.ready" ] && break; sleep 0.05; done
[ -f "$STATE_ROOT/worker.ready" ] || { echo "worker never became ready"; rm -rf -- "$TMP_ROOT"; exit 1; }
CHILD_PID=$(cat "$STATE_ROOT/worker.pid")

printf 'shutdown_delay=%ss supervisor=%s child=%s\n' "$DELAY" "$SUPERVISOR_PID" "$CHILD_PID"

# --- the test's teardown, verbatim in shape ---------------------------------
kill "$CHILD_PID" 2>/dev/null || true
RM_ERR=$(rm -rf -- "$TMP_ROOT" 2>&1)
RM_RC=$?
# ----------------------------------------------------------------------------

if [ -n "$RM_ERR" ]; then
  printf 'rm_stderr: %s\n' "$RM_ERR"
  printf 'TEARDOWN_RACE=REPRODUCED\n'
else
  printf 'rm_stderr: (none)  rc=%s\n' "$RM_RC"
  if [ -d "$TMP_ROOT" ]; then
    printf 'TEARDOWN_RACE=partial - rm was silent but the tree survives\n'
  else
    printf 'TEARDOWN_RACE=not reproduced\n'
  fi
fi
kill -TERM "$SUPERVISOR_PID" 2>/dev/null || true
sleep "$(awk -v d="$DELAY" 'BEGIN{print d+1}')"
kill -KILL "$SUPERVISOR_PID" 2>/dev/null || true
pkill -f "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" 2>/dev/null || true
sleep 0.3
rm -rf -- "$TMP_ROOT" 2>/dev/null || true
