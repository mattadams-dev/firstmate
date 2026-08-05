# Merge queue unavailable - Option A vs Option B decision record

Companion record to the Lavish decision surface (`.lavish/merge-queue-decision.html`, gitignored).
All figures read 2026-08-05. Nothing was executed: no transfer, no protection change, no ruleset
change, no workflow change.

## Verdict

Merge queue is UNAVAILABLE on mattadams-dev/firstmate. See `.evidence/availability-read.md`.

Ruleset UI look (captain's named surface): TAKEN, and it could not answer. chrome-devtools-axi
against github.com/mattadams-dev/firstmate/settings/rules returned GitHub's signed-out 404 with a
"Sign in" link, not the ruleset editor. The only browser on this machine is an anonymous headless
Chromium with no GitHub session; exactly one cookie store exists on the box and it is signed out.
Reaching the editor needs a logged-in web session, a credential I do not have.

## Cost per landed PR, against the measured baseline

Baseline: 12 required contexts, ~9.5 min per matrix, 3 of 3 PRs paid it twice.
Main push runs measured 8m16s-10m05s over the five most recent, mean ~9.4 min.

| Per landed PR | on PR | forced re-runs | queue | main after landing | matrices | minutes |
| --- | --- | --- | --- | --- | --- | --- |
| Today (strict on) | 1 | 1 measured; k-th of k lanes pays k-1 | - | 1 | 3, rising | ~28 |
| A: merge queue | 1 | 0 | 1 | 1 | 3, flat | ~28 |
| B: drop strict | 1 | 0 | - | 1 | 2, flat | ~19 |

THE NUMBER THAT CHANGES THE FRAMING: Option A does not reduce the measured 19-minute pre-merge cost
at the observed cadence. A queue requires the PR to pass every required check BEFORE it can be
queued, then runs them again on the merge group - two pre-merge matrices, exactly what strict costs
today. GitHub's wording: "Once a pull request has passed all required branch protection checks, a
user with write access to the repository can add the pull request to the queue."

A buys a cap under concurrency plus an unbreakable main. B is the only one that lowers the number.
Runs that can throw a blocking false red, per PR: today 2, A 2, B 1.

## Option A - concrete transfer inventory (every row read, not assumed)

| What | Current | Transfer effect |
| --- | --- | --- |
| origin + fork remotes | ssh://git@github.com-personal/mattadams-dev/firstmate.git | REPOINT. One edit covers all 10 worktrees (shared .git). Old URLs redirect meanwhile |
| upstream remote | https://github.com/kunchenguid/firstmate.git | UNAFFECTED |
| SSH alias | Host github.com-personal -> github.com, id_ed25519_personal | UNAFFECTED. Alias binds a key to a host, not an owner; only the owner path changes |
| no-mistakes fork config | bare ~/.no-mistakes/repos/c5e834eacdf2.git, remote.origin.url = fork URL | REPOINT. One config edit. This is the pipeline's push target |
| Tracked material | ZERO occurrences of "mattadams-dev" in bin/, .agents/, skills/, docs/, .github/, root md | NO CODE CHANGE |
| Actions secrets / variables | 0 and 0 | Nothing to migrate |
| Open PRs | 1 (#12) | Transferred with the repo |
| Fork status | fork of kunchenguid/firstmate (public, not archived) | Transferable; association preserved. Private-upstream bar does not apply |
| Receiving org | none exists | Must hold no same-name repo and no fork in the same network. Free org suffices; no plan qualifier for public org repos |
| Redirects | - | Clone/fetch/push redirect, BUT creating any new repo or fork at the old location permanently deletes them |
| Branch protection | strict, 12 contexts, enforce_admins on | UNKNOWN whether classic protection survives; re-read and reapply after |
| API token | works on the user-owned repo | UNKNOWN whether it needs org authorisation |
| Ownership | outright | Original owner becomes a collaborator |

Work remaining after the transfer:
1. Neither workflow triggers on merge_group; both fire only on push/pull_request. The queue waits on
   checks that never report.
2. UNSOLVED: "PR must be raised via no-mistakes" is one of the 12 required contexts (confirmed from
   the protection API) and reads github.event.pull_request.body. On merge_group there is no pull
   request in the payload, so it cannot run as written. It must be rebuilt to resolve the PR from
   the merge-group ref, or dropped from required - and dropping it removes the guard forcing every
   contribution through the pipeline.
3. That workflow keys concurrency on the PR number with cancel-in-progress: true. On merge_group the
   number is empty, so every merge group would share one group and cancel its predecessor.

## Option B - what main-CI-plus-revert detects and cannot

Detects: any semantic conflict covered by one of the 12 contexts. Latency measured at ~9.4 min mean.
No detection is lost to a following merge: ci.yml declares NO concurrency group, so back-to-back
merges each get their own main run and none is cancelled (verified by reading the workflow).

Cannot: prevent anything - main is broken from merge until a revert lands. Cannot see a conflict no
test, lint rule or invariant covers; that lands silently and stays. Realistic exposure ~9.4 min to
red, plus notice, plus revert and another ~9.4 min - roughly 20-30 min of red main. All lanes edit
bin/, so textual merges succeed while semantics can collide.

Base rate from this repo: 13 main push runs, 12 success, 1 failure (run #5, 2026-07-31, job
"Behavior portable serial"). UNKNOWN whether that was a semantic conflict or the known flaky shard -
the job name predates the four-way shard split and there is no re-run on that commit to
discriminate. So zero CONFIRMED semantic-conflict breakages in 13 merges, and one unexplained red.

## Unknowns, stated rather than guessed

1. Whether the live ruleset UI matches the docs - no signed-in browser here. COULD OVERTURN THE VERDICT.
2. Whether classic branch protection survives a transfer - docs silent.
3. Whether the current API token keeps access once the repo is org-owned - no org to test against.
4. How "PR must be raised via no-mistakes" would report on merge_group - undesigned, load-bearing for A.
5. Whether main run #5 was a semantic conflict or the known flake.
6. This repo's true semantic-conflict rate - never measured; 13 merges is a thin sample.

## Where the evidence points (the captain rules; nothing executed)

A buys an unbreakable main and a cost that stops growing under concurrency, but does not lower
today's bill, costs an org transfer with two open unknowns, and is blocked behind a required check
that cannot run on merge_group as written.

B is the only one that lowers the measured number - about 19 min to about 9.5 - halves flake
exposure, and needs no transfer and no workflow change, trading pre-merge prevention for post-merge
detection in a measured ~9.4-minute window against a history with zero confirmed breakages.

The judgement is whether a briefly-broken main is acceptable. If yes, B is strictly cheaper and
available today. If no, A is the only path to the guarantee and should be scheduled as a project.

Overriding caveat: all of this assumes the availability verdict holds. A signed-in look at the
ruleset UI showing a merge-queue option voids this page.
