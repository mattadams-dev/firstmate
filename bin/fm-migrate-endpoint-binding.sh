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
# UNKNOWN IS NOT ABSENT
#
# "The endpoint is gone" and "the backend could not be queried" are two
# different worlds, and a reading that cannot tell them apart must never report
# the stronger one. Every live read here is status-checked before its output is
# interpreted: a failed `herdr` call or an unparseable response yields an
# explicit UNKNOWN disposition naming that condition, never an absence claim.
# The receipt carries the same distinction, because the receipt is the durable
# surface where a sharpened guess would outlive the run that made it.
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
# Four record SHAPES are refused for the same reason - the repair this script
# performs cannot be performed safely on them:
#
#   - a symlinked record, and a symlink whose target is gone. The validator
#     requires a regular file that is not a symlink, so writing through the link
#     would replace it with a regular file and turn a record teardown REFUSES
#     into one teardown ACCEPTS, on content imported from outside state/.
#   - a record that cannot be read as a regular file. Nothing about it was
#     observed, so nothing about it is claimed.
#   - a record whose last line carries no terminating newline. It is already
#     malformed, and appending would concatenate the binding onto that partial
#     line, corrupting the preceding key AND leaving the record a candidate for
#     every later run.
#   - a record with no `window=` line. It names no endpoint for a binding to
#     describe, and teardown refuses it too.
#
# EVERY RECORD IS ACCOUNTED FOR
#
# Every file the state/*.meta glob matches produces exactly one outcome line, on
# stdout and in the receipt: MIGRATED, WOULD-MIGRATE, NOT-REQUIRED, or
# DISPOSITION. No record is passed over in silence, so a reader of a receipt can
# never confuse a record that was skipped with one that never existed. A receipt
# that omits entries is not a record of the run, it is a record-shaped object
# that lies by omission.
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
# home-level state. The only shape this script writes is a well-formed record
# with ZERO `endpoint_task_id=` lines. After such a record is migrated it carries
# exactly one correct binding, so on any later run it is a non-candidate and is
# skipped untouched: no second binding, no second provenance line, no rewrite.
# The migrated bytes of an already-repaired record are identical after the second
# run and after the tenth.
#
# That property depends on the appended binding landing on its own line, which is
# why a record whose last line is unterminated is refused rather than appended
# to: an append there would corrupt the preceding key and leave `endpoint_task_id`
# still matching zero lines, so every later run would append again.
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
# A run that cannot write its receipt does not run, and a run that loses the
# receipt part way through does not continue: every append is checked, and a
# failed one stops the run loudly and non-zero. An unrecorded or half-recorded
# run that reported success would be exactly the divergent second account this
# design exists to make impossible.
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
# or environment error, or when the run receipt could not be written. A
# disposition item is a reported outcome, not a failure of this script.

set -uo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,162p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# receipt_require <line>: append, or stop the run. Every append after the first
# is as load-bearing as the first - a receipt that stops being written mid-run
# leaves a partial account of a run that reported success, which is the second
# and divergent account this design exists to prevent. Refusing here also keeps
# the failure loud at the moment it happens rather than discoverable later by
# noticing an absence.
receipt_require() {
  receipt_append "$1" || {
    echo "REFUSED: cannot append to the run receipt at $RECEIPTS; stopping rather than continuing unrecorded." >&2
    exit 1
  }
}

receipt_open() {
  mkdir -p "$(dirname "$RECEIPTS")" || return 1
  receipt_append "$(printf 'run\tstart=%s\thome=%s\tmode=%s\tby=%s\ttool=%s' \
    "$RUN_AT" "$FM_HOME" "$MODE" "$(basename "${BASH_SOURCE[0]}")" "${HERDR_VERSION:-absent}")"
}

receipt_close() {
  receipt_require "$(printf 'run\tend=%s\tstart=%s\tmode=%s\tobserved=%s\tdisposition=%s\tnot_required=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_AT" "$MODE" "$migrated" "$refused" "$not_required")"
}

