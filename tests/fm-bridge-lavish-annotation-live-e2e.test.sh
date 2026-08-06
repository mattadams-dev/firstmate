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

# THE QUEUE API IS THE OTHER VENDOR FACT THE BOARD RULES THROUGH, and v2 depends
# on it far more than v1 did: every clicked ruling goes through queuePrompt, and
# queueKey is what makes a change of mind replace an answer instead of sending a
# second one. Both are pinned against the installed binary here.
#
# It is checked HERE rather than in the browser below, and that is a limitation
# worth stating: Lavish sandboxes the artifact frame without allow-same-origin,
# so the hosting page cannot reach in and `chrome-devtools-axi eval` would be
# reading the wrong document. Measuring the API's real behaviour needs a CDP
# attach to the frame's own target - the procedure is in section 3 of
# docs/verification/bridge-board-v2.md, and that record is what this pin
# protects: if these names leave the binary, the measurement behind them is
# stale and the board's whole queue path is unproven.
for symbol in queuePrompt queueKey sendQueuedPrompts; do
  grep -qF "$symbol" "$LAVISH_DIST/cli.mjs" 2>/dev/null \
    || fail "lavish-axi $LAVISH_VERSION no longer carries '$symbol', which the board's
  queue path is built on. Every clicked ruling goes through window.lavish.queuePrompt,
  and queueKey is what stops a change of mind sending two answers. Re-measure
  section 3 of docs/verification/bridge-board-v2.md before trusting either."
done
pass "the installed lavish-axi still carries the queue API and its replace-by-key option"

# --- 2. a real browser, a real session, a real ask row ----------------------

command -v chrome-devtools-axi >/dev/null 2>&1 \
  || fail "chrome-devtools-axi is not installed, so the browser half of this guard checked nothing"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bridge-lavish-live.XXXXXX")
SESSION_NAME="fm-bridge-lavish-live-$$"
ARTIFACT_DIR="$LAB/.lavish"
ARTIFACT="$ARTIFACT_DIR/bridge-live-guard.html"
mkdir -p "$ARTIFACT_DIR" "$LAB/home/state" "$LAB/home/data/bridge"

# A hosted session outlives this script unless it is ended, and one left behind
# shows up in the captain's own Lavish list. So it is ended FIRST, while the file
# it is keyed to still exists - `lavish-axi end` resolves the path, so deleting
# the lab first would strand the session as permanently open - and on an
# interrupt as well as a clean exit, because a killed run is exactly when this
# gets forgotten.
cleanup() {
  lavish-axi end "$ARTIFACT" >/dev/null 2>&1 || true
  CHROME_DEVTOOLS_AXI_SESSION="$SESSION_NAME" chrome-devtools-axi stop >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

FM_HOME="$LAB/home" "$BRIDGE" ask -q --id live-one --project orca \
  --title "an ask to annotate" --answer "A: retire it" --answer "B: keep it" >/dev/null \
  || fail "could not seed a ledger"
FM_HOME="$LAB/home" "$RENDER" --html > "$ARTIFACT" || fail "could not render the board"

SESSION_URL=$(lavish-axi "$ARTIFACT" 2>/dev/null | sed -n 's/.*url: "\([^"]*\)".*/\1/p' | head -1)
[ -n "$SESSION_URL" ] || fail "lavish-axi $LAVISH_VERSION did not return a session URL for the board"

export CHROME_DEVTOOLS_AXI_SESSION="$SESSION_NAME"
chrome-devtools-axi open "$SESSION_URL" >/dev/null 2>&1 \
  || fail "no reachable browser for the live guard (set CHROME_DEVTOOLS_AXI_BROWSER_URL at a Chrome with remote debugging)"

# EVERY HELPER IS DEFINED HERE, ABOVE THE FIRST LINE THAT CALLS ONE. This script
# runs under `set -u` and not `set -e`, so a call to a not-yet-defined function
# does not stop it: bash reports "command not found", returns 127, and the script
# carries on into the assertions below with the exit it was supposed to take
# never taken. That is how the COULD-NOT-OBSERVE outcome - the whole reason this
# guard has three outcomes and not two - would come out as a plain FAILURE.

# uids are only valid against the snapshot that produced them, so every click
# re-snapshots first.
snap() { chrome-devtools-axi snapshot 2>&1; }

# The uid out of a snapshot line. One extractor, used everywhere, because the
# lines differ in what picks them (first match, last match, role check first)
# but never in where the uid sits.
uid_in() { printf '%s' "$1" | sed -E 's/.*uid=([^ ]+).*/\1/'; }

# THREE OUTCOMES, NOT TWO. "No annotation card" is only alarming if the page was
# actually in a state where a card could have opened: the artifact frame loaded,
# and annotate mode on. A headless browser that never finished rendering the
# frame produces the same silence, and reporting that as "the captain cannot
# answer an ask" is a false alarm - the expensive kind, because the next reader
# goes looking for a defect in the board.
#
# So: 0 = a card opened, 1 = a card did not open with the page demonstrably
# ready, 2 = the page was not in a state that could answer the question.
annotation_card_opened() {  # <uid>
  local out after
  out=$(chrome-devtools-axi click "@$1" 2>&1)
  case "$out" in
    *"Tell the agent what to change"*) return 0 ;;
  esac
  # A card can render a beat after the click returns.
  sleep 1
  after=$(snap)
  case "$after" in
    *"Tell the agent what to change"*) return 0 ;;
  esac
  page_can_answer "$after" || return 2
  return 1
}

