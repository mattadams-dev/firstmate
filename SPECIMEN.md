# RED SPECIMEN - serial shard 4, the only naturally-occurring failure under the changed code

Captured 2026-08-06 on the captain's order, BEFORE any perturbation ran. Perturbation destroys the
scene, and this is the one occurrence that happened on its own.

## What failed

    Behavior portable serial 1:  success
    Behavior portable serial 2:  success
    Behavior portable serial 3:  success
    Behavior portable serial 4:  FAILURE     <- the shard this task exists to deflake

Siblings passing ISOLATES the failure to the target rather than suggesting infrastructure noise.

## Pointers

| What | Where |
|---|---|
| Failing CI run | https://github.com/mattadams-dev/firstmate/actions/runs/31069846420 |
| PR | https://github.com/mattadams-dev/firstmate/pull/15 |
| Branch head, ls-remote verified | `refs/heads/rescue/serial-shard-red-specimen` = `9fb50b89d95c930700d0393bb5e5b9a03dc271fe` |
| Pipeline run id | `01KZAFDND435TB5J3SA3A55W19` |
| Local evidence at capture time | `/tmp/no-mistakes-evidence/01KZAFDND435TB5J3SA3A55W19/` - 31 files, copied here |

## THE TWO WORLDS THIS SPECIMEN MUST SEPARATE

The captain's framing, and the reason this is not simply a regression:

**WORLD A - CHANGE-INCOMPLETENESS.** The OLD wall-clock assertion survived somewhere the change did
not reach. Then the red is the old blind instrument still present, and the fix is to finish removing
it.

**WORLD B - THE HONEST INSTRUMENT'S FIRST TRUE READING.** The NEW record-based assertion is failing,
and it is correctly reporting a REAL PRODUCT DEFECT that the old wall-clock assertion masked by
reading two worlds identically. **This world was predicted by the brief's own constraint, and it
presents identically to a flake.**

> **A deflake that turns its target red may be a deflake that worked.** - the captain

## THE METHOD THAT SEPARATES THEM

Not repetition. Repetition samples the dice; it cannot distinguish a test that reads too early from
code that publishes too late, because both present identically under re-running.

**Two-sided perturbation, on demand:**
1. force the PRODUCT's timing, observe whether the red can be summoned
2. force the TEST's ordering, observe whether the red can be summoned

**The side that can summon the failure owns it.** If neither can, the honest state is `unknown`, not
a verdict - and `flaky test` is forbidden as the convenient answer.

## FIRST DIAGNOSTIC QUESTION, before any perturbation

**WHICH ASSERTION FORM FAILED?** Old wall-clock, or new record-based? That single reading points at
world A or world B before a single re-run happens.
