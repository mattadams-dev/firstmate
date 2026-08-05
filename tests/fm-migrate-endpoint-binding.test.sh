#!/usr/bin/env bash
# tests/fm-migrate-endpoint-binding.test.sh - behavior tests for the
# `endpoint_task_id=` binding migration (bin/fm-migrate-endpoint-binding.sh),
# driven through a fake herdr CLI that serves canned inventory by CONTENT
# (workspace/tab/pane fixtures) rather than by call order, so a case can model
# a specific live-world shape instead of a specific call sequence.
#
# The migration is retained as the documented recovery procedure for a future
# legacy lane, so these tests are permanent: they are what keeps the next
# re-runner's guards honest. The recorded run in
# docs/verification/endpoint-binding-migration.md is the evidence of the one
# time it was applied, not a substitute for them.
#
# Every case runs in a subshell and reports independently, because `fail`
# exits. That is what lets the mutation harness see which cases a given
# mutation flips, rather than only the first one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-migrate-endpoint-binding)
MIGRATE="${FM_MIGRATE_BIN:-$ROOT/bin/fm-migrate-endpoint-binding.sh}"

# --- fake herdr -------------------------------------------------------------

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
FIX="${FM_FAKE_HERDR_FIX:?}"
[ "${1:-}" = --version ] && { echo "herdr 9.9.9-fake"; exit 0; }
[ "${1:-}" = status ] && { echo '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}'; exit 0; }
# A hook for making the receipt unwritable MID-RUN, after the start line was
# written and before the first per-record outcome. Replacing the file with a
# directory is deterministic and cannot be bypassed by uid, unlike a mode
# change, so the case tests the same thing when the suite runs as root.
if [ -n "${FM_FAKE_HERDR_BREAK_RECEIPT:-}" ]; then
  rm -rf "$FM_FAKE_HERDR_BREAK_RECEIPT"
  mkdir -p "$FM_FAKE_HERDR_BREAK_RECEIPT"
fi
ws=
prev=
for a in "$@"; do
  [ "$prev" = --workspace ] && ws=$a
  prev=$a
done
case "${1:-} ${2:-}" in
  "workspace list") f="$FIX/workspaces.json" ;;
  "tab list")       f="$FIX/tabs-$ws.json" ;;
  "pane list")      f="$FIX/panes-$ws.json" ;;
  *) exit 1 ;;
esac
[ -f "$f" ] || exit 1
cat "$f"
# A call that emits a WELL-FORMED body and then fails - a truncated or timed-out
# read, and the shape real herdr 0.7.1 uses for a business-logic refusal. The
# body alone looks authoritative here, so only the call's exit status tells the
# two worlds apart.
[ -z "${FM_FAKE_HERDR_FAIL_AFTER_OUTPUT:-}" ] || exit 1
exit 0
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

# --- scenario builder -------------------------------------------------------
#
# new_home <name>: an FM_HOME with state/ and an empty fixture dir. Echoes the
# home path; the fixture dir is "<home>/fix".
new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/fix"
  printf '%s' "$h"
}

# workspaces <home> <label> <ws-id>...: this home's live workspace list.
workspaces() {
  local h=$1 label=$2
  shift 2
  local first=1 out='{"result":{"type":"workspace_list","workspaces":['
  for w in "$@"; do
    [ $first -eq 1 ] || out+=','
    first=0
    out+="{\"workspace_id\":\"$w\",\"label\":\"$label\"}"
  done
  printf '%s]}}\n' "$out" > "$h/fix/workspaces.json"
}

# tabs <home> <ws> <tab-id>:<label>...
tabs() {
  local h=$1 ws=$2
  shift 2
  local first=1 out='{"result":{"type":"tab_list","tabs":['
  for t in "$@"; do
    [ $first -eq 1 ] || out+=','
    first=0
    out+="{\"tab_id\":\"${t%%:label=*}\",\"label\":\"${t#*:label=}\",\"workspace_id\":\"$ws\"}"
  done
  printf '%s]}}\n' "$out" > "$h/fix/tabs-$ws.json"
}

# panes <home> <ws> <pane-id>@<tab-id>...
panes() {
  local h=$1 ws=$2
  shift 2
  local first=1 out='{"result":{"type":"pane_list","panes":['
  for p in "$@"; do
    [ $first -eq 1 ] || out+=','
    first=0
    out+="{\"pane_id\":\"${p%@*}\",\"tab_id\":\"${p#*@}\",\"workspace_id\":\"$ws\",\"foreground_cwd\":\"/wt/${p%@*}\"}"
  done
  printf '%s]}}\n' "$out" > "$h/fix/panes-$ws.json"
}

