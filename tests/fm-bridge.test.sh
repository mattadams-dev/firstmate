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
#   6. LEDGER TEXT ESCAPES ITS CONTAINER. The board embeds the state document in
#      a <script type="application/json"> element, which ends at the first
#      `</script` in its text - so an ordinary title could end the block early
#      and hand the rest of the fold to the HTML parser as live markup.
#   7. A RECORD OUTGROWS PIPE_BUF. The bound is why an append needs no lock, so
#      a line over it is a line a concurrent lane can tear. It is a BYTE bound,
#      and every free-text field can carry the weight, not just title and body.
#   8. AN INSTRUMENT REPORTS SOMETHING IT DID NOT OBSERVE. A lint that could not
#      read the fold must say unknown, not clean; a narrowed document must not
#      name items it does not carry; a jump from the asks index must land where
#      the reader can actually see the card.
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

# Whether the board file was WRITTEN, which is the question the hosted page
# answers to - Lavish reloads on the write, not on a diff. Portable across the
# two stat dialects rather than assuming GNU.
board_mtime() {  # <path> -> mtime in seconds
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

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

# The ask is countable and findable: counted where the board is read, and one
# click from the index that lists it.
asks=$(state_query "$HOME4" 'len(d["asks"])')
[ "$asks" = 3 ] || fail "asks: expected 3 open asks, got $asks"
boardhtml=$(cat "$TMP_ROOT/mode-board.html")
# THE COUNT IS RENDERED CONTENT, in normal flow with the other tallies. That is
# the only surface on a hosted board a redraw is guaranteed to refresh: the tab
# title is propagated into the hosting page once, at load (section 29), and
# unlike anything that travels with the viewport a tally cannot come to cover a
# row.
case "$boardhtml" in
  *'<b>3</b>waiting on you'*) : ;;
  *) fail "asks: the board's own header does not carry the open-ask count" ;;
esac
# It still reaches the index in one click, which is the one thing a bare number
# would have lost.
case "$boardhtml" in
  *'class="tally ask" href="#waiting"'*) : ;;
  *) fail "asks: the count does not jump to the asks index" ;;
esac
pass "the open-ask count is rendered in the board's own header, in normal flow"

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
  *"state resolved, with no pointer to where it went"*) : ;;
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

# --- 11. the tick: it writes only when the ledger content changed -----------
#
# THE WRITE IS THE COST. Lavish hosts this board and reloads the page on any
# write to the file, which silently destroys a ruling the captain is part-way
# through annotating - and it reloads on a byte-identical rewrite too, because
# the reload keys on the write and not on a diff. Both measured:
# docs/verification/bridge-hosted-input.md.
#
# So the guard is writer-side and it is about the FILE, not about the bytes: an
# unchanged ledger must leave the board's mtime alone. Refresh yields to
# composition; supervision liveness is the beacon's and the guard's job.

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
before_mtime=$(board_mtime "$BOARD")
sleep 1
FM_BRIDGE_NOW=2026-07-31T12:03:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: skip path failed"
diff "$TMP_ROOT/before-skip.html" "$BOARD" >/dev/null \
  || fail "tick: an unchanged ledger changed the board's bytes"
[ "$(board_mtime "$BOARD")" = "$before_mtime" ] \
  || fail "tick: an unchanged ledger rewrote the board file, which reloads it out from under an open annotation"
pass "an unchanged ledger leaves the board file untouched, not rewritten with a copy of itself"

# The clock that used to be restamped in is gone with it. A board that printed
# a "checked" time nothing advances would be an instrument reporting a liveness
# it never observed - the exact failure the restamp existed to avoid, arrived at
# from the other side.
grep -q 'content as of <span class="clock">2026-07-31T12:00:00Z' "$BOARD" \
  || fail "tick: the board does not say when its content is from"
grep -q 'checked <span class="clock"' "$BOARD" \
  && fail "tick: the board still claims a checked time nothing advances"
pass "the board dates its content and claims no supervision liveness of its own"

FM_HOME=$HOME11 "$BRIDGE" note -q --project orca --title "a new fact" >/dev/null
FM_BRIDGE_NOW=2026-07-31T12:06:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: re-render after a ledger change failed"
grep -q 'content as of <span class="clock">2026-07-31T12:06:00Z' "$BOARD" \
  || fail "tick: a changed ledger did not advance the content clock"
grep -q 'a new fact' "$BOARD" || fail "tick: a changed ledger did not pick up the new record"
pass "a changed ledger re-renders the body and re-dates the content"

# A ledger touched without changing content is not a change. The signature reads
# CONTENT for this reason: an mtime-shaped signature would rewrite the board,
# and the rewrite is what costs the captain their open ruling.
touch "$(FM_HOME=$HOME11 "$RENDER" --ledger-path)"
before_mtime=$(board_mtime "$BOARD")
sleep 1
FM_BRIDGE_NOW=2026-07-31T12:07:00Z FM_HOME=$HOME11 "$RENDER" --tick \
  || fail "tick: failed after the ledger was touched"
[ "$(board_mtime "$BOARD")" = "$before_mtime" ] \
  || fail "tick: touching the ledger rewrote the board"
pass "touching the ledger without changing it does not rewrite the board"

# The backstop under the tick's own skip: whatever asks for a write, a render
# that comes out byte-identical to the board already on disk must not replace
# it. An explicit --write at a fixed clock is that case, and it is the only
# rewrite path the tick's signature does not already stand in front of.
before_mtime=$(board_mtime "$BOARD")
sleep 1
FM_BRIDGE_NOW=2026-07-31T12:09:00Z FM_HOME=$HOME11 "$RENDER" --write >/dev/null \
  || fail "write: explicit write failed"
first_write=$(board_mtime "$BOARD")
[ "$first_write" != "$before_mtime" ] \
  || fail "write: an explicit write at a new clock did not rewrite the board, so this guard proves nothing"
sleep 1
FM_BRIDGE_NOW=2026-07-31T12:09:00Z FM_HOME=$HOME11 "$RENDER" --write >/dev/null \
  || fail "write: repeat write failed"
[ "$(board_mtime "$BOARD")" = "$first_write" ] \
  || fail "write: a byte-identical render replaced the board file anyway, which reloads the hosted page for nothing"
pass "a byte-identical render never replaces the board file"

# The board is generated. A hand edit is not a place to put facts, and the next
# tick says so by overwriting it.
printf '<!-- hand edit -->\n' >> "$BOARD"
FM_HOME=$HOME11 "$BRIDGE" note -q --project orca --title "yet another fact" >/dev/null
FM_BRIDGE_NOW=2026-07-31T12:09:00Z FM_HOME=$HOME11 "$RENDER" --tick >/dev/null
grep -q 'hand edit' "$BOARD" && fail "tick: a hand edit to the generated board survived"
pass "a hand edit to the board is overwritten by the next tick"

# --- 11b. a board that stopped rendering alarms, and says why ---------------
#
# A board rendering fine and a board whose render has been failing for an hour
# look IDENTICAL to the reader: the content clock says an older time, which is
# also what a quiet fleet looks like. Silence here is a stale surface wearing a
# freshness promise, so the tick counts its own consecutive failures.
#
# Three directions, because each one is a different lie:
#   - three in a row passing quietly is the missed alarm,
#   - one transient failure alarming is the false alarm that trains the reader
#     to ignore the real one,
#   - an alarm that does not carry the reason is a content-free alarm: it sends
#     the reader off to reproduce what the tick already observed.
# And the reset is evidence-based: a render that LANDS clears the count; the
# passage of time never does.

HOME11B=$(new_home)
FM_HOME=$HOME11B "$BRIDGE" ask -q --id alarm-one --project orca \
  --title "something to render" --answer "A" >/dev/null

# A FILE where the board's directory would have to be, so the write fails the
# same way on every run and for every user, root included.
BLOCKED="$HOME11B/blocked"
: > "$BLOCKED"
FAILURES="$HOME11B/state/.bridge-tick-failures"
TICKLOG="$HOME11B/state/.bridge-tick.log"

failing_tick() {  # -> the tick's stderr; the tick itself fails
  { FM_BRIDGE_BOARD="$BLOCKED/bridge.html" FM_HOME=$HOME11B "$RENDER" --tick >/dev/null; } 2>&1
}

first=$(failing_tick)
case "$first" in
  *bridge-alarm:*) fail "tick: a single transient render failure raised the alarm; the next tick retries by itself" ;;
esac
[ "$(cut -f1 "$FAILURES" 2>/dev/null)" = 1 ] \
  || fail "tick: the first render failure was not recorded, so nothing can count to three"
second=$(failing_tick)
case "$second" in
  *bridge-alarm:*) fail "tick: two render failures raised the alarm; the threshold is three" ;;
esac
[ "$(cut -f1 "$FAILURES" 2>/dev/null)" = 2 ] || fail "tick: the second consecutive failure was not counted"
pass "one and two failed renders stay quiet, and both are counted"

