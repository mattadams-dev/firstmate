#!/usr/bin/env bash
# Decisive teardown instrument: after the test's EXIT trap sends its single kill
# to the recorded --serve child, is the worker tree actually stopped?
#
# The trap only ever signals the pid in worker.pid. On Linux the process the test
# launched is worker_supervise_linux, which respawns its child whenever that child
# exits non-zero. This probe removes the state tree the way the trap does and then
# watches whether it comes BACK - recreation after removal is the same event that
# reads as "rm: Directory not empty" when it lands during the removal instead of
# after it.
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
MODE=${1:-clean}   # clean = child exits 0 ; wedged = child's shutdown fails

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-respawn.XXXXXX")
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.local/bin"
cleanup() {
  pkill -f "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" 2>/dev/null || true
  sleep 0.4
  rm -rf -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
if [ "$MODE" = wedged ]; then
  # Stand in for a shutdown that cannot complete because the tree is vanishing
  # underneath it - the child then exits non-zero, which is the supervisor's
  # respawn trigger.
  perl -0pi -e 's/(\n  worker_clear_quarantine \|\| \{)/\n  false || {\n    WORKER_RELEASE_OWNERSHIP=0\n    exit 125\n  }$1/' \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
  grep -q 'false || {' "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" || { echo "injection failed"; exit 2; }
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
[ -f "$STATE_ROOT/worker.ready" ] || { echo "worker never became ready"; exit 1; }
CHILD_PID=$(cat "$STATE_ROOT/worker.pid")

printf 'mode=%s supervisor=%s child=%s\n' "$MODE" "$SUPERVISOR_PID" "$CHILD_PID"

# --- exactly what the test's EXIT trap does: one kill, aimed at the child ----
kill "$CHILD_PID" 2>/dev/null || true
rm -rf -- "$STATE_ROOT" 2>/dev/null || true
# ----------------------------------------------------------------------------

sleep 1.5
if kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
  printf 'supervisor_still_alive_after_trap=yes\n'
else
  printf 'supervisor_still_alive_after_trap=no\n'
fi
if [ -d "$STATE_ROOT" ]; then
  printf 'state_tree_recreated_after_removal=YES\n'
  printf 'recreated_entries: %s\n' "$(ls -A "$STATE_ROOT" 2>/dev/null | tr '\n' ' ')"
  printf 'TEARDOWN_LEAK=CONFIRMED - the trap did not stop the worker tree\n'
else
  printf 'state_tree_recreated_after_removal=no\n'
  printf 'TEARDOWN_LEAK=not observed in this mode\n'
fi
