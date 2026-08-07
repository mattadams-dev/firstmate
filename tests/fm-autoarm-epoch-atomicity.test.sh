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

strict node "node /home/u/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js --session-id x" \
  || fail "provenance strict refused an interpreter-hosted Claude at the exact trusted package path"
strict python "python /usr/lib/@anthropic-ai/claude-code/cli.py" \
  || fail "provenance strict refused the python-hosted trusted package path"
# ps flattens argv with spaces, so a script path CONTAINING whitespace is
# indistinguishable from multiple arguments by splitting. Refusing those is
# not conservative - it clears the session id, writes a pid-only lock, and
# restores the ancestry basis this branch deletes. An install under a spaced
# directory must admit.
strict node "node /home/u/My Apps/node_modules/@anthropic-ai/claude-code/cli.js" \
  || fail "provenance strict refused a legitimate install under a SPACED path - that refusal lands in the ancestry fallback"
pass "provenance strict: ADMIT - script position, including paths containing spaces"

# POSITION is the axis the round-2 fixtures missed: they probed the right
# shapes only in script position, so a trusted path in ARGUMENT position went
# untested and the implementation scanned the whole argument string - identity
# forgery by carrying a data path. Every refusal shape is now enumerated by
# position AND by string.
if strict node "node /opt/foreign/codex.js --fixture /tmp/@anthropic-ai/claude-code/data"; then
  fail "FORGERY: trusted package path in ARGUMENT position admitted a foreign script"
fi
if strict python "python /opt/foreign/codex.py --data /tmp/@anthropic-ai/claude-code/x"; then
  fail "FORGERY: trusted path in argument position admitted under the python branch"
fi
if strict node "node --experimental-x /opt/foreign/x.js /@anthropic-ai/claude-code/cli.js"; then
  fail "FORGERY: trusted path in a later position admitted behind a flag"
fi
if strict node "node /opt/foreign/x.js /usr/lib/@anthropic-ai/claude-code/cli.js"; then
  fail "FORGERY: a trusted path in a SECOND absolute argument admitted - the anchor must end at argv[1]"
fi
if strict node "node  /usr/lib/@anthropic-ai/claude-code/cli.js"; then
  fail "an empty argv[1] (double separator) admitted - ps joins argv with single spaces, so this is argv[2], a foreign shape"
fi
pass "provenance strict: REFUSE - trusted path in ARGUMENT position never admits (node and python)"

if strict node "node /opt/claude-tools/codex.js"; then
  fail "provenance strict admitted a foreign script under a claude-substring path"
fi
if strict node "node /x/@anthropic-ai/claude-code-fake/cli.js"; then
  fail "provenance strict admitted a near-miss package path - component exactness failed"
fi
if strict node "node /x/claude-code/@anthropic-ai/cli.js"; then
  fail "provenance strict admitted reversed path components"
fi
if strict node "node @anthropic-ai/claude-code/cli.js"; then
  fail "provenance strict admitted a bare relative script path (no leading component boundary)"
fi
if strict node "node --loader x.mjs /usr/lib/@anthropic-ai/claude-code/cli.js"; then
  fail "provenance strict admitted a flags-before-script shape - unsupported shapes must refuse"
fi
if strict node "node"; then
  fail "provenance strict admitted a bare interpreter with no script argument"
fi
if strict codex "codex --model x"; then
  fail "provenance strict admitted codex"
fi
pass "provenance strict: REFUSE - near-miss, reversed, relative, flag-shifted, and argument-less shapes"

# The shared matcher must be UNTOUCHED by round 3: the loose substring still
# sets the flag, which is what keeps the ancestry walk's reach unchanged. A
# mutant that narrowed the shared matcher instead of the provenance consumer
# breaks this test - that mutant is review-1's original defect.
flag=$(matcher_claude_flag node "node /opt/claude-tools/codex.js")
[ "$flag" = 1 ] \
  || fail "shared matcher narrowed: FM_HARNESS_IS_CLAUDE=$flag for a claude-substring path; the ancestry walk's reach changed"
pass "shared matcher unchanged: walk reach preserved while provenance narrowed"
