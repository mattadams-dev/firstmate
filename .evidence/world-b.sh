#!/usr/bin/env bash
# World-(b) probe: is the PUBLISHER able to execute a queued job whose durable
# queue deadline has already passed?
#
# The queued job is given a deadline a short distance in the FUTURE, so the
# worker's expiry check passes, and the worker is then delayed between that
# check and the command execution. If the job still mutates, the expiry
# guarantee has a hole on the code side (world b). If the worker refuses, the
# guarantee holds and the CI red cannot have come from here.
#
# Usage: world-b.sh <deadline-offset-seconds> <check-to-claim-delay-seconds>
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
OFFSET=${1:-1}
P2=${2:-3}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-worldb.XXXXXX")
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
perl -0pi -e "s/(\n    worker_claim \"\\\$job\" \|\| continue\n)/\n    sleep $P2\$1/" \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
grep -q "sleep $P2" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" || { echo "injection failed"; exit 2; }

printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
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

SIDE_EFFECT="$TMP_ROOT/side-effect"
# Stage the job BEFORE any worker exists, so the record is fully constructed and
# its deadline settled before the worker's first sight of it. No race by design.
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-touch-job.sh "$SIDE_EFFECT" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
DEADLINE=$(( $(date +%s) + OFFSET ))
printf '%s\n' "$DEADLINE" > "$STATE_ROOT/jobs/$JOB_ID/queue_deadline"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=5 \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || { echo "await error: $FM_REMOTE_JOB_ERROR"; exit 1; }
RAN_AT=$(date +%s)

printf 'deadline_offset_at_stage=+%ss  check_to_claim_delay=%ss\n' "$OFFSET" "$P2"
printf 'queue_deadline=%s completed_at=%s (deadline passed %ss before completion)\n' \
  "$DEADLINE" "$RAN_AT" "$((RAN_AT - DEADLINE))"
printf 'exit=%s\n' "$FM_REMOTE_JOB_EXIT"
if [ -e "$SIDE_EFFECT" ]; then
  printf 'mutated=yes\n'
  printf 'WORLD_B=LIVE - the worker executed a job past its durable queue deadline\n'
else
  printf 'mutated=no\n'
  printf 'WORLD_B=not reproduced - the worker refused to execute past the deadline\n'
fi
