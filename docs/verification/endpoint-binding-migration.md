# Endpoint binding migration

Audience: maintainer verification.

Repeatable repair of `endpoint_task_id=` in `state/<id>.meta` records created before `bin/fm-spawn.sh` began writing that field.
Re-running is harmless by construction rather than by memory of a previous run; "one-shot" appears below only where the deleted guard is being discussed.
First applied 2026-08-01 against the primary home.

Unlike its sibling records, this one embeds captured live tool output, whose paths and identifiers are the evidence itself and are never edited; the siblings' zero-absolute-path form binds prose only.
That divergence is declared here so a later path-counting audit reads it as deliberate rather than as a defect, which is what an undeclared divergence is indistinguishable from.

`bin/fm-migrate-endpoint-binding.sh` and its two test files ship, and the script is safe to run again; see "Why there is no one-shot guard" below.
This page is the durable evidence that the repair happened and that its guards were load-bearing when it ran.

## What the field guards, and what it does not

`fm_backend_validate_task_endpoint` (`bin/fm-backend.sh`) is teardown's gate; `bin/fm-teardown.sh:133` calls it and exits on refusal.
For an opaque backend (herdr, zellij, orca, cmux) it refuses when `endpoint_task_id=` is absent, empty, ambiguous, or unequal to the task id.
A legacy tmux record is exempt: its window is `<session>:fm-<id>`, so the binding is already in the window name.

The validator requires the field to EQUAL the task id, so the value is fixed by the record's own filename.
That makes the value itself worthless as evidence - anyone can copy a filename into a file and satisfy the check.
What the field is supposed to stand for is the claim "a live endpoint belonging to this task was seen", and only the way a value is produced can make that claim true.

The migration therefore took the task identity from the LABEL herdr reported for a live tab and wrote that, using the filename only as a cross-check.
A record whose endpoint was gone, moved, duplicated, or inconsistent with what was recorded was never written.

## Environment

```
captured_at_utc=2026-08-01T17:49:53Z
herdr_version=herdr 0.7.5
fm_home=/home/jamada/code/personal/firstmate
```

## Records repaired

Derived as the `state/*.meta` files carrying a `window=` line and no `endpoint_task_id=` line.
All four were `backend=herdr`; no tmux or other-backend candidate existed.

### What the applied run's `disposition=0` did and did not mean

The validator refuses four binding shapes: absent, empty, ambiguous, and unequal to the task id.
At the time of the run, the script treated only *absent* as a candidate and skipped the other three in silence, so a record carrying an empty, duplicated, or mismatched binding would have produced no disposition item.

That run's guarantee was therefore outcome-verified - zero affected, checked - and never mechanism-carried.
It was correct because the home was checked and contained no empty, duplicated, or mismatched binding, not because the script would have caught one.
The check that established zero affected was made against the home at run time and is not reproduced in this record; what the captured output below does show is the shape of the four candidates, each refused before migration with the validator's absent-binding message `lacks an exact task binding` rather than its empty or ambiguous message.
Read `disposition=0` as exactly that fact about this home at that moment, not as a general claim that no stranded records remain anywhere.

All four refusal shapes report as disposition items from this fix forward, each with a fixture proving it fires.
The migration appends a binding to a record that has none and never edits or removes an existing one, so the three broken shapes are reported for a maintainer to resolve by hand rather than rewritten.

## Live read the values came from

Read at migration time from herdr's own tab and pane inventory, scoped to this home's workspace by label.
Nothing was derived from `state/`, from a prior snapshot, from the status log, or from another metadata file.

```
## fm_backend_herdr_workspace_find_all 1 (home label: firstmate)
wB
## fm_backend_herdr_list_live 1
1:wB:p19	fm-observe-m1-slice
1:wB:p1A	fm-observe-fixture-corpus
1:wB:p1B	fm-observe-ocr-bakeoff
1:wB:p1F	fm-fm-supervision-successor-arming
```

Raw herdr CLI output backing that read:

```
## raw: herdr tab list --workspace wB (session 1)
{"id":"cli:tab:list","result":{"tabs":[{"agent_status":"idle","focused":false,"label":"fm-observe-m1-slice","number":41,"pane_count":1,"tab_id":"wB:t19","workspace_id":"wB"},{"agent_status":"working","focused":false,"label":"fm-observe-fixture-corpus","number":42,"pane_count":1,"tab_id":"wB:t1A","workspace_id":"wB"},{"agent_status":"idle","focused":false,"label":"fm-observe-ocr-bakeoff","number":43,"pane_count":1,"tab_id":"wB:t1B","workspace_id":"wB"},{"agent_status":"idle","focused":false,"label":"fm-fm-supervision-successor-arming","number":47,"pane_count":1,"tab_id":"wB:t1F","workspace_id":"wB"}],"type":"tab_list"}}

## raw: herdr pane list --workspace wB (session 1)
{"id":"cli:pane:list","result":{"panes":[{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/2/observe","pane_id":"wB:p19","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t19","terminal_id":"term_657e30e1a2ecb14","terminal_title":"✳ Build M1 static vertical slice for observer system","terminal_title_stripped":"Build M1 static vertical slice for observer system","workspace_id":"wB"},{"agent":"claude","agent_status":"working","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/3/observe","pane_id":"wB:p1A","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1A","terminal_id":"term_657e30e63d28815","terminal_title":"⠂ Build problem fixture corpus with simulator validation","terminal_title_stripped":"Build problem fixture corpus with simulator validation","workspace_id":"wB"},{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate/projects/observe","focused":false,"foreground_cwd":"/home/jamada/.treehouse/observe-f7c3df/4/observe","pane_id":"wB:p1B","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1B","terminal_id":"term_657e30e9ec53f16","terminal_title":"✳ Run OCR engine bake-off and record selection decision","terminal_title_stripped":"Run OCR engine bake-off and record selection decision","workspace_id":"wB"},{"agent":"claude","agent_status":"idle","cwd":"/home/jamada/code/personal/firstmate","focused":false,"foreground_cwd":"/home/jamada/.treehouse/firstmate-8bf1b0/2/firstmate","pane_id":"wB:p1F","revision":2,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":46},"tab_id":"wB:t1F","terminal_id":"term_657ed95f20b3b1a","terminal_title":"✳ Fix supervisor successor arming and parked lane cadence","terminal_title_stripped":"Fix supervisor successor arming and parked lane cadence","workspace_id":"wB"}],"type":"pane_list"}}
```

## The applied run

```
# fm-migrate-endpoint-binding run
run_at=2026-08-01T18:01:00Z
apply=1
fm_home=/home/jamada/code/personal/firstmate
herdr=herdr 0.7.5

MIGRATED	fm-supervision-successor-arming	endpoint_task_id=fm-supervision-successor-arming	source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1F pane=wB:p1F label=fm-fm-supervision-successor-arming foreground_cwd=/home/jamada/.treehouse/firstmate-8bf1b0/2/firstmate tool=herdr 0.7.5
MIGRATED	observe-fixture-corpus	endpoint_task_id=observe-fixture-corpus	source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1A pane=wB:p1A label=fm-observe-fixture-corpus foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/3/observe tool=herdr 0.7.5
MIGRATED	observe-m1-slice	endpoint_task_id=observe-m1-slice	source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t19 pane=wB:p19 label=fm-observe-m1-slice foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/2/observe tool=herdr 0.7.5
MIGRATED	observe-ocr-bakeoff	endpoint_task_id=observe-ocr-bakeoff	source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1B pane=wB:p1B label=fm-observe-ocr-bakeoff foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/4/observe tool=herdr 0.7.5

summary observed=4 disposition=0 not_required=0
```

Nothing was refused, so there were no disposition items.
Each record gained exactly two lines and was otherwise untouched:

```
--- fm-supervision-successor-arming.meta
17a18,19
> endpoint_task_id=fm-supervision-successor-arming
> endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1F pane=wB:p1F label=fm-fm-supervision-successor-arming foreground_cwd=/home/jamada/.treehouse/firstmate-8bf1b0/2/firstmate tool=herdr 0.7.5
--- observe-fixture-corpus.meta
15a16,17
> endpoint_task_id=observe-fixture-corpus
> endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1A pane=wB:p1A label=fm-observe-fixture-corpus foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/3/observe tool=herdr 0.7.5
--- observe-m1-slice.meta
17a18,19
> endpoint_task_id=observe-m1-slice
> endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t19 pane=wB:p19 label=fm-observe-m1-slice foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/2/observe tool=herdr 0.7.5
--- observe-ocr-bakeoff.meta
15a16,17
> endpoint_task_id=observe-ocr-bakeoff
> endpoint_task_id_provenance=migrated observed_at=2026-08-01T18:01:00Z by=fm-migrate-endpoint-binding.sh source=herdr-live-tab-and-pane-list session=1 workspace=wB tab=wB:t1B pane=wB:p1B label=fm-observe-ocr-bakeoff foreground_cwd=/home/jamada/.treehouse/observe-f7c3df/4/observe tool=herdr 0.7.5
```

## Provenance mechanism

A migrated record carries a sibling `endpoint_task_id_provenance=` line next to the value it describes.

The metadata format is line-oriented `key=value` read exclusively through targeted `^key=` lookups (`fm_meta_get`, `fm_backend_meta_exact_value`), so a new key is inert to every existing reader.
Keeping it in the record means it cannot drift away from the value it explains, the way a sidecar file could.
`bin/fm-spawn.sh` never writes this key, so its presence means migrated and its absence means recorded at spawn - the distinction a later reader needs.
The line records when the observation happened, what read it, and the exact herdr coordinates and label it came from.

`foreground_cwd` is recorded as corroboration but was deliberately not gated on: a live agent can change directory, so a mismatch would not be evidence the binding is wrong, and gating on it would manufacture false refusals.

## Teardown's own validation, before and after

Run against the real records with `fm_backend_validate_task_endpoint`, the function `bin/fm-teardown.sh:133` calls.
`bin/fm-teardown.sh` has no validation-only mode, and invoking it for real would have destroyed the lanes' worktrees, which this task was scoped not to touch - one of the four was an actively working lane.

```
## BEFORE migration: teardown validator against the untouched snapshots
fm-supervision-successor-arming:
REFUSED: legacy Herdr endpoint metadata for task fm-supervision-successor-arming lacks an exact task binding; preserving task state.
  rc=1 REFUSED
observe-fixture-corpus:
REFUSED: legacy Herdr endpoint metadata for task observe-fixture-corpus lacks an exact task binding; preserving task state.
  rc=1 REFUSED
observe-m1-slice:
REFUSED: legacy Herdr endpoint metadata for task observe-m1-slice lacks an exact task binding; preserving task state.
  rc=1 REFUSED
observe-ocr-bakeoff:
REFUSED: legacy Herdr endpoint metadata for task observe-ocr-bakeoff lacks an exact task binding; preserving task state.
  rc=1 REFUSED

## AFTER migration: teardown validator against the live repaired records
fm-supervision-successor-arming:
  rc=0 ACCEPTED backend=herdr target=1:wB:p1F
observe-fixture-corpus:
  rc=0 ACCEPTED backend=herdr target=1:wB:p1A
observe-m1-slice:
  rc=0 ACCEPTED backend=herdr target=1:wB:p19
observe-ocr-bakeoff:
  rc=0 ACCEPTED backend=herdr target=1:wB:p1B
```

The refusal half matters as much as the acceptance half: without it, acceptance afterwards would not show the guard had been active.

## Every record is accounted for

A later review found that the shapes above were not the only silent skips: a record with no `window=` line, a record that could not be read, and a dangling symlink were each dropped with no line at all - not on stdout and not in the receipt.

