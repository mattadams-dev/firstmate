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

The authenticated list is itself one capped call, and a complete list and a
truncated one differ only in size, so the sweep compares the row count against
the cap and reports unknown coverage when they match. Eight repositories against
the default cap of 200 leaves this account far from the boundary today, which is
exactly why it is checked by machine rather than by assumption.
`test_capped_enumeration_reads_unknown_coverage` and
`test_full_enumeration_under_the_cap_reads_clean` hold both directions.

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

## The instrument's own run, against the live forge

Run in a disposable home so the tasks it created were throwaway. Captured
verbatim at 23:20 UTC, about four and a half hours after the hand readings above.

```
$ FM_HOME=<disposable> bin/fm-fork-freshness.sh sweep --owner mattadams-dev
FORK_FRESHNESS: mattadams-dev/firstmate status=diverged behind=21 ahead=6 upstream=kunchenguid/firstmate compare=main...main action=task fm-sync-mattadams-dev-firstmate queued
FORK_FRESHNESS: mattadams-dev/gnhf status=ahead behind=0 ahead=2 upstream=kunchenguid/gnhf compare=main...main action=none
FORK_FRESHNESS: mattadams-dev/no-mistakes status=behind behind=29 ahead=0 upstream=kunchenguid/no-mistakes compare=main...main action=task fm-sync-mattadams-dev-no-mistakes queued
FORK_FRESHNESS_COVERAGE: owner=mattadams-dev repos=8 forks=3 swept=3 behind=2 unknown=0 ignored=0
exit 3
```

The counts differ from the hand readings above - firstmate 20 to 21, no-mistakes
28 to 29 - because upstream moved between the two measurements. Both sets are
recorded as taken rather than reconciled, which is the same reason the generated
sync instructions tell their worker to re-take the reading before acting.

An earlier run of the same command in a separate disposable home reported
`already queued` for both forks on its second invocation and created no second
task; `test_repeat_sweep_creates_no_duplicate_task` holds that behavior. Recorded
as taken: the third review round below narrowed when that line may be printed
(only over a task the backlog still reports open) and made it name its evidence,
so a run repeated today prints `already queued (the backlog reports it queued)`.

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

The unmutated suite breaks nothing, per-test and as a whole. The run above was
taken at 28 tests, before the id-collision regression and the review rounds below
were added; the suite now runs 54 tests and reports 54 ok, 0 not ok
(`bash tests/fm-fork-freshness.test.sh | grep -c '^ok -'` against the count of
invocations in the file's trailing block - both 54, which is the point: a suite
that halts early would show fewer ok lines than invocations).

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

## Review round: the silent-omission paths, each pinned by reverting its fix

Review found five ways the instrument could still be quiet about something it had
not determined. Each fix carries a regression test, and each test was proven to
fail without its fix: the fix was reverted in a scratch copy of the tree and the
whole suite run there. The suite halts at its first failure, so what is recorded
below is the exact line that halted it, not a per-test broken set like the table
above.

| Reverted fix | Captured failure |
| --- | --- |
| whole-entry dedupe of the extras list against the enumeration | `not ok - the second fork is behind, so the sweep must not exit clean: expected exit 3, got 0` |
| trailing-slash strip in the origin-URL parser | `not ok - a cloned fork that is behind must not exit clean: expected exit 3, got 0` |
| enumeration-cap detection | `not ok - a sweep whose enumeration hit its cap must not exit clean: expected exit 4, got 0` |
| cap detection forced always-on (the cry-wolf direction) | `not ok - a fork behind its upstream must not exit clean: expected exit 3, got 5` |
| session-start trigger relaying the sweep's stderr | `not ok - a sync task whose backlog write failed reached the digest as a clean queued task (missing: 'TASK_MANUAL: acme/widget is behind but sync task fm-sync-acme-widget')` |
| session-start trigger reporting a non-0/3/4/5 exit | `not ok - a sweep that crashed without a reading printed exactly what a not-due sweep prints (missing: 'FORK_FRESHNESS_COVERAGE: status=unknown')` |
| time bound on the pre-PR reading | `not ok - a stalled freshness reading hung the PR-ready path for 20s` |

The fourth row is the anti-cry-wolf half of the cap check, and it is the reason
the cap is compared rather than assumed hit: an instrument that declares coverage
unknown on every run has stopped distinguishing anything.

The last row is a real 20-second hang, not a simulated one: the recorder stands
in for a forge that accepts the connection and never answers, and without the
bound the PR-ready path waits for it with the merge watch already armed.

