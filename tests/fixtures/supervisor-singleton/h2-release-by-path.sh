#!/usr/bin/env bash
# H2: does a dying predecessor's release-by-path unlink a SUCCESSOR's lock?
set -u
ROOT=${1:?root}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FM_STATE_OVERRIDE="$TMP/state"
mkdir -p "$FM_STATE_OVERRIDE"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
LOCK="$FM_STATE_OVERRIDE/.probe.lock"

# Predecessor P acquires.
fm_lock_try_acquire "$LOCK" || { echo "PROBE-ERROR: predecessor could not acquire"; exit 1; }
PRED_OWNER=$FM_LOCK_OWNER_DIR
echo "predecessor pid=$$ ownerdir=$(basename "$PRED_OWNER") link=$(readlink "$LOCK" | xargs basename)"

# Simulate a successor rotating the lock: it creates its own owner dir with its
# own pid and re-points the path. This is the exact race H2 posits.
SUCC_OWNER=$(mktemp -d "$LOCK.owner.XXXXXX")
SUCC_PID=99999
printf '%s\n' "$SUCC_PID" > "$SUCC_OWNER/pid"
rm -f "$LOCK"
ln -s "$SUCC_OWNER" "$LOCK"
echo "after rotation: link=$(readlink "$LOCK" | xargs basename) holder_pid=$(cat "$LOCK/pid")"

# Now the predecessor's EXIT trap fires: release BY PATH.
fm_lock_release "$LOCK"

if [ -L "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$SUCC_PID" ]; then
  echo "RESULT: H2 KILLED - successor lock survived predecessor release-by-path"
  exit 0
fi
echo "RESULT: H2 PROVEN - predecessor release unlinked the successor's lock (link exists: $([ -L "$LOCK" ] && echo yes || echo no))"
exit 3
