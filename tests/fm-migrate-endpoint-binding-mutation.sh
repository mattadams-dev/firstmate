#!/usr/bin/env bash
# tests/fm-migrate-endpoint-binding-mutation.sh - mutation experiment for the
# endpoint-binding migration.
#
# A guard-class change has to show its tests are load-bearing in BOTH
# directions: an observable binding still migrates, and a mutation that lets an
# UNOBSERVED value be written fails - precisely, in the case that owns that
# property, not everywhere at once. A suite that goes all-red under every
# mutation cannot tell you which guard it is actually holding.
#
# Each mutation is a sed edit applied to a copy of the script placed inside
# bin/ (so its FM_ROOT resolution still works), run through the real suite via
# FM_MIGRATE_BIN, with the set of failing cases diffed against the expectation.
#
# The migration is retained as the documented recovery procedure for a future
# legacy lane, so this experiment is permanent alongside it.
#
# shellcheck disable=SC2016
# Single quotes are load-bearing throughout: guard_line patterns and sed
# expressions are LITERAL source text of the script under mutation. Expanding
# them here would compare against this file's own variables and match nothing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/bin/fm-migrate-endpoint-binding.sh"
SUITE="$ROOT/tests/fm-migrate-endpoint-binding.test.sh"
# The mutant lives in bin/ so the copy's own FM_ROOT resolution still finds the
# repo, but deliberately carries no .sh suffix: bin/fm-lint.sh lints bin/*.sh,
# and a residue left by a signal the EXIT trap cannot catch must not become a
# lint failure in an unrelated later run. Removed up front as well as on exit,
# so a stale copy from a killed run heals rather than accumulating.
MUTANT="$ROOT/bin/fm-migrate-endpoint-binding.mutant"

rm -f "$MUTANT"
trap 'rm -f "$MUTANT"' EXIT

overall=0

# guard_line <lineno> <must-contain>: pin a mutation to the guard it means to
# neutralise. Line-addressed edits are precise but blind; this makes a drifted
# line number an explicit failure instead of a silent mutation of the wrong
# code, which would quietly invalidate the whole experiment.
guard_line() {
  local n=$1 want=$2 got
  got=$(sed -n "${n}p" "$SRC")
  case "$got" in
    *"$want"*) return 0 ;;
    *) printf 'INVALID  line %s is not the expected guard\n  want substring: %s\n  got:            %s\n' \
         "$n" "$want" "$got"; overall=1; return 1 ;;
  esac
}

# failing_cases: names of cases the suite reports as not ok, one per line.
failing_cases() {
  FM_MIGRATE_BIN="$MUTANT" bash "$SUITE" 2>&1 \
    | sed -n 's/^not ok - \(.*\)$/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'
}

# mutate <name> <expected-failing-cases> <sed-expr>...
#
# Every sed expression must be `<line>s/.*/<replacement>/` and is checked
# against guard_line() first, so a mutation can never silently land on the
# wrong line after the script is edited.
mutate() {
  local name=$1 expected=$2
  shift 2
  cp "$SRC" "$MUTANT"
  chmod +x "$MUTANT"
  for e in "$@"; do
    sed -i "$e" "$MUTANT"
  done
  if cmp -s "$SRC" "$MUTANT"; then
    printf 'INVALID  %-34s mutation changed nothing (pattern drifted)\n' "$name"
    overall=1
    return
  fi
  if ! bash -n "$MUTANT" 2>/dev/null; then
    printf 'INVALID  %-34s mutation broke the script syntactically\n' "$name"
    overall=1
    return
  fi
  local got
  got=$(failing_cases)
  if [ "$got" = "$expected" ]; then
    printf 'CAUGHT   %-34s failing: %s\n' "$name" "${got:-<none>}"
  else
    printf 'ESCAPED  %-34s expected: [%s]  got: [%s]\n' "$name" "$expected" "$got"
    overall=1
  fi
}