## Second review round: the materialisation window and the unobserved artifacts

The next round found the guard problem the bounded kills above made reachable:
`data/<id>/brief.md` is both the task's instructions and its idempotency guard,
and it used to be the FIRST artifact written, so a run cut short between it and
the backlog, wake and Bridge steps left a permanent guard over a task nobody had
been told about. The three notifications were also the quiet kind: only the
backlog step reported its own failure, so `queued` could assert four artifacts
while one of them was never observed.

Same method: revert one fix in a scratch copy, run the whole suite there, record
the line that halted it.

| Reverted fix | Captured failure |
| --- | --- |
| brief rendered beside itself and moved into place last | `not ok - an interrupted materialisation left the guard behind, and no later sweep will finish the task` |
| wake append reporting its own failure | `not ok - a wake entry that could not be appended must say so rather than pass silently (missing: 'WAKE_MANUAL:')` |
| Bridge ask reporting its own failure | `not ok - a Bridge ask that could not be raised must say so rather than pass silently (missing: 'BRIDGE_MANUAL:')` |

`test_interrupted_materialisation_leaves_no_guard` drives the interruption
through the executable interface rather than describing it: the fake backlog
client signals the shells that invoked it, which stops the materialisation
between its first artifact and its last whichever way the shell laid the call
out. The test then asserts three things about the wreckage - no guard, no wake,
no half-written brief left behind - and that the next sweep redoes the whole
task rather than reporting `already queued` over it.

The two notification tests force a real failure rather than a simulated one: an
unwritable wake sequence file, and a run whose `bin/fm-bridge.sh` is absent. Both
assert the loud stderr line AND the `MANUAL=` marker on the reading, because the
reading is what the digest shows first, and both assert the brief survived -
a failed notification must never cost the task its instructions.

## Third review round: the guard's liveness, and four smaller over-claims

Date: 2026-08-05.

**Superseded in part by the fourth round below.** This round asked the task
system the liveness question but kept the brief as the gate deciding whether the
question got asked, and re-materialised with `add`, which cannot reopen. The
fourth round removed the gate and the guard entirely; the rows below marked
superseded describe mechanisms that no longer exist, and the rest were re-run
against the current tree.

The round before this one gave the marker a lifetime by retiring it on a
`behind=0` reading. Review then found that trigger is not enough on its own: it
fires only where a reading happens to catch the fork level, and the readings
above show upstream moving again within four and a half hours (firstmate 20 to
21, no-mistakes 28 to 29). Between two weekly sweeps that window can open and
close unobserved, and the marker outlives its episode exactly as before.

The fix splits the two jobs the file was doing. The brief keeps its
creation-proof job unchanged - rendered beside itself, moved into place last, one
atomic move. Liveness - is a sync task actually open for this fork - is asked of
the task system (`tasks-axi show <id>`, run from `$FM_HOME`, the same working
directory the backlog write uses) on every reading. Open short-circuits, spent
retires the marker and raises a fresh task, and a state that could not be read
does neither and says so.

Same method as the rounds above: revert one fix in a scratch copy, run the whole
suite there, record the line that halted it verbatim.

| Reverted fix | Captured failure |
| --- | --- |
| liveness asked of the task system (guard keyed on the marker file alone) | superseded by the fourth round: the brief no longer gates the question |
| the live/spent distinction (every marker treated as spent) | superseded by the fourth round: the four-answer classification replaced it |
| an unreadable task state kept distinct from an open one | `not ok - a liveness question that could not be answered passed silently (missing: 'TASK_UNKNOWN:')` |
| the stale brief filed away on a level reading | `not ok - the reading that found the marker spent did not retire it (missing: 'action=task fm-sync-acme-widget retired')` |
| credential strip on the clone origin written into the brief | `not ok - the brief carries the clone's credential into a durable, travelling artifact` |
| the atomic move checked by its result, not only its status | `not ok - the reading dropped the reason its task could not be created (missing: 'NOT queued: instructions could not be placed')` |
| `data/projects.md` as a discovery source | `not ok - a registered fork that is behind must not exit clean: expected exit 3, got 0` |
| the composed task-failure reason kept on the reading | `not ok - the reading dropped the reason its task could not be created (missing: 'NOT queued: instructions could not be placed')` |
| `--owner` rejecting a missing value | `not ok - a flag with no value must be refused like every other malformed option: expected exit 2, got 1` |

