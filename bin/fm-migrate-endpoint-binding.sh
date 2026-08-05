#!/usr/bin/env bash
# bin/fm-migrate-endpoint-binding.sh - REPEATABLE repair of
# `endpoint_task_id=` in a home's state/<id>.meta records.
#
# SAFE TO RUN AGAIN. There is no one-shot guard and no refusal to run twice.
# Re-running is harmless by construction, not by memory of a previous run, and
# every run writes a receipt. See SAFE TO REPEAT and THE RECEIPT below, and
# docs/verification/endpoint-binding-migration.md.
#
# WHY THE FIELD MATTERS
#
# fm_backend_validate_task_endpoint (bin/fm-backend.sh) refuses cleanup for a
# non-tmux record whose `endpoint_task_id=` is absent, empty, ambiguous, or
# unequal to the task id. Legacy tmux records are exempt: their window name is
# itself `<session>:fm-<id>`, so the binding is already encoded in the window.
# Records spawned before fm-spawn.sh began writing the field therefore strand
# only on the opaque backends (herdr, zellij, orca, cmux).
#
# WHAT "OBSERVED" MEANS HERE, AND WHY IT IS NOT A FORMALITY
#
# The validator requires `endpoint_task_id` to EQUAL the task id, so the value
# is not an opaque runtime handle to be discovered - it is fixed by the record's
# own name. That makes it trivially forgeable: anyone can write the filename
# into the file and satisfy the check while proving nothing. The protection is
# not the value, it is the claim the value stands for: "a live endpoint that
# belongs to this task was seen".
#
# So this migration does not copy the filename. It reads the live backend
# inventory, takes the task identity from the LABEL herdr reports for a live
# tab, and writes THAT. The filename is used only as a cross-check: if the
# observed label does not name the same task, the record is refused. A record
# whose endpoint is gone, moved, duplicated, or inconsistent with what is
# recorded is never written - it is emitted as a disposition item.
#
# Nothing here is derived from state/, from a prior snapshot, from the status
# log, or from another metadata file. Those records are what is being repaired;
# they cannot be their own evidence. The recorded endpoint fields are read only
# to state the expectation that the live read must then confirm.
#
# WHAT THIS REPAIRS, AND WHAT IT REFUSES TO REPAIR
#
# The validator refuses an opaque-backend record whose `endpoint_task_id=` is
# absent, empty, ambiguous (two or more lines), or unequal to the task id. Only
# ABSENT is repairable here: this migration APPENDS an observed binding to a
# record that has none, and never edits or removes an existing binding line. An
# empty, duplicated, or mismatched binding is a record whose existing content is
# already wrong, and repairing that is a different and riskier operation than
# the one this script is authorised to perform. Those three shapes are emitted
# as disposition items to be resolved by hand, never passed over in silence.
#
# PROVENANCE
#
# A migrated record gains a sibling `endpoint_task_id_provenance=` line
# alongside the value it describes. The metadata format is line-oriented
# `key=value` read exclusively through targeted `^key=` lookups
# (fm_meta_get, fm_backend_meta_exact_value), so a new key is inert to every
# existing reader, travels with the record it explains, and cannot drift away
# from it the way a sidecar file could. fm-spawn.sh never writes this key, so
# its presence means "migrated" and its absence means "recorded at spawn" -
# the distinction a reader needs six months from now.
#
# SAFE TO REPEAT
#
# There is no one-shot guard. Earlier versions refused a second `--apply` on an
# already-migrated home; three consecutive reviews found defects in that refusal,
# each one in the definition of which records it counted. The refusal was deleted
# rather than corrected a fourth time. An operation that is safe to repeat needs
# no memory of whether it already ran, and removing the consequence beats getting
# the trigger right.
#
# Repetition is harmless because of the per-record filter, not because of any
# home-level state. The only shape this script writes is a record with ZERO
# `endpoint_task_id=` lines. After a record is migrated it carries exactly one
# correct binding, so on any later run it is a non-candidate and is skipped
# untouched: no second binding, no second provenance line, no rewrite. The
# migrated bytes of an already-repaired record are identical after the second run
# and after the tenth.
#
# That also means an interrupted run simply resumes. Records already written are
# skipped, records not yet reached are repaired. There is no stranded state and
# no remedy that requires a hand-write.
#
# The anti-assertion guarantee is enforced by the same filter, unconditionally:
# the script only ever APPENDS a binding to a record that has none, and only from
# a live observation of that record's own endpoint. No path through this script
# writes an unobserved or asserted value, on any home, in any state.
#
# THE RECEIPT
#
# Every run appends a receipt to data/endpoint-binding-migration-receipts.log in
# the target home: when it ran, against which home, in which mode, with which
# tool versions, and the per-record outcome and totals. Observe-only runs are
# recorded too, because an observe run is still a run that happened.
#
# The receipt is the durable answer to "has this home been migrated, and what
# did the run do", which is the question the deleted guard was trying to answer
# from inferred state. Recording it at the source is what makes that question
# answerable without an instrument that has to distinguish two worlds it cannot
# see. The receipt is a record, never an authority: nothing in this script reads
# it back to decide whether to run or what to write.
#
# Usage:
#   bin/fm-migrate-endpoint-binding.sh [--apply]
#
#   (default)  observe and report only; writes no metadata
#   --apply    write observed bindings; refusals are still only reported
#
#   Both modes append a receipt. Running either mode twice is safe.
#
# Environment:
#   FM_HOME  home whose state/ is repaired (required; no default, so a
#            mistyped invocation cannot silently repair the wrong home)
#
# Exit: 0 when every candidate was either migrated or reported; 1 on a usage
# or environment error. A disposition item is a reported outcome, not a failure
# of this script.

