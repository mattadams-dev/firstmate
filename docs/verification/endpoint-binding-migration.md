# Endpoint binding migration

Audience: maintainer verification.

One-shot repair of `endpoint_task_id=` in `state/<id>.meta` records created before `bin/fm-spawn.sh` began writing that field.
Run 2026-08-01 against the primary home.

Unlike its sibling records, this one embeds captured live tool output, whose paths and identifiers are the evidence itself and are never edited; the siblings' zero-absolute-path form binds prose only.
That divergence is declared here so a later path-counting audit reads it as deliberate rather than as a defect, which is what an undeclared divergence is indistinguishable from.

`bin/fm-migrate-endpoint-binding.sh` and its two test files ship; see "Retirement" below for what "one-shot" is carried by now that it is not carried by deletion.
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

## Guard-class evidence: mutation testing, both directions

The output below is the suite and mutation harness as they stand with all four refusal shapes reporting and the one-shot guard in place.
The twelve-case output captured against the script at the moment of the applied run is superseded by it; the run's own captured output above is unchanged.

Behavior suite, driven through a fake herdr CLI serving canned inventory by content:

```
$ bash tests/fm-migrate-endpoint-binding.test.sh
ok - absent_endpoint_refused
ok - ambiguous_pane_refused
ok - dry_run_writes_nothing
ok - duplicated_binding_reported_not_skipped
ok - empty_binding_reported_not_skipped
ok - existing_binding_untouched
ok - foreign_workspace_refused
ok - label_names_other_task_refused
ok - mismatched_binding_reported_not_skipped
ok - observable_binding_migrates
ok - one_shot_allows_observe_on_migrated_home
ok - one_shot_allows_resume_after_partial_run
ok - one_shot_refuses_second_apply
ok - pane_mismatch_refused
ok - teardown_validator_accepts_migrated_record
ok - teardown_validator_rejects_unmigrated_record
ok - tmux_reported_not_silent
ok - unobservable_backend_refused
ok - valid_binding_is_not_a_disposition

all 19 cases passed
```

The empty-binding and duplicated-binding fixtures are synthetic on purpose, because zero real specimens existed in the migrated home.
A refusal shape without a fixture proving it fires is how the silent-skip hole survived review the first time.
`valid_binding_is_not_a_disposition` proves the other direction: a correctly bound record is simply not a candidate, so reporting the three broken shapes did not turn every bound record into a disposition item.

Mutation experiment.
Each mutation neutralises one guard by replacing its condition with `true`, leaving the refusal block intact, and is pinned to its target line by content so a drifted line number fails loudly rather than silently mutating unrelated code.

```
$ bash tests/fm-migrate-endpoint-binding-mutation.sh
== baseline: unmutated script ==
BASELINE green (19)

== mutations that let an unobserved value be written ==
CAUGHT   value-from-filename-not-label      failing: label_names_other_task_refused
CAUGHT   skip-pane-identity-check           failing: pane_mismatch_refused
CAUGHT   skip-home-workspace-check          failing: foreign_workspace_refused
CAUGHT   accept-ambiguous-pane              failing: ambiguous_pane_refused

== mutations that turn a refusal shape back into a silent skip ==
CAUGHT   silent-skip-empty-binding          failing: empty_binding_reported_not_skipped
CAUGHT   silent-skip-duplicated-binding     failing: duplicated_binding_reported_not_skipped

== mutations on the one-shot property, in both directions ==
CAUGHT   neuter-one-shot-guard              failing: one_shot_refuses_second_apply
CAUGHT   refuse-on-any-prior-work           failing: one_shot_allows_resume_after_partial_run

== control: a blanket bypass should be caught broadly, not narrowly ==
CAUGHT   blanket-write-without-observation  failing: absent_endpoint_refused ambiguous_pane_refused foreign_workspace_refused label_names_other_task_refused pane_mismatch_refused

RESULT: every mutation was caught by exactly the expected case(s)
```

Both directions hold.
A genuinely observable binding still migrates (baseline green, nineteen cases).
Each mutation that would let an unobserved value be written is caught by exactly the case that owns that guard, so the suite identifies which protection is missing rather than going uniformly red.