# raw_fixture <home> <basename> <json>: serve a body of our own choosing for one
# inventory call, so a case can model a WELL-FORMED response that is not the
# shape this migration expects - an error object, or a renamed field after a
# protocol bump. The builders above can only produce the expected shape.
raw_fixture() {
  printf '%s\n' "$3" > "$1/fix/$2.json"
}

# herdr_meta <home> <id> <session> <ws> <tab> <pane> [extra-line...]
# A pre-field record: window= present, endpoint_task_id= absent.
herdr_meta() {
  local h=$1 id=$2 s=$3 ws=$4 tab=$5 pane=$6
  shift 6
  {
    echo "window=$s:$pane"
    echo "worktree=/wt/$id"
    echo "project=/proj/$id"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=herdr"
    echo "herdr_session=$s"
    echo "herdr_workspace_id=$ws"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
    for extra in "$@"; do echo "$extra"; done
  } > "$h/state/$id.meta"
}

run_migrate() {  # <home> [--apply]
  local h=$1
  shift
  FM_HOME="$h" FM_FAKE_HERDR_FIX="$h/fix" "$MIGRATE" "$@" 2>&1
}

# --- cases ------------------------------------------------------------------
#
# Each case is a function; run_cases executes each in a subshell.

# The positive direction: a binding herdr genuinely reports still migrates.
case_observable_binding_migrates() {
  local h; h=$(new_home observable)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"MIGRATED"$'\t'"alpha"*) ;; *) fail "observable binding did not migrate: $out" ;; esac
  assert_grep 'endpoint_task_id=alpha' "$h/state/alpha.meta" "value not written"
  assert_grep 'endpoint_task_id_provenance=migrated' "$h/state/alpha.meta" "provenance not written"
  assert_grep 'label=fm-alpha' "$h/state/alpha.meta" "provenance omits the observed label"
  [ "$(grep -c '^endpoint_task_id=' "$h/state/alpha.meta")" -eq 1 ] \
    || fail "binding must appear exactly once"
}

# The core anti-assertion guard: the value comes from the live label, so a live
# endpoint belonging to a DIFFERENT task must never populate this record.
case_label_names_other_task_refused() {
  local h; h=$(new_home otherlabel)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-somebody-else"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"belongs to task somebody-else"*) ;;
    *) fail "a foreign task label was not refused: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding for a foreign label"
}

# A record whose endpoint is simply gone is a disposition item, never a guess.
case_absent_endpoint_refused() {
  local h; h=$(new_home gone)
  workspaces "$h" firstmate wB
  tabs "$h" wB
  panes "$h" wB
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"no live tab"*) ;;
    *) fail "a vanished endpoint was not reported: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding for a vanished endpoint"
}

# The recorded pane must be the pane herdr currently reports for that tab.
case_pane_mismatch_refused() {
  local h; h=$(new_home panemismatch)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:pZZ@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"not the recorded"*) ;;
    *) fail "a moved pane was not refused: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding for a moved pane"
}

# A workspace that is not one of THIS home's live workspaces must not qualify,
# even when it holds a tab with exactly the right label - the cross-home case.
case_foreign_workspace_refused() {
  local h; h=$(new_home foreignws)
  workspaces "$h" firstmate wB
  tabs "$h" wB
  panes "$h" wB
  tabs "$h" wOTHER "wOTHER:t19:label=fm-alpha"
  panes "$h" wOTHER "wOTHER:p19@wOTHER:t19"
  herdr_meta "$h" alpha 1 wOTHER wOTHER:t19 wOTHER:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"not a live workspace of this home"*) ;;
    *) fail "another home's workspace was not refused: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding from a foreign workspace"
}

# Ambiguity is refused, not resolved by preference.
case_ambiguous_pane_refused() {
  local h; h=$(new_home ambiguous)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19" "wB:p1A@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"more than one pane"*) ;;
    *) fail "an ambiguous tab was not refused: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding for an ambiguous tab"
}

