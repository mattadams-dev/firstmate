#!/usr/bin/env bash
# Does the rewritten "fresh bounded execution window" assertion still FAIL when
# the guarantee it names is actually broken?
#
# A deflaked assertion that can no longer fail is worse than the flake. This runs
# the exact two-job sequence and evaluates the new assertion's arithmetic against
# a correct worker and against a mutant whose execution window is measured from
# STAGING instead of from the claim - the precise defect the assertion names.
#
# Usage: mutation-check.sh correct|mutant
set -u

ROOT=${ROOT:?set ROOT to the firstmate repo root}
MODE=${1:-correct}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-mutcheck.XXXXXX")
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.local/bin"
cleanup() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    kill "$(cat "$STATE_ROOT/worker.pid")" 2>/dev/null || true
  fi
  sleep 0.6
  rm -rf -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
if [ "$MODE" = mutant ]; then
  # queue_deadline is stage + FM_REMOTE_JOB_QUEUE_TIMEOUT, and this probe exports
  # the SAME queue timeout to lib and worker, so this is exactly stage + timeout:
  # an execution window that does not move with the claim.
  perl -0pi -e 's/(\n    deadline=\$\(\( \$\(date \+%s\) \+ timeout \)\)\n)/\n    deadline=\$(( queue_deadline - FM_REMOTE_JOB_QUEUE_TIMEOUT + timeout ))\n/' \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
  grep -q 'queue_deadline - FM_REMOTE_JOB_QUEUE_TIMEOUT' "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" ||
    { echo "mutation failed to apply"; exit 2; }
fi

printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=30
export FM_REMOTE_JOB_TIMEOUT=10
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 300); do [ -f "$STATE_ROOT/worker.ready" ] && break; sleep 0.05; done
[ -f "$STATE_ROOT/worker.ready" ] || { echo "worker never became ready"; exit 1; }

FIRST="$TMP_ROOT/first-side-effect"
SECOND="$TMP_ROOT/second-side-effect"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-delay-job.sh 2 "$FIRST" < /dev/null > /dev/null
FIRST_JOB_ID=$FM_REMOTE_JOB_ID
FIRST_JOB_DIR="$STATE_ROOT/jobs/$FIRST_JOB_ID"
for _ in $(seq 1 200); do
  [ "$(fm_remote_job_read_state "$FIRST_JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
SECOND_STAGED_AT=$(date +%s)
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-delay-job.sh 1 "$SECOND" < /dev/null > /dev/null
JOB_ID=$FM_REMOTE_JOB_ID
JOB_DIR="$STATE_ROOT/jobs/$JOB_ID"
for _ in $(seq 1 600); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" = running ] && break
  sleep 0.05
done
SECOND_DEADLINE=$(fm_remote_job_read_deadline "$JOB_DIR" || true)
SECOND_TIMEOUT=$(fm_remote_job_read_number "$JOB_DIR" timeout || true)
case "$SECOND_DEADLINE$SECOND_TIMEOUT" in ''|*[!0-9]*) echo "could not read the durable record"; exit 1 ;; esac
GRANTED=$((SECOND_DEADLINE - SECOND_STAGED_AT - SECOND_TIMEOUT))

fm_remote_job_wait "$ACCOUNT_HOME" "$FIRST_JOB_ID" >/dev/null 2>&1 || true
WAIT_RC=0
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" >/dev/null 2>&1 || WAIT_RC=1

printf 'mode=%s\n' "$MODE"
printf 'granted_after_queue_wait=%s (assertion requires >= 1)\n' "$GRANTED"
if [ "$WAIT_RC" -eq 0 ]; then
  printf 'behavioral_exit=%s side_effect=%s\n' "$FM_REMOTE_JOB_EXIT" \
    "$([ -e "$SECOND" ] && echo present || echo absent)"
fi
if [ "$GRANTED" -ge 1 ]; then
  printf 'NEW_ASSERTION=passes\n'
else
  printf 'NEW_ASSERTION=FAILS - "queue time consumed the second job'"'"'s execution timeout"\n'
fi
