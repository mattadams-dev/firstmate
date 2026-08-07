#!/usr/bin/env bash
# tests/fm-autoarm-epoch-atomicity.test.sh - the epoch writer's atomic
# composition and the provenance-strict Claude test. Round 3 (trio) acceptance
# for review-4 and review-1 on fm-rebirth-identity-redesign.
#
# The round-2 fixture was strictly sequential and therefore structurally blind
# to the window the defect lives in: the epoch writer's rename was atomic but
# its read-decide-rename COMPOSITION was not, so two writers could read the
# same sequence and the last mv won blind. These fixtures race the SHIPPED
# writer text extracted from the script under test, in BOTH directions:
#
#   DETECT - the same race run through a reference mutant shaped like the
#            pre-round-3 body must lose updates. A fixture that cannot catch
#            the defect proves nothing about the fix (the gate's own words).
#   HOLD   - the shipped writer under the same race loses nothing, a racing
#            refusal never supersedes a fresh non-refused claim, a stale claim
#            is superseded normally, and a wedged lock holder bounds the
#            writer instead of wedging the Stop hook behind it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-autoarm-epoch)

AUTOARM="$ROOT/bin/fm-claude-stop-autoarm.sh"
LOCKLIB="$ROOT/bin/fm-session-lock-lib.sh"

# --- harness: run N writes of one outcome through the SHIPPED writer ----------
# The writer text (its lock/freshness constants through the closing brace) is
# extracted from the script under test at run time, so these fixtures race the
# code that ships, never a copy that can drift from it.
WRITER_SRC="$TMP_ROOT/writer-src.sh"
sed -n '/^EPOCH_WRITE_LOCK=/,/^}/p' "$AUTOARM" > "$WRITER_SRC"
grep -q 'write_epoch()' "$WRITER_SRC" \
  || fail "extraction: could not lift write_epoch from $AUTOARM"

RUNNER="$TMP_ROOT/runner.sh"
cat > "$RUNNER" <<'RUNNER_EOF'
#!/usr/bin/env bash
# <state-dir> <writes> <outcome> <result-file>
set -u
STATE=$1 WRITES=$2 OUTCOME=$3 RESULT=$4
EPOCH="$STATE/.claude-autoarm-epoch"
. "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
. "$FM_TEST_ROOT/bin/fm-session-lock-lib.sh"
. "$FM_TEST_WRITER_SRC"
ok=0
i=0
last_rc=0
while [ "$i" -lt "$WRITES" ]; do
  i=$((i + 1))
  if write_epoch "$OUTCOME"; then
    ok=$((ok + 1))
    last_rc=0
  else
    last_rc=$?
  fi
done
printf '%s %s\n' "$ok" "$last_rc" > "$RESULT"
RUNNER_EOF
chmod +x "$RUNNER"

epoch_seq() {  # <state-dir>
  sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$1/.claude-autoarm-epoch" 2>/dev/null
}
epoch_outcome() {  # <state-dir>
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/.claude-autoarm-epoch" 2>/dev/null
}

race() {  # <state-dir> <writers> <writes-each> <outcome> -> total successes
  local state=$1 writers=$2 writes=$3 outcome=$4 w total=0 rfile pids='' p
  rm -f "$state/.last-rcs"
  for w in $(seq 1 "$writers"); do
    FM_TEST_ROOT="$ROOT" FM_TEST_WRITER_SRC="$WRITER_SRC" \
      "$RUNNER" "$state" "$writes" "$outcome" "$state/.rc.$w" &
    pids="$pids $!"
  done
  # Explicit pids, never bare wait: this runs in a command-substitution
  # subshell, which inherits the parent's job table - a bare wait tries to
  # reap the parent's unrelated background jobs (the wedged-holder sleep) and
  # bash spins forever on "not a child of this shell".
  for p in $pids; do
    wait "$p" 2>/dev/null || true
  done
  for w in $(seq 1 "$writers"); do
    rfile="$state/.rc.$w"
    read -r ok_n rc_n < "$rfile" 2>/dev/null || { ok_n=0; rc_n=; }
    total=$((total + ok_n))
    printf '%s\n' "$rc_n" >> "$state/.last-rcs"
    rm -f "$rfile"
  done
  printf '%s\n' "$total"
}
last_rcs() {  # <state-dir> -> the per-writer final return codes, then clears
  cat "$1/.last-rcs" 2>/dev/null
  rm -f "$1/.last-rcs"
}