# Quiet is about the ALARM, not about the reason. Only the prefix that wakes
# somebody waits for the threshold; what failed is printed at every count,
# because bin/fm-session-start.sh runs this same tick and prints whatever it
# says. Withhold the reason below three and the captain's first two failures
# read as "could not be brought up to date" and nothing else.
case "$first" in
  *"$BLOCKED"*) : ;;
  *) fail "tick: the first failure never said what failed, so session start has nothing to print: $first" ;;
esac
case "$second" in
  *"$BLOCKED"*) : ;;
  *) fail "tick: the second failure never said what failed: $second" ;;
esac
pass "a below-threshold failure still names its reason; only the alarm prefix waits for the threshold"

third=$(failing_tick)
case "$third" in
  *bridge-alarm:*) : ;;
  *) fail "tick: three consecutive failed renders raised no alarm at all: $third" ;;
esac
case "$third" in
  *"3 times in a row"*) : ;;
  *) fail "tick: the alarm does not say how long the board has been failing: $third" ;;
esac
case "$third" in
  *"$BLOCKED"*) : ;;
  *) fail "tick: the alarm names no reason, so it only says a failure happened: $third" ;;
esac
pass "the third consecutive failure alarms, and the alarm carries what actually failed"

grep -q 'render FAILED (3 in a row)' "$TICKLOG" \
  || fail "tick: the failures are not in the log, so the episode cannot be reconstructed"

# Evidence of health, not the passage of time, is what clears an alarm.
FM_HOME=$HOME11B "$RENDER" --tick >/dev/null 2>&1 \
  || fail "tick: the render did not recover once the board path was writable again"
[ -f "$FAILURES" ] && fail "tick: a successful render left the failure count standing"
grep -q 'render RECOVERED after 3 consecutive failures' "$TICKLOG" \
  || fail "tick: the reset was not logged, so the alarm history stops being reconstructable"
pass "a render that lands resets the count and logs the transition"

fourth=$(failing_tick)
case "$fourth" in
  *bridge-alarm:*) fail "tick: a failure after a recovery alarmed immediately; the reset did not really restart the count" ;;
esac
[ "$(cut -f1 "$FAILURES" 2>/dev/null)" = 1 ] || fail "tick: the count did not restart at one after the recovery"
pass "after a recovery the count restarts, so the next alarm needs three fresh failures"

# --- 11c. what a skip is, and what it is measured against -------------------
#
# A SKIP IS NEUTRAL. Only a landed render resets the consecutive-failure count
# and only a failed render increments it; a tick with nothing to render did not
# observe whether the renderer works, so it may neither clear an alarm a real
# failure earned nor manufacture one.
#
# And "unchanged ledger" means UNCHANGED SINCE THE LAST SUCCESSFUL RENDER, never
# unchanged since the last tick. Compare tick-to-tick and the failure is silent:
# two renders fail, the ledger then goes quiet, and every later tick sees "same
# as last time" and skips forever - the count frozen below the threshold, the
# board stale, the alarm never earned. A skip is only a skip when there is
# genuinely nothing owed to the surface.

HOME11C=$(new_home)
FM_HOME=$HOME11C "$BRIDGE" ask -q --id owed-one --project orca \
  --title "something to render" --answer "A" >/dev/null
BOARD11C=$(FM_HOME=$HOME11C "$RENDER" --path)
BOARDDIR11C=$(dirname "$BOARD11C")
FAILURES11C="$HOME11C/state/.bridge-tick-failures"

FM_HOME=$HOME11C "$RENDER" --tick >/dev/null 2>&1 \
  || fail "owed: the first render failed, so this fixture proves nothing"
[ -f "$BOARD11C" ] || fail "owed: the first render wrote no board"

# The ledger moves on, and the render starts failing with the board file STILL
# IN PLACE - so the skip's board-exists clause cannot stand in for the stamp and
# mask the question this fixture asks. The directory is only unwritable for the
# duration of each attempt, so a failed assertion still leaves a removable tree.
FM_HOME=$HOME11C "$BRIDGE" note -q --project orca \
  --title "a fact the board never got" >/dev/null
attempt_11c() {  # one tick against an unwritable board directory
  chmod 500 "$BOARDDIR11C"
  { FM_HOME=$HOME11C "$RENDER" --tick >/dev/null; } 2>&1
  chmod 700 "$BOARDDIR11C"
}

owed=$(attempt_11c)
[ "$(cut -f1 "$FAILURES11C" 2>/dev/null)" = 1 ] \
  || fail "owed: the first failing render was not counted: $owed"

# FROM HERE THE LEDGER IS QUIET. A tick-to-tick baseline would call this
# unchanged and skip; the last-successful-render baseline still owes the surface
# a render, so the tick must keep attempting.
owed=$(attempt_11c)
[ "$(cut -f1 "$FAILURES11C" 2>/dev/null)" = 2 ] \
  || fail "owed: with the ledger quiet the tick stopped attempting, so the count froze at one: $owed"
owed=$(attempt_11c)
case "$owed" in
  *bridge-alarm:*) : ;;
  *) fail "owed: a quiet ledger let a broken board skip its way past the alarm: $owed" ;;
esac
pass "an unrendered delta stays owed while the ledger is quiet, so a failing board still reaches its alarm"

# Reaching a GENUINE skip with a failure already on the record needs a failure
# from BEFORE the render - the fold itself refusing - because a failed write
# leaves the delta owed and the next tick re-renders rather than skipping.
HOME11D=$(new_home)
FM_HOME=$HOME11D "$BRIDGE" ask -q --id neutral-one --project orca \
  --title "something to render" --answer "A" >/dev/null
FAILURES11D="$HOME11D/state/.bridge-tick-failures"
FM_HOME=$HOME11D "$RENDER" --tick >/dev/null 2>&1 \
  || fail "neutral: the first render failed, so this fixture proves nothing"

STUBBIN="$TMP_ROOT/fold-refuses"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/python3" <<'STUB'
#!/usr/bin/env bash
printf 'python3 refused to run the fold\n' >&2
exit 1
STUB
chmod +x "$STUBBIN/python3"
PATH="$STUBBIN:$PATH" FM_HOME=$HOME11D "$RENDER" --tick >/dev/null 2>&1
[ "$(cut -f1 "$FAILURES11D" 2>/dev/null)" = 1 ] \
  || fail "neutral: a fold that refused to run was not counted as a failed render"

# The fold works again, and the ledger has not moved since the last SUCCESSFUL
# render - so this tick genuinely has nothing to do. It observed nothing about
# the renderer, so it must leave the count exactly where it found it.
FM_HOME=$HOME11D "$RENDER" --tick >/dev/null 2>&1 \
  || fail "neutral: the tick failed once the fold worked again"
[ "$(cut -f1 "$FAILURES11D" 2>/dev/null)" = 1 ] \
  || fail "neutral: a tick with nothing to render moved the failure count to $(cut -f1 "$FAILURES11D" 2>/dev/null)"
pass "a tick with nothing to render is neutral: it neither clears the count nor adds to it"

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
  *'<b>1</b>waiting on you'*) : ;;
  *) fail "routing: the header count counts co-captain items as captain asks" ;;
esac
tally=$(state_query "$HOME15" 'd["summary"]["needs-captain"]')
[ "$tally" = 1 ] || fail "routing: the captain tally counts $tally instead of 1"
pass "co-captain items are absent from the header count and the captain tally"

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
  *"Nothing is waiting on you"*) : ;;
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
FM_HOME=$HOME16 "$RENDER" --state > "$TMP_ROOT/links-state.json"

python3 - "$TMP_ROOT/links.html" <<'LINKCHECK' || fail "links: see the reported anchor"
import re, sys
html = open(sys.argv[1]).read()
anchors = re.findall(r"<a [^>]*>", html)
if not anchors:
    sys.exit("the board rendered no anchors at all, so this guard proves nothing")
for tag in anchors:
    if "data-lavish-action" not in tag:
        sys.exit("anchor without Lavish pass-through, unclickable for the captain: %s" % tag)
# The other half of the same rule. The attribute buys a working left-click by
# spending the element's annotatability, and annotation is the board's ONLY
# input path - so an anchor, whose own job is to navigate, is the one thing that
# can afford the trade. On anything else it would silently create a dead spot
# the captain cannot rule on.
for tag in re.findall(r"<[a-zA-Z][^>]*>", html):
    if "data-lavish-action" not in tag:
        continue
    if not re.match(r"<a[ >]", tag):
        sys.exit("data-lavish-action on a non-anchor makes it un-annotatable, "
                 "and annotation is the only way the captain answers: %s" % tag)
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