Rows six and eight halt on the same assertion for different reasons, and the
coincidence is worth naming rather than smoothing over: without the result check,
`mv` onto an existing directory *succeeds* by moving the brief inside it, so the
reading says `queued` over a file nobody will find; without the composed reason,
the failure is reported but its cause and `MANUAL=` marker are overwritten by a
bare literal. The same test catches both because it asserts the reading carries
what actually happened.

Rows one and two were this round's own fix and are superseded: it made the
liveness answer come from the task system but left the brief deciding whether the
question was asked at all, so the conflation survived one layer down. The fourth
round removed that gate.

A brief is still never silently deleted - it is kept as
`data/<id>/brief.retired-<stamp>.md` and named on the reading that replaced it -
and `bin/fm-teardown.sh` is untouched, removing exactly what it removed before.

The fake `tasks-axi` in the suite gained `show <id>` in the installed CLI's
shape, checked against the installed one (tasks-axi 0.2.3): an indented
`state: <queued|in_flight|done>` line at rc=0, and `code: NOT_FOUND` on
**stdout** at rc=1. The stream matters - a fake that wrote NOT_FOUND to stderr
would let a mis-parsed absent task pass here and read as unknown in production.

## Fourth round: the boundary itself, not a fourth patch

Date: 2026-08-05.

Three rounds moved one conflation a step downstream each time - a file existing
read as a task existing, then retiring on observation read as retiring on
completion, then `add` read as reopening. The third failed while PRINTING
`queued` over a task that stayed `done`, on every sweep, forever, which is a
false success and therefore worse than the silent failures it replaced.

Apply the two-world check to that reading. The two states `queued` was meant to
separate are (a) a sync task was created or reopened and is now owed, and (b) an
add short-circuited over a done task and nothing was queued at all. Both produced
the identical reading, so anything stronger than unknown was fabrication - and it
printed a definite success.

So this round reshapes the boundary rather than patching the seam again:

- **Is a sync owed?** the forge answers, `behind > 0`.
- **Does open work already carry it?** the task system answers, asked directly by
  id with nothing on disk gating the question.

The brief stops being a guard and keeps only creation-atomicity. The remediation
primitive is matched to the answer - `add` creates, `reopen` reopens - and the
post-state is read back rather than inferred, so `queued` is reachable only from
a confirmed reading. The task is created last, because whatever the sweep gates
on must be its final artifact.

## What the installed task CLI actually does

Taken 2026-08-05 against tasks-axi 0.2.3 in a throwaway backlog, because the
redesign below rests on these four facts and every one of them had been assumed
rather than read. `--file` is elided from the echoed commands for width.

`add` over an id that already exists is a **complete no-op at exit 0** - it does
not transition the task, and it does not even update the body:

```
$ tasks-axi add sync-probe "Sync acme/widget from up/widget" --body "second reading" --json
{
  "ok": true,
  "action": "add",
  "already": true,
  "task": {
    "id": "sync-probe",
    "state": "done",
    "body": "first reading",
```

```
[exit 0]
```

That is the round-3 finding in one reading: `"already": true`, `"state": "done"`,
the second body discarded, and rc=0. Exit status cannot distinguish a created
task from a discarded add, so nothing on this path may be inferred from it.

`reopen` is the primitive that does transition, and its `--json` form returns the
resulting task, so the post-state is available from the mutation itself:

```
$ tasks-axi reopen sync-probe --json
{
  "ok": true,
  "action": "reopen",
  "task": {
    "id": "sync-probe",
    "state": "queued",
```

```
[exit 0]
```

`reopen` over an absent id fails loudly rather than creating anything, so
create-vs-reopen is a real branch and not a convenience:

```
$ tasks-axi reopen sync-probe-absent --json
error: "Task \"sync-probe-absent\" not found in this backlog"
code: NOT_FOUND
[exit 1]
```

`hold` is an **orthogonal field, not a state**. A held task still reads
`state: queued`, and there is no state named `held` anywhere in the CLI:

```
$ tasks-axi hold sync-probe --reason "captain decision pending" --kind captain
ok: hold sync-probe -> held (captain)
task:
  id: sync-probe
  state: queued
  held: yes
  hold_kind: captain
[exit 0]
```

This retires the `held)` arm the sweep used to carry in its state classifier and
the `queued|in_flight|held|done` fake recorded above: the states are exactly
`queued`, `in_flight`, and `done`. The old arm was unreachable, so the outcome it
produced was right only by accident - a held task reaches `queued|in_flight` and
is correctly read as open, which is what it is.

One consequence bounds the redesign: `reopen` moves **Done or In flight** back to
Queued, so calling it on a task a worker already holds would yank that work back
to the queue underneath them.