# --- HOLD: the shipped writer loses no update under a real race ---------------
# Two distinct guarantees, asserted separately:
#   zero loss    - every write that REPORTED success is in the sequence. Holds
#                  at any contention, no exceptions.
#   envelope     - within the production envelope (a handful of concurrent hook
#                  firings) every write succeeds outright.
# Under a deliberate 24-writer storm - far past the envelope - the 1s
# acquisition bound may honestly give up on some writes (rc 2, unknown /
# unrecorded). That is designed behavior, not loss: a bounded-out write
# reported exactly that. (The attestation reviewer caught this comment naming
# rc 1 - the subordination code - contradicting the three-way distinction the
# suite exists to prove.)
S1="$TMP_ROOT/s1"; mkdir -p "$S1"
total=$(race "$S1" 24 6 arming)
seq_now=$(epoch_seq "$S1")
[ "$seq_now" = "$total" ] \
  || fail "shipped writer lost updates under storm: seq $seq_now != $total successful writes"
[ "$total" -ge 100 ] \
  || fail "storm liveness floor: only $total of 144 writes succeeded. On a loaded box this is scheduler starvation, NOT lost updates - lost updates are the seq-mismatch assertion above. Rerun quiet before reading it as a writer defect"
pass "epoch writer: storm of 144 writes/24 writers - $total recorded, zero lost, refusals honest"

S1B="$TMP_ROOT/s1b"; mkdir -p "$S1B"
env_total=$(race "$S1B" 4 6 arming)
env_seq=$(epoch_seq "$S1B")
[ "$env_total" -eq 24 ] \
  || fail "production envelope: expected all 24 writes to record at 4-way contention, got $env_total"
[ "$env_seq" = "$env_total" ] \
  || fail "production envelope lost updates: seq $env_seq != $env_total"
pass "epoch writer: production envelope (4 writers) - all 24 writes recorded, zero lost"

# --- DETECT: the reference mutant (pre-round-3 shape) loses updates -----------
# This mirrors the replaced body: read seq, format, mv -f - atomic rename,
# non-atomic composition, no lock. The fixture must catch it or the fixture
# proves nothing about the fix.
MUTANT_SRC="$TMP_ROOT/mutant-src.sh"
cat > "$MUTANT_SRC" <<'MUTANT_EOF'
write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}
MUTANT_EOF
S2="$TMP_ROOT/s2"; mkdir -p "$S2"
WRITER_SAVE="$WRITER_SRC"
WRITER_SRC="$MUTANT_SRC"
mutant_total=$(race "$S2" 24 6 arming)
WRITER_SRC="$WRITER_SAVE"
mutant_seq=$(epoch_seq "$S2")
[ -n "$mutant_seq" ] || fail "mutant run left no epoch at all"
[ "$mutant_seq" -lt "$mutant_total" ] \
  || fail "fixture has no teeth: the unlocked mutant lost no updates (seq $mutant_seq of $mutant_total) - raise the contention"
pass "epoch fixture detects the defect: unlocked mutant lost $((mutant_total - mutant_seq)) of $mutant_total updates"

# --- subordination on OBSERVED EVIDENCE, never a clock ------------------------
# The redesigned invariant, both mutation directions:
#   S3a  live owner on the lock + an AGED record  -> refusals subordinate.
#        A clock-based mutant records here (the record looks stale).
#   S3b  owner observed dead + a FRESH record     -> a refusal records.
#        A clock-based mutant subordinates here (the record looks fresh).
# A fake ps reports the designated holder pid as a live claude harness so
# fm_harness_pid_alive sees what a real lock owner would look like.
fakebin=$(fm_fakebin "$TMP_ROOT")
cat > "$fakebin/ps" <<FAKEPS
#!/usr/bin/env bash
target=\$(cat "$TMP_ROOT/fake-ps-target" 2>/dev/null)
mode=""; pid=""
prev=""
for a in "\$@"; do
  case "\$prev" in
    -o) mode=\$a ;;
    -p) pid=\$a ;;
  esac
  prev=\$a
