#!/usr/bin/env bash
# Behavior tests for the Bridge ledger, the ONE fold, and the generated board.
#
# The failures this suite pins, each of which has already cost this fleet
# something or is one edit away from doing so:
#
#   1. THE FOLD GOES KEY-BLIND. On 2026-07-31, 60 of 65 keyed records collapsed
#      into a single default slot because the key sat in a position the parser
#      did not read - decisions silently masked each other and the authoritative
#      reader reported 1 open where 3 were. Here that is two guards: the fold
#      reads every historical key position, and CONSERVATION makes an unread
#      record impossible to hide (lines == records + malformed, on the surface).
#   2. AN UNRECOGNIZED VALUE GETS DEFAULTED. Mapping an unknown state into a
#      known bucket is the same silent-masking failure wearing a different hat.
#   3. THE TWO OUTPUT MODES DRIFT. If the board could disagree with `--state`,
#      the second fold is back and "my reading disagrees with the board" is a
#      class of bug again. Seeded ledger, both outputs, byte identity.
#   4. AN ASK DOES NOT LOOK LIKE AN ASK. The state field exists so the captain
#      never mistakes an fm-handled item for an open ask; a decision that
#      reaches the board as fm-handling is the whole surface failing at its job.
#   5. ABSENCE GETS ASSERTED FROM NOTHING. Consumed and never-arrived look
#      identical on screen, so a lifecycle answer may only say "consumed" from a
#      durable consumption record, and must say "unknown" otherwise.
#
# Everything is hermetic: a temp FM_HOME, a fixed clock, and the real scripts.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
RENDER="$ROOT/bin/fm-bridge-render.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup; rm -rf "$TMP_ROOT"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }


# A fixed clock everywhere, so every assertion is about behavior and never about
# what time the suite happened to run.
export FM_BRIDGE_NOW=2026-07-31T12:00:00Z

# A genuinely fresh home per call. mktemp rather than a counter: new_home is
# always called through command substitution, so a shell counter would increment
# in the subshell and hand every caller the SAME directory - which silently
# turns the whole suite into one shared ledger.
new_home() {  # -> a fresh isolated FM_HOME
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/state" "$home/data/bridge"
  printf '%s' "$home"
}

ledger_of() { printf '%s/data/bridge/ledger.jsonl' "$1"; }

# Read one jq-ish field out of --state without a second parser of our own.
state_query() {  # <home> <python-expression over `d`>
  FM_HOME=$1 "$RENDER" --state | python3 -c "
import json,sys
d=json.load(sys.stdin)
print($2)
"
}

# --- 1. conservation: every non-blank line is accounted for -----------------
#
# This is the guard that makes a key-blind fold impossible to hide. A parser
# that stops reading a field stops adding up here, in the output, every tick.

HOME1=$(new_home)
LEDGER1=$(ledger_of "$HOME1")
mkdir -p "$(dirname "$LEDGER1")"
cat > "$LEDGER1" <<'EOF'
{"v":1,"ts":"2026-07-31T10:00:00Z","id":"a","kind":"decision","project":"orca","title":"first","answers":["A"]}
{"v":1,"ts":"2026-07-31T10:01:00Z","id":"b","kind":"decision","project":"orca","title":"second","answers":["A"]}
{"v":1,"ts":"2026-07-31T10:02:00Z","id":"c","kind":"decision","project":"orca","title":"third","answers":["A"]}

{ not json
["a","list"]
{"v":1,"ts":"2026-07-31T10:03:00Z","kind":"event","title":"no id anywhere"}
EOF

conserved=$(state_query "$HOME1" 'd["conserved"]')
[ "$conserved" = True ] || fail "conservation: fold reported not-conserved on a well-formed count"
counts=$(state_query "$HOME1" '"%d=%d+%d" % (d["counts"]["lines_considered"], d["counts"]["records"], d["counts"]["malformed"])')
[ "$counts" = "6=3+3" ] || fail "conservation: expected 6=3+3, got $counts"
pass "conservation accounts for every non-blank line (3 folded, 3 unreadable)"

# The three unreadable lines are REPORTED, not dropped in silence.
malformed=$(state_query "$HOME1" 'len(d["malformed"])')
[ "$malformed" = 3 ] || fail "conservation: unreadable lines were not reported ($malformed)"
board=$(FM_HOME=$HOME1 "$RENDER" --html)
case "$board" in
  *"Ledger records not accounted for"*) : ;;
  *) fail "conservation: the board did not surface unreadable records" ;;
esac
pass "unreadable records are named on the board, not silently dropped"

# --- 2. the fold reads every historical key position ------------------------
#
# THE 2026-07-31 SHAPE, EXACTLY: three separately-keyed decisions where the key
# sits somewhere other than `id`. The regression to prevent is all three
# collapsing into one slot and the reader announcing 1 open where 3 are.

