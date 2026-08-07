# Attestation-gate exemption - verification

Audience: maintainer-verification.
Subject: `bin/fm-attestation-exempt.sh` and the fork's `PR must be raised via no-mistakes` check.
Contract owner: [`docs/attestation-exemption.md`](../attestation-exemption.md).
Regression suites: `tests/fm-attestation-exempt.test.sh` (the decider), `tests/fm-attestation-gate.test.sh` (the report layer).

Date: 2026-08-06, both mutation matrices re-measured 2026-08-07 after the workflow-glue fixes below.
Versions: git 2.54.0, ShellCheck 0.11.0 (pinned).

## Why the exemption could not be "the auto-merge reproduces the head exactly"

The obvious formulation of "a verified true merge of upstream" is that re-running the merge from the head's two parents reproduces the head's tree byte for byte.
Measured against the fork's only real sync to date - PR 7, merge commit `46254c9`, parents `9735563` (fork main) and `4a9979a` (upstream main) - that formulation refuses the exact case the exemption exists for.

```
$ git merge-tree --write-tree 9735563 4a9979a
761e9bff165a1de91887d99699dbfd364534ec79
100644 eaf10bab730fb2c5c2f35cc2a22477a3baad0699 1	AGENTS.md
100644 aa2db07d0ce0d391afb086802dd23b74a9243760 2	AGENTS.md
100644 9f900897783434db054a965196168788282280fa 3	AGENTS.md
100755 4046a0b711df20aac5ea5773b0cf0df6cb91dba0 1	bin/fm-spawn.sh
...
$ echo $?
1
$ git rev-parse 46254c9^{tree}
b6d2333cc613d680e3bfbfb2c212a2640a6faff3
```

The auto-merge conflicts in six paths, so its tree `761e9bf` is a conflicted tree and cannot equal the head's `b6d2333`.
A real sync of a fork that carries its own commits conflicts as a matter of course.
Requiring a clean auto-merge would therefore make the exemption never fire, which is the mirror trap the captain's ruling names: an exemption that never applies leaves the standing manual bypass in place.

## What is actually true of a real sync head, and is checkable

The head's tree differs from the auto-merge tree at **exactly** the conflicted paths and nowhere else.

```
$ git diff --name-status 761e9bff165a1de91887d99699dbfd364534ec79 46254c9^{tree}
M	AGENTS.md
M	bin/fm-spawn.sh
M	docs/architecture.md
M	docs/configuration.md
M	docs/scripts.md
M	docs/watcher-continuity.md
$ git diff --name-only 761e9bff165a1de91887d99699dbfd364534ec79 46254c9^{tree} | wc -l
6
```

Six differing paths against six conflicted paths, with an empty symmetric difference.
This is the property the gate verifies: a sync head introduced no content of its own outside the regions git itself could not resolve.
It is a fact about the commit graph and the trees, forgeable only by actually performing the merge.
It also bounds the residual unattested surface to the set of files where upstream and the head's chosen base-side ancestor have both diverged, since condition 4 accepts any ancestor of the base branch rather than its tip.
Both sides of that divergence are content that already landed, so what the gate leaves unconstrained is how the conflicts between them were resolved.

## Why the conflicted paths are not further constrained to "no novel lines"

A stricter rule inside the conflicted paths - every line of the resolution must appear in one of the two sides - was measured and also refuses the real sync.

```
AGENTS.md: novel_lines=1 / total=564
bin/fm-spawn.sh: novel_lines=0 / total=2192
docs/architecture.md: novel_lines=0 / total=320
docs/configuration.md: novel_lines=0 / total=636
docs/scripts.md: novel_lines=0 / total=114
docs/watcher-continuity.md: novel_lines=1 / total=93
```

Two of 3,919 resolved lines are genuinely novel: one union-shaped line splicing both sides' watcher-internals list, and one declared coexistence note recording that two delivery-record mechanisms now live side by side.
Both are legitimate conflict resolution, and neither is expressible as a copy of one side.
The gate therefore reports the conflicted paths as the residual surface rather than pretending to constrain their contents.

## Guard-class mutation matrix