done
if [ -n "\$target" ] && [ "\$pid" = "\$target" ]; then
  case "\$mode" in
    comm*) echo claude; exit 0 ;;
    args*) echo "claude --resume"; exit 0 ;;
  esac
fi
exec /bin/ps "\$@"
FAKEPS
chmod +x "$fakebin/ps"

S3="$TMP_ROOT/s3"; mkdir -p "$S3"
bash -c 'sleep 45; :' &
OWNER_HOLDER=$!
printf '%s\n' "$OWNER_HOLDER" > "$TMP_ROOT/fake-ps-target"
printf '%s\nsession=owner-live\n' "$OWNER_HOLDER" > "$S3/.lock"

one=$(PATH="$fakebin:$PATH" race "$S3" 1 1 arming)
[ "$one" -eq 1 ] || fail "seed arming write did not record"
touch -d '40 seconds ago' "$S3/.claude-autoarm-epoch" 2>/dev/null \
  || fail "cannot age the epoch for the anti-clock case"
refused_ok=$(PATH="$fakebin:$PATH" FM_SESSION_ID=bystander-bbb race "$S3" 12 1 refused)
[ "$refused_ok" -eq 0 ] \
  || fail "evidence rule broken: $refused_ok refusals recorded over a LIVE owner (aged record - a clock mutant would do this)"
[ "$(epoch_outcome "$S3")" = arming ] \
  || fail "a refusal superseded a live owner's claim: outcome $(epoch_outcome "$S3")"
for rc in $(last_rcs "$S3"); do
  [ "$rc" = 1 ] \
    || fail "a subordinated refusal returned $rc, not 1 - the caller cannot tell deliberate quiet from unknown"
done
pass "epoch writer: live owner + 40s-old record - 12 refusals subordinate (rc 1); the clock is dead"

kill "$OWNER_HOLDER" 2>/dev/null || true
wait "$OWNER_HOLDER" 2>/dev/null || true
fresh=$(PATH="$fakebin:$PATH" race "$S3" 1 1 arming)
[ "$fresh" -eq 1 ] || fail "re-seed arming write did not record"
dead_ok=$(PATH="$fakebin:$PATH" FM_SESSION_ID=bystander-bbb race "$S3" 1 1 refused)
[ "$dead_ok" -eq 1 ] \
  || fail "refusal against a DEAD owner did not record despite a fresh record - a clock mutant would subordinate here"
[ "$(epoch_outcome "$S3")" = refused ] \
  || fail "dead-owner supersede failed: outcome $(epoch_outcome "$S3")"
grep -q 'by=bystander-bbb' "$S3/.claude-autoarm-epoch" \
  || fail "the refusal record does not name its author: $(cat "$S3/.claude-autoarm-epoch")"
grep -q "saw_owner=$OWNER_HOLDER" "$S3/.claude-autoarm-epoch" \
  || fail "the refusal record does not carry its observed-owner evidence: $(cat "$S3/.claude-autoarm-epoch")"
pass "epoch writer: dead owner + fresh record - refusal records with author and evidence (by=, saw_owner=)"

# --- HOLD: a wedged lock holder bounds the writer, never wedges the hook ------
S4="$TMP_ROOT/s4"; mkdir -p "$S4"
sleep 60 &
HOLDER=$!
mkdir -p "$S4/.claude-autoarm-epoch.write-lock"
printf '%s\n' "$HOLDER" > "$S4/.claude-autoarm-epoch.write-lock/pid"
start=$(date +%s)
bounded=$(race "$S4" 1 1 arming)
elapsed=$(( $(date +%s) - start ))
kill "$HOLDER" 2>/dev/null || true
[ "$bounded" -eq 0 ] || fail "writer claimed success behind a live wedged holder"
[ "$elapsed" -le 5 ] || fail "writer wedged ${elapsed}s behind a held lock; bound is ~1s"
[ ! -e "$S4/.claude-autoarm-epoch" ] || fail "writer wrote despite never holding the lock"
wedged_rc=$(last_rcs "$S4")
[ "$wedged_rc" = 2 ] \
  || fail "a lock-bounded write returned $wedged_rc, not 2 - unknown must be distinguishable from subordinated"
pass "epoch writer: live wedged holder bounds the write to ${elapsed}s with the distinct code 2"

