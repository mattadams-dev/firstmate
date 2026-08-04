#!/usr/bin/env bash
# H1: is the singleton keyed by an ADDRESS rather than a home IDENTITY?
#  B1 - same physical state dir via different path strings: does the lock hold?
#  B2 - two path strings that are different files for the same logical home:
#       do two watchers coexist, each believing it is the singleton?
set -u
ROOT=${1:?root}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/state"
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/tmux"; chmod +x "$FAKE/tmux"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/fm-crew-state.sh"; chmod +x "$FAKE/fm-crew-state.sh"
seed() { printf '%s\n' fm-pr-check-migration-scan-v1 > "$1/.pr-check-migration-scan-v1"
         printf '%s\n' fm-pr-check-migration-v1 > "$1/.pr-check-migration-v1"
         chmod 0600 "$1"/.pr-check-migration-*; }
seed "$HOME_DIR/state"
ln -s "$HOME_DIR" "$TMP/home-link"

start() { PATH="$FAKE:$PATH" env FM_STATE_OVERRIDE="$1" FM_POLL=2 FM_CHECK_INTERVAL=999999 \
  FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 "$ROOT/bin/fm-watch.sh" > "$2" 2>&1 & echo $!; }

echo "--- B1: same physical dir, different path strings ---"
A=$(start "$HOME_DIR/state" "$TMP/a.out")
sleep 1
B=$(start "$TMP/home-link/state" "$TMP/b.out")
C=$(start "$HOME_DIR/./state" "$TMP/c.out")
sleep 2
live=0; for p in $A $B $C; do kill -0 "$p" 2>/dev/null && live=$((live+1)); done
echo "live watchers on the same physical state dir: $live (expect 1)"
[ "$live" -eq 1 ] && echo "  B1: singleton HELD across differing path strings" \
                  || echo "  B1: singleton FAILED across differing path strings"
kill $A $B $C 2>/dev/null; wait $A $B $C 2>/dev/null
sleep 0.5

echo "--- B2: one logical home, two state addresses ---"
# The shape a firstmate task worktree produces: same repo, same logical fleet,
# but FM_ROOT (and therefore STATE) resolves somewhere else.
ALT="$TMP/worktree/state"; mkdir -p "$ALT"; seed "$ALT"
rm -rf "$HOME_DIR/state"/.watch.lock* 2>/dev/null
D=$(start "$HOME_DIR/state" "$TMP/d.out")
E=$(start "$ALT" "$TMP/e.out")
sleep 2
live=0; for p in $D $E; do kill -0 "$p" 2>/dev/null && live=$((live+1)); done
echo "live watchers across two state addresses: $live (2 = address-keyed, not identity-keyed)"
echo "  process table shows: $(pgrep -fc 'fm-watch\.sh' 2>/dev/null || echo '?') matching 'fm-watch.sh'"
echo "  lock A holder=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || echo none) home=$(cat "$HOME_DIR/state/.watch.lock/fm-home" 2>/dev/null || echo none)"
echo "  lock B holder=$(cat "$ALT/.watch.lock/pid" 2>/dev/null || echo none) home=$(cat "$ALT/.watch.lock/fm-home" 2>/dev/null || echo none)"
kill $D $E 2>/dev/null; wait $D $E 2>/dev/null