HOME2=$(new_home)
LEDGER2=$(ledger_of "$HOME2")
mkdir -p "$(dirname "$LEDGER2")"
cat > "$LEDGER2" <<'EOF'
{"v":1,"ts":"2026-07-31T10:00:00Z","id":"canonical","kind":"decision","project":"orca","state":"needs-captain","title":"key under id","answers":["A"]}
{"v":1,"ts":"2026-07-31T10:01:00Z","key":"alias-key","kind":"decision","project":"orca","state":"needs-captain","title":"key under key","answers":["A"]}
{"ts":"2026-07-31T10:02:00Z","item_id":"alias-item","kind":"decision","project":"orca","state":"needs-captain","title":"key under item_id, and no v at all","answers":["A"]}
EOF

open_count=$(state_query "$HOME2" 'len(d["asks"])')
[ "$open_count" = 3 ] \
  || fail "key positions: expected 3 distinct open asks, got $open_count (records collapsed into one slot - this is the 2026-07-31 failure)"
distinct=$(state_query "$HOME2" 'len(d["items"])')
[ "$distinct" = 3 ] || fail "key positions: expected 3 distinct items, got $distinct"
pass "keys in id / key / item_id positions fold to three distinct items, not one"

# Same result set across variants: the point of tolerance is that WHERE the key
# was written cannot change WHAT the reader concludes.
titles=$(state_query "$HOME2" 'sorted(v["title"][:8] for v in d["items"].values())')
[ "$titles" = "['key unde', 'key unde', 'key unde']" ] \
  || fail "key positions: variants did not produce an equivalent result set: $titles"
pass "every key-position variant yields an equivalent result set"

# --- 3. an unrecognized value is never defaulted into a known bucket --------

HOME3=$(new_home)
LEDGER3=$(ledger_of "$HOME3")
mkdir -p "$(dirname "$LEDGER3")"
cat > "$LEDGER3" <<'EOF'
{"v":1,"ts":"2026-07-31T10:00:00Z","id":"weird","kind":"decision","project":"orca","state":"pending","severity":"spicy","title":"values from a future producer"}
{"v":1,"ts":"2026-07-31T10:01:00Z","id":"future-kind","kind":"telemetry","project":"orca","title":"a kind this reader has never seen"}
EOF

kept=$(state_query "$HOME3" 'd["items"]["weird"]["state"]')
[ "$kept" = pending ] \
  || fail "unrecognized values: state was rewritten to '$kept' instead of preserved verbatim"
flagged=$(state_query "$HOME3" 'd["items"]["weird"]["recognized"]["state"]')
[ "$flagged" = False ] || fail "unrecognized values: unknown state was not flagged"
sev=$(state_query "$HOME3" 'd["items"]["weird"]["recognized"]["severity"]')
[ "$sev" = False ] || fail "unrecognized values: unknown severity was not flagged"
pass "unknown state and severity are preserved verbatim and flagged, never defaulted"

unzoned=$(state_query "$HOME3" 'd["zones"]["unzoned"]')
[ "$unzoned" = "['future-kind']" ] \
  || fail "unrecognized values: an unknown kind was filed somewhere convenient instead of shown ($unzoned)"
case "$(FM_HOME=$HOME3 "$RENDER" --html)" in
  *"Unrecognized records"*) : ;;
  *) fail "unrecognized values: the board hid an unknown-kind record" ;;
esac
pass "an unknown kind is shown on the board rather than filed into a known zone"

# An unrecognized state must not be counted as though it were understood.
unrec=$(state_query "$HOME3" 'd["summary"]["unrecognized"]')
[ "$unrec" = 1 ] || fail "unrecognized values: summary did not count the unrecognized state"
pass "an unrecognized disposition is counted as unrecognized, not as resolved"

# --- 4. state mode and the board cannot drift -------------------------------
#
# Seeded ledger, both outputs, byte identity. The board embeds the exact state
# document it was drawn from, so the two agreeing is not a coincidence to be
# re-checked by eye - it is the same bytes.

HOME4=$(new_home)
FM_HOME=$HOME4 "$BRIDGE" ask -q --id o-one --project orca \
  --title "seeded decision" --answer "A: yes" --answer "B: no" >/dev/null
FM_HOME=$HOME4 "$BRIDGE" critical -q --id c-one --project fleet \
  --title "seeded critical" --answer "A: act" >/dev/null
FM_HOME=$HOME4 "$BRIDGE" note -q --project orca --title "seeded event" \
  --pointer "https://example.invalid/1" >/dev/null
FM_HOME=$HOME4 "$BRIDGE" task -q --id t-one --project orca --phase validating >/dev/null
# A PR waiting on a merge decision: a TASK that is also an ask. It reaches the
# asks index like any other, so it needs an anchor to land on and a form to
# answer with - the fleet strip renders rows, not cards, and an ask that links
# nowhere is worse than one that was never listed.
FM_HOME=$HOME4 "$BRIDGE" task -q --id t-pr --project orca --phase pr-open \
  --state needs-captain --pointer "https://example.invalid/pull/9" \
  --answer "merge it" --answer "hold" >/dev/null

