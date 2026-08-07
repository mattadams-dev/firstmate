#!/usr/bin/env bash
# fm-attestation-gate.sh - run the attestation exemption decider over a pull
# request head and report which of its three outcomes actually happened.
#
# Once the pull request body carries no no-mistakes marker, the workflow step
# that owns the fork's "PR must be raised via no-mistakes" check has one job:
# ask bin/fm-attestation-exempt.sh whether the head is exempt, and say what came
# back. Saying it correctly is the whole difficulty. The decider reports three
# outcomes, and a caller that maps "not exempt and not undetermined" to refused
# reports a refusal it never observed the moment the decider cannot run at all:
# a pull request that deletes or renames the decider would make such a caller
# print "the head does not qualify" on the strength of exit code 127.
#
# The mapping here is therefore exhaustive in the other direction. Exit 0 with
# an exempt decision line is exempt, exit 1 with a decision line is refused, and
# EVERYTHING else is undetermined - the decider's own 64 usage error, 126 and
# 127 from a decider that is missing or not executable, any code a later
# revision adds, and any exit at all that arrives without a decision line to
# read. Neither collapse is permitted: a head that could not be read must never
# be reported as a head that does not qualify, and must never be reported as
# exempt either.
#
# Usage:
#   fm-attestation-gate.sh check --head-ref <name> --head <ref> --base <ref> \
#       --upstream <ref> [--repo <dir>] [--pr-author <login>]
#   fm-attestation-gate.sh --help
#
#   --head-ref    head branch name as the forge reports it, without refs/heads/
#   --head        the head commit under consideration
#   --base        tip of the branch the pull request merges into
#   --upstream    tip of the upstream default branch this fork tracks
#   --repo        repository to read (default: current directory)
#   --pr-author   login to name in the report, when the caller knows it
#
# Exit codes mirror the decider: 0 exempt, 1 refused, 2 undetermined, 64 usage
# error. The decision line is echoed on stdout; the human-facing explanation
# goes to stderr as GitHub workflow annotations, and only its first line differs
# between refused and undetermined, because only its first line states a fact
# the gate observed.
#
# The decider is resolved as this script's own sibling, so the two halves of the
# gate cannot be pointed at different checkouts. docs/attestation-exemption.md
# owns the contract and the reasoning.

set -uo pipefail

SELF=$(basename "$0")
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DECIDER="$SELF_DIR/fm-attestation-exempt.sh"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit 64
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# The shared tail of both non-exempt reports: what the pipeline is, and how a
# fork sync earns its one exemption.
explain() {
  local decision=$1 pr_author=$2
  echo
  echo "$decision"
  echo
  echo "Contributions to this repository must be submitted via 'git push no-mistakes'."
  echo "That pipeline runs the required review/test/lint/CI steps and writes a"
  echo "deterministic '## Pipeline' section into the PR body containing:"
  echo
  echo "    $MARKER"
  echo
  echo "The one exemption is a fork sync: a sync/* head that is a verified true"
  echo "merge of the upstream default branch. It is decided from the commit graph"
  echo "by bin/fm-attestation-exempt.sh, never from anything typed into the PR."
  echo "See docs/attestation-exemption.md and CONTRIBUTING.md."
  if [ -n "$pr_author" ]; then
    echo
    echo "PR author: $pr_author"
  fi
}

cmd_check() {
  local head_ref='' head='' base='' upstream='' repo=. pr_author=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --head-ref) [ $# -ge 2 ] || die "--head-ref needs a value"; head_ref=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head needs a value"; head=$2; shift 2 ;;
      --base) [ $# -ge 2 ] || die "--base needs a value"; base=$2; shift 2 ;;
      --upstream) [ $# -ge 2 ] || die "--upstream needs a value"; upstream=$2; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; shift 2 ;;
      --pr-author) [ $# -ge 2 ] || die "--pr-author needs a value"; pr_author=$2; shift 2 ;;
      *) die "unknown argument '$1' (see --help)" ;;
    esac
  done
  [ -n "$head_ref" ] || die "--head-ref is required"
  [ -n "$head" ] || die "--head is required"
  [ -n "$base" ] || die "--base is required"
  [ -n "$upstream" ] || die "--upstream is required"

  # The decider's stderr is left alone so a shell-level failure to run it at all
  # ("No such file or directory", "Permission denied") stays visible in the step
  # log rather than being folded into the decision line.
  local decision='' raw=0
  decision=$("$DECIDER" check --repo "$repo" --head-ref "$head_ref" \
    --head "$head" --base "$base" --upstream "$upstream") || raw=$?

  local rc
  case "$raw" in
    0) rc=0 ;;
    1) rc=1 ;;
    *) rc=2 ;;
  esac

  # Exempt is the only outcome that lets a pull request through, so it is the
  # only one that also requires the decider to have said so in words. A decider
  # that exits 0 without deciding is a decider that could not be read.
  if [ "$rc" -eq 0 ]; then
    case "$decision" in
      'ATTESTATION_EXEMPT: decision=exempt '*) : ;;
      *)
        rc=2
        decision="ATTESTATION_EXEMPT: decision=unknown reason=the exemption decider exited 0 without an exempt decision"
        ;;
    esac
  fi
  # A decision line the gate cannot parse means nothing was determined, whatever
  # exit code carried it. A decider that dies before deciding - under its own
  # set -u, say - exits 1 and prints nothing, and 1 without a decision is not a
  # refusal: no head was ever read.
  case "$decision" in
    'ATTESTATION_EXEMPT: '*) : ;;
    *)
      rc=2
      decision="ATTESTATION_EXEMPT: decision=unknown reason=the exemption decider produced no decision (exit $raw)"
      ;;
  esac

  printf '%s\n' "$decision"

  if [ "$rc" -eq 0 ]; then
    printf '::notice::Exempt from the no-mistakes attestation: %s\n' "${decision#ATTESTATION_EXEMPT: }"
    exit 0
  fi

  {
    if [ "$rc" -eq 1 ]; then
      echo "::error::This PR was not raised through no-mistakes, and its head does not qualify for the exemption."
    else
      echo "::error::This PR was not raised through no-mistakes, and the gate could not read the head, so the exemption could not be evaluated."
    fi
    explain "$decision" "$pr_author"
  } >&2
  exit "$rc"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  -h | --help | help) usage ;;
  '') die "a subcommand is required (see --help)" ;;
  *) die "unknown subcommand '$1' (see --help)" ;;
esac
