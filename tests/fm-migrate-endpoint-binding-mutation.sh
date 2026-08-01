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
guard_line 249 'local observed_id=${observed_label#fm-}' &&
mutate value-from-filename-not-label \
  label_names_other_task_refused \
  '249s/.*/  local observed_id=$id/'

# Each remaining mutation neutralises ONE guard by replacing its condition with
# `true`, leaving the `|| { ... }` refusal block syntactically intact. A
# restructuring edit would break the script outright and turn the whole suite
# red, which proves nothing about any individual guard.

# M2: stop requiring the live pane to be the recorded pane.
guard_line 272 '[ "$observed_pane" = "$pane" ]' &&
mutate skip-pane-identity-check \
  pane_mismatch_refused \
  '272s/.*/  true || {/'

# M3: stop requiring the workspace to belong to this home. The fixture gives
# the foreign workspace a correctly-labelled tab, so only this check stands
# between the migration and another home's endpoint.
guard_line 221 'grep -qx -- "$workspace"' &&
mutate skip-home-workspace-check \
  foreign_workspace_refused \
  '221s/.*/  true || {/'

# M4: accept a tab that holds more than one pane instead of refusing ambiguity.
guard_line 267 '"$pane_matches" | wc -l' &&
mutate accept-ambiguous-pane \
  ambiguous_pane_refused \
  '267s/.*/  true || {/'

echo
echo "== mutations that turn a refusal shape back into a silent skip =="

# The validator refuses four binding shapes; only absence is repairable here.
# M6 and M7 restore the original blind spot by dropping the report and skipping
# the record, which is the silent-skip class this migration must never have.

# M6: an empty endpoint_task_id= line stops being reported.
guard_line 329 'empty endpoint task binding' &&
mutate silent-skip-empty-binding \
  empty_binding_reported_not_skipped \
  '329s/.*/      continue/'

# M7: a duplicated endpoint_task_id= line stops being reported.
guard_line 324 'ambiguous endpoint task binding' &&
mutate silent-skip-duplicated-binding \
  duplicated_binding_reported_not_skipped \
  '324s/.*/    continue/'

echo
echo "== mutations on the one-shot property, in both directions =="

# M8: neuter the guard that refuses --apply against a fully migrated home.
# Only the refusal case can see this: every other fixture home either has an
# unbound candidate left or carries zero provenance lines, so the guard never
# fires there and removing it changes nothing. Observe-only mode is unaffected
# by construction, and the resume case expects the run to proceed anyway, so
# listing either would be an expectation this experiment could satisfy only by
# accident.
guard_line 162 '"$unbound_candidates" -eq 0' &&
mutate neuter-one-shot-guard \
  one_shot_refuses_second_apply \
  '162s/.*/if false; then/'

# M9: reintroduce the defect this guard was corrected for - refuse whenever any
# provenance exists, ignoring whether unbound candidates remain. That strands
# every record an interrupted run never reached. It must break exactly the
# resume case; a fully migrated home refuses under both conditions, so the
# refusal case cannot see this mutation.
guard_line 162 '"$provenance_records" -gt 0' &&
mutate refuse-on-any-prior-work \
  one_shot_allows_resume_after_partial_run \
  '162s/.*/if [ "$APPLY" -eq 1 ] \&\& [ "$provenance_records" -gt 0 ]; then/'

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
guard_line 355 'if ! result=$(observe_herdr_binding' &&
mutate blanket-write-without-observation \
  "absent_endpoint_refused ambiguous_pane_refused foreign_workspace_refused label_names_other_task_refused pane_mismatch_refused" \
  '355s|.*|  result=$(observe_herdr_binding "$id" "$meta") \|\| result=$(printf "%s\\tsource=UNOBSERVED" "$id"); if false; then|'

echo
if [ "$overall" -eq 0 ]; then
  echo "RESULT: every mutation was caught by exactly the expected case(s)"
else
  echo "RESULT: at least one mutation escaped or drifted - see above"
fi
exit "$overall"
