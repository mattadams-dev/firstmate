# Raw perturbation results - fm-serial-shard-order-sensitivity

Raw output, committed before the analysis drawn from it.

Machine conditions for every run below: Linux 6.18.33.2-microsoft-standard-WSL2, 32 cores, 17979 MiB
total memory. Idle-machine runs had 6.8-12.6 GiB available and load average ~4. Loaded runs are
labelled with their load average; load was produced by `timeout N bash -c 'while :; do :; done'`
spinners, always time-capped so none could outlive the experiment. Memory available never dropped
below 9.3 GiB, well above the 2 GiB floor the brief sets.

Repo state at the start: branch fm/fm-serial-shard-order-sensitivity off 423e099, `bin/` unmodified
throughout - every perturbation was applied to a FIXTURE COPY of the worker, never to the product.

## Baseline

`bash tests/fm-remote-job.test.sh` -> ALL TESTS PASSED, real 0m37.430s, idle.

## Part 1 - the assertion CI caught

### Timing margin (.evidence/window.sh)

The assertion "the worker expires queued jobs before they can mutate" built its expired condition
by rewriting a live queued record's `queue_deadline` while a 1-second blocking job held the worker.

```
inject_delay=0
first_job_deadline=1785972339
queued_original_queue_deadline=1785972343
detect_running_at=1785972338.081780292
queued_job_staged_at=1785972338.109812577
queue_deadline_rewritten_at=1785972338.113565912
margin_seconds_before_worker_free=0.886
queued_state_when_rewritten=queued
first_job_exit=124
queued_job_exit=124
queued_job_mutated=no
VERDICT=assertion-would-pass
```

The entire safety margin is **0.886 seconds on an idle machine**.

A 1.2s delay placed BEFORE staging did not summon the red (margin -1.069s, still passed). Moving the
whole block later does not widen the vulnerable window, which is bounded by the gap between the
queued job becoming visible and its deadline being rewritten. Recorded because a perturbation that
produces nothing is still a result.

### Two-sided perturbation (.evidence/perturb.sh)

Per the captain's method: inject delay on one side of the boundary at a time.

```
=== CONTROL - no perturbation ===
perturbation: P1_expiry_publish=0 P2_check_to_claim=0 P3_stage_to_rewrite=0 wait_grace=30
queued_job_exit=124  queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P1 - delay the expiry publication by 3s ===          [PUBLISHER SIDE]
queued_job_exit=124  queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P1-hard - delay the expiry publication by 25s ===    [PUBLISHER SIDE]
queued_job_exit=124  queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P2 - delay 3s between the expiry check and the claim ===   [PUBLISHER SIDE]
queued_job_exit=124  queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P3 - delay 1.5s between publishing the queued job and rewriting its deadline ===  [TEST SIDE]
queued_job_exit=0    queued_job_mutated=yes
OBSERVED_CI_RED=YES  "an expired queued job did not publish a timeout result"

=== P3 repeat, 5 consecutive runs ===                    [TEST SIDE]
queued_job_exit=0 / queued_job_mutated=yes / OBSERVED_CI_RED=YES     5 of 5

=== P4 - P3 plus a maximally generous await (grace 300s) ===  [TEST SIDE]
queued_job_exit=0    queued_job_mutated=yes
OBSERVED_CI_RED=YES  "an expired queued job did not publish a timeout result"
```

The test side summons the red on demand, 5 of 5. The publisher side does not summon it at any
injected delay, including one deliberately longer than the caller's entire await bound.

P4 is the separate half of the method: lengthening the await does NOT make the red vanish, because
the result was published promptly and correctly. The red was never an await-length problem.

### Full CI signature reproduced in the real test file

`tests/fm-remote-job.test.sh` copied verbatim with one 1.5s test-side delay injected between staging
the queued job and rewriting its deadline:

```
ok - the worker enforces the job timeout and publishes its result
not ok - an expired queued job did not publish a timeout result
```

Reproduced 4 of 4 runs, byte-identical to the CI failure line.

### World-(b) probe (.evidence/world-b.sh)

```
--- deadline already past at the worker's first sight ---
deadline_offset_at_stage=+0s  check_to_claim_delay=3s
exit=124  mutated=no
WORLD_B=not reproduced - the worker refused to execute past the deadline

--- deadline expires during the check-to-claim gap ---
deadline_offset_at_stage=+2s  check_to_claim_delay=5s
queue_deadline=1785972645 completed_at=1785972648 (deadline passed 3s before completion)
exit=0  mutated=yes
WORLD_B=LIVE - the worker executed a job past its durable queue deadline
```

The second reading is an ADJACENT BOUNDED OBSERVATION, not the cause of the CI red, and the two are
different worlds. In the CI failure the deadline was still ~4 seconds in the FUTURE when the worker
checked it, so the check-to-claim gap plays no part. The expiry check is a check-time test, and a
job claimed just before its deadline runs to completion afterwards; that latency is bounded by the
claim path and absorbed by `FM_REMOTE_JOB_WAIT_GRACE` (30s), which is why the caller is still
waiting. It took a 5-second artificial injection to expose it at all. Reported, not silently fixed.

## Part 2 - the teardown error

### Teardown probe (.evidence/teardown.sh)

Reproducing the test's EXIT trap shape (`kill $(cat worker.pid); rm -rf -- "$TMP_ROOT"`):

