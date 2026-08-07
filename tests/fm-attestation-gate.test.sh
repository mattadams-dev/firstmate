#!/usr/bin/env bash
# Behavior tests for fm-attestation-gate.sh, the workflow layer of the fork's
# attestation-gate exemption.
#
# bin/fm-attestation-exempt.sh reports three outcomes and is pinned by its own
# suite. This layer is the one that can lose them. It is guard-class in both
# directions at once, and each direction needs its own fixture because a mutant
# that collapses one way still passes the other way's test:
#
#   - a head the gate could not read at all must be reported undetermined, with
#     the attestation still in force - whatever exit code carried the silence,
#     including the 1 the decider uses for a refusal it never reached. A mutant
#     that maps every code other than 0 and 2 to refused breaks exactly this;
#   - a head that was read and does not qualify must still be reported refused.
#     A mutant that maps those same codes to exempt breaks exactly this;
#   - a qualifying head must still be reported exempt, because a mapping that
#     never grants the exemption leaves the standing manual bypass in place.
#
# The unreadable-decider cases run a copy of the real script from a directory
# where its sibling decider is missing or not executable, so the exit codes
# under test (127, 126) are produced by the shell rather than simulated.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-attestation-gate.sh"
DECIDER="$ROOT/bin/fm-attestation-exempt.sh"
TMP_ROOT=$(fm_test_tmproot fm-attestation-gate-tests)
REPO_N=0

# --- fixtures ---------------------------------------------------------------

# new_repo: a fork-shaped history with a qualifying sync head already on it.
# Sets the globals REPO and DEFAULT_BRANCH (an assignment made in a command
# substitution would be lost with the subshell).
#
#   c0                     shared root
#    |- <default>          fork side:     adds fork.txt
#    \- upstream-main      upstream side: adds up.txt
#    \- sync/upstream-x    a true merge of the two
#
# The merge is conflict-free on purpose: what this suite tests is the reporting
# of the decider's verdict, and the verdicts themselves are pinned over richer
# graphs by tests/fm-attestation-exempt.test.sh.
new_repo() {
  REPO_N=$((REPO_N + 1))
  REPO="$TMP_ROOT/repo-$REPO_N"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf 'root\n' > "$REPO/root.txt"
  git -C "$REPO" add root.txt
  git -C "$REPO" commit -qm root
  DEFAULT_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)

  git -C "$REPO" checkout -q -b upstream-main
  printf 'up\n' > "$REPO/up.txt"
  git -C "$REPO" add up.txt
  git -C "$REPO" commit -qm upstream-work

  git -C "$REPO" checkout -q "$DEFAULT_BRANCH"
  printf 'fork\n' > "$REPO/fork.txt"
  git -C "$REPO" add fork.txt
  git -C "$REPO" commit -qm fork-work

  git -C "$REPO" checkout -q -b sync/upstream-x "$DEFAULT_BRANCH"
  git -C "$REPO" merge -q --no-ff -m 'Merge upstream into fork main (sync)' upstream-main
  git -C "$REPO" checkout -q "$DEFAULT_BRANCH"
}

# gate_dir <name>: a directory holding a copy of the real gate script, so the
# decider beside it can be made missing, unreadable, or replaced.
gate_dir() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  cp "$GATE" "$dir/fm-attestation-gate.sh"
  printf '%s\n' "$dir"
}

# run_gate <script> <head-ref> <head>: run the gate over $REPO with stderr
# folded into stdout, since the report a human reads is on stderr.
run_gate() {
  local script=$1 ref=$2 head=$3
  "$script" check --repo "$REPO" --head-ref "$ref" --head "$head" \
    --base "$DEFAULT_BRANCH" --upstream upstream-main --pr-author someone 2>&1
}

# --- the exemption must still be reported (mirror trap) ---------------------