# write_binding replaces the record through a mktemp file, which is created 0600.
# The record's own mode has to be carried onto the replacement, or one --apply
# silently narrows every migrated record's permissions - a change to the record
# that no outcome line would ever mention. Asserted on the bytes of the mode,
# and on state/ holding no leftover temp file afterwards.
case_migrated_record_keeps_its_mode() {
  local h; h=$(new_home recordmode)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19
  chmod 640 "$h/state/alpha.meta"

  run_migrate "$h" --apply >/dev/null

  local mode
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$h/state/alpha.meta")
  else
    mode=$(stat -c %a "$h/state/alpha.meta")
  fi
  [ "$mode" = 640 ] || fail "the migrated record's mode became $mode, expected the 640 it was created with"

  local residue
  residue=$(find "$h/state" -name '*.migrate.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$residue" -eq 0 ] || fail "$residue temp file(s) left behind in state/"
}

# The default run observes and reports but must not touch a record.
case_dry_run_writes_nothing() {
  local h; h=$(new_home dryrun)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19
  local before; before=$(cat "$h/state/alpha.meta")

  local out; out=$(run_migrate "$h")
  case "$out" in *"WOULD-MIGRATE"$'\t'"alpha"*) ;; *) fail "dry run did not report: $out" ;; esac
  [ "$(cat "$h/state/alpha.meta")" = "$before" ] || fail "dry run modified the record"
}

# A record that already carries the field is not a candidate and is left alone,
# so this can never overwrite an originally-observed binding. It is still
# ACCOUNTED for: every record the glob matches gets exactly one outcome line, so
# a reader of the receipt cannot confuse a skipped record with one that never
# existed. Accounted, but not a disposition - there is nothing to decide.
case_existing_binding_untouched() {
  local h; h=$(new_home existing)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha"
  local before; before=$(cat "$h/state/alpha.meta")

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"MIGRATED"$'\t'"alpha"*) fail "an already-bound record was treated as a candidate: $out" ;; esac
  case "$out" in *"DISPOSITION"$'\t'"alpha"*) fail "an already-bound record became a disposition item: $out" ;; esac
  case "$out" in *"NOT-REQUIRED"$'\t'"alpha"*"already carries endpoint_task_id=alpha"*) ;;
    *) fail "an already-bound record was not accounted for: $out" ;; esac
  [ "$(cat "$h/state/alpha.meta")" = "$before" ] || fail "an already-bound record was modified"
  assert_no_grep 'endpoint_task_id_provenance' "$h/state/alpha.meta" \
    "a spawn-written binding must not gain migration provenance"
}

# --- the validator's other three refusal shapes -----------------------------
#
# The validator refuses an opaque-backend record whose endpoint_task_id= is
# absent, empty, ambiguous, or unequal to the task id. Only absence is
# repairable here; the other three must still be REPORTED, because a silent
# skip is exactly the class rider 3 exists to eliminate.
#
# The empty and duplicated fixtures below are synthetic on purpose: zero real
# specimens existed in the migrated home, and a refusal shape without a fixture
# proving it fires is how this hole survived review the first time.

case_empty_binding_reported_not_skipped() {
  local h; h=$(new_home emptybinding)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id="
  cp "$h/state/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"empty endpoint task binding"*) ;;
    *) fail "an empty binding was skipped instead of reported: $out" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "an empty-binding record was modified; this migration never rewrites a binding"
}

case_duplicated_binding_reported_not_skipped() {
  local h; h=$(new_home dupbinding)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha" "endpoint_task_id=alpha"
  cp "$h/state/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"ambiguous endpoint task binding"*) ;;
    *) fail "a duplicated binding was skipped instead of reported: $out" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "a duplicated-binding record was modified; this migration never rewrites a binding"
}

case_mismatched_binding_reported_not_skipped() {
  local h; h=$(new_home mismatchbinding)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=beta"
  cp "$h/state/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"belongs to task beta, not alpha"*) ;;
    *) fail "a mismatched binding was skipped instead of reported: $out" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "a mismatched-binding record was modified; this migration never rewrites a binding"
}

# The other direction: reporting the three broken shapes must not have turned
# every already-bound record into a disposition item. A correctly bound record
# is simply not a candidate, while an unbound sibling in the same home still
# migrates.
case_valid_binding_is_not_a_disposition() {
  local h; h=$(new_home validbinding)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha" "wB:t1A:label=fm-beta"
  panes "$h" wB "wB:p19@wB:t19" "wB:p1A@wB:t1A"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha"
  herdr_meta "$h" beta 1 wB wB:t1A wB:p1A

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*)
    fail "a correctly bound record became a disposition item: $out" ;; esac
  case "$out" in *"MIGRATED"$'\t'"beta"*) ;;
    *) fail "the unbound sibling did not migrate: $out" ;; esac
  case "$out" in *"disposition=0"*) ;;
    *) fail "expected no disposition items in this home: $out" ;; esac
}