# --- 16b. the board takes no input, and everything on it can be annotated ---
#
# The board's input path is Lavish's annotation layer and its conversation
# panel. Nothing else. It used to carry a composer of its own - a textarea with
# copy and clear and no send - which could not reach anybody and was wiped by
# the next redraw, so a captain who typed a ruling into it believed they had
# answered and the fleet never heard it.
#
# That makes two properties guard-class, and they fail in opposite directions:
#   1. the board must offer NO input affordance of its own, and
#   2. everything the captain must annotate must actually BE annotatable.
# Lavish skips native controls and everything inside them when deciding what can
# be annotated, so the same list settles both: a control on this board is either
# an input path it does not have, or a dead spot on a row the captain must rule
# on. Measured, both directions, against real hosting:
# docs/verification/bridge-hosted-input.md.

python3 - "$TMP_ROOT/links.html" <<'INPUTCHECK' \
  || fail "input path: see the reported element"
import re, sys
html = open(sys.argv[1]).read()
# Markup only. Stylesheet text and the embedded state document are not elements,
# and a rule or a record that merely mentions a tag name is not one.
markup = re.sub(r"<(style|script)\b[^>]*>.*?</\1>", "", html, flags=re.S | re.I)

# Lavish's own exclusion list, from its artifact SDK. Anything matching it - or
# nested inside something matching it - is invisible to annotation.
NATIVE = ("button", "input", "select", "textarea", "option", "optgroup",
          "label", "summary")

for tag in NATIVE:
    for found in re.finditer(r"<%s\b[^>]*>" % tag, markup, re.I):
        sys.exit("the board renders a native control, which is either an input "
                 "it cannot send or a spot the captain cannot annotate: %s"
                 % found.group(0))
if re.search(r'contenteditable=["\']?(?!false)', markup, re.I):
    sys.exit("the board renders a contenteditable element")

# The composer specifically, by every name it went under.
for dead in ("queue-text", "queue-copy", "queue-clear", "queued rulings",
             "dock-open"):
    if dead in html:
        sys.exit("the retired ruling composer is still on the board: %r" % dead)
sys.exit(0)
INPUTCHECK
pass "the board renders no control of its own: nothing to type into, nothing that cannot be annotated"

# The other half, and the reason the first half is safe: the ask rows still
# carry what an annotation needs to identify. An annotation arrives as the
# anchor it was rooted at plus the text it was placed on, so stripping either
# the per-item anchors or the visible refs would trade one broken input path
# for another - silently, since the board would still look right.
python3 - "$TMP_ROOT/links.html" "$TMP_ROOT/links-state.json" <<'ANCHORCHECK' \
  || fail "annotation anchors: see the reported ask"
import json, re, sys
html = open(sys.argv[1]).read()
doc = json.load(open(sys.argv[2]))
asks = doc["asks"]
if not asks:
    sys.exit("no asks in the fixture, so this guard proves nothing")

options = re.findall(r'<span class="ans">([^<]*)</span>', html)
if not options:
    sys.exit("no answer options rendered, so this guard proves nothing")

def where_it_lands(key):
    """The ask's OWN card or row, not the whole page.

    An annotation is rooted where it was placed, so what identifies it has to be
    there. Checking the document would pass a board whose refs live only in the
    index at the top - which is exactly what an annotation on the card never
    sees.
    """
    anchor = 'id="item-%s"' % key
    if anchor not in html:
        return None
    rest = html.split(anchor, 1)[1]
    return re.split(r'id="item-|</section>|</table>', rest, maxsplit=1)[0]

for key in asks:
    item = doc["items"][key]
    landing = where_it_lands(key)
    if landing is None:
        sys.exit("ask %s has no per-item anchor, so an annotation on it cannot "
                 "say which ask it meant" % key)
    label = item["ref"] or item["id"]
    if item["answers"]:
        for answer in item["answers"]:
            wanted = "%s: %s" % (label, answer)
            if wanted not in landing:
                sys.exit("ask %s renders an answer that does not name its own "
                         "ask where the annotation lands: expected %r"
                         % (key, wanted))
    if item["ref"] and ('<span class="ref">%s</span>' % item["ref"]) not in landing:
        sys.exit("ask %s renders no visible ref, so an annotation on it arrives "
                 "unquotable" % key)
sys.exit(0)
ANCHORCHECK
pass "every ask keeps its per-item anchor, its visible ref, and answers that name their own ask"

# And the board says where the input actually is, rather than leaving the
# captain to infer it from the absence of a box.
python3 - "$TMP_ROOT/links.html" <<'SIGNPOSTCHECK' \
  || fail "signpost: see the reported gap"
import sys
html = open(sys.argv[1]).read()
if "annotate" not in html.lower():
    sys.exit("the board never names annotation as the way to rule")
if "conversation panel" not in html.lower():
    sys.exit("the board never names where an annotated ruling is sent from")
if "no input path at all" not in html.lower():
    sys.exit("the board does not say what it is when opened as a plain file, "
             "which is the one case where there is no input path")
if "not saved anywhere" not in html.lower():
    sys.exit("the board does not warn that an unqueued annotation is lost on "
             "the next redraw, which is measured behaviour")
sys.exit(0)
SIGNPOSTCHECK
pass "the board states its input path, and states plainly what it does not promise"

# --- 17. ledger text cannot break out of the embedded state document -------
#
# The board carries the exact state document it drew from inside a
# <script type="application/json"> element. That element ends at the first
# `</script` in its text, so a title, note, answer, or unreadable raw line
# carrying one would end the block early and hand the REST of the fold to the
# HTML parser as live markup - in a page served in an iframe. The two output
# modes must stay byte-identical through the fix, so the escaping lives in the
# one serializer both modes call.

HOME17=$(new_home)
FM_HOME=$HOME17 "$BRIDGE" ask -q --id x-one --project orca \
  --title 'guard against </script><img src=x onerror=alert(1)> here' \
  --answer 'A: <b>yes</b>' --answer 'B: no' >/dev/null
FM_HOME=$HOME17 "$BRIDGE" note -q --id x-note --project orca --title "a note" \
  --body 'closing </SCRIPT > and an opener <script>' >/dev/null
# The tolerance path echoes an unreadable line verbatim, which is exactly the
# garbled-line case this design expects to survive.
printf '%s\n' '{"v":1,"ts":"2026-07-31T10:00:00Z" broken </script><img src=x>' \
  >> "$(ledger_of "$HOME17")"

FM_HOME=$HOME17 "$RENDER" --state > "$TMP_ROOT/esc-state.json"
FM_HOME=$HOME17 "$RENDER" --html > "$TMP_ROOT/esc-board.html"
python3 - "$TMP_ROOT/esc-state.json" "$TMP_ROOT/esc-board.html" <<'PY' \
  || fail "embed: see the reported breakout"
import json, re, sys
state = open(sys.argv[1]).read().rstrip("\n")
html = open(sys.argv[2]).read()
open_tag = '<script type="application/json" id="fm-bridge-state">\n'
start = html.index(open_tag) + len(open_tag)
# Where the BROWSER ends the element, not where the renderer meant to: the first
# `</script` in the raw text, case-insensitively, whatever follows it.
ends_at = re.search(r"</script", html[start:], re.I)
if ends_at is None:
    sys.exit("the embedded state document is never closed")
embedded = html[start:start + ends_at.start()].rstrip("\n")
if embedded != state:
    sys.exit("ledger text ended the state element early: the browser sees %d of %d bytes"
             % (len(embedded), len(state)))
doc = json.loads(embedded)
if doc["items"]["x-one"]["title"] != \
        "guard against </script><img src=x onerror=alert(1)> here":
    sys.exit("escaping changed the value a consumer reads back")
if not doc["malformed"]:
    sys.exit("the unreadable line was not carried into the document, so this proves nothing")
sys.exit(0)
PY
pass "no ledger text can end the embedded state document early"

diff "$TMP_ROOT/esc-state.json" <(python3 - "$TMP_ROOT/esc-board.html" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
match = re.search(r'<script type="application/json" id="fm-bridge-state">\n(.*?)\n</script>',
                  html, re.S)
sys.stdout.write(match.group(1) + "\n")
PY
) >/dev/null || fail "embed: escaping made the board and --state diverge"
pass "the escaped document is still byte-identical in both output modes"

# The page must also carry no live markup from that text.
case "$(cat "$TMP_ROOT/esc-board.html")" in
  *"<img src=x"*) fail "embed: ledger text reached the page as live markup" ;;
esac
pass "ledger text never reaches the board as live markup"

# --- 18. the record bound is a BYTE bound, and truncation always says so ----
#
# PIPE_BUF is why an append needs no lock, so a record over it is a record a
# concurrent lane can tear in half. Characters are not bytes, and title and body
# are not the only fields that can carry weight.

