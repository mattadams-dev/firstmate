# Deflaking `Behavior portable serial 4` - independent test-phase evidence

Host: Linux 6.18.33.2-microsoft-standard-WSL2, 32 cores, 17979 MiB.
Base `0d65ed4` vs target `95ea090`. Product code under `bin/` is byte-identical
between the two columns; every perturbation and mutant below was applied to the
suite's *fixture copy* of the worker, never to `bin/`.

| file | what it shows |
| --- | --- |
| `perturb-test-side-original.txt` | the original test, perturbed on the TEST side, reproduces the CI line 5/5 |
| `perturb-test-side-fixed.txt` | the same perturbation at the same boundary, fixed test, 4/4 green |
| `perturb-fixed-6s-names-fixture.txt` | pushed past the blocking hold, the fixed test names the FIXTURE, not the worker |
| `perturb-publisher-side.txt` | perturbing the PRODUCT side (3s and 25s) never summons the red - world (b) stays excluded |
| `teardown-leak-headtohead.txt` | supervisors left alive after each suite exits, base vs target, four suites |
| `mutation-record-check.txt` | the new record-only queue-wait check kills a mutant the behavioral assertions pass |
| `load-headtohead.txt` | interleaved runs at load average 75-120; base reproduced the second flake spontaneously |
| `fixed-fm-remote-job-idle.txt` | full target-suite transcript, idle |

## 1. Which side owns the race (the captain's binding constraint)

Test side, confirmed here independently by two-sided perturbation.

    ORIGINAL, delay inserted between staging the queued job and rewriting its live deadline
    FM_PERTURB_TEST_SIDE=0  exit=0   ok - the worker expires queued jobs before they can mutate
    FM_PERTURB_TEST_SIDE=2  exit=1   not ok - an expired queued job did not publish a timeout result   (5/5)

    PRODUCT, delay inserted before the worker publishes the queued-expiry result
    FM_PERTURB_PUBLISHER=3   exit=0  ok - the worker expires queued jobs before they can mutate
    FM_PERTURB_PUBLISHER=25  exit=0  ok - the worker expires queued jobs before they can mutate

25s is longer than the caller's whole await bound and still produces no red. The
test side summons it on demand, the product side cannot: the test owned it.

## 2. The fixed case cannot be summoned the same way, and fails honestly when it cannot run

    FIXED, same perturbation, same boundary
    2s exit=0, 2s exit=0, 2s exit=0, 4s exit=0   ok - the worker expires queued jobs before they can mutate
    6s exit=1  not ok - fixture precondition lost: the blocking job released the worker before the queued deadline passed

Past the 5s blocking hold the ordering genuinely cannot be established, and the
suite says so about the FIXTURE instead of accusing the worker.

## 3. Teardown

    suite                                base                          target
    fm-remote-backlog-handoff            PASSES, leaks 1 supervisor    PASSES, leaks 0
    fm-remote-secondmate-trace-context   PASSES, leaks 1 supervisor    PASSES, leaks 0
    fm-remote-job                        leaks 0 (idle)                leaks 0
    fm-on                                pre-existing PATH fail, leaks 1   same fail, leaks 0

Each leaked supervisor's temp root was already deleted by the suite that started
it. 23 orphans from earlier runs of these four suites were alive on this host
before testing began, which is the same defect observed in the wild.

## 4. The record-only queue-wait check is discriminating

Mutant, fixture worker only: execution deadline computed from STAGE time.

    control (no mutant)                 granted_after_queue_wait=6, case passes
    mutant + check softened             granted_after_queue_wait=0, behavioral assertions still say "ok"
    mutant + check as shipped           exit 1, "not ok - queue time consumed the second job's execution timeout"

At the target's safe margins the behavioral assertions cannot see this defect;
the record-only computation does.

## 5. Load (corroboration only, weakest evidence)

    round 1 BASE loadavg 75.58   exit=0
    round 1 HEAD loadavg 100.52  exit=0
    round 2 BASE loadavg 108.54  exit=0
    round 2 HEAD loadavg 110.63  exit=0
    round 3 BASE loadavg 118.22  exit=1  not ok - queue time consumed the second job's execution timeout
    round 3 HEAD loadavg 119.56  exit=0

The base column reproduced the SECOND flake spontaneously at load 118 - the one
the change addresses by reading the durable record. Memory available never fell
below 10.7 GiB.