Every verified property is pinned by exactly one test, and the exemption's own firing is pinned as hard as its refusals.
Each mutant below disables one property in `bin/fm-attestation-exempt.sh`; every test is then run in isolation, because a suite that stops at its first failure cannot show what a mutant did *not* break.

| Mutant | Property disabled | Tests broken |
| ------ | ----------------- | ------------ |
| baseline | none | none |
| `sync/*) : ;;` -> `*) : ;;` | 1, branch scope | `non_sync_branch_that_is_a_true_merge_is_refused` |
| `-ne 2` -> `-gt 99` | 2, exactly two parents | `sync_named_non_merge_head_is_refused`, `root_commit_sync_head_is_refused_with_no_parents_counted` |
| parent strip made unconditional | a parentless head is counted as having no parents | `root_commit_sync_head_is_refused_with_no_parents_counted` |
| `contains "${parents[1]}" "$upstream"` -> `true` | 3, upstream-side parent | `sync_head_merging_something_other_than_upstream_is_refused` |
| `contains "${parents[0]}" "$base"` -> `true` | 4, base-side parent | `sync_head_whose_other_parent_is_unlanded_is_refused` |
| `if [ -n "${stray// /}" ]` -> `if false` | 5, true-merge tree verification | `sync_head_smuggling_into_an_unconflicted_path_is_refused` |
| `decide exempt` -> `decide refused` | the exemption itself (mirror trap) | `conflicted_true_merge_sync_head_is_exempt`, `clean_true_merge_sync_head_is_exempt` |
| `sort -u "$work/conflicted"` -> empty allowed list | requires a conflict-free re-merge (mirror trap) | `conflicted_true_merge_sync_head_is_exempt` |
| `*) exit 2` -> `*) exit 1` | undetermined as its own outcome | `unreadable_head_is_undetermined_not_refused` |

No mutant breaks a test outside the property it disables, so no test is passing for an incidental reason and no property is unpinned.
The parent-count rows are the one place two tests answer to one mutant, and they are pinning different things about the same condition: disabling condition 2 outright lets both a single-parent head and a parentless one through, while the parent strip governs only what the refusal *says* about a parentless head, and the guard row breaks alone.
The two mirror-trap rows are the ones that matter most: an exemption that never fires would leave the manual bypass exactly where it was, so "the exemption still applies to a real sync" is a regression in its own right rather than a convenience.

## Guard-class mutation matrix, report layer

Three outcomes are only worth deciding if they survive being reported.
`bin/fm-attestation-gate.sh` is where they can be lost, so it is mutated on the same terms, with all ten tests of `tests/fm-attestation-gate.test.sh` run in isolation per mutant.

| Mutant | Property disabled | Tests broken |
| ------ | ----------------- | ------------ |
| baseline | none | none |
| `*) rc=2 ;;` -> `*) rc=1 ;;` | an exit code outside 0 and 1 is undetermined | `decider_undetermined_verdict_is_reported_undetermined`, `unfetched_head_ref_is_undetermined_not_refused` |
| `1) rc=1 ;;` -> `1) rc=0 ;;` | a refusal is not an exemption | `non_qualifying_head_is_reported_refused` |
| `0) rc=0 ;;` -> `0) rc=2 ;;` | the exemption is still granted (mirror trap) | `qualifying_head_is_reported_exempt` |
| `'ATTESTATION_EXEMPT: decision=exempt '*) : ;;` -> `*) : ;;` | exempt requires the decider to have said so | `non_exempt_verdict_at_exit_0_is_not_reported_exempt` |
| unparseable-decision arm keeps `rc` instead of setting `rc=2` | a decision the gate cannot read determines nothing, whatever exit code carried it | `silent_exit_1_decider_is_undetermined_not_refused` |
| `if [ "$rc" -eq 1 ]` -> `if true` | the report names the outcome it observed | the seven fixtures whose outcome is undetermined |
| the workflow's `marker='...'` literal edited | the quoted marker is the marker the check matches | `reported_marker_matches_the_workflow_check` |
| the script's `MARKER='...'` literal edited | the same, from the other owner | `reported_marker_matches_the_workflow_check` |