HOME18=$(new_home)
BIG_MULTIBYTE=$(python3 -c "print('é' * 3500)")
BIG_NOTE=$(python3 -c "print('n' * 6000)")
BIG_ANSWER=$(python3 -c "print('a' * 5000)")
FM_HOME=$HOME18 "$BRIDGE" ask -q --id b-multibyte --project orca \
  --title "$BIG_MULTIBYTE" --answer "A" >/dev/null
FM_HOME=$HOME18 "$BRIDGE" note -q --id b-note --project orca --title "short title" \
  --note "$BIG_NOTE" >/dev/null
FM_HOME=$HOME18 "$BRIDGE" ask -q --id b-answer --project orca --title "short title" \
  --answer "$BIG_ANSWER" >/dev/null
FM_HOME=$HOME18 "$BRIDGE" note -q --id b-small --project orca \
  --title "an ordinary record" >/dev/null

python3 - "$(ledger_of "$HOME18")" <<'PY' || fail "bound: see the reported record"
import json, sys
bound = 3800
for number, line in enumerate(open(sys.argv[1], "rb"), 1):
    raw = line.rstrip(b"\n")
    record = json.loads(raw.decode("utf-8"))
    if len(raw) > bound:
        sys.exit("line %d is %d bytes, over the %d-byte bound a concurrent append "
                 "can tear: id=%s" % (number, len(raw), bound, record["id"]))
    if len(raw) > bound - 400 and not record.get("truncated"):
        sys.exit("line %d sits at the bound with no truncated flag: id=%s"
                 % (number, record["id"]))
sys.exit(0)
PY
pass "every record fits the byte bound, whatever field carried the weight"

for id in b-multibyte b-note b-answer; do
  flagged=$(state_query "$HOME18" "d['items']['$id']['truncated']")
  [ "$flagged" = True ] || fail "bound: $id lost content without saying so"
done
kept=$(state_query "$HOME18" "d['items']['b-small']['truncated']")
[ "$kept" = False ] || fail "bound: an ordinary record was marked truncated"
pass "a shortened record always says truncated, and an ordinary one never does"

# --- 19. a narrowed document never points at an item it does not carry ------

HOME19=$(new_home)
FM_HOME=$HOME19 "$BRIDGE" ask -q --id n-one --project orca --title "first ask" \
  --answer "A" >/dev/null
FM_HOME=$HOME19 "$BRIDGE" ask -q --id n-two --project orca --title "second ask" \
  --answer "A" >/dev/null
FM_HOME=$HOME19 "$BRIDGE" ask -q --id n-co --project machine --title "a routed ask" \
  --answer "A" --to cocaptain >/dev/null
# A row from before the outcome axis, so the narrowed document has to carry
# `unobserved_outcomes` correctly too - the list that escaped the last time
# these were narrowed by name.
cat >> "$(ledger_of "$HOME19")" <<'EOF'
{"v":1,"ts":"2026-07-30T09:01:00Z","id":"n-old","kind":"decision","project":"orca","state":"needs-captain","title":"a pre-axis ask","answers":["A"]}
EOF

FM_HOME=$HOME19 "$RENDER" --state > "$TMP_ROOT/narrow-whole.json"
FM_HOME=$HOME19 "$RENDER" --state --id n-one > "$TMP_ROOT/narrow-one.json"
python3 - "$TMP_ROOT/narrow-whole.json" "$TMP_ROOT/narrow-one.json" <<'NARROW' \
  || fail "narrow: see the reported dangling reference"
import json, sys

whole = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
known = set(whole["items"])
keys = set(doc["items"])
if keys != {"n-one"}:
    sys.exit("narrowing kept %s" % sorted(keys))

# No list of field names here on purpose. A list is a list of item ids when its
# members are ids the whole fold carried, so this walk covers every id-list in
# the document INCLUDING ones nobody has added yet - which is the only version
# of this guard that survives the next field.
def walk(where, value):
    if isinstance(value, dict):
        for name, inner in value.items():
            walk("%s.%s" % (where, name), inner)
        return
    if not isinstance(value, list):
        return
    if value and all(isinstance(entry, str) and entry in known for entry in value):
        dangling = [entry for entry in value if entry not in keys]
        if dangling:
            sys.exit("%s still names %s, which the document does not carry"
                     % (where, dangling))
        return
    for position, entry in enumerate(value):
        walk("%s[%d]" % (where, position), entry)

for name, value in doc.items():
    if name == "items":
        continue
    walk(name, value)

# The walk only proves something if the document still HAS id-lists to check.
carried = [name for name, value in doc.items()
           if name != "items" and json.dumps(value).count("\"n-one\"")]
if len(carried) < 3:
    sys.exit("the narrowed document carries almost no references: %r" % carried)

# The documented traversal has to work on the narrowed document too.
[doc["items"][key] for key in doc["asks"]]
[doc["items"][key] for key in doc["unobserved_outcomes"]]
if not doc["query"]["found"]:
    sys.exit("the narrowed document does not report the item as found")
NARROW
pass "a narrowed document is narrowed in every list of ids, named or not"

FM_HOME=$HOME19 "$RENDER" --state --id never-written | python3 -c '
import json, sys
doc = json.load(sys.stdin)
if doc["query"]["found"] or doc["items"] or doc["asks"] or doc["order"]:
    sys.exit("narrowing to an unknown id carried items or references anyway")
' || fail "narrow: an unknown id still carried references"
pass "narrowing to an unknown id carries no references at all"

# --- 20. lint keeps clean, dirty, and could-not-read apart ------------------
#
# A lint that could not read the fold reporting success is the expensive lie:
# the caller cannot tell "the record is clean" from "the check never ran".

HOME20=$(new_home)
FM_HOME=$HOME20 "$BRIDGE" ask -q --id fine --project orca --title "well-formed" \
  --answer "A" >/dev/null
FAKEBIN="$TMP_ROOT/lint-fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/fm-bridge-render.sh" <<'SH'
#!/usr/bin/env bash
echo "fold blew up" >&2
exit 1
SH
chmod +x "$FAKEBIN/fm-bridge-render.sh"
cp "$BRIDGE" "$FAKEBIN/fm-bridge.sh"
cp "$ROOT/bin/fm-bridge-lib.sh" "$FAKEBIN/fm-bridge-lib.sh"

set +e
FM_HOME=$HOME20 "$FAKEBIN/fm-bridge.sh" lint > "$TMP_ROOT/lint-unknown.out" 2>&1
lint_rc=$?
set -e
[ "$lint_rc" -ne 0 ] \
  || fail "lint: a fold that failed was reported as a clean record (exit $lint_rc)"
case "$(cat "$TMP_ROOT/lint-unknown.out")" in
  *UNKNOWN*) : ;;
  *) fail "lint: a fold failure was not reported as unknown: $(cat "$TMP_ROOT/lint-unknown.out")" ;;
esac
pass "a lint that could not read the fold reports unknown, never a clean record"

FM_HOME=$HOME20 "$BRIDGE" lint >/dev/null 2>&1 \
  || fail "lint: a readable, clean record no longer exits 0"
pass "a readable clean record still lints clean"

# --- 21. nothing on this board is out of flow -------------------------------
#
# Two browser audits proved text on this board fully occluded, on rows in two
# different zones. The rows were never the cause: chrome that travels with a
# vertically scrolling page and sits across the top ends up over every row that
# passes it, and parks an anchor target underneath itself.
#
# That was answered for a while by a reserved gutter no content was laid out
# inside, which fixed chrome could occupy without covering anything. Once the
# ruling composer was removed, the only thing left in that gutter was a number,
# and a number that links to the asks index does not need chrome of its own. So
# the gutter went, the count moved into the page's own header, and what is
# pinned now is the stronger and simpler property: there is nothing out of flow
# to place.
#
# A shell suite cannot measure geometry, so this does NOT claim the page has no
# overlap; a browser audit is what says that. It pins the structural property
# that overlap-freedom rests on, by PARSING the stylesheet the board emits
# rather than matching how it happens to be written, so reformatting the CSS
# cannot break the guard and cannot quietly satisfy it either.

python3 - "$TMP_ROOT/links.html" <<'RAIL' || fail "layout: see the reported rule"
import re, sys

html = open(sys.argv[1]).read()
sheet = re.search(r"<style>(.*?)</style>", html, re.S)
if sheet is None:
    sys.exit("the board carries no stylesheet at all")

# selector -> {property: value}, whitespace, comments and ordering irrelevant.
# Blocks are matched by counting braces and at-rules are DESCENDED INTO, because
# the whole point of this guard is "no second out-of-flow element", and a parser
# that skips `@media { ... }` would answer that question without looking at
# whatever is nested inside one.
def parse(stylesheet, rules=None):
    rules = {} if rules is None else rules
    cursor = 0
    while True:
        opened = stylesheet.find("{", cursor)
        if opened < 0:
            return rules
        prelude = stylesheet[cursor:opened].strip()
        depth, index = 1, opened + 1
        while index < len(stylesheet) and depth:
            if stylesheet[index] == "{":
                depth += 1
            elif stylesheet[index] == "}":
                depth -= 1
            index += 1
        if depth:
            sys.exit("the stylesheet has an unclosed block, so it cannot be checked")
        body = stylesheet[opened + 1:index - 1]
        cursor = index
        if prelude.startswith("@"):
            if "{" in body:
                parse(body, rules)
            continue
        declarations = {}
        for declaration in body.split(";"):
            if ":" not in declaration:
                continue
            name, _, value = declaration.partition(":")
            declarations[name.strip()] = value.strip()
        for selector in prelude.split(","):
            selector = " ".join(selector.split())
            if selector:
                rules.setdefault(selector, {}).update(declarations)