FM_HOME=$HOME4 "$RENDER" --state > "$TMP_ROOT/mode-state.json"
FM_HOME=$HOME4 "$RENDER" --html > "$TMP_ROOT/mode-board.html"
python3 - "$TMP_ROOT/mode-state.json" "$TMP_ROOT/mode-board.html" <<'PY' \
  || fail "mode drift: the board's embedded state is not byte-identical to --state output"
import re, sys
state = open(sys.argv[1]).read().rstrip("\n")
html = open(sys.argv[2]).read()
match = re.search(r'<script type="application/json" id="fm-bridge-state">\n(.*?)\n</script>',
                  html, re.S)
if match is None:
    sys.exit("board carries no embedded state document")
sys.exit(0 if match.group(1) == state else "embedded state differs from --state output")
PY
pass "the board is byte-identically the same fold that --state returns"

# And every ask the fold reports is actually reachable on the board.
python3 - "$TMP_ROOT/mode-state.json" "$TMP_ROOT/mode-board.html" <<'PY' \
  || fail "mode drift: an ask present in folded state is missing from the board"
import json, sys
doc = json.load(open(sys.argv[1]))
html = open(sys.argv[2]).read()
for key in doc["asks"]:
    if ('id="item-%s"' % key) not in html:
        sys.exit("ask %s folded but never rendered" % key)
    if doc["items"][key]["title"] not in html:
        sys.exit("ask %s rendered without its title" % key)
sys.exit(0)
PY
pass "every folded ask reaches the board with an anchor and a title"

# A task-kind ask renders as a table ROW, not a card, so it needs its own guard:
# the asks index links to it, and an index entry that lands nowhere - or lands
# somewhere with no way to answer - is worse than one that was never listed.
python3 - "$TMP_ROOT/mode-board.html" <<'ROWCHECK' \
  || fail "mode drift: a task-kind ask is listed but not answerable where it lands"
import sys
html = open(sys.argv[1]).read()
if 'id="item-t-pr"' not in html:
    sys.exit("the asks index links to #item-t-pr but the fleet strip has no such anchor")
row = html.split('id="item-t-pr"', 1)[1].split("</tr>", 1)[0]
for form in ("merge it", "hold"):
    if form not in row:
        sys.exit("the PR row offers no way to answer it: %r missing" % form)
sys.exit(0)
ROWCHECK
pass "a PR waiting on a merge decision is anchored and answerable in the fleet strip"

# --- 5. an ask looks like an ask --------------------------------------------

state_of=$(state_query "$HOME4" 'd["items"]["o-one"]["state"]')
[ "$state_of" = needs-captain ] \
  || fail "disposition: a decision landed as '$state_of' - an ask that does not look like an ask"
crit_state=$(state_query "$HOME4" 'd["items"]["c-one"]["state"]')
[ "$crit_state" = needs-captain ] || fail "disposition: a critical landed as '$crit_state'"
task_state=$(state_query "$HOME4" 'd["items"]["t-one"]["state"]')
[ "$task_state" = fm-handling ] || fail "disposition: a dispatched task landed as '$task_state'"
pass "decisions and criticals open as asks; tasks open as firstmate-handled"

# The writer STATES the disposition, so the raw stream an auditor reads already
# says what the item is rather than depending on a reader default.
grep -q '"state":"needs-captain"' "$(ledger_of "$HOME4")" \
  || fail "disposition: the writer left state implicit in the raw record"
pass "the writer records disposition explicitly in the raw stream"

# The ask is countable, findable, and cannot be scrolled past.
asks=$(state_query "$HOME4" 'len(d["asks"])')
[ "$asks" = 3 ] || fail "asks: expected 3 open asks, got $asks"
boardhtml=$(cat "$TMP_ROOT/mode-board.html")
case "$boardhtml" in
  *"<title>Bridge - 3 need you</title>"*) : ;;
  *) fail "asks: the tab title does not carry the open-ask count" ;;
esac
case "$boardhtml" in
  *'class="pin-asks"'*) : ;;
  *) fail "asks: the board has no sticky ask counter" ;;
esac
pass "the open-ask count rides in the tab title and a sticky counter"

# Resolving must clear the ask, and must carry a pointer to the outcome.
FM_HOME=$HOME4 "$BRIDGE" resolve -q --id o-one \
  --pointer "https://example.invalid/ruling" >/dev/null
after=$(state_query "$HOME4" 'len(d["asks"])')
[ "$after" = 2 ] || fail "asks: resolving did not clear the ask (still $after)"
ptr=$(state_query "$HOME4" 'd["items"]["o-one"]["pointer"]')
[ "$ptr" = "https://example.invalid/ruling" ] || fail "asks: resolved item lost its pointer"
pass "resolving clears the ask and keeps a pointer to where the outcome lives"

