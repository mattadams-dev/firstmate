# Endpoint binding migration

One-shot repair of `endpoint_task_id=` in `state/<id>.meta` records created before `bin/fm-spawn.sh` began writing that field.
Run 2026-08-01 against the primary home, `/home/jamada/code/personal/firstmate`.

The migration script and its tests were deleted in the same change that landed this record; see "Retirement" below.
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

Behavior suite, driven through a fake herdr CLI serving canned inventory by content:

```
ok - absent_endpoint_refused
ok - ambiguous_pane_refused
ok - dry_run_writes_nothing
ok - existing_binding_untouched
ok - foreign_workspace_refused
ok - label_names_other_task_refused
ok - observable_binding_migrates
ok - pane_mismatch_refused
ok - teardown_validator_accepts_migrated_record
ok - teardown_validator_rejects_unmigrated_record
ok - tmux_reported_not_silent
ok - unobservable_backend_refused

all 12 cases passed
```

Mutation experiment.
Each mutation neutralises one guard by replacing its condition with `true`, leaving the refusal block intact, and is pinned to its target line by content so a drifted line number fails loudly rather than silently mutating unrelated code.

```
== baseline: unmutated script ==
BASELINE green (12)

== mutations that let an unobserved value be written ==
CAUGHT   value-from-filename-not-label      failing: label_names_other_task_refused
CAUGHT   skip-pane-identity-check           failing: pane_mismatch_refused
CAUGHT   skip-home-workspace-check          failing: foreign_workspace_refused
CAUGHT   accept-ambiguous-pane              failing: ambiguous_pane_refused

== control: a blanket bypass should be caught broadly, not narrowly ==
CAUGHT   blanket-write-without-observation  failing: absent_endpoint_refused ambiguous_pane_refused foreign_workspace_refused label_names_other_task_refused pane_mismatch_refused

RESULT: every mutation was caught by exactly the expected case(s)
```

Both directions hold.
A genuinely observable binding still migrates (baseline green, twelve cases).
Each mutation that would let an unobserved value be written is caught by exactly the case that owns that guard, so the suite identifies which protection is missing rather than going uniformly red.

The `value-from-filename-not-label` mutation is the one that matters most: it is precisely "assertion instead of observation", and it is caught by exactly one case.
The blanket-bypass control breaks five cases at once, which is the correct shape for a change that removes observation entirely rather than one specific check.

Existing guard suites were re-run unchanged: `fm-teardown-endpoint-safety` (5 ok), `fm-teardown-evidence` (6 ok), `fm-backend-herdr` (159 ok).

## Retirement

The script and its tests were deleted in the same change that landed this record, so the merged default branch does not carry them.

Deletion was chosen over a refuse-to-run-twice marker.
A marker is home-local, so it would only stop a second run in the home that already ran; every other home would still hold a working tool that fills a safety field on demand.
The window this backfill addressed is closed - `fm-spawn.sh` has written the field since before these records' successors - so a surviving re-runnable backfill would be liability with no remaining use, which is the "standing bypass machinery" failure mode this was written to avoid.

The tests were one-shot for the same reason: a permanent test for a deleted script would assert nothing.
Their value is the recorded result above, taken against the real script at the time it ran.
The permanent guarantee - that teardown refuses an unbound or mismatched record - is owned by `tests/fm-teardown-endpoint-safety.test.sh`, which this change left untouched and green.
