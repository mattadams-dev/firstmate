#!/usr/bin/env bash
# tests/fm-migrate-endpoint-binding.test.sh - behavior tests for the one-shot
# `endpoint_task_id=` binding migration (bin/fm-migrate-endpoint-binding.sh),
# driven through a fake herdr CLI that serves canned inventory by CONTENT
# (workspace/tab/pane fixtures) rather than by call order, so a case can model
# a specific live-world shape instead of a specific call sequence.
#
# These tests, like the script they cover, are one-shot: they are deleted in
# the same change that retires the migration. Their durable product is the
# recorded run in docs/verification/endpoint-binding-migration.md, including
# the mutation experiment that shows each guard is load-bearing.
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