FM_HOME=$HOME4 "$BRIDGE" resolve --id o-one >/dev/null 2>&1 \
  && fail "asks: resolve accepted no pointer, so the outcome would be unfindable"
pass "resolve refuses without a pointer to the outcome"

FM_HOME=$HOME4 "$BRIDGE" ask --project orca --title "no answer form" >/dev/null 2>&1 \
  && fail "asks: an ask was accepted with no answer form"
pass "an ask is refused without an answer form"

# --- 6. an ask that has been waiting says so --------------------------------
#
# The captain's evidence: eight captain-kind items queued, two already ruled and
# never closed. Nothing about "open" separates those two from the rest - age
# does, so age is what the surface has to carry.

HOME6=$(new_home)
FM_HOME=$HOME6 "$BRIDGE" ask -q --id stale --project orca --title "open for days" \
  --answer "A" --ts 2026-07-28T09:00:00Z >/dev/null
FM_HOME=$HOME6 "$BRIDGE" ask -q --id recent --project orca --title "just raised" \
  --answer "A" --ts 2026-07-31T11:58:00Z >/dev/null

aging=$(state_query "$HOME6" 'd["items"]["stale"]["aging"]')
[ "$aging" = True ] || fail "aging: a three-day-old ask was not flagged as aging"
fresh=$(state_query "$HOME6" 'd["items"]["recent"]["aging"]')
[ "$fresh" = False ] || fail "aging: a two-minute-old ask was flagged as aging"
label=$(state_query "$HOME6" 'd["items"]["stale"]["age_label"]')
[ "$label" = 3d ] || fail "aging: expected a 3d label, got $label"
pass "an ask open for days is flagged aging and labelled with its age"

# Oldest first within a severity band, so forgotten items rise instead of sink.
first=$(state_query "$HOME6" 'd["asks"][0]')
[ "$first" = stale ] || fail "aging: the oldest ask is not first in the index (got $first)"
pass "the asks index puts the longest-waiting item first"

# Age is measured from the last DISPOSITION change, not from the last touch,
# so an unrelated later update cannot make a forgotten ask look fresh.
FM_HOME=$HOME6 "$BRIDGE" append -q id=stale note="an unrelated later note" \
  ts=2026-07-31T11:59:00Z >/dev/null
still=$(state_query "$HOME6" 'd["items"]["stale"]["age_label"]')
[ "$still" = 3d ] || fail "aging: an unrelated update reset the ask's age to $still"
pass "an unrelated update does not reset an ask's age"

# --- 7. lifecycle queries: consumed, pending, and honestly unknown ----------

HOME7=$(new_home)
FM_HOME=$HOME7 "$BRIDGE" append -q id=msg-consumed kind=steering phase=sent \
  project=fleet title="a steer" ts=2026-07-31T11:00:00Z >/dev/null
FM_HOME=$HOME7 "$BRIDGE" append -q id=msg-consumed kind=steering phase=delivered \
  ts=2026-07-31T11:00:05Z >/dev/null
FM_HOME=$HOME7 "$BRIDGE" append -q id=msg-consumed kind=steering phase=consumed \
  ts=2026-07-31T11:01:00Z >/dev/null
FM_HOME=$HOME7 "$BRIDGE" append -q id=msg-sent kind=steering phase=sent \
  project=fleet title="another steer" ts=2026-07-31T11:02:00Z >/dev/null

lc() {  # <home> <id> <python expression over `d`>
  FM_HOME=$1 "$RENDER" --lifecycle "$2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print($3)
"
}

verdict=$(lc "$HOME7" msg-consumed 'd["verdict"]')
[ "$verdict" = consumed ] || fail "lifecycle: a consumed message reported '$verdict'"
explained=$(lc "$HOME7" msg-consumed 'd["absence_explained"]')
[ "$explained" = True ] \
  || fail "lifecycle: a durable consumption record did not license the absence claim"
pass "a consumed message reports consumed, and that is what licenses 'absent'"

verdict=$(lc "$HOME7" msg-sent 'd["verdict"]')
[ "$verdict" = sent ] || fail "lifecycle: a sent-only message reported '$verdict'"
explained=$(lc "$HOME7" msg-sent 'd["absence_explained"]')
[ "$explained" = False ] \
  || fail "lifecycle: absence was asserted for a message with no consumption record"
pass "a sent-but-unconsumed message never licenses an absence claim"

verdict=$(lc "$HOME7" never-written 'd["verdict"]')
[ "$verdict" = unknown ] \
  || fail "lifecycle: an id with no record reported '$verdict' instead of unknown"
explained=$(lc "$HOME7" never-written 'd["absence_explained"]')
[ "$explained" = False ] || fail "lifecycle: absence was asserted from no record at all"
pass "an id with no record is unknown - never 'absent'"