That matters more than it looks, because the ruling below made the receipt THE record of a run.
A receipt that omits entries is not a record; it is a record-shaped object that lies by omission, and a reader cannot tell a record that was skipped from one that never existed.
It would leave exactly the stranded-and-invisible state the deleted guard was reaching for.

Every file the `state/*.meta` glob matches now produces exactly one outcome line, on stdout and in the receipt: `MIGRATED`, `WOULD-MIGRATE`, `NOT-REQUIRED`, or `DISPOSITION`.
No path through the loop skips a record in silence.

| Shape | Outcome | Why |
| --- | --- | --- |
| no `window=` line | `DISPOSITION` | names no endpoint for a binding to describe; teardown refuses it too |
| could not be read | `DISPOSITION` | nothing was observed, so nothing is claimed about what it holds |
| dangling symlink | `DISPOSITION` | the entry exists, the record does not |
| symlink to a live target | `DISPOSITION` | see below; never written |
| unterminated last line | `DISPOSITION` | see below; never appended to |
| legacy tmux record | `NOT-REQUIRED` | the validator binds it by window name |
| already carries the binding | `NOT-REQUIRED` | not a candidate, and nothing is wrong with it |

`meta_count` used to return an empty string for an unreadable file, so `[ "" -ge 1 ]` both errored to stderr and evaluated false - an unreadable record silently read as "no window line".
It now distinguishes `grep -c`'s "no match" (exit 1, count 0) from its "cannot read" (exit 2) and fails rather than returning a count, so a read failure can never be reported as a fact about the record's contents.

The other direction is guarded too: `healthy_record_is_never_a_disposition` asserts a healthy, observable record still produces its normal outcome and no disposition item, so the accounting rule cannot degenerate into calling every record a disposition.

## Unknown is not absent

`fm_backend_herdr_workspace_find_all` returns 0 with EMPTY output when `herdr workspace list` fails (`bin/backends/herdr.sh`, `|| return 0`), and the migration masked its non-zero return on top of that.
With the herdr server stopped, herdr uninstalled, or jq missing, every record therefore emitted the definite claim `workspace <ws> is not a live workspace of this home in session <s>` - to stdout and into the durable receipt.

That is "could not look" reported as "looked and it was not there".
Two different world-states produced the same reading, and the stronger one was written permanently into the record.

The migration now makes the workspace read itself, checks its exit status, checks the tool availability first, and checks the exit status of every `jq` parse rather than letting a swallowed parse failure become an empty inventory.
Each of those conditions yields an explicit UNKNOWN disposition naming it; none of them yields an absence claim.
The two worlds are now distinguishable in the receipt, which is where the distinction has to survive:

```
DISPOSITION	alpha	could not list live workspaces in session 1, so whether workspace wB is still live is UNKNOWN, not absent
DISPOSITION	alpha	workspace wB is not a live workspace of this home in session 1
```

The first is an unreachable backend, the second a genuine absence, and `unreachable_backend_is_unknown_not_absent` asserts the first world never produces the second reading.

## Two shapes that are refused rather than repaired

**A symlinked record is never written.**
`write_binding`'s `mv -f` replaces the LINK itself with a regular file holding the target's content plus the new binding, and `fm_backend_validate_task_endpoint` refuses a symlinked record outright (`[ -f "$meta" ] && [ ! -L "$meta" ]`).
One `--apply` would therefore have converted a record teardown REFUSES into one teardown ACCEPTS, acting on a worktree path imported from outside `state/` - defeating the standing constraint that this work must not weaken teardown's requirement, by side effect rather than by intent.
The record is now detected with the same test teardown applies, reported, and left exactly as found; `symlinked_record_refused_and_stays_a_symlink` runs the real validator afterwards and asserts it still refuses.

**A record whose last line has no terminating newline is never appended to.**
The append would concatenate the binding onto the partial line, producing something like `traceparendpoint_task_id=alpha`: the preceding key is corrupted, `^endpoint_task_id=` still matches zero lines, so the record stays a candidate and every later run appends again.
That is the one way the structural idempotence this change rests on can fail, so the record is refused as already malformed rather than repaired by guessing where the truncated line ended.
The idempotence claim in the script header is scoped accordingly: it is stated for a well-formed record, which is the only shape the script writes.