Every mutant breaks only tests whose property it falsifies, so no property is passing on the strength of another's fixture.
The two undetermined fixtures that share the exit-code row are the two production shapes of the same signal - a head that was never fetched, and any other head the decider cannot resolve - and the wording row breaks exactly the fixtures whose reported outcome it misnames.

The last two rows are the only pair of mutants in either matrix that live in different files, which is the point of the test they break.
The marker literal has two owners by necessity: the workflow greps for it before any checkout exists, so it cannot read the script, while the script quotes it back to a refused contributor.
Nothing in the shell pins the copies equal, so the suite does it, by reading the marker out of a refusal the gate actually printed and comparing it to the literal the workflow greps for.
Either copy drifting alone turns the check red, which is the loud failure that a comment asking the two to agree would not have produced.

Each row needed a fixture where the mutated arm is the only thing standing between the input and the wrong answer, which is why the four unreadable-decider fixtures do not appear against the exit-code rows.
A decider that is missing, not executable, or silent fails two guards at once - it has no decision line either - so the decision-line guard alone still saves it and the exit-code mutants pass those tests.
The rows above are therefore anchored on the cases where exactly one signal is available: a well-formed `decision=unknown` at exit 2 for the exit-code mapping, a well-formed non-exempt line at exit 0 for the exempt-line check, and an empty decision at exit 1 - the code a real refusal also uses - for the unparseable-decision arm.

## The gate against the real specimen

The script reaches the same verdicts on the fork's actual history as on the fixtures.

```
$ bin/fm-attestation-exempt.sh check --head-ref sync/upstream-2026-08-04 \
    --head 46254c9 --base 9735563 --upstream 4a9979a
ATTESTATION_EXEMPT: decision=exempt class=sync-true-merge base_parent=9735563... upstream_parent=4a9979a... resolved_paths=6

$ bin/fm-attestation-exempt.sh check --head-ref feature/x \
    --head 46254c9 --base 9735563 --upstream 4a9979a
ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=head branch 'feature/x' is not sync/*
```

A head forged from that same merge - identical parents and message, with `bin/fm-watch-arm.sh` (a path the re-merge resolved cleanly) swapped for other content - is refused and names the path.

```
ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=head changes paths the re-merge resolved cleanly: bin/fm-watch-arm.sh
```

The workflow step's own shell was exercised end to end against those refs in a separate clone, confirming the ref plumbing and that an unreadable upstream parent produces the undetermined message rather than the refusal message.
The exit-code handling is no longer verified that way: it moved into `bin/fm-attestation-gate.sh` precisely so it could be driven by a suite, and the matrix above is what pins it.
What remains inline in the workflow is one branch - exit 0 passes, anything else fails the step, and a code that is neither 0, 1 nor 2 also prints that the gate could not be run at all.

## The two workflow steps that no suite can drive

Two things happen before the gate script is reached, and neither is a shell a fixture can call: the checkout and the fetch.
Both were routes around the three-outcome report rather than through it, and both are now shaped so that failing leaves the gate still able to speak.

The checkout is pinned to `github.event.pull_request.head.sha` rather than the default `github.ref`.
On `pull_request` that default is `refs/pull/N/merge`, a ref GitHub does not create for a head that conflicts with the base and computes asynchronously after `opened`.
Either case failed the checkout outright, so the required check went red with a checkout error and the exemption was never evaluated - and an operator meeting a red sync is exactly the operator who reaches for the admin bypass this change exists to abolish.
A conflicting head now reaches the gate and is reported rather than crashing the step.

The fetch of the head and base is guarded the way the upstream fetch already was.
Under `set -eu` an unfetchable head aborted the step before `bin/fm-attestation-gate.sh` ran at all, and the check went red carrying git's stderr and none of the three outcome annotations - the one path in this change that produced a red attestation with no statement of what was observed.
The ref it would have written now simply stays absent, which is a shape a fixture *can* reach: `unfetched_head_ref_is_undetermined_not_refused` passes the gate the same `refs/fmgate/head` the workflow does, with nothing behind it, and pins that the outcome is undetermined, that the attestation stays in force, and that the wording is the reporter's rather than git's.