# The sharp coupling: if the fold could not read every line, one of the
# unreadable ones may be the very record being asked about, so no confident
# verdict is available at any id - not even one whose own records parsed fine.
#
# Note this is STRICTER than conservation, deliberately. An unreadable line is
# still counted, so the stream below stays conserved while being only partially
# readable; a query that keyed off conservation alone would answer "consumed"
# here with full confidence. Accounting for a line is not reading it.
printf '%s\n' '{ this line cannot be parsed' >> "$(ledger_of "$HOME7")"
conserved=$(state_query "$HOME7" 'd["conserved"]')
[ "$conserved" = True ] \
  || fail "lifecycle: an unreadable-but-counted line should still conserve"
verdict=$(lc "$HOME7" msg-consumed 'd["verdict"]')
[ "$verdict" = unknown ] \
  || fail "lifecycle: reported '$verdict' over a stream it could not fully read"
readable=$(lc "$HOME7" msg-consumed 'd["fully_readable"]')
[ "$readable" = False ] || fail "lifecycle: did not report the stream as partially unreadable"
explained=$(lc "$HOME7" msg-consumed 'd["absence_explained"]')
[ "$explained" = False ] \
  || fail "lifecycle: still licensed an absence claim over an unreadable stream"
pass "a query over a partially-unreadable stream degrades to unknown, even when conserved"

# --- 8. steering records are substrate, not captain-facing noise ------------

HOME8=$(new_home)
FM_HOME=$HOME8 "$BRIDGE" append -q id=s1 kind=steering phase=sent project=fleet \
  title="machinery" >/dev/null
FM_HOME=$HOME8 "$BRIDGE" ask -q --id real --project orca --title "a real ask" \
  --answer "A" >/dev/null
tally=$(state_query "$HOME8" 'd["summary"]["needs-captain"]')
[ "$tally" = 1 ] || fail "substrate: steering records leaked into the captain's tallies"
counted=$(state_query "$HOME8" 'd["substrate"]["steering"]["items"]')
[ "$counted" = 1 ] || fail "substrate: steering records were not counted at all"
pass "steering lifecycle is counted as substrate and kept out of captain tallies"

# A new event kind is an ordinary addition: it needed no migration and it folds
# through the same path as everything else.
conserved=$(state_query "$HOME8" 'd["conserved"]')
[ "$conserved" = True ] || fail "substrate: adding a second producer broke conservation"
pass "a second producer's records fold through the identical path"

# --- 9. the record linter reads through the fold, and finds real problems ---

HOME9=$(new_home)
LEDGER9=$(ledger_of "$HOME9")
mkdir -p "$(dirname "$LEDGER9")"
cat > "$LEDGER9" <<'EOF'
{"v":1,"ts":"2026-07-31T10:00:00Z","id":"no-pointer","kind":"decision","project":"orca","state":"resolved","title":"ruled but unfindable"}
{"v":1,"ts":"2026-07-31T10:01:00Z","id":"no-form","kind":"decision","project":"orca","state":"needs-captain","title":"an ask with no way to answer it"}
EOF
lint_out=$(FM_HOME=$HOME9 "$BRIDGE" lint)
case "$lint_out" in
  *"resolved with no pointer"*) : ;;
  *) fail "lint: did not flag a resolved decision with no pointer" ;;
esac
case "$lint_out" in
  *"ask with no answer form"*) : ;;
  *) fail "lint: did not flag an ask with no answer form" ;;
esac
pass "the linter flags unfindable outcomes and unanswerable asks"

FM_HOME=$HOME9 "$BRIDGE" lint --strict >/dev/null 2>&1 \
  && fail "lint --strict returned success despite real problems"
pass "lint --strict fails when the record has problems"

HOME9B=$(new_home)
FM_HOME=$HOME9B "$BRIDGE" ask -q --id fine --project orca --title "well-formed" \
  --answer "A" >/dev/null
FM_HOME=$HOME9B "$BRIDGE" lint --strict >/dev/null 2>&1 \
  || fail "lint --strict failed on a clean record"
pass "lint --strict passes on a clean record"

# --- 10. an empty or missing ledger is honest about being empty -------------

HOME10=$(new_home)
empty_conserved=$(state_query "$HOME10" 'd["conserved"]')
[ "$empty_conserved" = True ] || fail "empty ledger: reported not-conserved"
present=$(state_query "$HOME10" 'd["ledger"]["present"]')
[ "$present" = False ] || fail "empty ledger: claimed a ledger exists"
case "$(FM_HOME=$HOME10 "$RENDER" --html)" in
  *"because nothing has been written, not because"*) : ;;
  *) fail "empty ledger: the board did not distinguish empty from nothing-happened" ;;
esac
pass "a missing ledger renders as explicitly empty, not as a quiet all-clear"

# --- 11. the tick: cheap when nothing changed, honest about both clocks -----
#
# Board freshness IS supervision freshness, so a frozen clock and a dead
# supervision cycle must not look the same. The tick therefore skips the BODY
# when the ledger is unchanged, but never skips saying when it last checked.