## A receipt that fails mid-run stops the run

`receipt_open` failing was already fatal, but every later append discarded its exit status.
If the receipt became unwritable after the run started, the per-record lines and the `run end=` line were dropped while the run continued, printed its receipt path, and exited 0 - contradicting the script's own "a run that cannot write its receipt does not run" and its claim that the receipt "can never become a second and divergent account of what the run did".

Every append is now checked, and a failed one stops the run with a `REFUSED` on stderr and a non-zero exit.
`receipt_failure_mid_run_is_not_silent` makes the receipt unwritable after the start line and before the first outcome, and asserts the run neither reports success nor reaches its summary.

## Guard-class evidence: mutation testing, both directions

The output below is the suite and mutation harness as they stand with every record accounted for, unknown distinguished from absent, symlinked and unterminated records refused, no one-shot guard, and idempotence and the receipt carrying its job.
Earlier captures against the script at the moment of the applied run are superseded by it; the run's own captured output above is unchanged.

Behavior suite, driven through a fake herdr CLI serving canned inventory by content:

```
$ bash tests/fm-migrate-endpoint-binding.test.sh
ok - absent_endpoint_refused
ok - ambiguous_pane_refused
ok - dangling_symlink_reported_not_skipped
ok - dry_run_writes_nothing
ok - duplicated_binding_reported_not_skipped
ok - empty_binding_reported_not_skipped
ok - existing_binding_untouched
ok - foreign_workspace_refused
ok - healthy_record_is_never_a_disposition
ok - interrupted_run_resumes
ok - label_names_other_task_refused
ok - mismatched_binding_reported_not_skipped
ok - observable_binding_migrates
ok - observe_reports_unbound_record_on_partial_home
ok - pane_mismatch_refused
ok - receipt_accumulates_across_runs
ok - receipt_failure_mid_run_is_not_silent
ok - receipt_written_for_apply_run
ok - receipt_written_for_observe_run
ok - repeated_apply_is_idempotent
ok - repeated_apply_is_not_refused
ok - symlinked_record_refused_and_stays_a_symlink
ok - teardown_validator_accepts_migrated_record
ok - teardown_validator_rejects_unmigrated_record
ok - tmux_reported_not_silent
ok - unobservable_backend_refused
ok - unreachable_backend_is_unknown_not_absent
ok - unreadable_record_reported_not_skipped
ok - unterminated_record_refused
ok - valid_binding_is_not_a_disposition
ok - windowless_record_reported_not_skipped

all 31 cases passed
```

The empty-binding and duplicated-binding fixtures are synthetic on purpose, because zero real specimens existed in the migrated home.
A refusal shape without a fixture proving it fires is how the silent-skip hole survived review the first time.
The same reasoning applies to the windowless, unreadable, dangling-symlink, symlinked, and unterminated fixtures: none of them is produced by any current `bin/fm-spawn.sh` writer, so each is defensive, and each has a case that would notice if it stopped being reported.
`valid_binding_is_not_a_disposition` and `healthy_record_is_never_a_disposition` prove the other direction: a correctly bound record and a healthy observable record produce their normal outcomes, so reporting the broken shapes did not turn every record into a disposition item.

Mutation experiment.
Each mutation neutralises one guard, leaving the surrounding block intact, and is pinned to its target line by content so a drifted line number fails loudly rather than silently mutating unrelated code.

