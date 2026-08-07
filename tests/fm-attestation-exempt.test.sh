#!/usr/bin/env bash
# Behavior tests for fm-attestation-exempt.sh, the fork's attestation-gate
# exemption.
#
# The exemption exists because the fork's "PR must be raised via no-mistakes"
# check is red by construction for a sync: a true merge of upstream can never
# carry a no-mistakes marker. It must therefore be decided from properties of
# the head itself, and it is guard-class in three directions at once:
#
#   - a head that does not qualify must still be refused;
#   - a sync/*-named head that is NOT a true merge of upstream must still be
#     refused, because name-only trust is the whole hazard;
#   - the exemption must actually fire for a real sync. A mutant that makes it
#     never apply leaves the standing admin bypass in place, which is the
#     failure this closes, so the qualifying cases below are as load-bearing as
#     the refusals.
#
# Each test drives the real script over a real commit graph, so a mutation to
# any single verified property breaks exactly the test that names it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-attestation-exempt.sh"
TMP_ROOT=$(fm_test_tmproot fm-attestation-exempt-tests)
REPO_N=0

# --- fixtures ---------------------------------------------------------------

# new_repo: a repo whose history has diverged the way a fork's does. Sets the
# globals REPO and DEFAULT_BRANCH (an assignment made in a command substitution
# would be lost with the subshell).
#
#   c0                     shared root, with clean.txt and shared.txt
#    |- <default>          fork side:     shared.txt -> "fork",   adds fork.txt
#    \- upstream-main      upstream side: shared.txt -> "up",     adds up.txt
#
# shared.txt conflicts on merge; clean.txt, fork.txt and up.txt do not. That
# split is the point: the exemption tolerates resolution content only inside the
# paths git could not resolve, so the fixture must have both kinds.
new_repo() {
  REPO_N=$((REPO_N + 1))
  REPO="$TMP_ROOT/repo-$REPO_N"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf 'clean\n' > "$REPO/clean.txt"
  printf 'root\n' > "$REPO/shared.txt"
  git -C "$REPO" add clean.txt shared.txt
  git -C "$REPO" commit -qm root
  DEFAULT_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)

  git -C "$REPO" checkout -q -b upstream-main
  printf 'up\n' > "$REPO/shared.txt"
  printf 'up\n' > "$REPO/up.txt"
  git -C "$REPO" add shared.txt up.txt
  git -C "$REPO" commit -qm upstream-work

  git -C "$REPO" checkout -q "$DEFAULT_BRANCH"
  printf 'fork\n' > "$REPO/shared.txt"
  printf 'fork\n' > "$REPO/fork.txt"
  git -C "$REPO" add shared.txt fork.txt
  git -C "$REPO" commit -qm fork-work
}

# merge_upstream_onto <branch> [smuggle]: branch sync/upstream-x off <branch>,
# merge upstream-main, and commit. A conflict is resolved the way a real sync
# resolves one - a union of both sides, which is content that appears verbatim
# in neither parent. A merge that did NOT conflict is committed untouched, so
# the conflict-free fixture stays honest. With `smuggle`, also edit clean.txt,
# a path the merge resolved without conflict.
#
# The fixture checks its own precondition: if a case that must conflict merges
# cleanly, the failure names the fixture rather than the product.
merge_upstream_onto() {
  local from=$1 smuggle=${2:-} rc=0
  git -C "$REPO" checkout -q -b sync/upstream-x "$from"
  git -C "$REPO" merge --no-commit --no-ff upstream-main >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'fork\nup\nreconciled\n' > "$REPO/shared.txt"
    git -C "$REPO" add shared.txt
  fi
  if [ -n "$smuggle" ]; then
    printf 'smuggled\n' > "$REPO/clean.txt"
    git -C "$REPO" add clean.txt
  fi
  git -C "$REPO" commit -qm 'Merge upstream into fork main (sync)'
  MERGE_CONFLICTED=$rc
}

# gate <head-ref> <head> [base] [upstream]: run the real script over $REPO, echo
# its decision line, and return its exit code.
gate() {
  local ref=$1 head=$2 base=${3:-$DEFAULT_BRANCH} up=${4:-upstream-main}
  "$GATE" check --repo "$REPO" --head-ref "$ref" --head "$head" --base "$base" --upstream "$up"
}

# --- the exemption must fire (mirror trap) ----------------------------------

test_conflicted_true_merge_sync_head_is_exempt() {
  local out rc=0
  new_repo
  merge_upstream_onto "$DEFAULT_BRANCH"
  [ "$MERGE_CONFLICTED" -ne 0 ] ||
    fail "fixture: the diverged sync merge was expected to conflict and did not"
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 0 "$rc" "a real conflicted sync must be exempt"
  assert_contains "$out" "decision=exempt" "a real conflicted sync must be exempt"
  assert_contains "$out" "class=sync-true-merge" "the exempting class must be named"
  # The one conflicted path is reported as the residual unattested surface.
  assert_contains "$out" "resolved_paths=1" "the conflicted path count must be reported"
  pass "a sync/* head that is a true merge of upstream, conflicts and all, is exempt"
}