HOME11=$(new_home)
FM_HOME=$HOME11 "$BRIDGE" ask -q --id tick-one --project orca \
  --title "something to render" --answer "A" >/dev/null
BOARD=$(FM_HOME=$HOME11 "$RENDER" --path)

FM_BRIDGE_NOW=2026-07-31T12:00:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: cold render failed"
[ -f "$BOARD" ] || fail "tick: cold render wrote no board"
[ -f "$HOME11/state/.bridge-render" ] || fail "tick: cold render wrote no change stamp"
pass "the first tick renders the board and records a change stamp"

cp "$BOARD" "$TMP_ROOT/before-skip.html"
FM_BRIDGE_NOW=2026-07-31T12:03:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: skip path failed"
diff <(grep -v 'FM-FRESH' "$TMP_ROOT/before-skip.html") <(grep -v 'FM-FRESH' "$BOARD") \
  >/dev/null || fail "tick: an unchanged ledger regenerated the board body"
grep -q 'checked <span class="clock">2026-07-31T12:03:00Z' "$BOARD" \
  || fail "tick: the skip path did not advance the checked clock"
grep -q 'content as of <span class="clock">2026-07-31T12:00:00Z' "$BOARD" \
  || fail "tick: the skip path moved the content clock, which did not change"
pass "an unchanged ledger restamps only the freshness line, advancing checked but not content"

FM_HOME=$HOME11 "$BRIDGE" note -q --project orca --title "a new fact" >/dev/null
FM_BRIDGE_NOW=2026-07-31T12:06:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: re-render after a ledger change failed"
grep -q 'content as of <span class="clock">2026-07-31T12:06:00Z' "$BOARD" \
  || fail "tick: a changed ledger did not advance the content clock"
grep -q 'a new fact' "$BOARD" || fail "tick: a changed ledger did not pick up the new record"
pass "a changed ledger re-renders the body and advances both clocks"

# The board is generated. A hand edit is not a place to put facts, and the next
# tick says so by overwriting it.
printf '<!-- hand edit -->\n' >> "$BOARD"
FM_HOME=$HOME11 "$BRIDGE" note -q --project orca --title "yet another fact" >/dev/null
FM_BRIDGE_NOW=2026-07-31T12:09:00Z FM_HOME=$HOME11 "$RENDER" --tick >/dev/null
grep -q 'hand edit' "$BOARD" && fail "tick: a hand edit to the generated board survived"
pass "a hand edit to the board is overwritten by the next tick"

# --- 12. caps overflow to the record; they never truncate in silence --------

HOME12=$(new_home)
i=1
while [ "$i" -le 18 ]; do
  FM_HOME=$HOME12 "$BRIDGE" note -q --project orca --title "event number $i" \
    --ts "2026-07-31T10:$(printf '%02d' "$i"):00Z" >/dev/null
  i=$((i + 1))
done
capped=$(FM_HOME=$HOME12 "$RENDER" --html)
shown=$(printf '%s' "$capped" | grep -c '<li><span class="when">' || true)
[ "$shown" = 12 ] || fail "caps: expected 12 events shown, got $shown"
case "$capped" in
  *"older events. They are not lost"*) : ;;
  *) fail "caps: events were truncated with no overflow pointer to the record" ;;
esac
case "$capped" in
  *"tail -n 40"*) : ;;
  *) fail "caps: the overflow pointer does not name a command that reaches the record" ;;
esac
pass "capped zones show an overflow pointer to the full record, never silent truncation"

# Boards carry their check commands.
for probe in "fm-bridge-render.sh --state" "fm-bridge.sh lint" "tail -n 40"; do
  case "$capped" in
    *"$probe"*) : ;;
    *) fail "checks: the board does not carry '$probe'" ;;
  esac
done
pass "the board carries the commands that check it against its own source"

# --- 13. per-project refs are stable as new projects arrive -----------------
#
# A bare ref must never need disambiguating, and must never quietly come to mean
# something else. An existing project's prefix therefore cannot change when a
# later project collides with it - the newcomer takes the longer prefix.

HOME13=$(new_home)
FM_HOME=$HOME13 "$BRIDGE" ask -q --id r1 --project orca --title "first" \
  --answer "A" >/dev/null
before=$(state_query "$HOME13" 'd["items"]["r1"]["ref"]')
[ "$before" = O1 ] || fail "refs: expected O1, got $before"
FM_HOME=$HOME13 "$BRIDGE" ask -q --id r2 --project opencode --title "colliding project" \
  --answer "A" >/dev/null
after=$(state_query "$HOME13" 'd["items"]["r1"]["ref"]')
[ "$after" = O1 ] || fail "refs: an existing ref changed to $after when a new project arrived"
newref=$(state_query "$HOME13" 'd["items"]["r2"]["ref"]')
[ "$newref" = OP1 ] || fail "refs: the colliding newcomer got $newref instead of a longer prefix"
pass "an existing project's refs survive a later colliding project"