# --- every record is accounted for ------------------------------------------
#
# The receipt is THE record of a run, so it must account for every file the
# state/*.meta glob matches. A record skipped without a line is indistinguishable
# from a record that never existed, which is a record-shaped object that lies by
# omission. Each shape below owns its own case, so a mutation that lets one of
# them vanish breaks the case that owns it rather than a neighbour's.

# No window= line: nothing names an endpoint, so there is no binding to describe.
case_windowless_record_reported_not_skipped() {
  local h; h=$(new_home windowless)
  workspaces "$h" firstmate wB
  {
    echo "worktree=/wt/alpha"
    echo "project=/proj/alpha"
    echo "backend=herdr"
  } > "$h/state/alpha.meta"
  cp "$h/state/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"no window= line"*) ;;
    *) fail "a windowless record was skipped in silence: $out" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" || fail "a windowless record was modified"
}

# A record that could not be read is reported as exactly that. It is never
# described as having or lacking a field, because that was not observed.
case_unreadable_record_reported_not_skipped() {
  local h; h=$(new_home unreadable)
  workspaces "$h" firstmate wB
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19
  chmod 000 "$h/state/alpha.meta"
  if [ -r "$h/state/alpha.meta" ]; then
    # Running as a uid that ignores the mode. Use a shape no uid can read as a
    # record instead, so this case exercises the same branch either way.
    rm -f "$h/state/alpha.meta"
    mkdir "$h/state/alpha.meta"
  fi

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"could not be read"*) ;;
    *) fail "an unreadable record was skipped in silence: $out" ;; esac
  case "$out" in *"no window= line"*) fail "an unreadable record was described as lacking a field: $out" ;; esac
}

# A dangling symlink exists as an entry but not as a record. The -e test alone
# dropped these entirely, so the reader saw nothing at all.
case_dangling_symlink_reported_not_skipped() {
  local h; h=$(new_home dangling)
  workspaces "$h" firstmate wB
  ln -s "$h/state/nowhere.meta" "$h/state/alpha.meta"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"target does not exist"*) ;;
    *) fail "a dangling symlink was skipped in silence: $out" ;; esac
  [ -L "$h/state/alpha.meta" ] || fail "the dangling symlink was replaced"
}

# A symlinked record must never be written. write_binding's mv replaces the LINK
# with a regular file, and fm_backend_validate_task_endpoint refuses a symlinked
# record outright - so one --apply would convert a record teardown REFUSES into
# one teardown ACCEPTS, on content imported from outside state/.
case_symlinked_record_refused_and_stays_a_symlink() {
  local h; h=$(new_home symlinked)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  mkdir -p "$h/outside"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19
  mv "$h/state/alpha.meta" "$h/outside/alpha.meta"
  ln -s "$h/outside/alpha.meta" "$h/state/alpha.meta"
  cp "$h/outside/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"is a symlink"*) ;;
    *) fail "a symlinked record was not refused: $out" ;; esac
  [ -L "$h/state/alpha.meta" ] || fail "the symlinked record was laundered into a regular file"
  cmp -s "$h/alpha.before" "$h/outside/alpha.meta" \
    || fail "the symlink target was modified"

  # The record teardown refused before must still be refused after.
  local rc
  bash -c '
    set -u
    FM_HOME='"$h"'
    . '"$ROOT"'/bin/fm-backend.sh >/dev/null 2>&1
    fm_backend_validate_task_endpoint "'"$h"'/state/alpha.meta" alpha
  ' >/dev/null 2>&1
  rc=$?
  [ $rc -ne 0 ] || fail "the validator now accepts a record it refused before the migration ran"
}

# A record whose last line is unterminated is already malformed. Appending would
# run the binding onto that partial line, corrupting the preceding key AND
# leaving endpoint_task_id= matching zero lines - so the record would stay a
# candidate and every later run would append again. That is the one way the
# structural idempotence claim can fail, so the record is refused instead.
case_unterminated_record_refused() {
  local h; h=$(new_home unterminated)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19
  printf 'traceparent=00-abc' >> "$h/state/alpha.meta"
  cp "$h/state/alpha.meta" "$h/alpha.before"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"no terminating newline"*) ;;
    *) fail "an unterminated record was not refused: $out" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "an unterminated record was modified"
  assert_no_grep 'traceparendpoint_task_id' "$h/state/alpha.meta" \
    "the binding was concatenated onto a partial line"
}