test_clean_true_merge_sync_head_is_exempt() {
  local out rc=0
  new_repo
  # Drop the fork-side divergence in shared.txt so the merge resolves cleanly.
  printf 'root\n' > "$REPO/shared.txt"
  git -C "$REPO" commit -qam un-diverge
  merge_upstream_onto "$DEFAULT_BRANCH"
  [ "$MERGE_CONFLICTED" -eq 0 ] ||
    fail "fixture: the un-diverged sync merge was expected to be clean and conflicted"
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 0 "$rc" "a conflict-free sync must be exempt too"
  assert_contains "$out" "decision=exempt" "a conflict-free sync must be exempt too"
  assert_contains "$out" "resolved_paths=0" "a conflict-free sync resolves no paths by hand"
  pass "a sync/* head that merges upstream with no conflicts at all is exempt"
}

# --- the exemption must refuse ----------------------------------------------

test_sync_head_smuggling_into_an_unconflicted_path_is_refused() {
  local out rc=0
  new_repo
  merge_upstream_onto "$DEFAULT_BRANCH" smuggle
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "a sync carrying its own change must be refused"
  assert_contains "$out" "decision=refused" "a sync carrying its own change must be refused"
  assert_contains "$out" "clean.txt" "the refusal must name the smuggled path"
  pass "a correctly shaped sync/* merge that also edits a cleanly merged path is refused"
}

test_non_sync_branch_that_is_a_true_merge_is_refused() {
  local out rc=0
  new_repo
  merge_upstream_onto "$DEFAULT_BRANCH"
  # Identical head, identical graph - only the branch name differs.
  out=$(gate feature/x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "a true merge outside sync/* must still be refused"
  assert_contains "$out" "decision=refused" "a true merge outside sync/* must still be refused"
  assert_contains "$out" "is not sync/*" "the refusal must name the branch as the reason"
  pass "a head that is a true merge of upstream but is not on sync/* is refused"
}

test_sync_named_non_merge_head_is_refused() {
  local out rc=0
  new_repo
  git -C "$REPO" checkout -q -b sync/upstream-x "$DEFAULT_BRANCH"
  printf 'hand written\n' > "$REPO/clean.txt"
  git -C "$REPO" commit -qam 'ordinary change wearing a sync name'
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "an ordinary commit on a sync/* branch must be refused"
  assert_contains "$out" "decision=refused" "an ordinary commit on a sync/* branch must be refused"
  assert_contains "$out" "parent" "the refusal must name the missing merge shape"
  pass "an ordinary single-parent commit on a sync/*-named branch is refused"
}

test_sync_head_merging_something_other_than_upstream_is_refused() {
  local out rc=0
  new_repo
  # A merge of the right shape whose merged parent is a local branch upstream
  # has never seen - the forgery a name-only check would wave through.
  git -C "$REPO" checkout -q -b interloper "$DEFAULT_BRANCH"
  printf 'interloper\n' > "$REPO/clean.txt"
  git -C "$REPO" commit -qam interloper
  git -C "$REPO" checkout -q -b sync/upstream-x "$DEFAULT_BRANCH"
  git -C "$REPO" merge -q --no-ff -m 'Merge (not upstream)' interloper
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "merging a non-upstream branch must be refused"
  assert_contains "$out" "decision=refused" "merging a non-upstream branch must be refused"
  assert_contains "$out" "upstream-side" "the refusal must name the parent test"
  pass "a sync/* merge whose merged parent is not in upstream's history is refused"
}

test_sync_head_whose_other_parent_is_unlanded_is_refused() {
  local out rc=0
  new_repo
  # Upstream merged correctly, but onto unlanded work rather than the base
  # branch, so the head carries commits the base has never accepted.
  git -C "$REPO" checkout -q -b unlanded "$DEFAULT_BRANCH"
  printf 'unlanded\n' > "$REPO/clean.txt"
  git -C "$REPO" commit -qam unlanded
  merge_upstream_onto unlanded
  out=$(gate sync/upstream-x sync/upstream-x) || rc=$?
  expect_code 1 "$rc" "a sync built on unlanded work must be refused"
  assert_contains "$out" "decision=refused" "a sync built on unlanded work must be refused"
  assert_contains "$out" "base-side" "the refusal must name the parent test"
  pass "a sync/* merge whose other parent is not on the base branch is refused"
}

# --- unknown is its own outcome ---------------------------------------------

test_unreadable_head_is_undetermined_not_refused() {
  local out rc=0
  new_repo
  out=$(gate sync/upstream-x 0000000000000000000000000000000000000000) || rc=$?
  expect_code 2 "$rc" "an unreadable head is undetermined, not refused"
  assert_contains "$out" "decision=unknown" "an unreadable head is undetermined, not refused"
  assert_not_contains "$out" "decision=refused" "undetermined must never render as refused"
  pass "a head the gate cannot read reports undetermined rather than a refusal"
}

test_conflicted_true_merge_sync_head_is_exempt
test_clean_true_merge_sync_head_is_exempt
test_sync_head_smuggling_into_an_unconflicted_path_is_refused
test_non_sync_branch_that_is_a_true_merge_is_refused
test_sync_named_non_merge_head_is_refused
test_sync_head_merging_something_other_than_upstream_is_refused
test_sync_head_whose_other_parent_is_unlanded_is_refused
test_unreadable_head_is_undetermined_not_refused
