# Merge queue availability read - mattadams-dev/firstmate - 2026-08-05

## Verdict: UNAVAILABLE

## Discriminating fact, read live from GitHub's own documentation 2026-08-05

Quoted verbatim, identical on two independent pages:

> Pull request merge queues are available in any public repository owned by an organization,
> or in private repositories owned by organizations using GitHub Enterprise Cloud.

Sources (both read anonymously, both returned the same sentence):
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/merging-a-pull-request-with-a-merge-queue

Both documented paths require an ORGANIZATION owner. Neither covers a User-owned repository.

## Repository facts, read from the API 2026-08-05

    GET /repos/mattadams-dev/firstmate
      owner.login: mattadams-dev
      owner.type:  User          <- fails the organization requirement
      visibility:  public
      fork:        true

## Why this read discriminates where the earlier probe did not

The earlier probe used the merge-queue API endpoint, which returns 404 both when the feature is
unavailable and when it is merely unconfigured. That reading cannot separate the two worlds.
This read separates them on the axis that actually decides the question - owner type - by
comparing a fact about the repository (owner.type = User) against GitHub's stated requirement
(owner must be an organization). Both states are directly observed, neither is inferred.

## What I could NOT establish, stated as unknown rather than guessed

The captain named the ruleset settings UI as the surface to look at. I could not reach it.
The only browser on this machine is an anonymous headless Chromium; the GitHub session is logged
out, so https://github.com/mattadams-dev/firstmate/settings/rules returns GitHub's 404 page for
signed-out visitors rather than the ruleset editor. Reaching that surface needs a logged-in
GitHub web session, which is a credential I do not have and did not attempt to obtain.

So the verdict rests on documentation plus observed owner type, NOT on seeing the option absent
in the UI. I did not substitute the ambiguous API probe for the UI look, and I did not attempt a
ruleset write to test acceptance, because that would have been a configuration change.

Confidence: high on the documented rule and on owner.type. The residual gap is whether GitHub's
live UI diverges from its own current documentation - unknown, and only the UI look would close it.
