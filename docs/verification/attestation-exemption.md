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