echo "== baseline: unmutated script =="
if base=$(FM_MIGRATE_BIN="$SRC" bash "$SUITE" 2>&1); then
  printf 'BASELINE green (%s)\n\n' "$(printf '%s' "$base" | grep -c '^ok - ')"
else
  printf 'BASELINE RED - fix the suite before trusting mutation results\n%s\n' "$base"
  exit 1
fi

echo "== mutations that let an unobserved value be written =="

# M1, the headline mutation: take the identity from the record's own filename
# instead of from the live label. This is exactly "assertion instead of
# observation" - the field would be filled by belief and the check would still
# pass. It must break the case that owns that property, and only that case.
guard_line 391 'local observed_id=${observed_label#fm-}' &&
mutate value-from-filename-not-label \
  label_names_other_task_refused \
  '391s/.*/  local observed_id=$id/'

# Each remaining mutation neutralises ONE guard by replacing its condition with
# `true`, leaving the `|| { ... }` refusal block syntactically intact. A
# restructuring edit would break the script outright and turn the whole suite
# red, which proves nothing about any individual guard.

# M2: stop requiring the live pane to be the recorded pane.
guard_line 421 '[ "$observed_pane" = "$pane" ]' &&
mutate skip-pane-identity-check \
  pane_mismatch_refused \
  '421s/.*/  true || {/'

# M3: stop requiring the workspace to belong to this home. The fixture gives
# the foreign workspace a correctly-labelled tab, so only this check stands
# between the migration and another home's endpoint.
guard_line 356 'grep -qxF -- "$workspace"' &&
mutate skip-home-workspace-check \
  "foreign_workspace_refused workspace_metacharacter_refused" \
  '356s/.*/  true || {/'

# M3b: keep the check but make it a PATTERN match again. The cross-home boundary
# is the only comparison here not made by `=`, so a recorded id carrying a regex
# metacharacter would match a different live id of the same length. The foreign
# workspace fixture cannot see this - `wOTHER` is not a pattern for `wB` - so the
# metacharacter case is what owns it.
guard_line 356 'grep -qxF -- "$workspace"' &&
mutate workspace-match-not-fixed-string \
  workspace_metacharacter_refused \
  '356s/grep -qxF/grep -qx/'

# M4: accept a tab that holds more than one pane instead of refusing ambiguity.
guard_line 416 '"$pane_matches" | wc -l' &&
mutate accept-ambiguous-pane \
  ambiguous_pane_refused \
  '416s/.*/  true || {/'

echo
echo "== mutations that report an unobservable world as a definite absence =="

# "The endpoint is gone" and "the backend could not be queried" are different
# worlds. The receipt is durable, so a guess sharpened into a definite claim
# there outlives the run that made it.

# Each live read is checked twice - once on the call's exit status, once on the
# SHAPE of the body it returned - because either check alone leaves a world it
# cannot tell from a genuine absence. The three mutations below remove the pair
# and then each half on its own, so no half can rot behind the other.

# M11: restore the masking that made an unobservable herdr indistinguishable
# from a genuine absence - drop BOTH workspace-level refusals and let an empty
# extraction be read as "the workspace is not live", whatever produced it.
guard_line 344 'return 1' &&
guard_line 343 'could not list live workspaces' &&
guard_line 348 'return 1' &&
guard_line 346 '(.result.workspaces | type) == "array"' &&
mutate unreachable-backend-read-as-absent \
  "failed_call_with_wellformed_body_is_unknown_not_absent unexpected_workspace_body_is_unknown_not_absent unreachable_backend_is_unknown_not_absent" \
  '344s/.*/    :/' '348s/.*/    :/'

# M11a: drop only the exit-status half, keeping the shape check. A call that
# emits a well-formed list and THEN fails passes the shape check on a body the
# backend never finished standing behind, so only the status check can see it.
guard_line 344 'return 1' &&
guard_line 343 'could not list live workspaces' &&
mutate trust-the-body-of-a-failed-call \
  failed_call_with_wellformed_body_is_unknown_not_absent \
  '344s/.*/    :/'