test_qualifying_head_is_reported_exempt() {
  local out rc=0
  new_repo
  out=$(run_gate "$GATE" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 0 "$rc" "a qualifying sync head must pass the gate"
  assert_contains "$out" "decision=exempt" "the decider's exempt verdict must be reported"
  assert_contains "$out" "::notice::Exempt from the no-mistakes attestation" \
    "an exemption must be announced as a notice"
  pass "a qualifying sync head is reported exempt and the step passes"
}

# --- a read head that does not qualify is refused ---------------------------

test_non_qualifying_head_is_reported_refused() {
  local out rc=0
  new_repo
  # The same head under a branch name the exemption does not scope to: read in
  # full, and refused on the facts.
  out=$(run_gate "$GATE" feature/x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "a read head that does not qualify is refused"
  assert_contains "$out" "decision=refused" "the decider's refusal must be reported"
  assert_contains "$out" "its head does not qualify for the exemption" \
    "a refusal must say the head does not qualify"
  assert_not_contains "$out" "could not read the head" \
    "a refusal must not be reported as an unreadable head"
  assert_not_contains "$out" "::notice::Exempt" "a refusal must never render as an exemption"
  pass "a head that was read and does not qualify is reported refused"
}

# --- a head the gate could not read at all is undetermined ------------------

test_missing_decider_is_undetermined_not_refused() {
  local dir out rc=0
  new_repo
  dir=$(gate_dir gate-without-decider)
  out=$(run_gate "$dir/fm-attestation-gate.sh" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 2 "$rc" "a decider that is not there leaves the outcome undetermined"
  assert_contains "$out" "could not read the head" \
    "an undetermined outcome must say the gate could not read the head"
  assert_not_contains "$out" "does not qualify" \
    "an unreadable head must never be reported as a head that does not qualify"
  assert_not_contains "$out" "decision=exempt" "an unreadable head must never be reported as exempt"
  assert_not_contains "$out" "::notice::Exempt" "an unreadable head must never pass the attestation"
  pass "a missing decider reports undetermined with the attestation still in force"
}

test_non_executable_decider_is_undetermined_not_refused() {
  local dir out rc=0
  new_repo
  dir=$(gate_dir gate-with-unrunnable-decider)
  cp "$DECIDER" "$dir/fm-attestation-exempt.sh"
  chmod a-x "$dir/fm-attestation-exempt.sh"
  out=$(run_gate "$dir/fm-attestation-gate.sh" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 2 "$rc" "a decider that cannot be executed leaves the outcome undetermined"
  assert_contains "$out" "could not read the head" \
    "an undetermined outcome must say the gate could not read the head"
  assert_not_contains "$out" "does not qualify" \
    "an unreadable head must never be reported as a head that does not qualify"
  assert_not_contains "$out" "::notice::Exempt" "an unreadable head must never pass the attestation"
  pass "a non-executable decider reports undetermined with the attestation still in force"
}

test_silent_decider_is_not_reported_exempt() {
  local dir out rc=0
  new_repo
  dir=$(gate_dir gate-with-silent-decider)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fm-attestation-exempt.sh"
  chmod +x "$dir/fm-attestation-exempt.sh"
  out=$(run_gate "$dir/fm-attestation-gate.sh" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 2 "$rc" "a decider that exits 0 without deciding decided nothing"
  assert_contains "$out" "could not read the head" \
    "a decider that never decided leaves the outcome undetermined"
  assert_not_contains "$out" "::notice::Exempt" "silence must never be read as an exemption"
  pass "a decider that exits 0 without a decision is undetermined, not exempt"
}

test_silent_exit_1_decider_is_undetermined_not_refused() {
  local dir out rc=0
  new_repo
  dir=$(gate_dir gate-with-dying-decider)
  # Exit 1 is the decider's refusal code, but this decider never got as far as
  # refusing: it dies under its own set -u before deciding anything. Bash's own
  # exit status for that is 1, so the code alone cannot tell the two apart.
  cat > "$dir/fm-attestation-exempt.sh" <<'DECIDER'
#!/usr/bin/env bash
set -u
printf '%s' "$never_set_by_anyone"
DECIDER
  chmod +x "$dir/fm-attestation-exempt.sh"
  out=$(run_gate "$dir/fm-attestation-gate.sh" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 2 "$rc" "exit 1 without a decision determined nothing"
  assert_contains "$out" "could not read the head" \
    "a decider that died before deciding must report an unreadable head"
  assert_not_contains "$out" "does not qualify" \
    "a refusal must never be asserted on top of a decision the gate could not parse"
  assert_not_contains "$out" "::notice::Exempt" "silence must never be read as an exemption"
  pass "a decider that exits 1 without a decision is undetermined, not a refusal"
}

test_decider_undetermined_verdict_is_reported_undetermined() {
  local out rc=0
  new_repo
  # The decider's own undetermined outcome: a head it cannot read, decided in
  # words and carried by exit 2. This is the ordinary production shape of
  # undetermined - an upstream ref the workflow could not fetch reaches the gate
  # exactly this way - and it is the case that distinguishes exit 2 from exit 1
  # while both carry a well-formed decision line.
  out=$(run_gate "$GATE" sync/upstream-x 0000000000000000000000000000000000000000) || rc=$?
  expect_code 2 "$rc" "the decider's undetermined verdict must stay undetermined"
  assert_contains "$out" "decision=unknown" "the decider's own unknown line must be reported"
  assert_contains "$out" "could not read the head" \
    "an undetermined outcome must say the gate could not read the head"
  assert_not_contains "$out" "does not qualify" \
    "undetermined must never be reported as a head that does not qualify"
  pass "a decider verdict of undetermined is reported as undetermined, not as a refusal"
}

test_non_exempt_verdict_at_exit_0_is_not_reported_exempt() {
  local dir out rc=0
  new_repo
  dir=$(gate_dir gate-with-disagreeing-decider)
  # A well-formed decision line that does not say exempt, carried by the exit
  # code that does. The two disagree, and only one of them is a decision.
  cat > "$dir/fm-attestation-exempt.sh" <<'DECIDER'
#!/usr/bin/env bash
printf 'ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=some reason\n'
exit 0
DECIDER
  chmod +x "$dir/fm-attestation-exempt.sh"
  out=$(run_gate "$dir/fm-attestation-gate.sh" sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 2 "$rc" "exit 0 without an exempt decision grants nothing"
  assert_not_contains "$out" "::notice::Exempt" \
    "an exit code alone must never be read as an exemption the decider did not state"
  assert_contains "$out" "could not read the head" \
    "a decision the gate cannot take at face value leaves the outcome undetermined"
  pass "an exit 0 whose decision line does not say exempt is undetermined, not exempt"
}

test_qualifying_head_is_reported_exempt
test_non_qualifying_head_is_reported_refused
test_decider_undetermined_verdict_is_reported_undetermined
test_non_exempt_verdict_at_exit_0_is_not_reported_exempt
test_missing_decider_is_undetermined_not_refused
test_non_executable_decider_is_undetermined_not_refused
test_silent_decider_is_not_reported_exempt
test_silent_exit_1_decider_is_undetermined_not_refused