set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,116p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $(basename "$0") [--apply]" >&2; exit 1 ;;
esac

[ -n "${FM_HOME:-}" ] || { echo "REFUSED: FM_HOME must be set explicitly." >&2; exit 1; }
STATE="$FM_HOME/state"
[ -d "$STATE" ] || { echo "REFUSED: no state directory at $STATE." >&2; exit 1; }

# No one-shot guard here, deliberately. Repetition is made harmless by the
# per-record filter further down, which writes only to a record with zero
# binding lines; see SAFE TO REPEAT in the header for why that is the whole
# protection and why the previous refusal was removed rather than corrected.

RECEIPTS="$FM_HOME/data/endpoint-binding-migration-receipts.log"

# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"

RUN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 || true)
MODE=observe
[ "$APPLY" -eq 1 ] && MODE=apply

migrated=0
refused=0
not_required=0

# The receipt is append-only and written AS THE RUN PROCEEDS, not summarised at
# the end. A run that dies halfway therefore leaves a start line with no end
# line, so a completed run and an interrupted one are distinguishable in the
# record instead of looking identical. Recording the event at its source is what
# makes "was this home migrated, and what happened" answerable later without an
# instrument that has to tell apart two worlds it cannot see.
#
# A run that cannot write its receipt does not run. An unrecorded run is the
# state this design exists to make impossible, so a receipt failure is refused
# up front rather than discovered afterwards.
receipt_append() {
  printf '%s\n' "$1" >> "$RECEIPTS"
}

receipt_open() {
  mkdir -p "$(dirname "$RECEIPTS")" || return 1
  receipt_append "$(printf 'run\tstart=%s\thome=%s\tmode=%s\tby=%s\ttool=%s' \
    "$RUN_AT" "$FM_HOME" "$MODE" "$(basename "${BASH_SOURCE[0]}")" "${HERDR_VERSION:-absent}")"
}

receipt_close() {
  receipt_append "$(printf 'run\tend=%s\tstart=%s\tmode=%s\tobserved=%s\tdisposition=%s\tnot_required=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_AT" "$MODE" "$migrated" "$refused" "$not_required")"
}

# outcome <line>: report one record's result on stdout and in the receipt. Both
# surfaces get the same text, so the receipt can never become a second and
# divergent account of what the run did.
outcome() {
  printf '%s\n' "$1"
  receipt_append "$1"
}

receipt_open || {
  echo "REFUSED: cannot write the run receipt at $RECEIPTS; refusing to run unrecorded." >&2
  exit 1
}

# meta_count <meta> <key>: number of lines for <key>.
meta_count() { grep -c "^$2=" "$1" 2>/dev/null || true; }

