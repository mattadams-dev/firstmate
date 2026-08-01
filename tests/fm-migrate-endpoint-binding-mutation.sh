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
MUTANT="$ROOT/bin/fm-migrate-endpoint-binding.mutant.sh"

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
guard_line 210 'local observed_id=${observed_label#fm-}' &&
mutate value-from-filename-not-label \
  label_names_other_task_refused \
  '210s/.*/  local observed_id=$id/'

# Each remaining mutation neutralises ONE guard by replacing its condition with
# `true`, leaving the `|| { ... }` refusal block syntactically intact. A
# restructuring edit would break the script outright and turn the whole suite
# red, which proves nothing about any individual guard.

# M2: stop requiring the live pane to be the recorded pane.
guard_line 233 '[ "$observed_pane" = "$pane" ]' &&
mutate skip-pane-identity-check \
  pane_mismatch_refused \
  '233s/.*/  true || {/'

# M3: stop requiring the workspace to belong to this home. The fixture gives
# the foreign workspace a correctly-labelled tab, so only this check stands
# between the migration and another home's endpoint.
guard_line 182 'grep -qx -- "$workspace"' &&
mutate skip-home-workspace-check \
  foreign_workspace_refused \
  '182s/.*/  true || {/'

# M4: accept a tab that holds more than one pane instead of refusing ambiguity.
guard_line 228 '"$pane_matches" | wc -l' &&
mutate accept-ambiguous-pane \
  ambiguous_pane_refused \
  '228s/.*/  true || {/'

echo
echo "== mutations that turn a refusal shape back into a silent skip =="

# The validator refuses four binding shapes; only absence is repairable here.
# M6 and M7 restore the original blind spot by dropping the report and skipping
# the record, which is the silent-skip class this migration must never have.

# M6: an empty endpoint_task_id= line stops being reported.
guard_line 290 'empty endpoint task binding' &&
mutate silent-skip-empty-binding \
  empty_binding_reported_not_skipped \
  '290s/.*/      continue/'

# M7: a duplicated endpoint_task_id= line stops being reported.
guard_line 285 'ambiguous endpoint task binding' &&
mutate silent-skip-duplicated-binding \
  duplicated_binding_reported_not_skipped \
  '285s/.*/    continue/'

echo
echo "== mutation that removes the one-shot property =="

# M8: neuter the guard that refuses --apply against an already-migrated home.
# Only the refusal case can see this: every other fixture home carries zero
# provenance lines, so the guard never fires there and removing it changes
# nothing. Observe-only mode is unaffected by construction, so listing
# one_shot_allows_observe_on_migrated_home would be an expectation this
# experiment could satisfy only by accident.
guard_line 123 '${provenance_records:-0}' &&
mutate neuter-one-shot-guard \
  one_shot_refuses_second_apply \
  '123s/.*/if false; then/'

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
guard_line 316 'if ! result=$(observe_herdr_binding' &&
mutate blanket-write-without-observation \
  "absent_endpoint_refused ambiguous_pane_refused foreign_workspace_refused label_names_other_task_refused pane_mismatch_refused" \
  '316s|.*|  result=$(observe_herdr_binding "$id" "$meta") \|\| result=$(printf "%s\\tsource=UNOBSERVED" "$id"); if false; then|'

echo
if [ "$overall" -eq 0 ]; then
  echo "RESULT: every mutation was caught by exactly the expected case(s)"
else
  echo "RESULT: at least one mutation escaped or drifted - see above"
fi
exit "$overall"
