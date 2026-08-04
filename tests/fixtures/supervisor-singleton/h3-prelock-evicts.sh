#!/usr/bin/env bash
# H3: does fm-watch.sh's PRE-LOCK migration terminate the live incumbent watcher
# before the newcomer ever reaches its own singleton gate?
set -u
ROOT=${1:?root}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; FAKE="$TMP/fakebin"
mkdir -p "$STATE" "$FAKE"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/tmux"; chmod +x "$FAKE/tmux"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/fm-crew-state.sh"; chmod +x "$FAKE/fm-crew-state.sh"
printf '%s\n' fm-pr-check-migration-scan-v1 > "$STATE/.pr-check-migration-scan-v1"
printf '%s\n' fm-pr-check-migration-v1 > "$STATE/.pr-check-migration-v1"
chmod 0600 "$STATE"/.pr-check-migration-*

env_common=(FM_STATE_OVERRIDE="$STATE" FM_POLL=2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1)

# Incumbent W1.
PATH="$FAKE:$PATH" env "${env_common[@]}" "$ROOT/bin/fm-watch.sh" > "$TMP/w1.out" 2>&1 &
W1=$!
i=0; while [ "$i" -lt 100 ] && [ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" != "$W1" ]; do sleep 0.05; i=$((i+1)); done
[ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" = "$W1" ] || { echo "PROBE-ERROR: incumbent never took the lock"; kill "$W1" 2>/dev/null; exit 1; }
echo "incumbent W1=$W1 holds the singleton"

# Make the migration scan incomplete again - the state any home lands in when a
# check artifact is added or an X shim is refreshed.
rm -f "$STATE/.pr-check-migration-scan-v1"

# Newcomer W2 starts. Its FIRST act is the pre-lock migration.
PATH="$FAKE:$PATH" env "${env_common[@]}" "$ROOT/bin/fm-watch.sh" > "$TMP/w2.out" 2>&1 &
W2=$!
i=0; while [ "$i" -lt 200 ] && kill -0 "$W1" 2>/dev/null; do sleep 0.05; i=$((i+1)); done

if kill -0 "$W1" 2>/dev/null; then
  echo "RESULT: H3 KILLED - incumbent survived the newcomer's pre-lock work"
  kill "$W1" "$W2" 2>/dev/null; exit 0
fi
echo "RESULT: H3 PROVEN - incumbent W1 was terminated by W2's PRE-LOCK migration"
echo "  W1 output: $(tr '\n' '|' < "$TMP/w1.out")"
echo "  W2 output: $(tr '\n' '|' < "$TMP/w2.out")"
echo "  lock now held by: $(cat "$STATE/.watch.lock/pid" 2>/dev/null || echo none) (W2=$W2)"
kill "$W1" "$W2" 2>/dev/null
exit 3