The `value-from-filename-not-label` mutation is the one that matters most: it is precisely "assertion instead of observation", and it is caught by exactly one case.
The two silent-skip mutations restore the original blind spot by dropping a report and skipping the record, and each is caught by exactly the fixture that owns that refusal shape.
The one-shot guard is mutated in both directions, because it has two ways to be wrong.
`neuter-one-shot-guard` removes the refusal entirely and is expected to break only `one_shot_refuses_second_apply`: every other fixture home either still has an unbound candidate or carries zero provenance lines, so the guard never fires there and removing it changes nothing.
`refuse-on-any-prior-work` restores the round-1 condition that gated on prior work alone, and is expected to break only `one_shot_allows_resume_after_partial_run`, since a fully migrated home refuses under both conditions.
Listing `one_shot_allows_observe_on_migrated_home` for either would be an expectation the experiment could satisfy only by accident, which is the same rule the blanket-bypass control already follows for `unobservable_backend_refused`.
The blanket-bypass control breaks five cases at once, which is the correct shape for a change that removes observation entirely rather than one specific check.

Existing guard suites were re-run unchanged: `fm-teardown-endpoint-safety` (5 ok), `fm-teardown-evidence` (6 ok), `fm-backend-herdr` (159 ok).

## Retirement

The script and its tests ship.
Retired here means the script cannot be run casually or by accident, not that it was erased.
It is retained deliberately as the documented recovery procedure for a future legacy lane, and its tests are retained with it because they are what keeps the next re-runner's guards honest.

The one-shot property is carried by a guard rather than by absence.
`--apply` refuses against a home that is already fully migrated: some `state/*.meta` carries an `endpoint_task_id_provenance=` line AND no unbound candidate remains, where an unbound candidate is a record with a `window=` line and zero `endpoint_task_id=` lines.
It reports the provenance count on refusal, and observe-only mode stays allowed on such a home.

The second half of that condition was added before landing, and the reason is worth recording.
The first version of this guard gated on prior work alone: any provenance present meant refuse.
That made a partially completed run unresumable - a run interrupted after writing some records would leave the rest stranded permanently, with their teardown blocked and the hand-write as the only remaining remedy, which is the exact action the governing rule forbids.
Gating on remaining work instead refuses the casual re-run the rider targets while letting an interrupted run finish the home it started.

Resuming is safe because the per-record filter writes only to a record with zero binding lines.
A resumed run physically cannot rewrite, overwrite, or re-stamp an already-migrated record, so the anti-overwrite guarantee sits in the per-record filter and the home-level guard only has to stop a re-run with nothing left to do.
The unbound-candidate test is deliberately the loose one the loop itself uses rather than a backend-narrowed copy, because duplicating backend routing in the guard would let the two drift apart, and a permissive guard cannot cause a write the per-record filter would not already allow.

That guard cannot drift, because the proof the backfill already ran is the repaired records themselves rather than a marker kept alongside them.
A marker can be deleted, lost in a home copy, or never written after a partial run; the provenance lines cannot go missing without the repair itself going missing.

It cannot be satisfied by accident, because there is no flag to pass, no variable to set, and no file to remember.
Defeating it means stripping the provenance lines off already-repaired records, which is deliberate, visible in a diff, and simultaneously destroys the audit trail those lines exist to keep.
The guard and the provenance record protect each other.

It preserves the recovery use the script is retained for, because a genuinely new legacy home carries zero provenance lines, so the procedure works there on first run and refuses once that run has finished the home.
An interrupted run leaves unbound candidates behind, so the next `--apply` resumes and repairs only what is still stranded.

It blocks the hazard rather than the looking.
The failure mode this rider guards against is a tool that fills a safety field on demand, so the guard gates the write; observing and reporting an already-migrated home stays available, which is what a future investigator actually needs.

The permanent guarantee - that teardown refuses an unbound or mismatched record - is owned by `tests/fm-teardown-endpoint-safety.test.sh`, which this change left untouched and green.
