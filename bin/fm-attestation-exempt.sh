#!/usr/bin/env bash
# fm-attestation-exempt.sh - decide, from the commit graph alone, whether a pull
# request head is exempt from the fork's "PR must be raised via no-mistakes"
# attestation check.
#
# The attestation check matches a marker string in the PR body. A fork sync can
# never carry that marker: a true merge of upstream is not a no-mistakes-authored
# change and never can be, so the check is red by construction for the one
# procedure that keeps the fork current. The only remaining route to land a sync
# is an admin bypass, which means routinely disarming a required check.
#
# This script closes that without adding a bypass. It grants the exemption only
# from properties of the head being merged, checkable here and forgeable only by
# actually performing the merge - never from a typed flag, a signature, a role,
# or a review. docs/attestation-exemption.md owns the contract and the reasoning;
# docs/verification/attestation-exemption.md holds the measurements behind this
# exact formulation, including the two stricter formulations that a real fork
# sync refuses.
#
# Usage:
#   fm-attestation-exempt.sh check --head-ref <name> --head <sha> \
#       --base <sha> --upstream <sha> [--repo <dir>]
#   fm-attestation-exempt.sh --help
#
#   --head-ref   head branch name as the forge reports it, without refs/heads/
#   --head       the head commit under consideration
#   --base       tip of the branch the pull request merges into
#   --upstream   tip of the upstream default branch this fork tracks
#   --repo       repository to read (default: current directory)
#
# Output is exactly one line on stdout:
#   ATTESTATION_EXEMPT: decision=exempt class=sync-true-merge base_parent=<sha> upstream_parent=<sha> resolved_paths=<n>
#   ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=<text>
#   ATTESTATION_EXEMPT: decision=unknown reason=<text>
#
# Exit codes: 0 exempt, 1 refused, 2 undetermined, 64 usage error. Refused and
# undetermined are deliberately distinct: refused means the head was read and
# does not qualify, undetermined means the head could not be read at all. Both
# leave the attestation in force, and neither may be reported as the other.
#
# THE PROPERTY VERIFIED, for class sync-true-merge. All of:
#   1. the head branch is named sync/*;
#   2. the head has exactly two parents;
#   3. one parent is already contained in the upstream default branch's history;
#   4. the other parent is already contained in the base branch's history;
#   5. every path where the head's tree differs from a clean re-merge of those
#      two parents is a path that the re-merge itself could not resolve.
#
# (5) is the load-bearing one. It proves the sync introduced no content of its
# own outside the regions git could not merge, so the residual unattested
# surface is the set of files where upstream and the head's chosen base-side
# ancestor have both diverged. (4) accepts any ancestor of the base branch
# rather than its tip - deliberately, since requiring the tip would refuse a
# legitimate sync whenever the base advances while its pull request is open - so
# an older ancestor can widen that set. Both sides of the divergence are still
# content that already landed; only the resolutions between them are
# unconstrained. docs/attestation-exemption.md states the bound in full. (1) is not
# security, it is scope: a branch name is trivially forgeable and is never
# trusted on its own, but it keeps the exemption from reaching heads that were
# never meant to claim it. (2) is what stops a sync branch from carrying extra
# hand-authored commits on top of the merge.
#
# Deliberately NOT verified: that the resolutions inside conflicted paths copy
# one side. Measured against the fork's only real sync, two of 3,919 resolved
# lines are genuinely novel and legitimately so, so that rule would make the
# exemption never fire. The conflicted paths are counted and reported rather
# than constrained.
#
# A path whose name contains a newline is split by the line-oriented comparison
# below. Both sides split it identically, so a real sync still matches; a
# mismatch can only push the decision toward refusal, never toward exemption.

set -uo pipefail

SELF=$(basename "$0")
REPO=.

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit 64
}