# A resolved item keeps its number rather than renumbering its successors.
FM_HOME=$HOME13 "$BRIDGE" resolve -q --id r1 --pointer "https://example.invalid/x" >/dev/null
FM_HOME=$HOME13 "$BRIDGE" ask -q --id r3 --project orca --title "later orca ask" \
  --answer "A" >/dev/null
third=$(state_query "$HOME13" 'd["items"]["r3"]["ref"]')
[ "$third" = O2 ] || fail "refs: expected O2 after a resolved O1, got $third"
kept=$(state_query "$HOME13" 'd["items"]["r1"]["ref"]')
[ "$kept" = O1 ] || fail "refs: a resolved item's ref was recycled"
pass "resolved items keep their refs; successors never renumber"

# --- 14. term collisions are defined up front AND repeated locally ----------

HOME14=$(new_home)
FM_HOME=$HOME14 "$BRIDGE" term -q --project orca --term spec \
  --means "the workspace layout file" >/dev/null
FM_HOME=$HOME14 "$BRIDGE" term -q --project dotfiles --term spec \
  --means "the shell test contract" >/dev/null
FM_HOME=$HOME14 "$BRIDGE" ask -q --id g1 --project orca --title "an orca ask" \
  --answer "A" >/dev/null
collided=$(state_query "$HOME14" '[g["collision"] for g in d["glossary"]]')
[ "$collided" = "[True]" ] || fail "glossary: a cross-project term collision was not detected"
gloss=$(FM_HOME=$HOME14 "$RENDER" --html)
case "$gloss" in
  *"Terms that mean different things by project"*) : ;;
  *) fail "glossary: collisions are not defined up front" ;;
esac
case "$gloss" in
  *'class="local-terms"'*) : ;;
  *) fail "glossary: the definition is not repeated locally in the project section" ;;
esac
pass "a colliding term is defined up front and repeated in its project section"

# --- 15. routing: an item addressed elsewhere never costs captain attention --
#
# The evidence behind this class: a machine-config item sat on the captain's
# queue all day when its whole resolution was one reader away. So `owner` is a
# ROUTING decision - the queue an item lands on is what decides who spends
# attention on it - and the guard is that a co-captain item is absent from
# EVERY captain-facing count, not merely styled differently.

HOME15=$(new_home)
FM_HOME=$HOME15 "$BRIDGE" ask -q --id for-cap --project orca \
  --title "a real captain decision" --answer "A" >/dev/null
FM_HOME=$HOME15 "$BRIDGE" ask -q --id for-co --project machine \
  --title "bump the shellcheck pin on this box" --answer "A: bump" \
  --to cocaptain >/dev/null
FM_HOME=$HOME15 "$BRIDGE" critical -q --id crit-co --project dotfiles \
  --title "stale symlink in ~/.config" --answer "A: relink" --to cocaptain >/dev/null

cap_queue=$(state_query "$HOME15" 'd["queues"]["captain"]')
[ "$cap_queue" = "['for-cap']" ] \
  || fail "routing: the captain's queue is $cap_queue - a routed item leaked onto it"
co_queue=$(state_query "$HOME15" 'sorted(d["queues"]["cocaptain"])')
[ "$co_queue" = "['crit-co', 'for-co']" ] \
  || fail "routing: the co-captain's queue is $co_queue"
pass "an item addressed to the co-captain lands on their queue, not the captain's"

owner=$(state_query "$HOME15" 'd["items"]["for-co"]["owner"]')
[ "$owner" = cocaptain ] || fail "routing: owner is '$owner', not the reader it was addressed to"
pass "routing sets the owner to the reader the item was addressed to"

# The captain-facing surface must not count it ANYWHERE.
routed=$(FM_HOME=$HOME15 "$RENDER" --html)
case "$routed" in
  *"<title>Bridge - 1 need you</title>"*) : ;;
  *) fail "routing: the tab title counts co-captain items as captain asks" ;;
esac
case "$routed" in
  *'<b>1</b> waiting on you'*) : ;;
  *) fail "routing: the sticky counter counts co-captain items as captain asks" ;;
esac
tally=$(state_query "$HOME15" 'd["summary"]["needs-captain"]')
[ "$tally" = 1 ] || fail "routing: the captain tally counts $tally instead of 1"
pass "co-captain items are absent from the tab title, the sticky counter, and the captain tally"

# But they are neither hidden from the captain nor lost: visible as routed, and
# a first-class list for the reader who actually owns them.
case "$routed" in
  *"With the co-captain"*) : ;;
  *) fail "routing: routed items are invisible to the captain, so they cannot see where work went" ;;
esac
cotally=$(state_query "$HOME15" 'd["summary"]["needs-cocaptain"]')
[ "$cotally" = 2 ] || fail "routing: routed items are not counted at all ($cotally)"
pass "routed items stay visible as routed, and are counted on their own queue"