# --- HOLD: exactly one writer of the epoch exists in the tree -----------------
# The atomic-composition guarantee is a lock DISCIPLINE: it holds only while
# every writer takes the lock. Today write_epoch is the sole writer; this
# assertion makes a second writer break a test instead of quietly voiding the
# guarantee (the reviewer's note: a comment binds only whoever remembers it).
writer_files=$(grep -rlE 'claude-autoarm-epoch' "$ROOT/bin" | sort)
for f in $writer_files; do
  case "${f##*/}" in
    fm-claude-stop-autoarm.sh|fm-turnend-guard.sh) : ;;
    *) fail "new file touches the epoch path: ${f##*/} - it must go through write_epoch's lock or extend this allowlist deliberately" ;;
  esac
done
guard_writes=$(grep -nE '(^|[^<])>+ *"?\$?\{?EPOCH|mv [^#]*claude-autoarm-epoch' "$ROOT/bin/fm-turnend-guard.sh" | grep -v 'write-lock' | grep -cv '^\s*#' || true)
[ "${guard_writes:-0}" -eq 0 ] \
  || fail "fm-turnend-guard.sh gained a write-shaped line touching the epoch; all writes go through write_epoch under its lock"
pass "epoch writer: single-writer invariant asserted - a second writer now breaks a test"

# --- provenance-strict: REFUSE and ADMIT, pure-function cases -----------------
strict() {  # <comm> <args>
  bash -c ". \"\$0\"; fm_harness_claude_provenance_strict \"\$1\" \"\$2\"" "$LOCKLIB" "$1" "$2"
}
matcher_claude_flag() {  # <comm> <args> -> prints flag value
  bash -c ". \"\$0\"; fm_harness_process_matches \"\$1\" \"\$2\"; printf '%s' \"\$FM_HARNESS_IS_CLAUDE\"" "$LOCKLIB" "$1" "$2"
}

strict claude "claude --resume" \
  || fail "provenance strict refused the plain claude CLI"
strict 2.1.222 "/home/u/.local/share/claude/versions/2.1.222 --session-id abc" \
  || fail "provenance strict refused a version-named binary under a claude path component"
strict claude-code "claude-code --help" \
  || fail "provenance strict refused a claude- prefixed basename"
pass "provenance strict: ADMIT - real Claude shapes pass"

if strict node "node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"; then
  fail "the rendered-string predicate still admits an interpreter shape - the interpreter path must be decided from real argv only"
fi
pass "provenance strict: the rendered-string predicate decides NATIVE shapes only"

# --- interpreter-hosted: decided from REAL ARGV, never rendered text ---------
# The redesign three review rounds paid for. `ps -o args=` joins argv with
# spaces irreversibly, so "node /a b/cli.js" is both a spaced path and two
# arguments; every defect this predicate produced came from trying to invert
# that. These fixtures pass argv as SEPARATE ARGUMENTS, exactly as the kernel
# holds it and as fm_harness_pid_is_claude now reads it from
# /proc/<pid>/cmdline - so position and content are facts, not inferences.
argv_hosted() {  # <argv...>
  bash -c '. "$1"; shift; fm_harness_claude_argv_is_interpreter_hosted "$@"' _ "$LOCKLIB" "$@"
}

argv_hosted node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js --session-id x \
  || fail "argv predicate refused an interpreter-hosted Claude at the trusted package path"
argv_hosted python /usr/lib/@anthropic-ai/claude-code/cli.py \
  || fail "argv predicate refused the python-hosted trusted package path"
# A spaced path needs no rule now - it is simply argv[1] containing spaces.
# Refusing it was never conservative: it clears the session id, writes a
# pid-only lock, and restores the ancestry basis this branch deletes.
argv_hosted node "/home/u/My Apps/node_modules/@anthropic-ai/claude-code/cli.js" \
  || fail "argv predicate refused a legitimate install under a SPACED path"
argv_hosted node "/home/u/My  Apps/tabs	and spaces/@anthropic-ai/claude-code/cli.js" \
  || fail "argv predicate refused a path with tabs and repeated spaces - argv carries them verbatim"
pass "argv predicate: ADMIT - trusted package in argv[1], including paths with spaces and tabs"