# meta_one <meta> <key>: the value when the key appears exactly once and is
# non-empty; otherwise fails. Same exactness rule the validator applies.
meta_one() {
  local n
  n=$(meta_count "$1" "$2")
  [ "$n" -eq 1 ] || return 1
  local v
  v=$(grep "^$2=" "$1" | cut -d= -f2-)
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# disposition <id> <reason>: emit an explicit item requiring a decision. A
# record that cannot be verified is never left to be inferred from silence.
disposition() {
  refused=$((refused + 1))
  outcome "$(printf 'DISPOSITION\t%s\t%s' "$1" "$2")"
}

# observe_herdr_binding <id> <meta>: the whole observation. Prints
# "<observed-id>\t<provenance-detail>" and returns 0 only when a single live
# tab in this home's live workspace carries the label for this task and every
# recorded endpoint coordinate matches what herdr currently reports. Prints a
# refusal reason and returns 1 otherwise.
observe_herdr_binding() {
  local id=$1 meta=$2
  local session workspace tab pane window
  session=$(meta_one "$meta" herdr_session) || { echo "recorded herdr_session is missing, empty, or ambiguous"; return 1; }
  workspace=$(meta_one "$meta" herdr_workspace_id) || { echo "recorded herdr_workspace_id is missing, empty, or ambiguous"; return 1; }
  tab=$(meta_one "$meta" herdr_tab_id) || { echo "recorded herdr_tab_id is missing, empty, or ambiguous"; return 1; }
  pane=$(meta_one "$meta" herdr_pane_id) || { echo "recorded herdr_pane_id is missing, empty, or ambiguous"; return 1; }
  window=$(meta_one "$meta" window) || { echo "recorded window is missing, empty, or ambiguous"; return 1; }

  fm_backend_source herdr >/dev/null 2>&1 || { echo "herdr adapter unavailable"; return 1; }

  # 1. The recorded workspace must currently be one of THIS home's workspaces.
  #    workspace_find_all resolves by this home's own label, so a workspace
  #    belonging to another home or to a stale label can never qualify.
  local live_workspaces
  live_workspaces=$(fm_backend_herdr_workspace_find_all "$session" 2>/dev/null) || live_workspaces=
  printf '%s\n' "$live_workspaces" | grep -qx -- "$workspace" || {
    echo "workspace $workspace is not a live workspace of this home in session $session"
    return 1
  }

  # 2. Exactly one live tab in that workspace must be labelled for a task, and
  #    the identity comes FROM that label. A duplicate label is ambiguous and
  #    is refused rather than resolved by preference.
  local tabs label_matches observed_label observed_tab
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || {
    echo "could not list live tabs in workspace $workspace of session $session"
    return 1
  }
  label_matches=$(printf '%s' "$tabs" | jq -r --arg t "$tab" \
    '.result.tabs[]? | select(.tab_id == $t) | "\(.label)\t\(.tab_id)"' 2>/dev/null)
  [ -n "$label_matches" ] || { echo "no live tab $tab in workspace $workspace of session $session"; return 1; }
  [ "$(printf '%s\n' "$label_matches" | wc -l)" -eq 1 ] || {
    echo "tab id $tab is ambiguous in workspace $workspace of session $session"
    return 1
  }
  IFS=$'\t' read -r observed_label observed_tab <<<"$label_matches"

  # 3. The task identity is the label with herdr's fm- prefix removed. This is
  #    the observed value; the filename never supplies it.
  case "$observed_label" in
    fm-?*) ;;
    *) echo "live tab $observed_tab is labelled '$observed_label', which does not name a task"; return 1 ;;
  esac
  local observed_id=${observed_label#fm-}

  # 4. Cross-check: the observation must be about the record being repaired.
  [ "$observed_id" = "$id" ] || {
    echo "live tab $observed_tab belongs to task $observed_id, not $id"
    return 1
  }

  # 5. Exactly one live pane must sit in that tab, and it must be the recorded
  #    pane, so the window endpoint cleanup will act on is the one observed.
  local panes pane_matches observed_pane
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || {
    echo "could not list live panes in workspace $workspace of session $session"
    return 1
  }
  pane_matches=$(printf '%s' "$panes" | jq -r --arg t "$observed_tab" \
    '.result.panes[]? | select(.tab_id == $t) | .pane_id' 2>/dev/null)
  [ -n "$pane_matches" ] || { echo "live tab $observed_tab has no pane"; return 1; }
  [ "$(printf '%s\n' "$pane_matches" | wc -l)" -eq 1 ] || {
    echo "live tab $observed_tab has more than one pane"
    return 1
  }
  observed_pane=$pane_matches
  [ "$observed_pane" = "$pane" ] || {
    echo "live tab $observed_tab holds pane $observed_pane, not the recorded $pane"
    return 1
  }
  [ "$window" = "$session:$observed_pane" ] || {
    echo "recorded window $window does not match the live endpoint $session:$observed_pane"
    return 1
  }

  # Corroborating detail, recorded but deliberately NOT gated on: a live agent
  # can change directory, so a mismatch here is not evidence the binding is
  # wrong, and gating on it would manufacture false refusals.
  local fg
  fg=$(printf '%s' "$panes" | jq -r --arg p "$observed_pane" \
    '.result.panes[]? | select(.pane_id == $p) | .foreground_cwd // ""' 2>/dev/null | head -1)

  printf '%s\t%s\n' "$observed_id" \
    "source=herdr-live-tab-and-pane-list session=$session workspace=$workspace tab=$observed_tab pane=$observed_pane label=$observed_label foreground_cwd=${fg:-unknown} tool=${HERDR_VERSION:-unknown}"
}

