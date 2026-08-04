# Fork freshness sweep - verification

Audience: maintainer-verification.
Subject: `bin/fm-fork-freshness.sh` and its two triggers.
Contract owner: [`docs/fork-freshness.md`](../fork-freshness.md).
Regression suite: `tests/fm-fork-freshness.test.sh`.

Date: 2026-08-04.
Versions: gh 2.x with an authenticated account, jq 1.8.2, ShellCheck 0.11.0 (pinned).

## Enumeration completeness

The sweep reads the authenticated repository list rather than the public
`users/<login>/repos` endpoint, because that endpoint returns only public
repositories and would drop private forks without saying so.

```
$ gh repo list mattadams-dev --limit 100 --json nameWithOwner,isFork,isPrivate,isArchived,parent
mattadams-dev/firstmate fork=true private=false archived=false parent=kunchenguid/firstmate
mattadams-dev/dotfiles fork=false private=true archived=false parent=-/-
mattadams-dev/observe fork=false private=true archived=false parent=-/-
mattadams-dev/gnhf fork=true private=false archived=false parent=kunchenguid/gnhf
mattadams-dev/diagram fork=false private=true archived=false parent=-/-
mattadams-dev/fleet-evidence fork=false private=true archived=false parent=-/-
mattadams-dev/no-mistakes fork=true private=false archived=false parent=kunchenguid/no-mistakes
mattadams-dev/mobile_development_testing fork=false private=true archived=false parent=-/-

$ gh api "users/mattadams-dev/repos?per_page=100" --jq length   # public-only endpoint
3
```

Eight repositories through the authenticated list, three through the public one.
`tests/fm-fork-freshness.test.sh::test_private_and_uncloned_forks_are_covered`
holds this: a private fork and a fork with no local clone must both appear in
the output and in the coverage counts.

## Baseline readings, taken by hand before the instrument existed

```
$ gh api repos/kunchenguid/firstmate/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":6,"behind_by":20,"status":"diverged"}
$ gh api repos/kunchenguid/gnhf/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":2,"behind_by":0,"status":"ahead"}
$ gh api repos/kunchenguid/no-mistakes/compare/kunchenguid:main...mattadams-dev:main
{"ahead_by":0,"behind_by":28,"status":"behind"}
```

`no-mistakes` was 28 behind and had no local clone, so a sweep built from clones
would have missed it entirely - the concrete case behind the enumeration rule
above.

## First run of the instrument, against the live forge

Run in an isolated home so the tasks it created were disposable.

```
$ FM_HOME=<disposable> bin/fm-fork-freshness.sh sweep --owner mattadams-dev
FORK_FRESHNESS: mattadams-dev/firstmate status=diverged behind=20 ahead=6 upstream=kunchenguid/firstmate compare=main...main action=task fm-sync-mattadams-dev-firstmate queued
FORK_FRESHNESS: mattadams-dev/gnhf status=ahead behind=0 ahead=2 upstream=kunchenguid/gnhf compare=main...main action=none
FORK_FRESHNESS: mattadams-dev/no-mistakes status=behind behind=28 ahead=0 upstream=kunchenguid/no-mistakes compare=main...main action=task fm-sync-mattadams-dev-no-mistakes queued
FORK_FRESHNESS_COVERAGE: owner=mattadams-dev repos=8 forks=3 swept=3 behind=2 unknown=0 ignored=0
exit 3
```

The second run of the same command reports `already queued` for both and creates
no second task.

## Mutation evidence

Each mutant was applied to `bin/fm-fork-freshness.sh`, then every test in
`tests/fm-fork-freshness.test.sh` was run in its own process so the full set of
broken tests is visible rather than only the first failure. Reproduce by copying
the suite to a runner whose trailing invocation block is replaced with
`"$FM_ONE_TEST"`, placing it beside `tests/lib.sh`, and looping over the test
function names.

| Mutant | Change | Tests broken |
| --- | --- | --- |
| A: reports in-sync while behind | force `behind=0 status=identical` after the compare read | 13, including `test_behind_creates_a_sync_task`; **not** `test_in_sync_creates_no_task` |
| B: reports behind while level | force `behind=7 status=behind` after the compare read | 8, including `test_in_sync_creates_no_task`; **not** any unknown test |
| C: collapses an unreadable repository into an answer | make `repo_facts` return `false<TAB><TAB>main<TAB>false` instead of failing | exactly `test_unreadable_upstream_reads_unknown` and `test_check_cannot_read_reads_unknown` |
| D: keeps real readings but always warns | `[ "$behind" -gt 0 ] \|\| { behind=1; status=behind; }` | exactly `test_in_sync_creates_no_task`, `test_ahead_only_creates_no_task`, `test_outage_and_in_sync_are_distinguishable`, `test_private_and_uncloned_forks_are_covered` |

The unmutated suite breaks nothing, per-test and as a whole (29 ok; the mutation
run above was taken at 28, before the id-collision regression was added).

What the table establishes:

- Each direction of the reading is separately guarded. A leaves the quiet-side
  test passing and B leaves the unknown suite passing, so no constant answer
  passes both directions.
- Mutant D is the anti-cry-wolf proof: an implementation that keeps every real
  reading but warns on a level fork breaks only the quiet-side tests. Passing the
  behind tests by always warning is therefore closed off.
- Mutant C is the instrument-honesty proof: turning one indeterminate read into a
  determinate one breaks exactly the two tests that assert unknown.

## Two-world check

`test_outage_and_in_sync_are_distinguishable` runs the same fixture twice, once
healthy and once with the compare call failing at the network layer, and asserts
the two outputs differ and that the outage output never contains `in-sync`. This
is the mechanical form of the rule: name the two world-states the reading is
meant to separate, and if both produce the same reading, anything stronger than
unknown is fabrication.

## Trigger wiring

Both triggers are exercised through their real callers, with a recorder standing
in for the sweep in a copied `FM_ROOT`:

- `test_pr_check_takes_the_reading_before_a_fork_pr` runs `bin/fm-pr-check.sh`
  against a GitHub pull request URL and asserts the recorder saw
  `check acme/widget`.
- `test_session_start_sweep_runs_and_detect_only_skips_it` runs
  `bin/fm-bootstrap.sh` twice and asserts `sweep --if-due` is invoked on the
  locked path and never under `FM_BOOTSTRAP_DETECT_ONLY=1`.

`bin/fm-pr-merge.sh` refuses a task whose metadata carries no `pr=` line, and
`bin/fm-pr-check.sh` is that line's only writer, which is why the pre-PR reading
is taken there: no merge through the sanctioned path can skip it.

## Lint

```
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```