# Forgery axis: a trusted path anywhere OTHER than argv[1] is not the code
# executing, and cannot be, however the string would have rendered.
if argv_hosted node /opt/foreign/codex.js --fixture /tmp/@anthropic-ai/claude-code/data; then
  fail "FORGERY: trusted path as a DATA argument admitted"
fi
if argv_hosted python /opt/foreign/codex.py --data /tmp/@anthropic-ai/claude-code/x; then
  fail "FORGERY: trusted path as a data argument admitted under python"
fi
if argv_hosted node /opt/foreign/x.js /usr/lib/@anthropic-ai/claude-code/cli.js; then
  fail "FORGERY: trusted path in argv[2] admitted"
fi
if argv_hosted node --enable-source-maps /usr/lib/@anthropic-ai/claude-code/cli.js; then
  fail "flags-before-script admitted - argv[1] is a flag, not the trusted script"
fi
if argv_hosted node /x/@anthropic-ai/claude-code-fake/cli.js; then
  fail "near-miss package path admitted - component exactness failed"
fi
if argv_hosted node /x/claude-code/@anthropic-ai/cli.js; then
  fail "reversed path components admitted"
fi
if argv_hosted node; then
  fail "a bare interpreter with no script argument admitted"
fi
if argv_hosted codex --model x /usr/lib/@anthropic-ai/claude-code/cli.js; then
  fail "a non-interpreter argv[0] admitted"
fi
if argv_hosted "" /usr/lib/@anthropic-ai/claude-code/cli.js; then
  fail "an empty argv[0] admitted"
fi
pass "argv predicate: REFUSE - data-position, argv[2], flag-shifted, near-miss, reversed, empty, and non-interpreter shapes"

# --- live pid, end to end: the reader and the predicate together -------------
# Proves fm_harness_pid_argv recovers real kernel argv (including a spaced
# path) and that an absent cmdline refuses rather than guessing.
if [ -r /proc/$$/cmdline ]; then
  live_dir="$TMP_ROOT/live argv/@anthropic-ai/claude-code"
  mkdir -p "$live_dir"
  cat > "$live_dir/cli.js" <<'LIVE'
#!/usr/bin/env bash
sleep 30
LIVE
  chmod +x "$live_dir/cli.js"
  # A real process whose argv[0] is node-shaped and argv[1] is a SPACED path
  # into the trusted package - the exact shape the rendered string could not
  # distinguish from two arguments.
  ln -sf /bin/bash "$TMP_ROOT/node" 2>/dev/null || cp /bin/bash "$TMP_ROOT/node"
  "$TMP_ROOT/node" "$live_dir/cli.js" &
  live_pid=$!
  sleep 0.3
  argv_out=$(bash -c '. "$1"; fm_harness_pid_argv "$2"' _ "$LOCKLIB" "$live_pid") \
    || fail "fm_harness_pid_argv could not read a live pid's cmdline"
  [ "$(printf '%s\n' "$argv_out" | sed -n 2p)" = "$live_dir/cli.js" ] \
    || fail "kernel argv[1] not recovered verbatim (spaced path lost): $(printf '%s' "$argv_out" | tr '\n' '|')"
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  bash -c '. "$1"; fm_harness_pid_argv "$2"' _ "$LOCKLIB" "$live_pid" >/dev/null 2>&1 \
    && fail "an exited pid yielded argv - absence must refuse, never guess"
  pass "argv reader: live pid's spaced argv[1] recovered verbatim; an exited pid refuses"
else
  pass "argv reader: SKIPPED - /proc/<pid>/cmdline unavailable (the platform contract's refuse-to-prove side)"
fi

# The shared matcher must be UNTOUCHED by round 3: the loose substring still
# sets the flag, which is what keeps the ancestry walk's reach unchanged. A
# mutant that narrowed the shared matcher instead of the provenance consumer
# breaks this test - that mutant is review-1's original defect.
flag=$(matcher_claude_flag node "node /opt/claude-tools/codex.js")
[ "$flag" = 1 ] \
  || fail "shared matcher narrowed: FM_HARNESS_IS_CLAUDE=$flag for a claude-substring path; the ancestry walk's reach changed"
pass "shared matcher unchanged: walk reach preserved while provenance narrowed"
