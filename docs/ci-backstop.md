# CI backstop: what protects `main` now that strict is off

On 2026-08-05 this repository's `main` protection changed `required_status_checks.strict` from `true` to `false`.
Everything else stayed as it was: the same 12 required contexts, admin enforcement on, force pushes and deletions blocked.
Checks still have to pass; a branch merely no longer has to be up to date with `main` first.

This document owns what that traded away, what now catches the difference, and what a reader of a red `main` is expected to do.

## What was removed, and what replaced it

Strict meant every pull request was re-validated against the current `main` before it could merge.
That caught a semantic conflict between two independently-green pull requests **before** it landed: a conflict that merges cleanly as text but breaks behavior once both changes are present.

Nothing prevents that conflict now.
The replacement is **detection plus revert**, not prevention: the conflict lands, the `main` CI run that follows the merge fails, and the merge is reverted.

Naming the trade exactly, because a protection removed without naming its replacement is how a guard dies quietly:

| | Strict, before | Now |
| --- | --- | --- |
| Semantic conflict between two green PRs | prevented before merge | detected after merge, then reverted |
| Cost per landed PR | 2 pre-merge matrices, about 19 min | 1 pre-merge matrix, about 9.5 min |
| Runs that can throw a blocking false red | 2 | 1 |
| `main` can be broken | no | yes, until a revert lands |

The exact protection state before the change was captured verbatim in the fleet's private task record, so the change is precisely reversible.

## Why not a merge queue

A merge queue is the purpose-built fix for this, and it is **unavailable on this repository**.
GitHub gates it on organisation ownership: merge queues are available in public repositories owned by an organisation, or in private repositories owned by organisations on GitHub Enterprise Cloud.
This repository is owned by a user account, so neither path applies.

Two further facts, recorded so the idea is not re-proposed on the assumption that it would have been cheaper:

- A queue would not have lowered the measured pre-merge cost. A pull request must pass every required check *before* it can be queued, and the queue then runs them again on the merge group. That is two pre-merge matrices, which is what strict was already costing.
- Both required workflows trigger only on `push` and `pull_request`. A queue needs `merge_group`, and `PR must be raised via no-mistakes` reads the pull request body, which a `merge_group` event does not carry, so that required context could not report at all without being redesigned.

## What the `main` CI run does catch

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) triggers on every push to `main`, so a merge run reports the 11 required contexts that `ci.yml` owns, not all 12.
The 12th required context, `PR must be raised via no-mistakes`, comes from [`.github/workflows/no-mistakes-required.yml`](../.github/workflows/no-mistakes-required.yml), which triggers only on `pull_request` and so cannot report on a push at all.
No conflict detection is lost to that gap: it reads the pull request body for a signature, which is not something a semantic conflict can fail.
`ci.yml`'s own 12th job, `Behavior timing aggregate`, is not a required context either, so it is not counted here.

- **Latency is measured, not assumed.** The five most recent `main` push runs took 8m16s to 10m05s, mean about 9.4 minutes.
- **No detection is lost to a following merge.** `ci.yml` declares no `concurrency` group, so back-to-back merges each get their own run and none is cancelled by its successor.

So any semantic conflict that one of those 11 contexts actually exercises is detected, roughly nine to ten minutes after it lands.

## What it does not catch

Three separate gaps, and only the first is the obvious one.

**1. It cannot prevent anything.**
`main` carries the breakage from the merge until a revert lands.

**2. It only sees what the suite exercises.**
A conflict that no test, lint rule, or repo invariant covers is never detected at all.
A green `main` run means nothing in the suite disagreed, not that `main` is correct.

**3. Nothing in the tooling surfaces a red `main` to a human.**
This is the load-bearing gap, and it is a mechanism fact rather than an opinion: no script under `bin/` and no skill queries the GitHub Actions runs API at all.
The only merge-related poll, `bin/fm-pr-poll.sh`, emits exactly one `merged` line for a merged pull request and stays silent otherwise; the task then tears down.
So once a merge completed, nothing in this fleet looked at that project's CI again, and that is the condition the surfacing rule below exists to replace.

## Who actually notices, and how long that takes

Left to the tooling, the exposure window was **unbounded**, and the first reader was likely to be the wrong person holding the wrong explanation.

- **A human opens GitHub.** No bound on when.
- **The next lane discovers it, and misattributes it.** Task worktrees branch from the current default branch, so a pull request opened after a bad merge inherits the breakage and its own CI goes red. The lane sees a red on its own pull request and reasonably reads it as its own fault. That costs a human decision, and it can send a worker chasing a defect it did not cause.

This compounds with the known order-sensitive flake in the portable serial lane.
A reader of a red check must separate three possibilities rather than two: their own change, the flake, or a `main` that was already broken before they started.
Nothing in the red itself tells them which.

That unbounded window is what the surfacing rule below closes, and the bound is a property of the rule rather than a description of any particular moment.
Wherever a runtime carries that rule and follows it, a red `main` is read on the next wake-handling turn, because every such turn reads every cloned project's default branch.
The condition is evaluable rather than temporal, so a reader can test whether it applies to them: check whether the runtime doing the reading carries an `AGENTS.md` that already contains the unconditional default-branch read.
A document that has landed is not yet a rule a runtime is carrying, so merging this file does not by itself put the bound in effect for a runtime that started before it.