# M11b: drop only the shape half, keeping the status check. `.result.workspaces[]?`
# yields empty output and exit 0 for an `{"error":{...}}` body or a renamed field,
# so without this the response the run did not understand is reported as a
# definite absence - into stdout and into the durable receipt.
guard_line 348 'return 1' &&
guard_line 346 '(.result.workspaces | type) == "array"' &&
mutate read-unrecognised-workspace-body-as-absent \
  unexpected_workspace_body_is_unknown_not_absent \
  '348s/.*/    :/'

# M11c and M11d: the same shape check at the two later live reads. An empty
# `.result.tabs`/`.result.panes` otherwise means the endpoint is genuinely gone,
# which is exactly why an unrecognised body must not produce the same reading.
guard_line 371 'return 1' &&
guard_line 369 '(.result.tabs | type) == "array"' &&
mutate read-unrecognised-tab-body-as-absent \
  unexpected_tab_body_is_unknown_not_absent \
  '371s/.*/    :/'

guard_line 408 'return 1' &&
guard_line 406 '(.result.panes | type) == "array"' &&
mutate read-unrecognised-pane-body-as-absent \
  unexpected_pane_body_is_unknown_not_absent \
  '408s/.*/    :/'

# M11e and M11f: the tab and pane CLI-failure branches keep their honest wording
# but lose the UNKNOWN marker their siblings carry. Nothing asserts absence
# either way, so this is about the DURABLE receipt: an audit grepping it for
# UNKNOWN would file a herdr that died mid-run with the ordinary refusals.
guard_line 366 'could not list live tabs' &&
mutate tab-list-failure-omits-unknown-marker \
  tab_list_failure_is_unknown_not_absent \
  '366s/.*/    echo "could not list live tabs in workspace $workspace of session $session"/'

guard_line 403 'could not list live panes' &&
mutate pane-list-failure-omits-unknown-marker \
  pane_list_failure_is_unknown_not_absent \
  '403s/.*/    echo "could not list live panes in workspace $workspace of session $session"/'

echo
echo "== mutations that turn a refusal shape back into a silent skip =="

# The validator refuses four binding shapes; only absence is repairable here.
# M6 and M7 restore the original blind spot by dropping the report and skipping
# the record, which is the silent-skip class this migration must never have.

# M6: an empty endpoint_task_id= line stops being reported.
guard_line 538 'empty endpoint task binding' &&
mutate silent-skip-empty-binding \
  empty_binding_reported_not_skipped \
  '538s/.*/      continue/'

# M7: a duplicated endpoint_task_id= line stops being reported.
guard_line 533 'ambiguous endpoint task binding' &&
mutate silent-skip-duplicated-binding \
  duplicated_binding_reported_not_skipped \
  '533s/.*/    continue/'

echo
echo "== mutations that let a record vanish from the account entirely =="

# The receipt is THE record of a run, so every file the state/*.meta glob
# matches has to produce a line. A record skipped without one is
# indistinguishable from a record that never existed. Each shape below owns a
# case, so a mutation that lets one vanish breaks that case and not a
# neighbour's.

# M12: a record with no window= line stops being reported.
guard_line 520 'no window= line' &&
mutate silent-skip-windowless-record \
  windowless_record_reported_not_skipped \
  '520s/.*/    continue/'

# M13: a record that could not be read stops being reported.
guard_line 499 'could not be read as a regular file' &&
mutate silent-skip-unreadable-record \
  unreadable_record_reported_not_skipped \
  '499s/.*/    continue/'

# M14: a symlink whose target is gone stops being reported. Dropping only the
# report leaves the record caught by the live-symlink branch below, so the line
# that appears names the wrong fact - which is why this case pins the reason
# text and not merely the presence of a line.
guard_line 489 'target does not exist' &&
mutate silent-skip-dangling-symlink \
  dangling_symlink_reported_not_skipped \
  '489s/.*/    continue/'