# The other direction of the accounting rule. Reporting the shapes above must
# not degenerate into calling every record a disposition item: a healthy,
# observable record still produces its normal outcome and nothing else.
case_healthy_record_is_never_a_disposition() {
  local h; h=$(new_home healthy)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"MIGRATED"$'\t'"alpha"*) ;;
    *) fail "a healthy record did not produce its normal outcome: $out" ;; esac
  case "$out" in *DISPOSITION*) fail "a healthy record was reported as a disposition item: $out" ;; esac
  case "$out" in *"disposition=0"*) ;;
    *) fail "expected no disposition items for a healthy record: $out" ;; esac
}

# --- unknown is not absent --------------------------------------------------
#
# "the endpoint is gone" and "the backend could not be queried" are different
# worlds. fm_backend_herdr_workspace_find_all returns 0 with EMPTY output when
# the query fails, so an unreachable herdr used to be reported as a definite
# absence - into stdout and into the durable receipt.
case_unreachable_backend_is_unknown_not_absent() {
  local h; h=$(new_home unreachable)
  # No workspaces.json fixture: the fake herdr exits non-zero for `workspace
  # list`, which is what a stopped server, an uninstalled herdr, or a jq
  # failure look like from here.
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*UNKNOWN*) ;;
    *) fail "an unreachable backend was not reported as unknown: $out" ;; esac
  case "$out" in *"is not a live workspace"*)
    fail "an unreachable backend was reported as a definite absence: $out" ;; esac
  assert_no_grep 'is not a live workspace' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt records an absence claim for an unobservable world"
  assert_grep 'UNKNOWN' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt does not carry the unknown/absent distinction"
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding without a live read"
}

# The second unobservable world, which the case above cannot reach: the call
# SUCCEEDS and returns a well-formed body that is not the expected shape - an
# `{"error":{...}}` response, or a renamed field after a protocol bump.
# `.result.workspaces[]?` yields empty output and exit 0 for all of them, so a
# status-only check reads "not understood" as "looked, and it was not there".
# Asserted on the durable receipt as well as stdout, because the receipt is
# where a sharpened guess outlives the run that made it.
case_unexpected_workspace_body_is_unknown_not_absent() {
  local h; h=$(new_home unexpectedws)
  raw_fixture "$h" workspaces '{"error":{"code":"session_not_found","message":"no such session"}}'
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*UNKNOWN*) ;;
    *) fail "an unrecognised workspace list body was not reported as unknown: $out" ;; esac
  case "$out" in *"is not a live workspace"*)
    fail "an unrecognised workspace list body was reported as a definite absence: $out" ;; esac
  assert_no_grep 'is not a live workspace' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt records an absence claim for a body it did not understand"
  assert_grep 'UNKNOWN' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt does not carry the unknown/absent distinction"
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding from a body it did not understand"
}

# The same world one level down: the workspace read succeeds and the TAB list
# comes back well-formed but unrecognised. `.result.tabs[]?` is empty for it, and
# an empty tab list otherwise means the endpoint is genuinely gone.
case_unexpected_tab_body_is_unknown_not_absent() {
  local h; h=$(new_home unexpectedtabs)
  workspaces "$h" firstmate wB
  raw_fixture "$h" tabs-wB '{"result":{"type":"tab_list","windows":[]}}'
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*UNKNOWN*) ;;
    *) fail "an unrecognised tab list body was not reported as unknown: $out" ;; esac
  case "$out" in *"no live tab"*)
    fail "an unrecognised tab list body was reported as a definite absence: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding from a body it did not understand"
}

# And once more at the pane read, the last of the three live reads. An empty
# `.result.panes[]?` otherwise means the tab genuinely holds no pane.
case_unexpected_pane_body_is_unknown_not_absent() {
  local h; h=$(new_home unexpectedpanes)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  raw_fixture "$h" panes-wB '{"result":{"type":"pane_list","terminals":[]}}'
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*UNKNOWN*) ;;
    *) fail "an unrecognised pane list body was not reported as unknown: $out" ;; esac
  case "$out" in *"has no pane"*)
    fail "an unrecognised pane list body was reported as a definite absence: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding from a body it did not understand"
}

# The third unobservable world, and the one the SHAPE check cannot reach: the
# call emits a perfectly well-formed list and THEN fails. The body looks
# authoritative, so reading it would report the recorded workspace as absent on
# the strength of a list the backend never finished standing behind. Only the
# call's own exit status tells that world from a complete answer.
case_failed_call_with_wellformed_body_is_unknown_not_absent() {
  local h; h=$(new_home failedcallbody)
  workspaces "$h" firstmate wOTHER
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out
  out=$(FM_HOME="$h" FM_FAKE_HERDR_FIX="$h/fix" FM_FAKE_HERDR_FAIL_AFTER_OUTPUT=1 \
    "$MIGRATE" --apply 2>&1)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*UNKNOWN*) ;;
    *) fail "a failed call carrying a well-formed body was not reported as unknown: $out" ;; esac
  case "$out" in *"is not a live workspace"*)
    fail "the body of a failed call was read as a definite absence: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding from the body of a failed call"
}

