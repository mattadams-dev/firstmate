---
name: validation-supersession
description: >-
  Use when a captain instruction completely invalidates work already inside an active no-mistakes run, before the worker aborts, touches the branch, or starts a second run.
  Owns the abort, custody, pre-invalidation base, and validate-once sequence.
user-invocable: false
metadata:
  internal: true
---

# validation-supersession

This procedure runs only in the narrow case `AGENTS.md` section 7 names: a current, explicit captain instruction completely invalidates the work being validated, and that keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.

Anything less than complete invalidation is not this case.
A new requirement, a correction inside accepted intent, or a downstream fix stays with the ordinary validation rules and never reaches this skill.

The hazard the sequence exists to prevent is a second writer on a branch an active run still owns, and its quieter twin: shipping the obsolete work because custody came back and the head looked usable.

## Preserve before touching custody

Do this before step 1 of the sequence below, because step 1 destroys what it saves.

`data/learnings.md` in a home that has hit this records the companion hazard: fix-round commits live only in the gate repo, not on the lane's branch, and `axi abort` deletes that checkout.
Rescue anything that exists only there first, and confirm the rescue landed before aborting.

## The sequence

Run these in order, and do not compress them.

1. **Rescue first, then abort the active run through no-mistakes axi's supported abort command, then confirm through axi status that the run has stopped, before changing any code.**
   Complete the preservation step above before issuing the abort; the abort deletes the gate checkout, so anything not already rescued is gone.
   The confirmation is a separate step from the abort because the abort returning is not the run having stopped.

2. **Read `branch_sync.next_action` from structured axi status and follow it.**
   Use axi sync's supported guarded recovery only when its code is `recover_custody`.
   Otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
   A status that is neither of those two is not permission to proceed - see the worked case below.

3. **Rebuild from the correct pre-invalidation base.**
   Custody recovery settles branch ownership, not content.
   Replace the obsolete work from that base rather than building on top of the recovered-but-obsolete head, and keep the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
   This is the step that gets skipped, because after custody returns the branch is writable and the head looks like a starting point.

4. **Validate exactly once against that final head**, so no obsolete or intermediate head is ever treated as authoritative.

Apart from the single supported abort in step 1, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.

Firstmate recognises a violation of that rule from the resident supervision text in `AGENTS.md` section 7 and steers the worker back to the gate response flow; this skill owns what the worker does once it is back.

## Worked case - the third custody state

Recorded 2026-08-04 on `fm-endpoint-binding-migration`, and it is the reason step 2 spells out both permitted codes rather than only the recovery one.

Run `01KYZ85B9MSDZQP2DF84A20469` was aborted cleanly: cancelled, push, PR and CI never ran, nothing pushed, no PR opened.
The worker then read custody and found `axi sync --check` reporting `branch_sync.state ambiguous_context`, changed false, local clean.

That is neither `recover_custody` nor a clean ownership-returned.
The worker correctly refused to treat it as either, flagged it for whoever resumed the lane, and preserved the three fix rounds three separate ways - a local rescue branch, the same sha on the fork, and the original rescue ref - rather than committing onto an ambiguous branch.

Read that as the shape of a correct outcome: the sequence is allowed to stop at step 2 and escalate.
An ambiguous custody reading is a blocker to report, not a state to interpret in the direction that lets work continue.
