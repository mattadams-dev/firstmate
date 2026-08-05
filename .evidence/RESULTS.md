# Raw perturbation results - fm-serial-shard-order-sensitivity

Raw output, committed before any analysis drawn from it.

Machine conditions for every run below: Linux 6.18.33.2-microsoft-standard-WSL2, 17979 MiB total
memory, 7.4-12.6 GiB available across the runs, otherwise idle apart from this lane. This is an
IDLE machine; the CI specimen came from a loaded runner where the shard took 338s.

Repo state: branch fm/fm-serial-shard-order-sensitivity off 423e099, `bin/` unmodified.

## Baseline

`bash tests/fm-remote-job.test.sh` -> ALL TESTS PASSED, real 0m37.430s.

## Timing margin of the suspect assertion (.evidence/window.sh)

The assertion "the worker expires queued jobs before they can mutate" builds its expired
condition by rewriting a live queued record's `queue_deadline` while a 1-second blocking job
holds the worker.

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

A 1.2s delay placed BEFORE staging did not summon the red (margin -1.069s, still passed): moving
the whole block later does not widen the vulnerable window, which is bounded by the gap between
the queued job becoming visible and its deadline being rewritten.

## Two-sided perturbation (.evidence/perturb.sh)

Per the captain's method: inject delay on one side of the boundary at a time.

```
=== CONTROL - no perturbation ===
perturbation: P1_expiry_publish=0 P2_check_to_claim=0 P3_stage_to_rewrite=0 wait_grace=30
queued_job_exit=124
queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P1 - delay the expiry publication by 3s ===          [PUBLISHER SIDE]
queued_job_exit=124
queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P1-hard - delay the expiry publication by 25s ===    [PUBLISHER SIDE]
queued_job_exit=124
queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P2 - delay 3s between the expiry check and the claim ===   [PUBLISHER SIDE]
queued_job_exit=124
queued_job_mutated=no
OBSERVED_CI_RED=no (assertion passes)

=== P3 - delay 1.5s between publishing the queued job and rewriting its deadline ===  [TEST SIDE]
queued_job_exit=0
queued_job_mutated=yes
OBSERVED_CI_RED=YES  "an expired queued job did not publish a timeout result"

=== P3 repeat, 5 consecutive runs ===                    [TEST SIDE]
queued_job_exit=0 / queued_job_mutated=yes / OBSERVED_CI_RED=YES     x5

=== P4 - P3 plus a maximally generous await (grace 300s) ===  [TEST SIDE]
queued_job_exit=0
queued_job_mutated=yes
OBSERVED_CI_RED=YES  "an expired queued job did not publish a timeout result"
```

The test side summons the red on demand, 5/5. The publisher side does not summon it at any
injected delay, including one deliberately longer than the caller's whole await bound.

P4 matters separately: lengthening the await does NOT make the red vanish, because the result
was published promptly and correctly. The red is not an await-length problem at all.

## Full CI signature reproduced in the real test file

`tests/fm-remote-job.test.sh` copied verbatim with a single 1.5s test-side delay injected
between staging the queued job and rewriting its deadline:

```
ok - the worker enforces the job timeout and publishes its result
not ok - an expired queued job did not publish a timeout result
```

Reproduced 4/4 runs. Byte-identical to the CI failure line.

## World-(b) probe: can the publisher run a job past its durable deadline? (.evidence/world-b.sh)

```
--- deadline already past at the worker's first sight ---
deadline_offset_at_stage=+0s  check_to_claim_delay=3s
exit=124
mutated=no
WORLD_B=not reproduced - the worker refused to execute past the deadline

--- deadline expires during the check-to-claim gap ---
deadline_offset_at_stage=+2s  check_to_claim_delay=5s
queue_deadline=1785972645 completed_at=1785972648 (deadline passed 3s before completion)
exit=0
mutated=yes
WORLD_B=LIVE - the worker executed a job past its durable queue deadline
```

Recorded as an adjacent bounded observation, NOT as the cause of the CI red. See the analysis
commit for why the two are different worlds and why the second reading is bounded by design.

## Teardown probe (.evidence/teardown.sh)

Reproducing the test's EXIT trap shape (`kill $(cat worker.pid); rm -rf -- "$TMP_ROOT"`):

```
=== control (no shutdown delay) ===          rm_stderr: (none)  TEARDOWN_RACE=not reproduced
=== shutdown entry delayed 1s ===            rm_stderr: (none)  TEARDOWN_RACE=not reproduced
=== shutdown mid-write delay 0.3s / 1s ===   rm_stderr: (none)  TEARDOWN_RACE=not reproduced
```

The `rm: Directory not empty` line did NOT reproduce on this idle machine, including under the
perturbed real test that did produce the `not ok` line (0/4 runs). Recorded as a negative
result on an idle machine, which says little about a loaded runner. The mechanism is pursued
structurally in the next probe rather than by chasing the message.