# The two live reads AFTER the workspace read must carry the same UNKNOWN marker
# their sibling parse failures do. A herdr that dies between the workspace read
# and the tab read is the most likely mid-run backend loss, and a receipt that
# records it without the marker files it with the ordinary refusals.
case_tab_list_failure_is_unknown_not_absent() {
  local h; h=$(new_home tabcallfails)
  workspaces "$h" firstmate wB
  # No tabs-wB.json fixture: the fake herdr exits non-zero for `tab list`.
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"could not list live tabs"*UNKNOWN*) ;;
    *) fail "a failed tab list did not carry the unknown/absent distinction: $out" ;; esac
  assert_grep 'UNKNOWN' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt does not carry the unknown/absent distinction for a failed tab list"
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding without a live tab read"
}

case_pane_list_failure_is_unknown_not_absent() {
  local h; h=$(new_home panecallfails)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  # No panes-wB.json fixture: the fake herdr exits non-zero for `pane list`.
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"could not list live panes"*UNKNOWN*) ;;
    *) fail "a failed pane list did not carry the unknown/absent distinction: $out" ;; esac
  assert_grep 'UNKNOWN' "$h/data/endpoint-binding-migration-receipts.log" \
    "the durable receipt does not carry the unknown/absent distinction for a failed pane list"
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding without a live pane read"
}

# --- the cross-home workspace boundary --------------------------------------
#
# The workspace check is the only thing standing between this migration and
# another home's endpoint, and it is the only comparison here made by grep rather
# than by `=`. A recorded id carrying a regex metacharacter must not match a
# DIFFERENT live id of the same length, which a non-fixed-string match allows.
case_workspace_metacharacter_refused() {
  local h; h=$(new_home wsmetachar)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 'w.' wB:t19 wB:p19

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"not a live workspace of this home"*) ;;
    *) fail "a metacharacter-bearing workspace id matched a different live workspace: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" \
    "wrote a binding for a workspace id that only matched as a pattern"
}

# --- --help ------------------------------------------------------------------
#
# --help prints the file's own header, which is the surface a previous review
# round caught printing a claim that had gone stale. The range is derived rather
# than pinned, so this asserts what derivation has to get right in both
# directions: the whole header reaches the reader, and no shell source follows it.
case_help_prints_the_whole_header_and_no_source() {
  local out rc
  out=$("$MIGRATE" --help 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--help exited $rc"
  case "$out" in *"REPEATABLE repair"*) ;;
    *) fail "--help did not print the start of the header: $out" ;; esac
  case "$out" in *"disposition item is a reported outcome, not a failure of this script."*) ;;
    *) fail "--help truncated the header before its last line: $out" ;; esac
  case "$out" in *"set -uo pipefail"*|*"FM_ROOT="*)
    fail "--help leaked shell source past the end of the header: $out" ;; esac
}

# --- the one-shot guard -----------------------------------------------------
#
# partial_run_home <name>: the shape an interrupted --apply leaves behind - one
# already-migrated record (provenance present) and one record the run never
# reached, still unbound.
partial_run_home() {
  local h; h=$(new_home "$1")
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha" "wB:t1A:label=fm-beta"
  panes "$h" wB "wB:p19@wB:t19" "wB:p1A@wB:t1A"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha" \
    "endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list"
  herdr_meta "$h" beta 1 wB wB:t1A wB:p1A
  cp "$h/state/alpha.meta" "$h/alpha.before"
  cp "$h/state/beta.meta" "$h/beta.before"
  printf '%s' "$h"
}

# already_migrated_home <name>: every candidate already carries its binding and
# provenance, so a further run has nothing legitimate left to write.
already_migrated_home() {
  local h; h=$(new_home "$1")
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha" \
    "endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list"
  cp "$h/state/alpha.meta" "$h/alpha.before"
  printf '%s' "$h"
}

