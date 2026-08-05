#!/usr/bin/env bash
# Perturbation harness for the "the worker expires queued jobs before they can
# mutate" assertion in tests/fm-remote-job.test.sh.
#
# The captain's method: repetition samples the dice, perturbation loads them.
# The suspect boundary has two sides. This harness injects deliberate delay on
# ONE side at a time and reports whether the observed CI red
#   not ok - an expired queued job did not publish a timeout result
# appears on demand.
#
#   PUBLISHER SIDE (the code under test, bin/fm-remote-job-worker.sh)
#     P1  delay the expiry publication itself
#     P2  delay the gap between the expiry check and the claim
#   TEST SIDE (the assertion's own fixture construction)
#     P3  delay the gap between publishing the queued job and rewriting its
#         durable queue deadline
#     P4  lengthen the await (FM_REMOTE_JOB_WAIT_GRACE)
#
# Usage: perturb.sh <P1s> <P2s> <P3s> <grace> [label]
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
P1=${1:-0}
P2=${2:-0}
P3=${3:-0}
GRACE=${4:-30}
LABEL=${5:-unlabelled}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-perturb.XXXXXX")
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.local/bin"

cleanup() {
  pkill -f "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" 2>/dev/null || true
  sleep 0.5
  rm -rf -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"

# --- publisher-side injection, applied to the FIXTURE copy of the worker -----
# P1: delay the expiry publication for an expired queued job.
if [ "$P1" != 0 ]; then
  perl -0pi -e "s/(        if \[ \"\\\$\(date \+%s\)\" -ge \"\\\$queue_deadline\" \]; then\n)/\$1          sleep $P1\n/" \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
  grep -q "sleep $P1" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" || { echo "P1 injection failed"; exit 2; }
fi
# P2: delay between the queued-expiry check and the claim that starts execution.
if [ "$P2" != 0 ]; then
  perl -0pi -e "s/(\n    worker_claim \"\\\$job\" \|\| continue\n)/\n    sleep $P2\$1/" \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
  grep -q "sleep $P2" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" || { echo "P2 injection failed"; exit 2; }
fi

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
export FM_REMOTE_JOB_WAIT_GRACE="$GRACE"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 200); do [ -f "$STATE_ROOT/worker.ready" ] && break; sleep 0.05; done
[ -f "$STATE_ROOT/worker.ready" ] || { echo "worker never became ready"; exit 1; }

# --- the block under test, in its current shape -----------------------------
QUEUED_SIDE_EFFECT="$TMP_ROOT/queued-side-effect"
FM_REMOTE_JOB_TIMEOUT=1
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-timeout-job.sh < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 100); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] \
  || { echo "the blocking job did not begin running"; exit 1; }

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$QUEUED_SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID

# TEST-SIDE injection P3: the gap between the queued job becoming visible to the
# worker and the fixture rewriting its durable deadline.
[ "$P3" = 0 ] || sleep "$P3"

printf '%s\n' "$(fm_remote_job_read_deadline "$FIRST_JOB_DIR")" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"

WAIT1_RC=0
fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" || WAIT1_RC=1
WAIT2_RC=0
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || WAIT2_RC=1

printf '=== %s ===\n' "$LABEL"
printf 'perturbation: P1_expiry_publish=%s P2_check_to_claim=%s P3_stage_to_rewrite=%s wait_grace=%s\n' \
  "$P1" "$P2" "$P3" "$GRACE"
if [ "$WAIT2_RC" -ne 0 ]; then
  printf 'result: the await returned an error: %s\n' "$FM_REMOTE_JOB_ERROR"
  printf 'OBSERVED_CI_RED=no (different failure: the await, not the exit value)\n'
  exit 0
fi
printf 'queued_job_exit=%s\n' "$FM_REMOTE_JOB_EXIT"
if [ -e "$QUEUED_SIDE_EFFECT" ]; then printf 'queued_job_mutated=yes\n'; else printf 'queued_job_mutated=no\n'; fi
if [ "$FM_REMOTE_JOB_EXIT" -eq 124 ]; then
  printf 'OBSERVED_CI_RED=no (assertion passes)\n'
else
  printf 'OBSERVED_CI_RED=YES  "an expired queued job did not publish a timeout result"\n'
fi