```
=== control (no shutdown delay) ===          rm_stderr: (none)  TEARDOWN_RACE=not reproduced
=== shutdown entry delayed 1s ===            rm_stderr: (none)  TEARDOWN_RACE=not reproduced
=== shutdown mid-write delay 0.3s / 1s ===   rm_stderr: (none)  TEARDOWN_RACE=not reproduced
```

`rm: Directory not empty` did NOT reproduce on an idle machine, including under the perturbed real
test that did produce the `not ok` line (0 of 4). A negative result on an idle machine, recorded as
such. The mechanism was then pursued structurally instead of by chasing the message.

### Respawn probe (.evidence/respawn.sh) - decisive

After the trap's single kill, is the worker tree actually stopped?

```
=== clean shutdown ===
supervisor_still_alive_after_trap=yes
state_tree_recreated_after_removal=YES
recreated_entries: jobs logs worker.identity worker.lock worker.pid worker.ready
TEARDOWN_LEAK=CONFIRMED - the trap did not stop the worker tree

=== shutdown that cannot complete ===
supervisor_still_alive_after_trap=yes
state_tree_recreated_after_removal=YES
recreated_entries: jobs logs worker.identity worker.lock worker.pid worker.ready
TEARDOWN_LEAK=CONFIRMED - the trap did not stop the worker tree
```

Confirmed in BOTH modes. What the test launches is `worker_supervise_linux`, which respawns its
`--serve` child on any non-zero child exit. The trap signals only the recorded child, so the
supervisor rebuilds the entire tree - and when that rebuild lands during the removal rather than
after it, the reading is `rm: cannot remove ...: Directory not empty`.

### Corroborating footprint on the machine

14 orphaned worker supervisors were found alive with their temp roots already deleted, from
`fm-remote-job.*`, `fm-on.*`, `fm-remote-handoff.*`, `fm-remote-trace-context.*`, and a removed
no-mistakes worktree - each a bash process spinning a 0.05s poll loop indefinitely. Left in place
rather than terminated: they belong to other lanes' debris, not to this task.

## Part 3 - the second flake, found under load

Under deliberate load the ORIGINAL suite flaked on a DIFFERENT assertion:

```
load average 30, 6 runs of the original:
run 5 exit=1 : not ok - queue time consumed the second job's execution timeout
```

That case inferred its guarantee from whether a 1.8s sleep fit inside a 3s window - 1.2s of slack
against process startup, tracked-command validation and poll latency. Same defect class: a slow
machine and a subtracted window are indistinguishable through a stopwatch, and the failure names a
defect that did not occur.

### Mutation check of the rewritten assertion (.evidence/mutation-check.sh)

A deflaked assertion that can no longer fail is worse than the flake, so the replacement was checked
against a worker whose execution window is measured from staging instead of from the claim:

```
=== correct worker ===
granted_after_queue_wait=2 (assertion requires >= 1)
behavioral_exit=0 side_effect=present
NEW_ASSERTION=passes

=== mutant: window measured from staging ===
granted_after_queue_wait=0 (assertion requires >= 1)
behavioral_exit=0 side_effect=present
NEW_ASSERTION=FAILS - "queue time consumed the second job's execution timeout"
```

Note the mutant's BEHAVIORAL result still looks correct - exit 0, side effect present. The old
stopwatch style could only have caught this mutant by being tight enough to also catch the machine.
The record-reading check catches it with no timing sensitivity at all.

## Part 4 - a flake introduced and removed

The first version of the added pre-expired case stopped the worker tree, staged the job, then
started a replacement. Under load average 93 that stop racing the restart stranded worker ownership:

```
fixed  run 2 exit=1 : not ok - remote job worker did not report ready after startup
fixed  run 3 exit=1 : not ok - remote job worker did not report ready after startup
```

The readiness wait is 20 seconds, so this was stranded ownership rather than slowness. Rebuilt to
stage the job before any worker has ever existed for that state root, which needs nothing stopped,
restarted, or raced. Recorded because a fix that introduces a flake while removing one is exactly
the outcome this task exists to prevent.

## Part 5 - interleaved head-to-head under load

Original and fixed alternated so both met the same conditions, load average 74-92 throughout:

```
original  run 1 exit=1 : not ok - queue time consumed the second job's execution timeout
fixed     run 1 exit=0 : ALL TESTS PASSED
original  run 2 exit=0 : ALL TESTS PASSED
fixed     run 2 exit=0 : ALL TESTS PASSED
original  run 3 exit=0 : ALL TESTS PASSED
fixed     run 3 exit=0 : ALL TESTS PASSED
original  run 4 exit=0 : ALL TESTS PASSED
fixed     run 4 exit=0 : ALL TESTS PASSED
original  run 5 exit=0 : ALL TESTS PASSED
fixed     run 5 exit=0 : ALL TESTS PASSED
```

Totals under load across all sessions: original 2 failures in 11 runs; final fixed version 0 in 11.

**This repetition is the WEAKEST evidence here and is recorded as corroboration only.** Eleven clean
runs is exactly what a flake looks like between occurrences, which is the whole reason the captain's
method replaces repetition with perturbation. The load-bearing evidence is Part 1: the failure is
summonable on demand from the test side and not summonable from the publisher side, and Parts 3 and
4, where the replacement assertions were checked against a deliberately broken worker rather than
against a quiet runner.