# M15: a symlinked record stops being reported and is passed over instead.
guard_line 493 'is a symlink, which the validator refuses' &&
mutate silent-skip-symlinked-record \
  symlinked_record_refused_and_stays_a_symlink \
  '493s/.*/    continue/'

# M16: the live-symlink guard is removed outright, so a symlinked record is
# WRITTEN - `mv` replaces the link with a regular file, converting a record
# teardown refuses into one teardown accepts on content imported from outside
# state/.
#
# Only the laundering case is reachable: the dangling branch above is a separate
# test and still fires, which is exactly why the two shapes are branched apart
# rather than sharing one guard.
guard_line 492 'if [ -L "$meta" ]; then' &&
mutate launder-symlinked-record \
  symlinked_record_refused_and_stays_a_symlink \
  '492s/.*/  if false; then/'

# M17: the unterminated-record guard is removed, so the binding is appended onto
# a partial last line. That corrupts the preceding key AND leaves
# endpoint_task_id= matching zero lines, so the record stays a candidate and
# every later run appends again - the one way the structural idempotence claim
# can fail.
guard_line 507 'if meta_unterminated "$meta"; then' &&
mutate append-onto-unterminated-record \
  unterminated_record_refused \
  '507s/.*/  if false; then/'

echo
echo "== mutations on idempotence and the receipt, in both directions =="

# The one-shot guard was deleted; idempotence and the receipt are what replaced
# it, so they are what these mutations have to prove are load-bearing.

# M8: let a repeated run double-write. Dropping the skip on an
# already-correctly-bound record sends it back through observation and appends a
# SECOND binding and provenance pair - corrupting exactly what a previous run
# recorded, which is the property the deleted guard used to stand in for.
#
# Reachable set is wider than the idempotence case alone because every fixture
# holding a correctly bound record now has it rewritten - including the
# already-migrated record in the resume case. Listing only the idempotence case
# would be an expectation this experiment could not satisfy.
guard_line 549 'already carries endpoint_task_id' &&
guard_line 550 'continue' &&
mutate double-write-already-bound-record \
  "existing_binding_untouched interrupted_run_resumes repeated_apply_is_idempotent repeated_apply_is_not_refused" \
  '550s/.*/    :/'

# M9, the mirror. Idempotence means safe to repeat, not clever about refusing,
# so reintroducing one-shot behaviour must fail loudly. This restores the last
# shipped form of the guard - refuse when provenance exists and nothing unbound
# remains - because that is the most plausible way it would come back.
#
# interrupted_run_resumes is deliberately NOT expected: its home still holds an
# unbound record, so this form of the guard never fires there. The two cases
# that do run twice against a fully migrated home are the ones that can see it.
guard_line 193 'RECEIPTS=' &&
mutate reintroduce-one-shot-refusal \
  "repeated_apply_is_idempotent repeated_apply_is_not_refused" \
  '193s@.*@RECEIPTS="$FM_HOME/data/endpoint-binding-migration-receipts.log"; if [ "$APPLY" -eq 1 ] \&\& grep -q "^endpoint_task_id_provenance=" "$STATE"/*.meta 2>/dev/null \&\& ! grep -L "^endpoint_task_id=" "$STATE"/*.meta 2>/dev/null | grep -q .; then echo "REFUSED: already migrated" >\&2; exit 1; fi@'

# M10: let a run complete without recording itself. An unrecorded run is the
# state this design exists to make impossible, so every case that reads a
# receipt must see it: the three receipt cases, the mid-run failure case, and the
# four unknown-not-absent cases that assert the durable receipt carries the
# distinction rather than only stdout. No metadata behaviour changes, so no other
# case is reachable.
guard_line 218 '>> "$RECEIPTS"' &&
mutate run-without-writing-receipt \
  "pane_list_failure_is_unknown_not_absent receipt_accumulates_across_runs receipt_failure_mid_run_is_not_silent receipt_written_for_apply_run receipt_written_for_observe_run tab_list_failure_is_unknown_not_absent unexpected_workspace_body_is_unknown_not_absent unreachable_backend_is_unknown_not_absent" \
  '218s|.*|  :|'