# One decision line, then the matching exit code. Every exit from `check` goes
# through here, so no silent path can leave the caller reading a pass.
decide() {
  local decision=$1
  shift
  printf 'ATTESTATION_EXEMPT: decision=%s %s\n' "$decision" "$*"
  case "$decision" in
    exempt) exit 0 ;;
    refused) exit 1 ;;
    *) exit 2 ;;
  esac
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# contains <candidate> <tip>: true when <candidate> is <tip> or one of its
# ancestors, i.e. <candidate> is already part of that branch's history.
contains() {
  git -C "$REPO" merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

cmd_check() {
  local head_ref='' head='' base='' upstream=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --head-ref) [ $# -ge 2 ] || die "--head-ref needs a value"; head_ref=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head needs a value"; head=$2; shift 2 ;;
      --base) [ $# -ge 2 ] || die "--base needs a value"; base=$2; shift 2 ;;
      --upstream) [ $# -ge 2 ] || die "--upstream needs a value"; upstream=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO=$2; shift 2 ;;
      *) die "unknown argument '$1' (see --help)" ;;
    esac
  done
  [ -n "$head_ref" ] || die "--head-ref is required"
  [ -n "$head" ] || die "--head is required"
  [ -n "$base" ] || die "--base is required"
  [ -n "$upstream" ] || die "--upstream is required"

  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 ||
    decide unknown "reason=not a git repository: $REPO"

  local ref
  for ref in "$head" "$base" "$upstream"; do
    git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 ||
      decide unknown "reason=commit not present locally: $ref"
  done

  # (1) scope. Never trusted alone; every check below still runs.
  case "$head_ref" in
    sync/*) : ;;
    *) decide refused "class=sync-true-merge reason=head branch '$head_ref' is not sync/*" ;;
  esac

  # (2) exactly two parents.
  local parents_line
  parents_line=$(git -C "$REPO" rev-list --parents -n1 "$head" 2>/dev/null) ||
    decide unknown "reason=could not read the parents of $head"
  # rev-list --parents prints "<commit> <parent>...", so drop the commit itself.
  local -a parents=()
  read -r -a parents <<< "${parents_line#* }"
  if [ "${#parents[@]}" -ne 2 ]; then
    decide refused "class=sync-true-merge reason=head has ${#parents[@]} parent(s), a true merge has exactly 2"
  fi

  # (3) and (4). One parent must already be in upstream's history and the other
  # in the base branch's, under some assignment. A parent satisfying both is
  # fine; what is refused is a head for which no assignment works, which is
  # every head that merged in something neither side had already accepted.
  local base_parent upstream_parent
  if contains "${parents[1]}" "$upstream" && contains "${parents[0]}" "$base"; then
    base_parent=${parents[0]} upstream_parent=${parents[1]}
  elif contains "${parents[0]}" "$upstream" && contains "${parents[1]}" "$base"; then
    base_parent=${parents[1]} upstream_parent=${parents[0]}
  else
    decide refused "class=sync-true-merge reason=parents are not one upstream-side and one base-side commit"
  fi

  # (5) re-merge the two parents and require the head to add nothing outside
  # what git itself could not resolve.
  local work
  work=$(mktemp -d) || decide unknown "reason=could not create a working directory"
  # shellcheck disable=SC2064 # expand work now; the dir must be removed on any exit
  trap "rm -rf '$work'" EXIT

  # -z output holds NUL bytes, which a command substitution would strip, so the
  # re-merge is read from a file rather than a variable.
  local rc=0
  git -C "$REPO" merge-tree --write-tree -z --name-only \
    "$base_parent" "$upstream_parent" > "$work/merged" 2>/dev/null || rc=$?
  # merge-tree reports 0 clean and 1 conflicted; anything else means it could not
  # run the merge at all, which is undetermined rather than a refusal.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    decide unknown "reason=git merge-tree could not re-merge the parents (exit $rc)"
  fi

  # The NUL-separated fields are: the merged tree, each conflicted path, an empty
  # field, then informational records. Stop at the empty field so an
  # informational record is never read as a path the head may freely change.
  local auto_tree='' field first=1
  : > "$work/conflicted"
  while IFS= read -r -d '' field; do
    if [ "$first" = 1 ]; then
      auto_tree=$field
      first=0
      continue
    fi
    [ -n "$field" ] || break
    printf '%s\n' "$field" >> "$work/conflicted"
  done < "$work/merged"

  git -C "$REPO" rev-parse --verify --quiet "${auto_tree:-missing}^{tree}" >/dev/null 2>&1 ||
    decide unknown "reason=git merge-tree did not return a usable tree"

  local head_tree
  head_tree=$(git -C "$REPO" rev-parse --verify --quiet "$head^{tree}") ||
    decide unknown "reason=could not read the head tree"

  git -C "$REPO" diff --name-only -z "$auto_tree" "$head_tree" 2>/dev/null > "$work/diffz" ||
    decide unknown "reason=could not diff the head against the re-merge"
  tr '\0' '\n' < "$work/diffz" > "$work/changed"

  LC_ALL=C sort -u "$work/conflicted" > "$work/allowed"
  LC_ALL=C sort -u "$work/changed" > "$work/touched"

  local stray
  stray=$(LC_ALL=C comm -23 "$work/touched" "$work/allowed" | head -3 | tr '\n' ' ')
  if [ -n "${stray// /}" ]; then
    decide refused "class=sync-true-merge reason=head changes paths the re-merge resolved cleanly: ${stray% }"
  fi

  local resolved
  resolved=$(wc -l < "$work/allowed" | tr -d ' ')
  decide exempt "class=sync-true-merge base_parent=$base_parent upstream_parent=$upstream_parent resolved_paths=$resolved"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  -h | --help | help) usage ;;
  '') die "a subcommand is required (see --help)" ;;
  *) die "unknown subcommand '$1' (see --help)" ;;
esac