# The guard's own blind spot, checked first: a parser that cannot see into an
# at-rule reports a clean board while chrome sits over it inside a @media.
probe = parse("@media (max-width:700px) { #sneaky { position:fixed; top:0 } }")
if probe.get("#sneaky", {}).get("position") != "fixed":
    sys.exit("this guard cannot see out-of-flow rules nested in an at-rule, "
             "so it would pass a board with chrome hidden in one")

rules = parse(re.sub(r"/\*.*?\*/", " ", sheet.group(1), flags=re.S))

out_of_flow = sorted(selector for selector, declarations in rules.items()
                     if declarations.get("position") in ("fixed", "absolute", "sticky"))
if out_of_flow:
    sys.exit("something on the board is out of flow and can therefore come to "
             "cover the rows it sits over: %s" % out_of_flow)

# And the page reserves no gutter for chrome that no longer exists - a reserved
# column with nothing in it is a stripe of dead space on every screen.
for edge in ("padding-right", "padding-left"):
    reserved = rules.get("body", {}).get(edge, "0")
    if reserved not in ("", "0", "0px", "0rem"):
        sys.exit("the page still reserves %s: %r, with nothing out of flow to "
                 "put there" % (edge, reserved))

sys.exit(0)
RAIL
pass "nothing on the board is out of flow, and no gutter is reserved for chrome that is gone"

# The job the retired gutter counter did is still done by a count in the header
# that reaches the asks index in one click - the one thing a bare number would
# have lost, and the reason a count that does not follow the viewport is still
# enough.
case "$(cat "$TMP_ROOT/links.html")" in
  *'class="tally ask" href="#waiting"'*) : ;;
  *) fail "layout: the header count no longer reaches the asks index" ;;
esac
pass "the count reaches the index from the header, with no travelling chrome"

# --- 22. two axes: who owes it, and how it ended ---------------------------
#
# These are different questions and the fold answers them separately. Blending
# them into one value is what let a merged task read as thrown away and a
# thrown-away one read as a live ask: whichever fact was written last won, and
# the reader could not see the other.

HOME22=$(new_home)
# A task that merged and was then force-cleaned. Nobody owes it (state) AND it
# ended by landing (outcome) - a later cleanup of the working copy cannot
# un-land the work.
FM_HOME=$HOME22 "$BRIDGE" task -q --id t-merged --project orca --phase merged \
  --state resolved --outcome landed --pointer "https://example.invalid/pull/9" >/dev/null
FM_HOME=$HOME22 "$BRIDGE" append -q id=t-merged phase=force-cleaned outcome=landed \
  note="forced teardown: checks skipped, but the work had landed - evidence gate was broken" \
  >/dev/null
# A task nobody ruled on that was genuinely thrown away: someone still owed a
# decision when the work ended.
FM_HOME=$HOME22 "$BRIDGE" task -q --id t-gone --project orca --phase pr-open \
  --state needs-captain --pointer "https://example.invalid/pull/7" \
  --answer "merge it" >/dev/null
FM_HOME=$HOME22 "$BRIDGE" append -q id=t-gone phase=force-cleaned outcome=discarded \
  note="forced teardown: checks skipped, unlanded work discarded - branch was a dead end" \
  >/dev/null
# A cleanup that could not tell. Unknown is a value, not an absence.
FM_HOME=$HOME22 "$BRIDGE" task -q --id t-murky --project orca --phase dispatched \
  --state fm-handling >/dev/null
FM_HOME=$HOME22 "$BRIDGE" append -q id=t-murky phase=force-cleaned outcome=unknown \
  note="forced teardown: checks skipped and the landed-work test could not reach a verdict, so how this ended is unknown - the forge was unreachable" \
  >/dev/null
# And live work, so no guard below can pass by emptying the board.
FM_HOME=$HOME22 "$BRIDGE" task -q --id t-live --project orca --phase validating >/dev/null

FM_HOME=$HOME22 "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
items = doc["items"]
# Both facts survive on the item, neither rewritten by the other.
if items["t-merged"]["state"] != "resolved" or items["t-merged"]["outcome"] != "landed":
    sys.exit("the merged task lost an axis: %r" % items["t-merged"])
if items["t-gone"]["state"] != "needs-captain" or items["t-gone"]["outcome"] != "discarded":
    sys.exit("the discarded task lost an axis: %r" % items["t-gone"])
if items["t-live"]["outcome"] != "in-flight":
    sys.exit("silence on the outcome axis should read as in-flight, got %r"
             % items["t-live"]["outcome"])
# Each ending gets its own key. No key carries work that ended another way.
zones = doc["zones"]
for key, expected in (("fleet_landed", ["t-merged"]),
                      ("fleet_discarded", ["t-gone"]),
                      ("fleet_unknown", ["t-murky"]),
                      ("fleet_open", ["t-live"])):
    if zones[key] != expected:
        sys.exit("zones.%s is %r, not %r" % (key, zones[key], expected))
# One tally per axis, neither a rollup of the other.
if doc["outcomes"]["landed"] != 1 or doc["outcomes"]["discarded"] != 1 \
        or doc["outcomes"]["unknown"] != 1:
    sys.exit("the outcome tally does not count each ending once: %r" % doc["outcomes"])
if doc["summary"]["resolved"] != 1:
    sys.exit("the state tally lost the resolved task: %r" % doc["summary"])
' || fail "axes: see the reported item"
pass "state and outcome are recorded and reported as two independent facts"

# MERGED WORK NEVER READS AS THROWN AWAY. This is the case the whole design
# exists to make unrepresentable.
FM_HOME=$HOME22 "$RENDER" --html > "$TMP_ROOT/axes.html"
python3 - "$TMP_ROOT/axes.html" <<'PY' || fail "axes: see the reported row"
import re, sys
html = open(sys.argv[1]).read()
merged = re.search(r'<tr id="item-t-merged">.*?</tr>', html, re.S)
if merged is None:
    sys.exit("the merged task has no row on the fleet strip")
merged = merged.group(0)
if "discarded" in merged:
    sys.exit("merged work reads as discarded: %s" % merged)
for fragment in ("landed", "resolved"):
    if fragment not in merged:
        sys.exit("the merged row does not say %r, so a reader must guess: %s"
                 % (fragment, merged))
gone = re.search(r'<tr id="item-t-gone">.*?</tr>', html, re.S).group(0)
if "discarded" not in gone or "needs-captain" not in gone:
    sys.exit("the discarded row hides one of its two axes: %s" % gone)
murky = re.search(r'<tr id="item-t-murky">.*?</tr>', html, re.S).group(0)
if "unknown" not in murky:
    sys.exit("a cleanup that could not tell does not say so on the row: %s" % murky)
sys.exit(0)
PY
pass "every row shows both axes, and merged work never reads as thrown away"

# --- 23. an ask is a conjunction, and each condition disqualifies alone -----
#
# Someone owes a decision AND the work is still live. Neither condition
# overrides the other: a discarded item is not an ask because there is nothing
# left to decide, and a merged item is not an ask because nobody owes it.

HOME23=$(new_home)
# The producers' real sequence: spawn, pr-check's needs-captain, then a forced
# teardown that found the work genuinely unlanded.
FM_HOME=$HOME23 "$BRIDGE" task -q --id task-pr --project orca --phase dispatched \
  --state fm-handling --owner task-pr --title task-pr >/dev/null
FM_HOME=$HOME23 "$BRIDGE" task -q --id task-pr --project orca --phase pr-open \
  --state needs-captain --pointer "https://example.invalid/pull/9" --title task-pr \
  --answer "merge it" --answer "hold, I want to look first" --ts 2026-07-28T09:00:00Z >/dev/null
FM_HOME=$HOME23 "$BRIDGE" append -q id=task-pr phase=force-cleaned outcome=discarded \
  note="forced teardown: checks skipped, unlanded work discarded - branch was a dead end" \
  >/dev/null
# The co-captain's queue is the same mechanism and must not keep it either.
FM_HOME=$HOME23 "$BRIDGE" ask -q --id m-gone --project machine --title "a routed ask" \
  --answer "A" --to cocaptain >/dev/null