# M18: let a receipt that fails MID-RUN be survivable - the run prints its
# refusal and then carries on to a successful exit, leaving a partial account of
# a run that reported success. Only the mid-run case can see this: the other
# receipt cases never lose a writable receipt.
guard_line 230 'exit 1' &&
guard_line 228 'receipt_append "$1" ||' &&
mutate continue-past-failed-receipt-write \
  receipt_failure_mid_run_is_not_silent \
  '230s/.*/    :/'

echo
echo "== the false-positive direction: a healthy record reported as a decision =="

# The accounting rule must not degenerate into "call everything a disposition
# and every record is accounted for". A record that was in fact processed
# normally must never be reported as needing a human decision, so a mutation
# that does exactly that has to break the cases that assert it.
guard_line 549 'already carries endpoint_task_id' &&
mutate report-healthy-record-as-disposition \
  "existing_binding_untouched valid_binding_is_not_a_disposition" \
  '549s@.*@    disposition "$id" "already carries endpoint_task_id=$recorded_binding"@'

echo
echo "== control: a blanket bypass should be caught broadly, not narrowly =="

# M5: the "makes everything look healthy" failure mode - write the binding
# regardless of what was observed. A suite worth trusting must not shrug.
#
# Expected to break every case whose record reaches the herdr observation and
# is refused by it. unobservable_backend_refused is deliberately NOT in that
# set: a zellij record is turned away by the earlier backend branch and never
# reaches this line, so this mutation genuinely cannot affect it. Listing it
# anyway would be an expectation the experiment could only satisfy by accident.
guard_line 568 'if ! result=$(observe_herdr_binding' &&
mutate blanket-write-without-observation \
  "absent_endpoint_refused ambiguous_pane_refused failed_call_with_wellformed_body_is_unknown_not_absent foreign_workspace_refused label_names_other_task_refused pane_list_failure_is_unknown_not_absent pane_mismatch_refused tab_list_failure_is_unknown_not_absent unexpected_pane_body_is_unknown_not_absent unexpected_tab_body_is_unknown_not_absent unexpected_workspace_body_is_unknown_not_absent unreachable_backend_is_unknown_not_absent workspace_metacharacter_refused" \
  '568s|.*|  result=$(observe_herdr_binding "$id" "$meta") \|\| result=$(printf "%s\\tsource=UNOBSERVED" "$id"); if false; then|'

echo
echo "== the write must not silently change the record it repairs =="

# The replacement is a mktemp file, created 0600. Dropping the mode carry-over is
# what `chmod --reference` did on every non-GNU platform, silently: one --apply
# narrows every migrated record's permissions and no outcome line says so.
guard_line 471 'chmod "$mode" "$tmp"' &&
mutate write-without-carrying-the-mode \
  migrated_record_keeps_its_mode \
  '471s@.*@  :@'

echo
echo "== --help must print the header, and only the header =="

# --help prints the file's own header, the surface a previous review round caught
# printing a claim that had gone stale. The range is derived rather than pinned
# precisely so an edited header cannot silently truncate it or run past its end
# into shell source; both drift directions are mutations here.
guard_line 180 "sed -n '2,\${/^#/!q;p;}'" &&
mutate help-range-truncates-header \
  help_prints_the_whole_header_and_no_source \
  '180s@2,\${/\^#/!q;p;}@2,60p@'

guard_line 180 "sed -n '2,\${/^#/!q;p;}'" &&
mutate help-range-overruns-into-source \
  help_prints_the_whole_header_and_no_source \
  '180s@2,\${/\^#/!q;p;}@2,200p@'

echo
if [ "$overall" -eq 0 ]; then
  echo "RESULT: every mutation was caught by exactly the expected case(s)"
else
  echo "RESULT: at least one mutation escaped or drifted - see above"
fi
exit "$overall"
