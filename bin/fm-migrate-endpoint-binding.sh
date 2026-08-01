#!/usr/bin/env bash
# bin/fm-migrate-endpoint-binding.sh - ONE-SHOT, SELF-RETIRING repair of
# `endpoint_task_id=` in this home's state/<id>.meta records.
#
# THIS SCRIPT IS DELETED IN THE SAME CHANGE THAT LANDS ITS EVIDENCE.
# It exists on this branch so the repair, its tests, and its recorded run are
# reviewable together; the merged default branch does not carry it. Keeping a
# re-runnable tool that can fill a safety field on demand is the failure mode
# it is written to avoid, and a home-local "already ran" marker would not
# prevent another home from running it. See
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
# Usage:
#   bin/fm-migrate-endpoint-binding.sh [--apply]
#
#   (default)  observe and report only; writes nothing
#   --apply    write observed bindings; refusals are still only reported
#
# Environment:
#   FM_HOME  home whose state/ is repaired (required; no default, so a
#            mistyped invocation cannot silently repair the wrong home)
#
# Exit: 0 when every candidate was either migrated or reported; 1 on a usage
# or environment error. A disposition item is a reported outcome, not a
# failure of this script.

set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: $(basename "$0") [--apply]" >&2; exit 1 ;;
esac

[ -n "${FM_HOME:-}" ] || { echo "REFUSED: FM_HOME must be set explicitly." >&2; exit 1; }
STATE="$FM_HOME/state"
[ -d "$STATE" ] || { echo "REFUSED: no state directory at $STATE." >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"

RUN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 || true)

migrated=0
refused=0
not_required=0

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
  printf 'DISPOSITION\t%s\t%s\n' "$1" "$2"
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
  binding_lines=$(meta_count "$meta" endpoint_task_id)
  [ "$binding_lines" -eq 0 ] || continue

  backend=$(fm_backend_of_meta "$meta")

  if [ "$backend" = tmux ]; then
    # Not a candidate: the validator accepts a legacy tmux record on its window
    # name alone. Reported rather than passed over in silence.
    not_required=$((not_required + 1))
    printf 'NOT-REQUIRED\t%s\ttmux record; validator binds it by window name, no field needed\n' "$id"
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
      printf 'MIGRATED\t%s\tendpoint_task_id=%s\t%s\n' "$id" "$observed_id" "$detail"
    else
      disposition "$id" "observed cleanly but the metadata write failed"
    fi
  else
    migrated=$((migrated + 1))
    printf 'WOULD-MIGRATE\t%s\tendpoint_task_id=%s\t%s\n' "$id" "$observed_id" "$detail"
  fi
done

printf '\nsummary observed=%s disposition=%s not_required=%s\n' \
  "$migrated" "$refused" "$not_required"
exit 0
