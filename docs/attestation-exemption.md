# The attestation gate and its one exemption

Audience: maintainer-architecture.
Mechanism owner: `bin/fm-attestation-exempt.sh` (header and `--help`).
Gate owner: [`.github/workflows/no-mistakes-required.yml`](../.github/workflows/no-mistakes-required.yml).
Measurements: [`docs/verification/attestation-exemption.md`](verification/attestation-exemption.md).
Contributor-facing entry point: [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## What the gate is

`PR must be raised via no-mistakes` is a required status check on `main`, with `enforce_admins` on.
It matches the deterministic signature that the no-mistakes pipeline writes into a pull request body.
A PR without that signature is red, and because admins are enforced, red means unmergeable.

## The problem the exemption closes

A fork sync cannot satisfy that check and never will be able to.
A true merge of upstream is not a no-mistakes-authored change, so the signature it would need does not exist for it.
The check is therefore red **by construction** for the one procedure that keeps this fork current, and the only remaining route to land a sync is to disarm a required check by hand, on a schedule.
A protection switched off on a schedule is how safety checks die slowly, so unlocking protection per merge was rejected outright and no standing bypass machinery exists here.

## The shape of the exemption, and the constraint it obeys

The exemption is a property of the head being merged, checkable by the gate itself.
It is not a flag, a trailer, a commit signature, an author role, or a review.
None of those are properties of the change, and each is an authority to skip rather than a reason the change does not need the pipeline.

`bin/fm-attestation-exempt.sh` grants class `sync-true-merge` when all of:

1. the head branch is named `sync/*`;
2. the head has exactly two parents;
3. one parent is already contained in the upstream default branch's history;
4. the other parent is already contained in the base branch's history;
5. every path where the head's tree differs from a clean re-merge of those two parents is a path that the re-merge itself could not resolve.

Condition 5 is load-bearing and condition 1 is not.
A branch name is trivially forgeable and is never trusted on its own; it scopes the exemption to heads that meant to claim it, and every other condition still runs.
Condition 5 is what makes the whole thing a fact rather than a claim: it proves the sync introduced no content of its own outside the regions git could not merge, and it is forgeable only by actually performing the merge.
Condition 2 is what stops a sync branch from carrying hand-authored commits on top of the merge, and conditions 3 and 4 are what stop a correctly shaped merge of the wrong two things - unlanded work, or a branch upstream has never seen.

## The residual surface, stated rather than hidden

Conflict resolutions are content that exists in neither parent.
The exemption does not constrain them, because a stricter rule was measured against the fork's only real sync and would have made the exemption never fire - and an exemption that never fires leaves the manual bypass exactly where it was.
The gate reports the conflicted paths as `resolved_paths=<n>` instead, so the residual unattested surface is a number a reviewer can see.
That surface is bounded on its own: it is exactly the set of files where the fork and upstream have both diverged, and fork-side divergence can only have arrived through this same gate.

## Outcomes are three, not two

The script exits 0 exempt, 1 refused, 2 undetermined.
Refused means the head was read and does not qualify; undetermined means it could not be read at all - no upstream parent, an absent commit, a merge git could not replay.
Both leave the attestation in force, and the workflow says which one happened.
Collapsing undetermined into either direction would report a fact the gate never observed.

## What is deliberately not exempt, and why

The attended fast path - a small change authored directly, with no worker and no pipeline round - has **no exemption here**, and this is a finding rather than an omission.

"Attended" is a property of the authoring session, not of the commit.
Two byte-identical heads, one hand-authored under supervision and one generated unattended, are indistinguishable to any gate that reads the repository.
Every candidate property splits into one of two groups, and neither qualifies:

- **Identity and authority** - a commit signature, an author association, a review approval.
  Each is checkable, but each says who may skip rather than why this change does not need the pipeline.
  That is the rejected shape in a smaller package.
- **Size and surface** - a line ceiling, a file allowlist, a docs-only rule.
  Each is checkable and non-assertable, but none tracks attendance at all: they would exempt an unattended head of the same shape just as readily.
  They are also poor risk bounds here, since the specimen that raised the question was six lines inside `bin/`.

There is also a structural asymmetry that the sync case does not share.
A hand-authored change **can** satisfy the gate by being pushed through the pipeline; it is slower, not impossible.
Only the sync is red by construction, so only the sync needs an exemption in order to be landable at all.

## Scope of the guarantee

This workflow runs on `pull_request`, from the head's own copy of the repository, so a head that edits the workflow or the script changes what runs.
That is equally true of the marker check it replaces and is not narrowed here.
The gate is a procedural guarantee against routine erosion, not an adversarial control, and the exemption is built to be honest and non-decorative within that scope rather than to survive an attacker who already controls the branch.