```
$ tasks-axi show sync-probe   # state: in_flight
$ tasks-axi reopen sync-probe --json
  "action": "reopen",
    "state": "queued",
```

Reopen is therefore reachable only from a confirmed closed reading, never from an
open or unknown one.


### Mutation evidence for the fourth round

Same method as the rounds above: revert one fix in a scratch copy of the current
tree, run the whole suite there, record the line that halted it verbatim.

| Reverted fix | Captured failure |
| --- | --- |
| the post-state read back instead of inferred from exit status | `not ok - the sweep printed queued over a task that never left done - exit status was treated as a result (unexpected: 'action=task fm-sync-acme-widget queued')` |
| `reopen` as the primitive for a closed task (`add` used instead) | `not ok - the fork's second episode created no task (missing: 'action=task fm-sync-acme-widget queued')` |
| the liveness question asked unconditionally (gated on the brief again) | `not ok - a brief and a wake left by a dead run suppressed the sweep - only the task system may answer whether work is owed (missing: 'action=task fm-sync-acme-widget queued')` |
| the task created last, after the wake and the Bridge row | `not ok - the task landed without the wake that must precede it - creating it last is what prevents exactly this` |
| an unreadable post-state kept distinct from a confirmed one | `not ok - an unconfirmable post-state was reported as a definite success (unexpected: 'action=task fm-sync-acme-widget queued')` |
| `reopen` reachable only from a confirmed closed reading | `not ok - an in-flight sync task was pulled back to the queue underneath its worker (the backlog reports 'queued', expected 'in_flight')` |

Row two is the third finding itself, and it is worth naming why it needs the
post-state assertion rather than the reading alone: with `add` swapped back in,
the sweep still prints a line for that fork. What changes is what the backlog
says afterwards, so `assert_task_state` is what fails, not a string match on
stdout.

Row six is the reason `reopen` is entered only from a confirmed closed reading.
`reopen` moves Done **or In flight** back to Queued, so reaching it from an open
reading pulls work back to the queue underneath the crewmate holding it.

The `held)` arm this round removed carries no mutation row, and deliberately so:
it was unreachable, because hold is an orthogonal field and no state is ever
named `held`. An unreachable branch has no behavioral mutation to catch - the
evidence for removing it is the CLI reading above, and
`test_a_held_task_is_open_work_and_is_not_duplicated` pins the behavior that
matters, which is that a held task is open work and short-circuits.

### The fake had to stop being more generous than the CLI

The suite could not have caught the third finding. Its `tasks-axi` fake modelled
`add` as an upsert that also transitioned, so `add` over a done task reopened it
in the suite and no-opped in production. The one place the fake and the tool
disagreed is the exact place the defect lived.

The fake is now create-only over an existing id and answers `reopen` and
`update` in the installed shapes. This is the same rule the harness-dependent
check guidance states for vendor-emitted signals: a stub can only confirm the
assumption written into it, so anywhere it is more generous than the tool it
stands in for, the difference ships.

## Trigger wiring

Both triggers are exercised through their real callers, with a recorder standing
in for the sweep in a copied `FM_ROOT`:

- `test_pr_check_takes_the_reading_before_a_fork_pr` runs `bin/fm-pr-check.sh`
  against a GitHub pull request URL and asserts the recorder saw
  `check acme/widget`.
- `test_pr_check_bounds_the_freshness_reading` runs the same caller against a
  recorder that hangs, and asserts the PR-ready path finishes anyway, still
  prints its `armed:` line, and reports the reading as unknown.
- `test_session_start_sweep_runs_and_detect_only_skips_it` runs
  `bin/fm-bootstrap.sh` twice and asserts `sweep --if-due` is invoked on the
  locked path and never under `FM_BOOTSTRAP_DETECT_ONLY=1`.
- `test_session_start_relays_everything_the_sweep_says` and
  `test_session_start_never_prints_a_crashed_sweep_as_a_quiet_one` assert the
  digest carries the sweep's stderr as well as its stdout, and that a sweep which
  died and a sweep which was not due never print the same thing.

`bin/fm-pr-merge.sh` refuses a task whose metadata carries no `pr=` line, and
`bin/fm-pr-check.sh` is that line's only writer, which is why the pre-PR reading
is taken there: no merge through the sanctioned path can skip it.

## Lint

```
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

The review round re-ran it over the files it touched, with the same pinned
configuration:

```
$ bin/fm-lint.sh bin/fm-fork-freshness.sh bin/fm-bootstrap.sh bin/fm-pr-check.sh tests/fm-fork-freshness.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```