The trigger is every wake-handling turn, of any kind, in both always-on and away mode, and that choice is the substance of the rule rather than a detail of it.
Hanging the read on the fleet-wide heartbeat review instead would have made it a gate that a busy fleet can suppress: `bin/fm-watch.sh` absorbs a no-change heartbeat in always-on mode unless the cheap fleet-scan finds an unsurfaced captain-relevant status, and a red default branch produces no such status ([`architecture.md`](architecture.md) owns that wake classification).
A gate that could not run is indistinguishable from a gate that ran and found nothing, and always-on is the attended fast tier where changes move quickest, so that shape put the protection at its weakest exactly where it was needed most.
The residual is a latency bound rather than a suppression: a fleet with no wakes at all waits for its next wake or its next session start, but nothing absorbs or discards the read, and a busier fleet now makes it fire more often rather than less, which is the inversion of the failure it replaces.

## Revert procedure

Every task pull request lands as a squash - `bin/fm-pr-merge.sh` defaults to `--squash` - so one bad merge is exactly one commit on `main`, and the revert is tractable.

**1. Identify the offending merge.**
The failing `main` push run's head SHA is the squash commit of the pull request that broke it.

```
gh-axi api "repos/<owner>/<repo>/actions/workflows/ci.yml/runs?branch=main&event=push&per_page=5" \
  --jq '.workflow_runs[] | "\(.id) \(.head_sha) \(.status) \(.conclusion // "unknown") \(.run_started_at) \(.updated_at)"'
```

**2. Do not use `gh-axi pr revert <n>` here.**
It exists, and on this repository it produces a pull request that cannot merge.
A revert pull request it creates is authored by the token's user, and `PR must be raised via no-mistakes` is one of the 12 required contexts.
That check passes only when the pull request body carries the no-mistakes signature, and it skips only `github-actions[bot]` and `dependabot[bot]` authors.
Admin enforcement is on, so nobody can bypass it.
The revert pull request would sit open and unmergeable.

**3. Dispatch the revert as an ordinary `no-mistakes` ship task.**
Brief it as a revert of one named commit.
The pipeline then produces a properly signed pull request that can pass all 12 contexts and merge, at the cost of one full pipeline plus about 9.5 minutes of CI - the same as any other change.

**4. The reverted lane's work is not lost.**
`delete_branch_on_merge` is false, so the branch survives the revert.
Re-dispatch that lane as a new task that starts from the reverted `main` and resolves the conflict.
Do not reopen the merged pull request.

**5. Validate the revert on `main`, not only on its own pull request.**
The revert's own run proves the revert builds.
Treat `main` as recovered only when the `main` push run that follows the revert is green, because another merge can land between the two.

## Surfacing: a red `main` gets a Bridge line

**Decision: yes, and it is `critical`.**

With strict off, the `main` run is the only thing that catches a semantic conflict at all.
A red `main` blocks the fleet in the ordinary sense of that word: every lane that starts afterwards inherits it, and every lane already running gets a red on its next push.
Leaving that to be found by whichever worker pushes next is exactly the failure of an instrument that knows something and reports it where nobody reads.

**When the check happens matters.**
A merged-pull-request wake arrives at merge time, and the `main` run for that merge has not concluded yet - it needs about 9.4 minutes.
Reading it at that moment returns "in progress", which is a third outcome and must never be reported as green.
The check therefore belongs to every wake-handling turn rather than to that one wake: every turn reads every cloned project's default branch unconditionally, so a run that was unknown stays unknown, is never folded into green, and is simply read again on the next turn until it concludes.

**Reading unconditionally is what makes the unknown safe.**
Restricting the read to projects that landed work since the previous turn would drop that third outcome on the floor: a merge landing shortly before a turn is read as "in progress", so no item opens, and at the next turn nothing has landed since, so nobody looks again and a red `main` stays invisible indefinitely.
An unconditional read is stateless, so nothing is carried between turns and nothing can be carried wrongly.
It is idempotent: a re-read costs one API call and changes nothing when the answer has not moved.
And it makes an unconcluded run self-healing by construction rather than by anyone remembering to look again, because the run that was in progress last time is simply read again this time.

**Deliberately not built:** no new watcher, poll, script, state file, or remembered marker for a run previously read as unconcluded.
Remembered state is the more fragile shape for an identical outcome.
This is a procedure step on wakes that already happen, because the fleet already handles every wake in a turn.

## How a `main` run result is read

This format is doctrine, and it binds every reading of a default branch's CI result, including any check ever built to perform one.
Each clause names the mistake it prevents, because the failure mode here is not a missing reading but a reading that quietly reports an unknown as an answer.

- **Five fields per run, plus the read-time of the reading itself.** Never prose.
- **The five are `id`, `sha`, `status`, `conclusion`, and both timestamps**, the run's start and its completion.
- **Only a `completed` run contributes a verdict.** Every other run is named as unknown: not omitted, and never folded into the concluded count. An omitted run reads as though it does not exist, and a counted one reads as green.
- **The freshness stamp is the newest concluded run's completion time, never a run's creation or start time.** That substitution is what produced the first defective reading of this kind: stamping the reading with a run that had not finished folded an in-progress run into a concluded-success count.
- **A verdict line carries both the evidence-time and the read-time.** They are different facts, and the gap between them is what tells a reader how stale the verdict is.

Any check built to this rule inherits every clause above.
Its acceptance test must include a run that is still in flight at read time, and that case must yield pending and never green.

## Maintaining this file

Keep this file to what protects `main`, what that protection cannot see, and what a reader of a red `main` does about it.
Update the measured latency figures when the CI shape changes, and re-state the trade table if any part of the protection changes again.
If a mechanism is ever added that actively surfaces a red `main`, replace the "nothing surfaces it" finding rather than leaving both claims in the file.
