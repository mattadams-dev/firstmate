#!/usr/bin/env bash
# Live guard: the captain can actually annotate the Bridge board's ask rows.
#
# The board has no input of its own. Its whole input path is Lavish's annotation
# layer, and Lavish decides what may be annotated with a selector IT owns:
# anything matching `button,input,select,textarea,...`, or nested inside
# something that does, is skipped by its capture handlers. That verdict comes
# from the vendor, so it cannot be settled by a stub - a fake annotation layer
# would only confirm the assumption written into the fake.
#
# tests/fm-bridge.test.sh pins the same list portably, so CI enforces the board's
# side of the contract everywhere. This guard checks the OTHER side: that the
# list still is what the installed lavish-axi does, and that a real browser on a
# real hosted session still opens an annotation card on a real ask row. It fails
# naming the version, rather than degrading into a quiet pass, because a silent
# change here turns the board back into a surface the captain cannot answer.
#
# Refreshes docs/verification/bridge-hosted-input.md. Run it after every
# lavish-axi upgrade.
set -u

if [ "${FM_BRIDGE_LAVISH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_BRIDGE_LAVISH_LIVE_E2E=1 to run the live Lavish annotation guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$ROOT/bin/fm-bridge-render.sh"
BRIDGE="$ROOT/bin/fm-bridge.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

command -v lavish-axi >/dev/null 2>&1 \
  || fail "lavish-axi is not installed, so this guard checked nothing - install it or leave the opt-in off"

LAVISH_BIN=$(command -v lavish-axi)
LAVISH_REAL=$(readlink -f "$LAVISH_BIN" 2>/dev/null || printf '%s' "$LAVISH_BIN")
LAVISH_DIST=$(dirname "$LAVISH_REAL")
LAVISH_PKG="$LAVISH_DIST/../package.json"
LAVISH_VERSION=$(python3 - "$LAVISH_PKG" <<'PY' 2>/dev/null || printf 'unknown'
import json, sys
print(json.load(open(sys.argv[1]))["version"])
PY
)
printf 'lavish-axi %s at %s\n' "$LAVISH_VERSION" "$LAVISH_REAL"

# --- 1. the exclusion list is still what the board is authored against ------
#
# The board renders zero native controls precisely because Lavish will not let
# one be annotated. If upstream narrows or widens that list, the board's
# authoring rule has to be revisited - so the drift is an alarm, not a silent
# adjustment.
PINNED="button,input,select,textarea,option,optgroup,label,summary,[contenteditable]:not([contenteditable='false'])"
if ! grep -qF "$PINNED" "$LAVISH_DIST/cli.mjs" 2>/dev/null; then
  found=$(grep -oE '"button,input,select[^"]*"' "$LAVISH_DIST/cli.mjs" 2>/dev/null | head -1)
  fail "lavish-axi $LAVISH_VERSION no longer carries the annotation exclusion list the board is authored against.
  expected: $PINNED
  found:    ${found:-<nothing that looks like it - upstream restructured>}
  The board renders no native controls because of this list; re-check
  docs/verification/bridge-hosted-input.md before trusting either side."
fi
pass "the installed lavish-axi still excludes exactly the controls the board avoids"

# --- 2. a real browser, a real session, a real ask row ----------------------

command -v chrome-devtools-axi >/dev/null 2>&1 \
  || fail "chrome-devtools-axi is not installed, so the browser half of this guard checked nothing"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bridge-lavish-live.XXXXXX")
SESSION_NAME="fm-bridge-lavish-live-$$"
ARTIFACT_DIR="$LAB/.lavish"
ARTIFACT="$ARTIFACT_DIR/bridge-live-guard.html"
mkdir -p "$ARTIFACT_DIR" "$LAB/home/state" "$LAB/home/data/bridge"

cleanup() {
  lavish-axi end "$ARTIFACT" >/dev/null 2>&1 || true
  CHROME_DEVTOOLS_AXI_SESSION="$SESSION_NAME" chrome-devtools-axi stop >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

FM_HOME="$LAB/home" "$BRIDGE" ask -q --id live-one --project orca \
  --title "an ask to annotate" --answer "A: retire it" --answer "B: keep it" >/dev/null \
  || fail "could not seed a ledger"
FM_HOME="$LAB/home" "$RENDER" --html > "$ARTIFACT" || fail "could not render the board"

SESSION_URL=$(lavish-axi "$ARTIFACT" 2>/dev/null | sed -n 's/.*url: "\([^"]*\)".*/\1/p' | head -1)
[ -n "$SESSION_URL" ] || fail "lavish-axi $LAVISH_VERSION did not return a session URL for the board"

export CHROME_DEVTOOLS_AXI_SESSION="$SESSION_NAME"
chrome-devtools-axi open "$SESSION_URL" >/dev/null 2>&1 \
  || fail "no reachable browser for the live guard (set CHROME_DEVTOOLS_AXI_BROWSER_URL at a Chrome with remote debugging)"

# uids are only valid against the snapshot that produced them, so every click
# re-snapshots first.
snap() { chrome-devtools-axi snapshot 2>&1; }
uid_of() { snap | grep -oE "uid=[^ ]+ $1" | head -1 | sed -E 's/uid=([^ ]+).*/\1/'; }

# Three different worlds, three different readings. "No card opened" alone
# cannot tell them apart, and reporting the wrong one sends the next reader
# after the wrong thing entirely.
option_line=$(snap | grep -E 'uid=[^ ]+ [A-Za-z]+ "O1: A: retire it"' | head -1)
[ -n "$option_line" ] \
  || fail "the hosted board never rendered the ask's answer option at all, so this guard proves nothing"
case "$option_line" in
  *' button "'*|*' textbox "'*|*' combobox "'*|*' checkbox "'*)
    fail "the board renders its answer option as a native control:
  $option_line
  Lavish skips controls when deciding what may be annotated, so this option -
  on an ask the captain has to rule on - cannot be annotated at all." ;;
esac
option_uid=$(printf '%s' "$option_line" | sed -E 's/.*uid=([^ ]+).*/\1/')

if ! chrome-devtools-axi click "@$option_uid" 2>&1 | grep -q "Tell the agent what to change"; then
  fail "lavish-axi $LAVISH_VERSION opened no annotation card on the board's answer option.
  The board's only input path is annotation, so this is the captain being unable
  to answer an ask - re-measure docs/verification/bridge-hosted-input.md."
fi
pass "a real hosted session opens an annotation card on a real ask's answer option"

# The ref has to be annotatable too: it is what an annotation carries to say
# WHICH ask was ruled on.
ref_uid=$(uid_of 'StaticText "O1"')
[ -n "$ref_uid" ] || fail "the hosted board rendered no visible ref for the ask"
if ! chrome-devtools-axi click "@$ref_uid" 2>&1 | grep -q "Tell the agent what to change"; then
  fail "lavish-axi $LAVISH_VERSION opened no annotation card on the ask's visible ref"
fi
pass "the ask's visible ref is annotatable, so an annotation can name what it ruled on"

echo "all live Lavish annotation guards passed against lavish-axi $LAVISH_VERSION"