# write_binding <meta> <observed-id> <detail>: append the observed value and
# its provenance atomically, preserving the file's mode. Never rewrites an
# existing binding - this repairs absence only.
write_binding() {
  local meta=$1 observed_id=$2 detail=$3 tmp
  tmp=$(mktemp "$meta.migrate.XXXXXX") || return 1
  cat "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'endpoint_task_id=%s\n' "$observed_id"
    printf 'endpoint_task_id_provenance=migrated observed_at=%s by=%s %s\n' \
      "$RUN_AT" "$(basename "${BASH_SOURCE[0]}")" "$detail"
  } >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$meta" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$meta"
}

printf '# fm-migrate-endpoint-binding run\n'
printf 'run_at=%s\napply=%s\nfm_home=%s\nherdr=%s\n\n' \
  "$RUN_AT" "$APPLY" "$FM_HOME" "${HERDR_VERSION:-absent}"

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)

  [ "$(meta_count "$meta" window)" -ge 1 ] || continue

  # Binding shape decides candidacy. Absence is the only shape this migration
  # can repair, because it appends an observed binding and never rewrites one.
  # The validator's three other refusal shapes are reported rather than passed
  # over in silence.
  binding_lines=$(meta_count "$meta" endpoint_task_id)
  if [ "$binding_lines" -gt 1 ]; then
    disposition "$id" "$binding_lines endpoint_task_id= lines, which the validator refuses as an ambiguous endpoint task binding; resolve by hand, this migration writes a binding, it never rewrites one"
    continue
  fi
  if [ "$binding_lines" -eq 1 ]; then
    if ! recorded_binding=$(meta_one "$meta" endpoint_task_id); then
      disposition "$id" "endpoint_task_id= is present but has no value, which the validator refuses as an empty endpoint task binding; resolve by hand, this migration writes a binding, it never rewrites one"
      continue
    fi
    if [ "$recorded_binding" != "$id" ]; then
      disposition "$id" "endpoint metadata belongs to task $recorded_binding, not $id, which the validator refuses; resolve by hand, this migration writes a binding, it never rewrites one"
      continue
    fi
    # Correctly bound already: not a candidate, and nothing is wrong with it.
    continue
  fi

  backend=$(fm_backend_of_meta "$meta")

  if [ "$backend" = tmux ]; then
    # Not a candidate: the validator accepts a legacy tmux record on its window
    # name alone. Reported rather than passed over in silence.
    not_required=$((not_required + 1))
    outcome "$(printf 'NOT-REQUIRED\t%s\ttmux record; validator binds it by window name, no field needed' "$id")"
    continue
  fi

  if [ "$backend" != herdr ]; then
    disposition "$id" "backend $backend has no observation path in this migration; verify by hand"
    continue
  fi

  if ! result=$(observe_herdr_binding "$id" "$meta"); then
    disposition "$id" "$result"
    continue
  fi

  IFS=$'\t' read -r observed_id detail <<<"$result"

  if [ "$APPLY" -eq 1 ]; then
    if write_binding "$meta" "$observed_id" "$detail"; then
      migrated=$((migrated + 1))
      outcome "$(printf 'MIGRATED\t%s\tendpoint_task_id=%s\t%s' "$id" "$observed_id" "$detail")"
    else
      disposition "$id" "observed cleanly but the metadata write failed"
    fi
  else
    migrated=$((migrated + 1))
    outcome "$(printf 'WOULD-MIGRATE\t%s\tendpoint_task_id=%s\t%s' "$id" "$observed_id" "$detail")"
  fi
done

printf '\nsummary observed=%s disposition=%s not_required=%s\n' \
  "$migrated" "$refused" "$not_required"
printf 'receipt %s\n' "$RECEIPTS"

receipt_close
exit 0