FM_HOME=$HOME23 "$BRIDGE" append -q id=m-gone phase=force-cleaned outcome=discarded \
  note="forced teardown: checks skipped, unlanded work discarded - box was reimaged" >/dev/null
# Someone owed this one and it is still live: the one real ask.
FM_HOME=$HOME23 "$BRIDGE" ask -q --id o-live --project orca --title "a live decision" \
  --answer "A" >/dev/null

FM_HOME=$HOME23 "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for key in ("task-pr", "m-gone"):
    item = doc["items"][key]
    if item["outcome"] != "discarded":
        sys.exit("%s does not report how it ended" % key)
    if item["aging"]:
        sys.exit("%s is flagged aging, so work that ended still nags" % key)
    for name, queue in list(doc["queues"].items()) + [("asks", doc["asks"]),
                                                      ("cocaptain_asks", doc["cocaptain_asks"])]:
        if key in queue:
            sys.exit("%s is still on %s after the work ended" % (key, name))
# The state each item earned is still in the record - the classification
# changed, the ledger did not.
if doc["items"]["task-pr"]["state"] != "needs-captain":
    sys.exit("the cleanup rewrote the disposition the ledger recorded")
# The ASK count is the conjunction and drops it; the state tally still counts
# it, because a chip a reader can see must be findable in a count.
if doc["asks_count"] != 1:
    sys.exit("the ask count is %d, so work that ended is still asked about"
             % doc["asks_count"])
if doc["summary"]["needs-captain"] != 2:
    sys.exit("the state tally is %r - it should still count the row that earned "
             "needs-captain before the work ended" % doc["summary"])
if doc["asks"] != ["o-live"]:
    sys.exit("the asks index is %r, not the one live ask" % doc["asks"])
' || fail "asks: see the reported queue"
pass "work that ended leaves every queue, tally, and aging flag it had earned"

# The OTHER half of the conjunction, tested alone: a live item that nobody owes
# is not an ask either, for an entirely independent reason.
HOME23B=$(new_home)
# Deliberately no merge evidence: this fixture has to stay live on the outcome
# axis so the STATE half of the conjunction is what disqualifies it.
FM_HOME=$HOME23B "$BRIDGE" task -q --id t-settled --project orca --phase validating \
  --state resolved --pointer "https://example.invalid/pull/3" >/dev/null
FM_HOME=$HOME23B "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
item = doc["items"]["t-settled"]
if item["outcome"] != "in-flight":
    sys.exit("this case needs live work to prove the state half alone: %r" % item["outcome"])
if doc["asks"]:
    sys.exit("a settled item is an ask even though nobody owes it: %r" % doc["asks"])
' || fail "asks: see the reported queue"
pass "an item nobody owes is not an ask even while the work is still live"

FM_HOME=$HOME23 "$RENDER" --html > "$TMP_ROOT/discard-ask.html"
askboard=$(cat "$TMP_ROOT/discard-ask.html")
case "$askboard" in
  *'<b>1</b>waiting on you'*) : ;;
  *) fail "asks: the header count still counts work that ended" ;;
esac
# An override's provenance carries the accent; an ordinary note does not, so a
# routine event never reads as a problem on a board where orange means one thing.
FM_HOME=$HOME23 "$BRIDGE" note -q --id ev-plain --project orca \
  --title "a routine landed change" --note "picked up the pin bump too" >/dev/null
FM_HOME=$HOME23 "$RENDER" --html > "$TMP_ROOT/accent.html"
python3 - "$TMP_ROOT/accent.html" <<'ACCENT' || fail "accent: see the reported note"
import re, sys
html = open(sys.argv[1]).read()
seen_plain = False
for match in re.finditer(r'<div class="why([^"]*)">([^<]*)</div>', html):
    accented = "override" in match.group(1)
    provenance = "checks skipped" in match.group(2)
    if accented and not provenance:
        sys.exit("an ordinary note carries the override accent: %r" % match.group(2))
    if provenance and not accented:
        sys.exit("override provenance lost its accent: %r" % match.group(2))
    seen_plain = seen_plain or not accented
if not seen_plain:
    sys.exit("no ordinary note rendered, so this proves nothing")
sys.exit(0)
ACCENT
pass "only override provenance carries the alarm accent; an ordinary note reads as ordinary"
python3 - "$TMP_ROOT/discard-ask.html" <<'PY' || fail "asks: see the reported row"
import re, sys
html = open(sys.argv[1]).read()
row = re.search(r'<tr id="item-task-pr">.*?</tr>', html, re.S)
if row is None:
    sys.exit("the task vanished from the board instead of staying visible")
row = row.group(0)
if "discarded" not in row:
    sys.exit("the row does not show how the work ended: %s" % row)
if "needs-captain" not in row:
    sys.exit("the row hides the disposition it had earned: %s" % row)
if "branch was a dead end" not in row:
    sys.exit("the row does not carry the reason it was discarded: %s" % row)
if "button class=\"ans\"" in row:
    sys.exit("the row still offers a ruling on work that ended: %s" % row)
index = re.search(r'<section id="waiting">.*?</section>', html, re.S).group(0)
if "item-task-pr" in index:
    sys.exit("work that ended is still listed in the asks index")
sys.exit(0)
PY
pass "a row that ended stays visible with both axes and its reason, and offers no ruling"

# --- 24. neither axis is derived from the other ----------------------------
#
# The property under guard is the ABSENCE of a precedence rule. A ranking
# cannot survive both halves: which closed key an item lands in must depend on
# the outcome axis alone, and what the ledger stores on either axis must not
# depend on the other at all.

HOME24=$(new_home)
for state in needs-captain needs-cocaptain fm-handling resolved; do
  for outcome in landed discarded unknown; do
    FM_HOME=$HOME24 "$BRIDGE" task -q --id "t-$state-$outcome" --project orca \
      --phase force-cleaned --state "$state" --outcome "$outcome" >/dev/null
  done
done
FM_HOME=$HOME24 "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
states = ("needs-captain", "needs-cocaptain", "fm-handling", "resolved")
outcomes = ("landed", "discarded", "unknown")
zone_of = {"landed": "fleet_landed", "discarded": "fleet_discarded",
           "unknown": "fleet_unknown"}
# Hold the outcome fixed and vary the state: the closed key must not move.
for outcome in outcomes:
    for state in states:
        key = "t-%s-%s" % (state, outcome)
        if key not in doc["zones"][zone_of[outcome]]:
            sys.exit("%s is not in zones.%s, so the state axis moved an ending"
                     % (key, zone_of[outcome]))
        for other in outcomes:
            if other != outcome and key in doc["zones"][zone_of[other]]:
                sys.exit("%s also appears in zones.%s" % (key, zone_of[other]))
# Hold the state fixed and vary the outcome: what the ledger stores on each
# axis must be exactly what was written, with neither rewritten by the other.
for state in states:
    for outcome in outcomes:
        item = doc["items"]["t-%s-%s" % (state, outcome)]
        if item["state"] != state:
            sys.exit("outcome %s rewrote state %s to %r" % (outcome, state, item["state"]))
        if item["outcome"] != outcome:
            sys.exit("state %s rewrote outcome %s to %r" % (state, outcome, item["outcome"]))
# And no item that ended is on a queue, whatever it was owed - the conjunction,
# applied uniformly rather than as a tiebreak.
if doc["asks"] or doc["cocaptain_asks"]:
    sys.exit("work that ended is queued: %r %r" % (doc["asks"], doc["cocaptain_asks"]))
# The state tally reads the state axis. A consumer that re-derived it by
# ranking - counting an ending as though it were a disposition - would move
# these counts, which is what a blended value did before there were two axes.
expected = {"needs-captain": 3, "needs-cocaptain": 3, "fm-handling": 3,
            "resolved": 3, "unstated": 0, "unrecognized": 0}
got = {key: doc["summary"][key] for key in expected}
if got != expected:
    sys.exit("the state tally is %r, not %r - something is ranking the axes"
             % (got, expected))
# Each axis partitions the same items, so both add up to the same total.
if sum(doc["summary"].values()) != doc["counts"]["board_items"]:
    sys.exit("the state axis counts %d of %d items"
             % (sum(doc["summary"].values()), doc["counts"]["board_items"]))
if sum(doc["outcomes"].values()) != doc["counts"]["board_items"]:
    sys.exit("the outcome axis counts %d of %d items"
             % (sum(doc["outcomes"].values()), doc["counts"]["board_items"]))
# The outcome tally reads the outcome axis, with four items per ending.
for outcome in outcomes:
    if doc["outcomes"][outcome] != 4:
        sys.exit("the outcome tally counts %s %d times, not 4 - something is "
                 "ranking the axes" % (outcome, doc["outcomes"][outcome]))
' || fail "axes: see the reported independence failure"
pass "the closed key depends on the outcome axis alone, and neither axis rewrites the other"

# --- 25. closed rows are capped, and say what they are not showing ---------

