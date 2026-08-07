# Attestation-gate exemption - verification

Audience: maintainer-verification.
Subject: `bin/fm-attestation-exempt.sh` and the fork's `PR must be raised via no-mistakes` check.
Contract owner: [`docs/attestation-exemption.md`](../attestation-exemption.md).
Regression suite: `tests/fm-attestation-exempt.test.sh`.

Date: 2026-08-06.
Versions: git 2.54.0, ShellCheck 0.11.0 (pinned).

## Why the exemption could not be "the auto-merge reproduces the head exactly"

The obvious formulation of "a verified true merge of upstream" is that re-running
the merge from the head's two parents reproduces the head's tree byte for byte.
Measured against the fork's only real sync to date - PR 7, merge commit
`46254c9`, parents `9735563` (fork main) and `4a9979a` (upstream main) - that
formulation refuses the exact case the exemption exists for.

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

The auto-merge conflicts in six paths, so its tree `761e9bf` is a conflicted
tree and cannot equal the head's `b6d2333`. A real sync of a fork that carries
its own commits conflicts as a matter of course; requiring a clean auto-merge
would make the exemption never fire, which is the mirror trap the captain's
ruling names - an exemption that never applies leaves the standing manual bypass
in place.

## What is actually true of a real sync head, and is checkable

The head's tree differs from the auto-merge tree at **exactly** the conflicted
paths and nowhere else.

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

Six differing paths against six conflicted paths, with an empty symmetric
difference. This is the property the gate verifies: a sync head introduced no
content of its own outside the regions git itself could not resolve. It is a
fact about the commit graph and the trees, forgeable only by actually performing
the merge, and it bounds the residual unattested surface to the set of files
where the fork and upstream have both diverged - a set that can only grow
through the gate itself.

## Why the conflicted paths are not further constrained to "no novel lines"

A stricter rule inside the conflicted paths - every line of the resolution must
appear in one of the two sides - was measured and also refuses the real sync.

```
AGENTS.md: novel_lines=1 / total=564
bin/fm-spawn.sh: novel_lines=0 / total=2192
docs/architecture.md: novel_lines=0 / total=320
docs/configuration.md: novel_lines=0 / total=636
docs/scripts.md: novel_lines=0 / total=114
docs/watcher-continuity.md: novel_lines=1 / total=93
```

Two of 3,919 resolved lines are genuinely novel: one union-shaped line splicing
both sides' watcher-internals list, and one declared coexistence note recording
that two delivery-record mechanisms now live side by side. Both are legitimate
conflict resolution, and neither is expressible as a copy of one side. The gate
therefore reports the conflicted paths as the residual surface rather than
pretending to constrain their contents.

## Guard-class mutation matrix

Every verified property is pinned by exactly one test, and the exemption's own
firing is pinned as hard as its refusals. Each mutant below disables one
property in `bin/fm-attestation-exempt.sh`; every test is then run in isolation,
because a suite that stops at its first failure cannot show what a mutant did
*not* break.

| Mutant | Property disabled | Tests broken |
| ------ | ----------------- | ------------ |
| baseline | none | none |
| `sync/*) : ;;` -> `*) : ;;` | (1) branch scope | `non_sync_branch_that_is_a_true_merge_is_refused` |
| `-ne 2` -> `-gt 99` | (2) exactly two parents | `sync_named_non_merge_head_is_refused` |
| `contains "${parents[1]}" "$upstream"` -> `true` | (3) upstream-side parent | `sync_head_merging_something_other_than_upstream_is_refused` |
| `contains "${parents[0]}" "$base"` -> `true` | (4) base-side parent | `sync_head_whose_other_parent_is_unlanded_is_refused` |
| `if [ -n "${stray// /}" ]` -> `if false` | (5) true-merge tree verification | `sync_head_smuggling_into_an_unconflicted_path_is_refused` |
| `decide exempt` -> `decide refused` | the exemption itself (mirror trap) | `conflicted_true_merge_sync_head_is_exempt`, `clean_true_merge_sync_head_is_exempt` |
| `sort -u "$work/conflicted"` -> `: >` allowed | requires a conflict-free re-merge (mirror trap) | `conflicted_true_merge_sync_head_is_exempt` |
| `*) exit 2` -> `*) exit 1` | undetermined as its own outcome | `unreadable_head_is_undetermined_not_refused` |

No mutant breaks a test other than the one naming its property, so no test is
passing for an incidental reason and no property is unpinned. The two mirror-trap
rows are the ones that matter most: an exemption that never fires would leave the
manual bypass exactly where it was, so "the exemption still applies to a real
sync" is a regression in its own right, not a convenience.

## The gate against the real specimen

The script reaches the same verdicts on the fork's actual history as on the
fixtures.

```
$ bin/fm-attestation-exempt.sh check --head-ref sync/upstream-2026-08-04 \
    --head 46254c9 --base 9735563 --upstream 4a9979a
ATTESTATION_EXEMPT: decision=exempt class=sync-true-merge base_parent=9735563... upstream_parent=4a9979a... resolved_paths=6

$ bin/fm-attestation-exempt.sh check --head-ref feature/x \
    --head 46254c9 --base 9735563 --upstream 4a9979a
ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=head branch 'feature/x' is not sync/*
```

And on a head forged from that same merge - identical parents and message, with
`bin/fm-watch-arm.sh` (a path the re-merge resolved cleanly) swapped for other
content:

```
ATTESTATION_EXEMPT: decision=refused class=sync-true-merge reason=head changes paths the re-merge resolved cleanly: bin/fm-watch-arm.sh
```