# Re-addressing an existing item moves BOTH the queue and the owner.
FM_HOME=$HOME15 "$BRIDGE" route -q --id for-cap --to cocaptain >/dev/null
moved=$(state_query "$HOME15" 'len(d["queues"]["captain"])')
[ "$moved" = 0 ] || fail "routing: re-addressing left the item on the captain's queue"
movedowner=$(state_query "$HOME15" 'd["items"]["for-cap"]["owner"]')
[ "$movedowner" = cocaptain ] \
  || fail "routing: re-addressing left a stale owner '$movedowner' behind"
pass "re-addressing an item moves its queue and its owner together"

FM_HOME=$HOME15 "$BRIDGE" route --id for-cap --to nobody >/dev/null 2>&1 \
  && fail "routing: accepted an unknown reader"
pass "routing refuses an unknown reader"

# With every ask routed away, the board says so plainly rather than looking
# like a board that failed to load.
allclear=$(FM_HOME=$HOME15 "$RENDER" --html)
case "$allclear" in
  *"nothing is waiting on you"*) : ;;
  *) fail "routing: with all asks routed away the board does not report a clear queue" ;;
esac
pass "with every ask routed away the captain's queue reads as clear, not as empty"

# --- 16. every link survives Lavish's annotation layer ----------------------
#
# The board is read inside Lavish, whose annotation layer installs a
# capture-phase click handler that preventDefault()s everything except
# [data-lavish-ui], [data-lavish-action], and native controls
# (button,input,select,textarea,option,optgroup,label,summary,[contenteditable]).
# `a` is NOT on that list, so a plain anchor swallows left-clicks - both PR
# links and the in-page asks-index jumps. Right-click still works, so this is
# friction rather than a blocker; data-lavish-action is Lavish's own
# pass-through and costs one attribute, so the fix is pure authoring hygiene.
#
# A plain <a> anywhere in the renderer regresses it silently, so it is pinned.

HOME16=$(new_home)
FM_HOME=$HOME16 "$BRIDGE" ask -q --id l1 --project orca --title "an ask to jump to" \
  --answer "A" >/dev/null
FM_HOME=$HOME16 "$BRIDGE" note -q --project orca --title "a landed change" \
  --pointer "https://github.com/o/r/pull/7" >/dev/null
FM_HOME=$HOME16 "$BRIDGE" task -q --id l-pr --project orca --phase pr-open \
  --state needs-captain --pointer "https://github.com/o/r/pull/8" \
  --answer "merge it" >/dev/null
FM_HOME=$HOME16 "$BRIDGE" ask -q --id l-co --project machine --title "a routed ask" \
  --answer "A" --to cocaptain >/dev/null
FM_HOME=$HOME16 "$RENDER" --html > "$TMP_ROOT/links.html"

python3 - "$TMP_ROOT/links.html" <<'LINKCHECK' || fail "links: see the reported anchor"
import re, sys
html = open(sys.argv[1]).read()
anchors = re.findall(r"<a [^>]*>", html)
if not anchors:
    sys.exit("the board rendered no anchors at all, so this guard proves nothing")
for tag in anchors:
    if "data-lavish-action" not in tag:
        sys.exit("anchor without Lavish pass-through, unclickable for the captain: %s" % tag)
external = [t for t in anchors if 'href="http' in t]
if not external:
    sys.exit("no external link in the fixture, so the pass-through guard proves nothing")
for tag in external:
    if 'target="_blank"' not in tag:
        sys.exit("external link would navigate the board away inside its iframe: %s" % tag)
    if "noopener" not in tag:
        sys.exit("new-tab link without noopener: %s" % tag)
for tag in [t for t in anchors if 'href="#' in t]:
    if "target=" in tag:
        sys.exit("in-page jump should not open a new tab: %s" % tag)
# A pointer's most useful label is the URL itself, which is also what keeps it
# readable and copyable anywhere. This is the board's long-standing rendering,
# not a fallback affordance.
for match in re.finditer(r'<a [^>]*href="(https?://[^"]+)"[^>]*>([^<]*)</a>', html):
    if match.group(1) != match.group(2):
        sys.exit("external link text is not the URL itself: %s" % match.group(1))
sys.exit(0)
LINKCHECK
pass "every link carries Lavish's pass-through, opens safely, and reads as its own URL"

# The answer forms must keep working under the same layer. They are <button>,
# which Lavish already treats as native, so this checks the form was not
# "improved" into an anchor at some point.
python3 - "$TMP_ROOT/links.html" <<'FORMCHECK' \
  || fail "links: the answer forms are no longer native controls under Lavish"
import re, sys
html = open(sys.argv[1]).read()
if not re.search(r'<button class="ans"', html):
    sys.exit("answer forms are not <button>, so Lavish will swallow their clicks")
sys.exit(0)
FORMCHECK
pass "answer forms stay native controls, so rulings still queue through annotation"

echo "all bridge ledger and fold tests passed"
