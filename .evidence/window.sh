#!/usr/bin/env bash
# Isolate the "the worker expires queued jobs before they can mutate" block from
# tests/fm-remote-job.test.sh and measure the timing margin it depends on.
#
# Usage: window.sh [injected-delay-seconds]
# The injected delay stands in for a loaded runner slowing the test's own fixture
# setup between staging the queued job and rewriting its durable queue deadline.
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
INJECT=${1:-0}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-window.XXXXXX")
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.local/bin"

cleanup() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then kill "$(cat "$STATE_ROOT/worker.pid")" 2>/dev/null || true; fi
  pkill -f "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" 2>/dev/null || true
  sleep 0.4
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-timeout-job.sh" <<'SH'
#!/bin/bash
sleep 3
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=5
export FM_REMOTE_JOB_TIMEOUT=5
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 200); do [ -f "$STATE_ROOT/worker.ready" ] && break; sleep 0.05; done
[ -f "$STATE_ROOT/worker.ready" ] || { echo "worker never became ready"; exit 1; }

now() { date +%s.%N; }

# --- the block under test, verbatim in shape, instrumented ------------------
QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
T_DETECT=$(now)
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || { echo "the blocking job did not begin running"; exit 1; }
FIRST_DEADLINE=$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")

[ "$INJECT" = 0 ] || sleep "$INJECT"

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
T_STAGED=$(now)
ORIGINAL_QD=$(cat "$STATE_ROOT/jobs/$JOB_ID/queue_deadline")
printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"
T_WRITTEN=$(now)
OBSERVED_STATE_AT_WRITE=$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB_ID" 2>/dev/null || true)

fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || { echo "first wait failed: $FM_REMOTE_JOB_ERROR"; exit 1; }
FIRST_EXIT=$FM_REMOTE_JOB_EXIT
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || { echo "second wait failed: $FM_REMOTE_JOB_ERROR"; exit 1; }

printf 'inject_delay=%s\n' "$INJECT"
printf 'first_job_deadline=%s\n' "$FIRST_DEADLINE"
printf 'queued_original_queue_deadline=%s\n' "$ORIGINAL_QD"
printf 'detect_running_at=%s\n' "$T_DETECT"
printf 'queued_job_staged_at=%s\n' "$T_STAGED"
printf 'queue_deadline_rewritten_at=%s\n' "$T_WRITTEN"
printf 'margin_seconds_before_worker_free=%s\n' \
  "$(awk -v d="$FIRST_DEADLINE" -v w="$T_WRITTEN" 'BEGIN{printf "%.3f", d-w}')"
printf 'queued_state_when_rewritten=%s\n' "$OBSERVED_STATE_AT_WRITE"
printf 'first_job_exit=%s\n' "$FIRST_EXIT"
printf 'queued_job_exit=%s\n' "$FM_REMOTE_JOB_EXIT"
if [ -e "$QUEUED_SIDE_EFFECT" ]; then
  printf 'queued_job_mutated=yes\n'
else
  printf 'queued_job_mutated=no\n'
fi
if [ "$FM_REMOTE_JOB_EXIT" -eq 124 ]; then
  printf 'VERDICT=assertion-would-pass\n'
else
  printf 'VERDICT=assertion-would-FAIL (the CI symptom)\n'
fi
