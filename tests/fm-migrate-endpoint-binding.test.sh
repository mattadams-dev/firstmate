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
# so this can never overwrite an originally-observed binding.
case_existing_binding_untouched() {
  local h; h=$(new_home existing)
  workspaces "$h" firstmate wB
  tabs "$h" wB "wB:t19:label=fm-alpha"
  panes "$h" wB "wB:p19@wB:t19"
  herdr_meta "$h" alpha 1 wB wB:t19 wB:p19 "endpoint_task_id=alpha"
  local before; before=$(cat "$h/state/alpha.meta")

  local out; out=$(run_migrate "$h" --apply)
  case "$out" in *alpha*) fail "an already-bound record was treated as a candidate: $out" ;; esac
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