# IDEMPOTENCE, the property that replaced the deleted one-shot guard.
#
# A repeated --apply must not corrupt or double-write what an earlier run wrote.
# This is now the only thing protecting that, so it is asserted on the bytes:
# the record is identical after the second run, and carries exactly one binding
# and one provenance line rather than a second pair appended.
case_repeated_apply_is_idempotent() {
  local h; h=$(new_home repeatapply)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  run_migrate "$h" --apply >/dev/null
  cp "$h/state/alpha.meta" "$h/alpha.after-first"

  local out rc
  out=$(run_migrate "$h" --apply)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the second --apply failed: $out"

  cmp -s "$h/alpha.after-first" "$h/state/alpha.meta" \
    || fail "the second --apply changed a record the first run had migrated"

  local bindings provenances
  bindings=$(grep -c '^endpoint_task_id=' "$h/state/alpha.meta")
  provenances=$(grep -c '^endpoint_task_id_provenance=' "$h/state/alpha.meta")
  [ "$bindings" -eq 1 ] \
    || fail "record carries $bindings endpoint_task_id lines after two runs, expected 1"
  [ "$provenances" -eq 1 ] \
    || fail "record carries $provenances provenance lines after two runs, expected 1"
}

# The mirror direction. Idempotence means SAFE TO REPEAT, not clever about
# refusing: a second run must actually run. This is the regression test against
# reintroducing one-shot behaviour under any other name.
case_repeated_apply_is_not_refused() {
  local h; h=$(already_migrated_home repeatnotrefused)

  local err rc
  err=$(FM_HOME="$h" FM_FAKE_HERDR_FIX="$h/fix" "$MIGRATE" --apply 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--apply was refused on an already-migrated home; one-shot behaviour is back: $err"
  case "$err" in *REFUSED*) fail "--apply printed a refusal on an already-migrated home: $err" ;; esac
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "the repeated run modified an already-migrated record"
}

# An interrupted run simply resumes: records already written are skipped,
# records never reached are repaired. No stranded state, no hand-write remedy.
case_interrupted_run_resumes() {
  local h; h=$(partial_run_home resumepartial)

  local out rc
  out=$(run_migrate "$h" --apply)
  rc=$?
  [ "$rc" -eq 0 ] || fail "--apply failed after a partial run, stranding the unbound record: $out"
  case "$out" in *"MIGRATED"$'\t'"beta"*) ;;
    *) fail "the record an interrupted run never reached did not migrate: $out" ;; esac
  assert_grep 'endpoint_task_id=beta' "$h/state/beta.meta" "resumed run did not write the binding"
  cmp -s "$h/alpha.before" "$h/state/alpha.meta" \
    || fail "resumed run modified an already-migrated record"
}

# THE RECEIPT. An unrecorded run is the state this design exists to make
# impossible, so both modes must leave one, and it must carry the outcome rather
# than merely noting that something happened.
case_receipt_written_for_apply_run() {
  local h; h=$(new_home receiptapply)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  run_migrate "$h" --apply >/dev/null

  local r="$h/data/endpoint-binding-migration-receipts.log"
  [ -f "$r" ] || fail "no receipt was written for an --apply run"
  assert_grep 'mode=apply' "$r" "receipt does not record the mode"
  assert_grep "home=$h" "$r" "receipt does not record which home ran"
  assert_grep "MIGRATED"$'\t'"alpha" "$r" "receipt does not record the per-record outcome"
  assert_grep 'run	end=' "$r" "receipt has no end line for a completed run"
}

case_receipt_written_for_observe_run() {
  local h; h=$(already_migrated_home receiptobserve)

  run_migrate "$h" >/dev/null

  local r="$h/data/endpoint-binding-migration-receipts.log"
  [ -f "$r" ] || fail "no receipt was written for an observe-only run"
  assert_grep 'mode=observe' "$r" "receipt does not record observe mode"
  assert_grep 'run	end=' "$r" "receipt has no end line for a completed observe run"
}

# Two runs must leave two receipts. A receipt that overwrote the previous one
# would lose exactly the history the deleted guard used to infer.
case_receipt_accumulates_across_runs() {
  local h; h=$(already_migrated_home receiptaccum)

  run_migrate "$h" >/dev/null
  run_migrate "$h" >/dev/null

  local r="$h/data/endpoint-binding-migration-receipts.log"
  local starts
  starts=$(grep -c '^run	start=' "$r")
  [ "$starts" -eq 2 ] || fail "expected 2 recorded runs in the receipt, found $starts"
}