# outcome <line>: report one record's result on stdout and in the receipt. Both
# surfaces get the same text, so the receipt can never become a second and
# divergent account of what the run did.
outcome() {
  printf '%s\n' "$1"
  receipt_require "$1"
}

receipt_open || {
  echo "REFUSED: cannot write the run receipt at $RECEIPTS; refusing to run unrecorded." >&2
  exit 1
}

# meta_count <meta> <key>: number of lines for <key>, or FAILS when the record
# could not be read at all. grep -c returns 1 with a count of 0 when the key is
# simply absent and 2 when it cannot read the file; collapsing those two into an
# empty string is what let an unreadable record be silently read as "no such
# key" - two worlds, one reading, and the stronger one asserted.
meta_count() {
  local n rc
  n=$(grep -c "^$2=" "$1" 2>/dev/null)
  rc=$?
  [ "$rc" -le 1 ] || return 1
  printf '%s' "${n:-0}"
}

# meta_one <meta> <key>: the value when the key appears exactly once and is
# non-empty; otherwise fails. Same exactness rule the validator applies.
meta_one() {
  local n
  n=$(meta_count "$1" "$2") || return 1
  [ "$n" -eq 1 ] || return 1
  local v
  v=$(grep "^$2=" "$1" | cut -d= -f2-)
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# meta_unterminated <meta>: true when the record's last line has no terminating
# newline. Command substitution strips trailing newlines, so a terminated file
# yields the empty string here and an unterminated one yields its last byte.
meta_unterminated() {
  [ -s "$1" ] || return 1
  [ -n "$(tail -c 1 "$1" 2>/dev/null)" ]
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
# refusal reason and returns 1 otherwise. Every refusal reason states only what
# was observed: an unreachable or unreadable backend yields UNKNOWN, never the
# claim that an endpoint is gone.
observe_herdr_binding() {
  local id=$1 meta=$2
  local session workspace tab pane window
  session=$(meta_one "$meta" herdr_session) || { echo "recorded herdr_session is missing, empty, or ambiguous"; return 1; }
  workspace=$(meta_one "$meta" herdr_workspace_id) || { echo "recorded herdr_workspace_id is missing, empty, or ambiguous"; return 1; }
  tab=$(meta_one "$meta" herdr_tab_id) || { echo "recorded herdr_tab_id is missing, empty, or ambiguous"; return 1; }
  pane=$(meta_one "$meta" herdr_pane_id) || { echo "recorded herdr_pane_id is missing, empty, or ambiguous"; return 1; }
  window=$(meta_one "$meta" window) || { echo "recorded window is missing, empty, or ambiguous"; return 1; }

  fm_backend_source herdr >/dev/null 2>&1 || { echo "herdr adapter unavailable"; return 1; }
  fm_backend_herdr_tool_check >/dev/null 2>&1 || {
    echo "the herdr CLI or jq is not available, so no live read was possible; whether this endpoint is live is UNKNOWN, not absent"
    return 1
  }

  # 1. The recorded workspace must currently be one of THIS home's workspaces,
  #    resolved by this home's own label, so a workspace belonging to another
  #    home or to a stale label can never qualify.
  #
  #    The raw call is made HERE rather than through
  #    fm_backend_herdr_workspace_find_all because that function returns 0 with
  #    empty output when the query itself fails (bin/backends/herdr.sh, `||
  #    return 0`). Reading its emptiness as absence would report "the workspace
  #    is gone" for a stopped server, an uninstalled herdr, or a jq failure -
  #    two worlds, one reading. Checking the call's own exit status is what
  #    keeps them apart. The jq variable is $want, never $label: `label` is a jq
  #    reserved keyword, and a compile error there would empty every result.
  local workspace_list home_label live_workspaces
  workspace_list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "could not list live workspaces in session $session, so whether workspace $workspace is still live is UNKNOWN, not absent"
    return 1
  }
  home_label=$(fm_backend_herdr_workspace_label)
  live_workspaces=$(printf '%s' "$workspace_list" | jq -r --arg want "$home_label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id') || {
    echo "could not read the live workspace list of session $session, so whether workspace $workspace is still live is UNKNOWN, not absent"
    return 1
  }
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
    '.result.tabs[]? | select(.tab_id == $t) | "\(.label)\t\(.tab_id)"') || {
    echo "could not read the live tab list of workspace $workspace in session $session, so whether tab $tab is still live is UNKNOWN, not absent"
    return 1
  }
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
    '.result.panes[]? | select(.tab_id == $t) | .pane_id') || {
    echo "could not read the live pane list of workspace $workspace in session $session, so whether tab $observed_tab still holds pane $pane is UNKNOWN, not absent"
    return 1
  }
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
# existing binding - this repairs absence only. Refuses a symlink outright: the
# `mv` below replaces the link itself, which would launder a record teardown
# refuses into a regular file teardown accepts.
write_binding() {
  local meta=$1 observed_id=$2 detail=$3 tmp
  [ ! -L "$meta" ] || return 1
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
  id=$(basename "$meta" .meta)

  # A dangling symlink and a live symlink are refused separately, because they
  # are different facts about the record and a reader deserves the one that is
  # true. Neither is written: fm_backend_validate_task_endpoint requires a
  # regular file that is NOT a symlink, so writing through the link would
  # replace it with a regular file holding content imported from outside state/
  # - turning a record teardown REFUSES into one teardown ACCEPTS.
  if [ -L "$meta" ] && [ ! -e "$meta" ]; then
    disposition "$id" "the state record is a symlink whose target does not exist, so nothing about its endpoint could be read; teardown refuses a symlinked record too, resolve by hand"
    continue
  fi
  if [ -L "$meta" ]; then
    disposition "$id" "the state record is a symlink, which the validator refuses as endpoint metadata; writing here would replace the link with a regular file and turn a record teardown refuses into one it accepts, so it is left exactly as found"
    continue
  fi
  # Only an unmatched glob reaches this: a dangling symlink was caught above.
  [ -e "$meta" ] || continue
  if [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
    disposition "$id" "the state record could not be read as a regular file, so nothing about its binding was observed; resolve by hand"
    continue
  fi
  # An unterminated last line is refused rather than repaired: appending would
  # concatenate the binding onto that partial line, corrupting the preceding key
  # while leaving endpoint_task_id= still matching zero lines - so the record
  # would stay a candidate and every later run would append again. That is the
  # one way the structural idempotence above can fail, so it is closed here.
  if meta_unterminated "$meta"; then
    disposition "$id" "the record's last line has no terminating newline, so it is already malformed and an appended binding would run onto that partial line; resolve by hand, this migration does not guess where a truncated line ended"
    continue
  fi

  # A read that fails is not a record that lacks a key. meta_count fails rather
  # than returning an empty count, so this can never silently mean "no window
  # line" for a record nothing was actually read from.
  if ! window_lines=$(meta_count "$meta" window); then
    disposition "$id" "the record could not be read, so whether it records an endpoint is unknown; resolve by hand"
    continue
  fi
  if [ "$window_lines" -lt 1 ]; then
    disposition "$id" "no window= line, so this record names no endpoint for a binding to describe; teardown refuses it too as a missing, empty, or ambiguous window endpoint, resolve by hand"
    continue
  fi

  # Binding shape decides candidacy. Absence is the only shape this migration
  # can repair, because it appends an observed binding and never rewrites one.
  # The validator's three other refusal shapes are reported rather than passed
  # over in silence.
  if ! binding_lines=$(meta_count "$meta" endpoint_task_id); then
    disposition "$id" "the record could not be read, so its endpoint task binding was not observed; resolve by hand"
    continue
  fi
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
    # Still accounted for, so the receipt covers every record rather than
    # leaving this one indistinguishable from a record that never existed.
    not_required=$((not_required + 1))
    outcome "$(printf 'NOT-REQUIRED\t%s\talready carries endpoint_task_id=%s; not a candidate and nothing to repair' "$id" "$recorded_binding")"
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