```
$ bash tests/fm-migrate-endpoint-binding-mutation.sh
== baseline: unmutated script ==
BASELINE green (31)

== mutations that let an unobserved value be written ==
CAUGHT   value-from-filename-not-label      failing: label_names_other_task_refused
CAUGHT   skip-pane-identity-check           failing: pane_mismatch_refused
CAUGHT   skip-home-workspace-check          failing: foreign_workspace_refused
CAUGHT   accept-ambiguous-pane              failing: ambiguous_pane_refused

== mutations that report an unobservable world as a definite absence ==
CAUGHT   unreachable-backend-read-as-absent failing: unreachable_backend_is_unknown_not_absent

== mutations that turn a refusal shape back into a silent skip ==
CAUGHT   silent-skip-empty-binding          failing: empty_binding_reported_not_skipped
CAUGHT   silent-skip-duplicated-binding     failing: duplicated_binding_reported_not_skipped

== mutations that let a record vanish from the account entirely ==
CAUGHT   silent-skip-windowless-record      failing: windowless_record_reported_not_skipped
CAUGHT   silent-skip-unreadable-record      failing: unreadable_record_reported_not_skipped
CAUGHT   silent-skip-dangling-symlink       failing: dangling_symlink_reported_not_skipped
CAUGHT   silent-skip-symlinked-record       failing: symlinked_record_refused_and_stays_a_symlink
CAUGHT   launder-symlinked-record           failing: symlinked_record_refused_and_stays_a_symlink
CAUGHT   append-onto-unterminated-record    failing: unterminated_record_refused

== mutations on idempotence and the receipt, in both directions ==
CAUGHT   double-write-already-bound-record  failing: existing_binding_untouched interrupted_run_resumes repeated_apply_is_idempotent repeated_apply_is_not_refused
CAUGHT   reintroduce-one-shot-refusal       failing: repeated_apply_is_idempotent repeated_apply_is_not_refused
CAUGHT   run-without-writing-receipt        failing: receipt_accumulates_across_runs receipt_failure_mid_run_is_not_silent receipt_written_for_apply_run receipt_written_for_observe_run unreachable_backend_is_unknown_not_absent
CAUGHT   continue-past-failed-receipt-write failing: receipt_failure_mid_run_is_not_silent

== the false-positive direction: a healthy record reported as a decision ==
CAUGHT   report-healthy-record-as-disposition failing: existing_binding_untouched valid_binding_is_not_a_disposition

== control: a blanket bypass should be caught broadly, not narrowly ==
CAUGHT   blanket-write-without-observation  failing: absent_endpoint_refused ambiguous_pane_refused foreign_workspace_refused label_names_other_task_refused pane_mismatch_refused unreachable_backend_is_unknown_not_absent

RESULT: every mutation was caught by exactly the expected case(s)
```

Both directions hold.
A genuinely observable binding still migrates (baseline green, 31 cases).
Each mutation that would let an unobserved value be written is caught by exactly the case that owns that guard, so the suite identifies which protection is missing rather than going uniformly red.

The `value-from-filename-not-label` mutation is the one that matters most: it is precisely "assertion instead of observation", and it is caught by exactly one case.
`unreachable-backend-read-as-absent` restores the masking that let an unreachable herdr be written into the receipt as a definite absence, and is caught by the case that owns that distinction.
The silent-skip mutations restore a blind spot by dropping a report and skipping the record; each is caught by exactly the fixture that owns that shape, which is what the per-shape cases are for.
`silent-skip-dangling-symlink` and `launder-symlinked-record` each break only their own case because the two symlink shapes are branched apart rather than sharing one guard - dropping the dangling report leaves the record caught by the live-symlink branch, so the line that appears would name the wrong fact, which is why that case pins the reason text and not merely the presence of a line.
`append-onto-unterminated-record` removes the only guard standing between a truncated record and an append that corrupts the preceding key while leaving the record a candidate forever.
Idempotence and the receipt are mutated in both directions, because each has a way to fail that the other cannot see.
`double-write-already-bound-record` is expected to break every case holding a correctly bound record, not the idempotence case alone: dropping the skip sends each of them back through observation.
`reintroduce-one-shot-refusal` is expected to break only the two cases that run `--apply` twice against a fully migrated home; `interrupted_run_resumes` still holds an unbound record, so that form of the guard never fires there and listing it would be an expectation the experiment could satisfy only by accident - the same rule the blanket-bypass control follows for `unobservable_backend_refused`.
`run-without-writing-receipt` is expected to break every case that reads a receipt, which now includes `unreachable_backend_is_unknown_not_absent`: that case asserts the durable receipt carries the unknown/absent distinction, not only stdout.
`continue-past-failed-receipt-write` lets the run survive the failure it just reported, and only the mid-run case can see it, since no other case loses a writable receipt.
`report-healthy-record-as-disposition` is the false-positive direction of the accounting rule: it reports a record that was in fact processed normally as needing a human decision, and is caught by the two cases that assert a healthy record is accounted for without being a disposition.