HOME25=$(new_home)
i=1
while [ "$i" -le 9 ]; do
  FM_HOME=$HOME25 "$BRIDGE" task -q --id "gone-$i" --project orca --phase force-cleaned \
    --state fm-handling --outcome discarded --ts "2026-07-31T10:0$i:00Z" >/dev/null
  i=$((i + 1))
done
capped=$(FM_HOME=$HOME25 "$RENDER" --html)
shown=$(printf '%s' "$capped" | grep -c 'class="chip discarded"' || true)
[ "$shown" = 6 ] || fail "closed cap: expected 6 discarded rows shown, got $shown"
case "$capped" in
  *"older discarded tasks in the record"*) : ;;
  *) fail "closed cap: rows were dropped with no overflow pointer to the record" ;;
esac
case "$capped" in
  *"+3 older discarded tasks"*) : ;;
  *) fail "closed cap: the overflow does not say how many are not shown" ;;
esac
pass "closed rows are capped with a visible pointer to the full record"

# Record hygiene reads the same two axes: a cleanup that ended the work is not
# a record to clean up, and no answer form is demanded for work that ended.
FM_HOME=$HOME25 "$BRIDGE" lint --strict >/dev/null 2>&1 \
  || fail "closed: a record of ended work is reported as a hygiene problem"
pass "a record of ended work lints clean"

# Every zone keys its closed groups on the outcome axis, so a critical that was
# thrown away never sits under a heading that says these stay pinned until
# resolved, and a discarded decision never sits in its project's landed list.
HOME25B=$(new_home)
FM_HOME=$HOME25B "$BRIDGE" critical -q --id c-gone --project fleet \
  --title "a critical that was thrown away" --answer act >/dev/null
FM_HOME=$HOME25B "$BRIDGE" append -q id=c-gone phase=force-cleaned outcome=discarded \
  note="forced teardown: checks skipped, unlanded work discarded - superseded" >/dev/null
FM_HOME=$HOME25B "$BRIDGE" ask -q --id d-gone --project orca \
  --title "a decision that was thrown away" --answer A >/dev/null
FM_HOME=$HOME25B "$BRIDGE" append -q id=d-gone phase=force-cleaned outcome=discarded \
  note="forced teardown: checks skipped, unlanded work discarded - superseded" >/dev/null
FM_HOME=$HOME25B "$BRIDGE" critical -q --id c-live --project fleet \
  --title "a critical that still stands" --answer act >/dev/null

FM_HOME=$HOME25B "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
zones = doc["zones"]
if "c-gone" in zones["criticals"]:
    sys.exit("a critical that was thrown away is still pinned")
if zones["criticals_discarded"] != ["c-gone"]:
    sys.exit("a discarded critical is not in its own group: %r" % zones["criticals_discarded"])
if zones["criticals_landed"]:
    sys.exit("a discarded critical was filed under landed: %r" % zones["criticals_landed"])
if zones["criticals"] != ["c-live"]:
    sys.exit("the live critical is no longer pinned: %r" % zones["criticals"])
for group in zones["decisions"]:
    if group["project"] != "orca":
        continue
    if "d-gone" in group["open"]:
        sys.exit("a decision that was thrown away is still listed as open")
    if group["discarded"] != ["d-gone"]:
        sys.exit("a discarded decision is not in its own group: %r" % group["discarded"])
    if group["landed"]:
        sys.exit("a discarded decision was filed under landed: %r" % group["landed"])
' || fail "zones: see the reported placement"
pass "a critical or decision that ended is grouped by how it ended, never under landed"

# --- 26. absence on the outcome axis is read against what the writer could say

# Five rounds of rows were written before this axis existed. Reading their
# silence as `in-flight` would assert in bulk that all of it is still running -
# a claim, in a field built to be authoritative. So absence is resolved against
# the schema version the record carries, and only EVIDENCE may fill a value.

HOME26=$(new_home)
LEDGER26=$(ledger_of "$HOME26")
mkdir -p "$(dirname "$LEDGER26")"
cat > "$LEDGER26" <<'EOF'
{"v":1,"ts":"2026-07-30T10:00:00Z","id":"old-quiet","kind":"task","project":"orca","state":"fm-handling","title":"written before the axis existed"}
{"v":1,"ts":"2026-07-30T10:01:00Z","id":"old-merged","kind":"task","project":"orca","state":"resolved","phase":"merged","pointer":"https://example.invalid/pull/4","title":"merged before the axis existed"}
{"v":1,"ts":"2026-07-30T10:02:00Z","id":"old-discard","kind":"task","project":"orca","state":"fm-handling","phase":"discarded","note":"forced teardown: landed-work check skipped, work discarded - the old conflated record","title":"force-cleaned before the axis existed"}
{"ts":"2026-07-30T10:03:00Z","id":"no-version","kind":"task","project":"orca","state":"fm-handling","title":"no v at all"}
{"v":2,"ts":"2026-07-31T10:04:00Z","id":"new-quiet","kind":"task","project":"orca","state":"fm-handling","title":"written after the axis, saying nothing"}
{"v":2,"ts":"2026-07-31T10:05:00Z","id":"new-stated","kind":"task","project":"orca","state":"resolved","outcome":"landed","phase":"cleaned","pointer":"https://example.invalid/pull/5","title":"written after the axis, saying so"}
EOF

FM_HOME=$HOME26 "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
items = doc["items"]

# A pre-axis row that nothing resolves is unknown, and says why.
for key in ("old-quiet", "no-version"):
    item = items[key]
    if item["outcome"] != "unknown":
        sys.exit("%s reads %r; a writer with no outcome vocabulary said nothing about "
                 "how the work ended" % (key, item["outcome"]))
    if item["outcome_source"] != "unobserved":
        sys.exit("%s claims source %r" % (key, item["outcome_source"]))
    if not item["outcome_evidence"]:
        sys.exit("%s does not say why its ending is unobservable" % key)

# An old phase=discarded is NOT evidence of a discard. It is the ambiguous
# field the two axes exist to split, and laundering it would dress the old
# ambiguity in the new axis confidence.
discard = items["old-discard"]
if discard["outcome"] == "discarded":
    sys.exit("an old phase=discarded was mapped straight onto outcome=discarded, "
             "which is the conflation this axis removes")
if discard["outcome"] != "unknown" or discard["outcome_source"] != "unobserved":
    sys.exit("the old force-cleaned row reads %r/%r"
             % (discard["outcome"], discard["outcome_source"]))

# Evidence, and only evidence, populates a value.
merged = items["old-merged"]
if merged["outcome"] != "landed":
    sys.exit("a merged phase with a pointer is an observation of an ending, but "
             "%s reads %r" % ("old-merged", merged["outcome"]))
if merged["outcome_source"] != "backfilled":
    sys.exit("the backfilled value does not say it was backfilled: %r"
             % merged["outcome_source"])
if "merged phase" not in merged["outcome_evidence"]:
    sys.exit("the backfill does not name its evidence: %r" % merged["outcome_evidence"])

# A post-axis row that genuinely says nothing still reads in-flight - the
# correction must not swallow the legitimate case.
quiet = items["new-quiet"]
if quiet["outcome"] != "in-flight" or quiet["outcome_source"] != "unstated":
    sys.exit("a v2 row with genuine silence reads %r/%r, not in-flight/unstated"
             % (quiet["outcome"], quiet["outcome_source"]))

# And a stated value is reported as stated, never as worked out.
stated = items["new-stated"]
if stated["outcome"] != "landed" or stated["outcome_source"] != "observed":
    sys.exit("a stated outcome reads %r/%r" % (stated["outcome"], stated["outcome_source"]))
' || fail "backfill: see the reported row"
pass "pre-axis silence is unknown, evidence backfills, and post-axis silence is still in-flight"

# The rows nobody can resolve are named on the board, not quietly filled in.
FM_HOME=$HOME26 "$RENDER" --html > "$TMP_ROOT/backfill.html"
case "$(cat "$TMP_ROOT/backfill.html")" in
  *"written before the outcome axis existed"*) : ;;
  *) fail "backfill: the board does not surface the rows it could not resolve" ;;
esac
unresolved=$(state_query "$HOME26" 'sorted(d["unobserved_outcomes"])')
[ "$unresolved" = "['no-version', 'old-discard', 'old-quiet']" ] \
  || fail "backfill: unobserved_outcomes is $unresolved"
pass "rows whose ending nobody can observe are named on the board and in --state"

# --- 27. each axis counts every item, and the ask count is its own number ---
#
# Ledger conservation says every non-blank line is accounted for. The same
# discipline applies to the tallies: a reader who sees a needs-captain chip
# must be able to find that item in a count, and read on the other axis why it
# is not an ask.

HOME27=$(new_home)
for state in needs-captain needs-cocaptain fm-handling resolved; do
  for outcome in in-flight landed discarded unknown; do
    FM_HOME=$HOME27 "$BRIDGE" task -q --id "p-$state-$outcome" --project orca \
      --state "$state" --outcome "$outcome" >/dev/null
  done