# A receipt that stops being writable MID-RUN must stop the run, loudly and
# non-zero. Continuing would leave a partial account of a run that reported
# success - the second and divergent account the receipt exists to prevent, and
# the opposite of this script's own "a run that cannot write its receipt does
# not run". The fake herdr replaces the receipt with a directory on its first
# inventory call, which is after the start line and before the first outcome.
case_receipt_failure_mid_run_is_not_silent() {
  local h; h=$(new_home receiptbreak)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out rc
  out=$(FM_HOME="$h" FM_FAKE_HERDR_FIX="$h/fix" \
    FM_FAKE_HERDR_BREAK_RECEIPT="$h/data/endpoint-binding-migration-receipts.log" \
    "$MIGRATE" --apply 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run that lost its receipt mid-run still reported success: $out"
  case "$out" in *REFUSED*receipt*) ;;
    *) fail "a lost receipt was not reported loudly: $out" ;; esac
  case "$out" in *"summary observed="*)
    fail "the run continued past a failed receipt write: $out" ;; esac
}

# Observe mode on a partially migrated home still reports the record an
# interrupted run never reached. Kept separate from the case above because that
# one owns the refusal state, where nothing is left to report.
case_observe_reports_unbound_record_on_partial_home() {
  local h; h=$(partial_run_home partialobserve)

  local out rc
  out=$(run_migrate "$h")
  rc=$?
  [ "$rc" -eq 0 ] || fail "observe-only mode failed on a partially migrated home: $out"
  case "$out" in *"WOULD-MIGRATE"$'\t'"beta"*) ;;
    *) fail "observe-only mode did not report the unbound record: $out" ;; esac
  cmp -s "$h/beta.before" "$h/state/beta.meta" \
    || fail "observe-only mode modified a record"
}

# A legacy tmux record needs no field; it is reported, never silently passed.
case_tmux_reported_not_silent() {
  local h; h=$(new_home tmuxrec)
  workspaces "$h" firstmate wB
  {
    echo "window=main:fm-alpha"
    echo "worktree=/wt/alpha"
    echo "project=/proj/alpha"
  } > "$h/state/alpha.meta"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"NOT-REQUIRED"$'\t'"alpha"*) ;;
    *) fail "a tmux record was not reported as a disposition-visible outcome: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "tmux record should not gain the field"
}

# A backend with no observation path is refused explicitly, not assumed fine.
case_unobservable_backend_refused() {
  local h; h=$(new_home otherbackend)
  workspaces "$h" firstmate wB
  {
    echo "window=sess:1"
    echo "worktree=/wt/alpha"
    echo "project=/proj/alpha"
    echo "backend=zellij"
  } > "$h/state/alpha.meta"

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *"DISPOSITION"$'\t'"alpha"*"no observation path"*) ;;
    *) fail "an unobservable backend was not reported: $out" ;; esac
  assert_no_grep 'endpoint_task_id=' "$h/state/alpha.meta" "wrote a binding for an unobservable backend"
}

# The migrated record must satisfy the real validator - teardown's own gate,
# not a restatement of it.
case_teardown_validator_accepts_migrated_record() {
  local h; h=$(new_home validator)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  run_migrate "$h" --apply >/dev/null

  local out rc
  out=$(FM_HOME="$h" bash -c '
    set -u
    FM_HOME='"$h"'
    . '"$ROOT"'/bin/fm-backend.sh >/dev/null 2>&1
    fm_backend_validate_task_endpoint "'"$h"'/state/alpha.meta" alpha
  ' 2>&1)
  rc=$?
  [ $rc -eq 0 ] || fail "teardown validator rejected the migrated record: $out"
}

# The same validator must still reject the record BEFORE migration, or the
# case above proves nothing.
case_teardown_validator_rejects_unmigrated_record() {
  local h; h=$(new_home validatorneg)
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19

  local out rc
  out=$(bash -c '
    set -u
    FM_HOME='"$h"'
    . '"$ROOT"'/bin/fm-backend.sh >/dev/null 2>&1
    fm_backend_validate_task_endpoint "'"$h"'/state/alpha.meta" alpha
  ' 2>&1)
  rc=$?
  [ $rc -ne 0 ] || fail "validator accepted an unmigrated record; the guard is not active"
  case "$out" in *"lacks an exact task binding"*) ;;
    *) fail "unexpected refusal reason: $out" ;; esac
}

# --- runner -----------------------------------------------------------------

CASES=$(declare -F | sed -n 's/^declare -f \(case_.*\)$/\1/p' | sort)
failed=0
for c in $CASES; do
  if out=$( "$c" 2>&1 ); then
    pass "${c#case_}"
  else
    printf 'not ok - %s\n' "${c#case_}"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  printf '\n%s case(s) failed\n' "$failed" >&2
  exit 1
fi
printf '\nall %s cases passed\n' "$(printf '%s\n' "$CASES" | wc -w | tr -d ' ')"