Existing guard suites were re-run unchanged: `fm-teardown-endpoint-safety` (5 ok), `fm-teardown-evidence` (6 ok), `fm-backend-herdr` (159 ok).

## Why there is no one-shot guard

The script and its tests ship, and there is no refusal to run twice.

Earlier versions carried a one-shot guard: `--apply` refused against a home judged already migrated.
Three consecutive reviews found a defect in it, each one in the definition of which records it counted.
The first gated on prior work alone, which stranded every record an interrupted run had not reached and left the hand-write as the only remedy - the exact action the governing rule forbids.
The second gated on remaining work but counted any unbound record, including legacy tmux records and records on backends with no observation path, which can never be repaired; a home holding one of those never reached the refusal at all, so the guard silently did nothing there.
The third finding was that the header's "cannot be satisfied by accident" claim was therefore false, and it was printed verbatim by `--help`.

The guard was deleted rather than corrected a fourth time.
Every argument about which records count as candidates dissolves with it, because that question only existed to feed the guard.
With no guard, there is no candidate definition to be wrong about.

### What replaced it

**Idempotence, proven rather than asserted.**
The protection the guard was reaching for is that a repeated run must not corrupt what a previous run wrote.
That is now structural: the only shape this script writes is a record with zero `endpoint_task_id=` lines, so a migrated record - which carries exactly one correct binding - is a non-candidate on every later run and is skipped untouched.
An operation safe to repeat needs no memory of whether it already ran, and removing the consequence beats getting the trigger right.
The same property means an interrupted run simply resumes: records already written are skipped, records never reached are repaired, and no state is stranded.

**The receipt is the record.**
Every run appends to `data/endpoint-binding-migration-receipts.log` in the target home: when it ran, against which home, in which mode, with which tool versions, the per-record outcome, and the totals.
Observe-only runs are recorded too, because an observe run is still a run that happened.
The receipt is written as the run proceeds rather than summarised at the end, so a run that dies halfway leaves a start line with no end line and is distinguishable from a completed one instead of looking identical to it.
A run that cannot write its receipt refuses to run, because an unrecorded run is the state this design exists to make impossible.

The receipt is a record, never an authority.
Nothing in the script reads it back to decide whether to run or what to write, so it cannot become the inferred state the deleted guard kept getting wrong.
This is the difference between recording an event durably at its source and building an instrument that has to tell apart two worlds it cannot see.

**The anti-assertion guarantee is unchanged and was never the guard's job.**
The per-record filter enforces it unconditionally: the script only ever appends a binding to a record that has none, and only from a live observation of that record's own endpoint.
No path through the script writes an unobserved or asserted value, on any home, in any state.

### Guard-class coverage for the replacement

The mutation experiment above covers the new properties in all three directions the ruling required.
`double-write-already-bound-record` sends an already-bound record back through observation so a repeated run appends a second binding and provenance pair; it is caught by the idempotence case and by every other fixture holding a bound record.
`reintroduce-one-shot-refusal` restores the last shipped form of the guard, and is caught by exactly the two cases that run twice against a fully migrated home - idempotence means safe to repeat, not clever about refusing.
`run-without-writing-receipt` lets a run complete without recording itself and is caught by exactly the three receipt cases.

The permanent guarantee - that teardown refuses an unbound or mismatched record - is owned by `tests/fm-teardown-endpoint-safety.test.sh`, which this change left untouched and green.