done
FM_HOME=$HOME27 "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
total = doc["counts"]["board_items"]
if total != 16:
    sys.exit("expected 16 board items, got %d" % total)
state_total = sum(doc["summary"].values())
outcome_total = sum(doc["outcomes"].values())
if state_total != total:
    sys.exit("the state axis counts %d of %d items - it drops some silently"
             % (state_total, total))
if outcome_total != total:
    sys.exit("the outcome axis counts %d of %d items" % (outcome_total, total))
# The ask count is the conjunction and is published as its own number: four
# needs-captain rows, of which only the in-flight one is an ask.
if doc["asks_count"] != 1:
    sys.exit("the ask count is %d, not the one owed-and-live item" % doc["asks_count"])
if doc["summary"]["needs-captain"] != 4:
    sys.exit("the state tally lost the needs-captain rows that ended: %r" % doc["summary"])
' || fail "tallies: see the reported count"
pass "both axes count every item, and the ask count stands apart from them"

FM_HOME=$HOME27 "$RENDER" --html > "$TMP_ROOT/tallies.html"
tallyboard=$(cat "$TMP_ROOT/tallies.html")
case "$tallyboard" in
  *"waiting on you"*) : ;;
  *) fail "tallies: the board does not label the ask count" ;;
esac
case "$tallyboard" in
  *"who owes it, all 16"*) : ;;
  *) fail "tallies: the state axis does not say what it totals" ;;
esac
case "$tallyboard" in
  *"how it ended, all 16"*) : ;;
  *) fail "tallies: the outcome axis does not say what it totals" ;;
esac
pass "the board states what each axis totals, so a chip is always findable in a count"

# --- 28. one pointer rule, one predicate, two readers ----------------------

HOME28=$(new_home)
FM_HOME=$HOME28 "$BRIDGE" append -q id=d-state kind=decision project=orca \
  state=resolved title="closed on the state axis with nowhere to look" >/dev/null
FM_HOME=$HOME28 "$BRIDGE" append -q id=d-outcome kind=decision project=orca \
  state=needs-captain outcome=landed title="ended on the outcome axis with nowhere to look" >/dev/null
FM_HOME=$HOME28 "$BRIDGE" ask -q --id d-fine --project orca --title "still open" \
  --answer A >/dev/null

FM_HOME=$HOME28 "$BRIDGE" lint > "$TMP_ROOT/pointer-lint.txt"
FM_HOME=$HOME28 "$RENDER" --html > "$TMP_ROOT/pointer-board.html"
python3 - "$TMP_ROOT/pointer-lint.txt" "$TMP_ROOT/pointer-board.html" <<'POINTER' || fail "pointer: see the report"
import sys
lint = open(sys.argv[1]).read()
html = open(sys.argv[2]).read()
for key, axis in (("d-state", "state resolved"), ("d-outcome", "outcome landed")):
    if axis not in lint:
        sys.exit("lint does not name the axis that triggered for %s: %s" % (key, lint))
warned = html.count("with no pointer to where it went")
flagged = lint.count("with no pointer to where it went")
if warned != flagged:
    sys.exit("the board warns on %d items and lint reports %d - one rule, two answers"
             % (warned, flagged))
if flagged != 2:
    sys.exit("expected both closed-without-pointer items reported, got %d" % flagged)
if "d-fine" in lint:
    sys.exit("an open decision was reported as missing a pointer")
sys.exit(0)
POINTER
pass "the board and the linter read one pointer rule and name the axis that triggered it"

# --- 29. the count lives in rendered content, and the tab title says only what
#         it can keep ---------------------------------------------------------
#
# INHERITED MEASUREMENT, recorded in docs/verification/bridge-hosted-input.md
# and deliberately not re-derived here: Lavish copies the artifact's <title>
# into the HOSTING page's title at page load, and does not re-propagate it when
# the tick rewrites the board and the artifact frame live-reloads.
#
# The earlier measurement checked the title at load, after scrolling and after
# backgrounding - never across a COUNT CHANGE, which is the one event that moves
# the count AND the one event that redraws the board without re-propagating the
# title. So a count carried in the tab title is stale exactly when it changes,
# which is the only time anybody needs it.
#
# The fix is where the count lives, not a fresher title. Rendered content
# survives a redraw by construction, because the redraw is what produces it. So
# the count change is the fixture, and it pins both directions: the rendered
# count must MOVE with the ledger, and the tab title must not carry a number a
# redraw would leave standing.

HOME29=$(new_home)
FM_HOME=$HOME29 "$BRIDGE" ask -q --id count-first --project orca \
  --title "the first ask" --answer "A: yes" >/dev/null
FM_HOME=$HOME29 "$RENDER" --html > "$TMP_ROOT/count-before.html"
FM_HOME=$HOME29 "$BRIDGE" ask -q --id count-second --project orca \
  --title "the second ask" --answer "A: yes" >/dev/null
FM_HOME=$HOME29 "$RENDER" --html > "$TMP_ROOT/count-after.html"

python3 - "$TMP_ROOT/count-before.html" "$TMP_ROOT/count-after.html" <<'COUNT' || fail "count: see the reported surface"
import re, sys

before = open(sys.argv[1]).read()
after = open(sys.argv[2]).read()

def rendered_count(html, which):
    body = html.find("<body")
    if body < 0:
        sys.exit("the %s board has no body at all" % which)
    seen = [(match.start(), match.group(1))
            for match in re.finditer(r"<b>(\d+)</b>waiting on you", html)]
    if not seen:
        sys.exit("the %s board renders no open-ask count at all, so the count "
                 "has nowhere left to live that survives a redraw" % which)
    if len({value for _, value in seen}) != 1:
        sys.exit("the %s board renders disagreeing open-ask counts: %r"
                 % (which, [value for _, value in seen]))
    if seen[0][0] < body:
        sys.exit("the %s board's open-ask count is not in rendered content" % which)
    return seen[0][1]

# The ledger gained an ask, so the rendered count has to have gained one too.
# A count read off the tab title instead of the fold cannot do this: the title
# is identical across the change.
one, two = rendered_count(before, "one-ask"), rendered_count(after, "two-ask")
if (one, two) != ("1", "2"):
    sys.exit("the rendered count read %s then %s across a change from one open "
             "ask to two - it does not track the ledger" % (one, two))

def tab_title(html, which):
    match = re.search(r"<title>(.*?)</title>", html, re.S)
    if match is None:
        sys.exit("the %s board carries no <title> at all" % which)
    return match.group(1)

first, second = tab_title(before, "one-ask"), tab_title(after, "two-ask")
if first != second:
    sys.exit("the tab title changed from %r to %r across a count change, but "
             "Lavish propagates it at page load only - a hosted board would go "
             "on showing the old one" % (first, second))
if re.search(r"\d", first):
    sys.exit("the tab title carries a number (%r) that a redraw cannot refresh "
             "in the hosting page" % first)
sys.exit(0)
COUNT
pass "a count change moves the rendered count, and leaves the tab title untouched"

# The documentation may not promise what the tab cannot keep either - the
# affordance rule reaches browser chrome. A line that names the tab title as
# where the count lives is the retired claim coming back.
python3 - "$ROOT/docs/verification/bridge-hosted-input.md" "$ROOT/docs/bridge.md" <<'TABDOC' || fail "docs: see the reported claim"
import re, sys

SURFACE = re.compile(r"tab title|browser tab|hosting page's title|page's title|page title")
CLAIM = re.compile(r"carr(y|ies|ied) the (open-ask )?count|count rides|rides in the|"
                   r"count stays|keeps the count|already carries")
# A sentence that DENIES the claim is the correction, not the defect. The docs
# here are one sentence per line, so a line is the unit.
DENIAL = re.compile(r"\bnot\b|\bnever\b|\bno longer\b|\bstops\b|\bused to\b|\bwould\b")

for path in sys.argv[1:]:
    for number, line in enumerate(open(path), 1):
        if SURFACE.search(line) and CLAIM.search(line) and not DENIAL.search(line):
            sys.exit("%s:%d claims the tab title is where the open-ask count "
                     "lives, which Lavish propagates only at page load:\n  %s"
                     % (path, number, line.strip()))

record = open(sys.argv[1]).read()
if not re.search(r"at page load", record):
    sys.exit("%s no longer records that the artifact title is propagated at "
             "page load, which is the whole limit the count was moved for"
             % sys.argv[1])
if not re.search(r"re-propagat", record):
    sys.exit("%s no longer records that the hosting page's title is not "
             "re-propagated when the board is redrawn" % sys.argv[1])
sys.exit(0)
TABDOC
pass "the documentation states the title is propagated at load, and promises no freshness past it"

echo "all bridge ledger and fold tests passed"