# Was the page in a state where an annotation card COULD have opened?
page_can_answer() {  # <snapshot>
  case "$1" in
    *'RootWebArea url="about:blank"'*) return 1 ;;
    *"chrome-error://"*) return 1 ;;
  esac
  case "$1" in
    *'button "Annotate"'*pressed*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *'"A: retire it"'*) return 0 ;;
  esac
  return 1
}

could_not_observe() {  # <what was being checked>
  printf 'not ok - COULD NOT OBSERVE: %s\n' "$1" >&2
  printf '  The hosted board was not in a state that could answer the question -\n' >&2
  printf '  the artifact frame was not rendered, or annotate mode was off. This is\n' >&2
  printf '  NOT a verdict about the board. Re-run where the browser can actually\n' >&2
  printf '  render the page in the foreground.\n' >&2
  exit 2
}

dismiss_card() {
  local cancel
  cancel=$(snap | grep -oE 'uid=[^ ]+ button "Cancel"' | head -1)
  [ -n "$cancel" ] && chrome-devtools-axi click "@$(uid_in "$cancel")" >/dev/null 2>&1
  return 0
}

# Lavish holds the artifact behind a "waiting for fonts and final geometry"
# curtain until its own layout check settles, which on a headless browser can
# take a while - and it offers its own "Show anyway" reveal for exactly that.
# Waiting for the reveal, and saying so if it never comes, keeps "not revealed
# yet" from being reported as "the board rendered no ask", which would send the
# next reader after entirely the wrong thing.
revealed=0
attempt=0
while [ "$attempt" -lt 45 ]; do
  current=$(snap)
  case "$current" in
    *'"A: retire it"'*) revealed=1; break ;;
  esac
  reveal_line=$(printf '%s\n' "$current" | grep -oE 'uid=[^ ]+ button "Show anyway"' | head -1)
  if [ -n "$reveal_line" ]; then
    chrome-devtools-axi click "@$(uid_in "$reveal_line")" >/dev/null 2>&1 || true
  fi
  attempt=$((attempt + 1))
  sleep 2
done
[ "$revealed" -eq 1 ] \
  || could_not_observe "whether the board's ask rows can be annotated"

# THE ANSWER OPTION IS A CONTROL NOW, DELIBERATELY, and the live guard has to
# check the new contract rather than the old one. v1 rendered options as inert
# spans so they stayed annotatable; the captain then could not select one to
# queue a ruling, and a decision travelled by terminal instead. v2 makes them
# buttons that queue - which spends their annotatability, on purpose.
#
# So what this guard asserts here is the SHAPE, against the vendor: the option
# is a native control, which is what makes it clickable rather than annotated.
option_line=$(snap | grep -E 'uid=[^ ]+ [A-Za-z]+ "A: retire it"' | head -1)
[ -n "$option_line" ] \
  || fail "the hosted board never rendered the ask's answer option at all, so this guard proves nothing"
case "$option_line" in
  *' button "'*) : ;;
  *) fail "the board renders its answer option as something other than a native control:
  $option_line
  v2 queues a ruling from an option CLICK, and Lavish only lets a click through
  on a control - anything else is annotated instead, which is the failure that
  sent a decision to the terminal. Re-measure docs/verification/bridge-board-v2.md." ;;
esac
pass "the hosted board renders its answer options as controls, so a click can queue a ruling"

# AND THE FREE-TEXT PATH STAYS OPEN, which is the half that fails silently. If
# the ref or the title ever drifts inside a control, the card still LOOKS right
# and a ruling annotated on it arrives naming nothing.
#
# The ref, first: it is what an annotation carries to say WHICH ask was ruled on.
ref_line=$(snap | grep -E 'uid=[^ ]+ [A-Za-z]+ "O1"' | tail -1)
[ -n "$ref_line" ] || fail "the hosted board rendered no visible ref for the ask"
annotation_card_opened "$(uid_in "$ref_line")"
case "$?" in
  0) : ;;
  2) could_not_observe "whether an ask's visible ref can be annotated" ;;
  *) fail "lavish-axi $LAVISH_VERSION opened no annotation card on the ask's visible ref.
  A free-text ruling placed on this card would arrive unable to name its ask -
  re-measure docs/verification/bridge-board-v2.md." ;;
esac
dismiss_card
pass "the ask's visible ref is annotatable, so an annotation can name what it ruled on"

# And the title, which is where a reader actually places a free-text ruling.
title_line=$(snap | grep -E 'uid=[^ ]+ [A-Za-z]+ "an ask to annotate"' | tail -1)
[ -n "$title_line" ] || fail "the hosted board rendered no visible title for the ask"
annotation_card_opened "$(uid_in "$title_line")"
case "$?" in
  0) : ;;
  2) could_not_observe "whether an ask's title can be annotated" ;;
  *) fail "lavish-axi $LAVISH_VERSION opened no annotation card on the ask's title, so
  there is nothing left on the card to place a free-text ruling on." ;;
esac
dismiss_card
pass "the ask's title is annotatable, so a ruling the buttons cannot say still has somewhere to go"

echo "all live Lavish annotation guards passed against lavish-axi $LAVISH_VERSION"
