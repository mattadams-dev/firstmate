# AGENTS.md context-diet verification

This record holds the empirical facts the `AGENTS.md` context diet acts on: the birth-weight measurement instrument, and the cross-harness skill-listing coverage that decides whether section 13's trigger index may be replaced by a pointer.

`.agents/skills/firstmate-coding-guidelines/SKILL.md` owns the knowledge-placement policy this diet applies, including the extraction break-even and the two-sentence description cap that came out of these measurements.

## Where the remaining value is - read this before resuming

The diet's remaining scope is **duplicate removal, not extraction**.

Extraction is now measured as a poor lever: a new skill costs a fixed 300 to 400 resident tokens whether or not it ever loads, so nothing below roughly 1,500 bytes of removable procedure can pay for itself at any trigger rarity.
Removing a duplicate whose owner already exists carries no such tax and returns its full size.

The two results in this record are the comparison:

| Move | Class | Saving per call |
| --- | --- | --- |
| Section 2 operational-home tree | duplicate, owner already existed | 4,228 tokens |
| Section 7 supersession sequence | extraction behind a new trigger | 77 tokens |

Do not resume hunting extractions in `AGENTS.md`.
Section 7 was assessed block by block and yielded exactly one qualifying block out of seventeen, because the file's remaining bulk is contract rather than mechanics, and a contract clause has no trigger - it is what makes a trigger recognisable.
Look for content that is restated from an owner declared elsewhere, which is what the section 2 tree turned out to be.

Prose trimming is close to done regardless: `AGENTS.md` finished this work at 53,628 bytes against an original ~25K aspiration and a revised ~45K target, neither of which is reachable without moving laws behind triggers.
The remaining floor is the tool-schema surface, tracked separately as `fm-tool-schema-surface-diet`.

## Birth-weight measurement instrument

Birth weight is the resident cost a session pays before any work happens.
The reading is the first `message.usage` line of a session transcript, summed as `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.

Command, against a project transcript directory under `~/.claude/projects/`:

```sh
jq -rc 'select(.message.usage != null) | .message.usage |
  ((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0))' \
  "$transcript" | head -1
```

### Interactive readings, primary checkout, 2026-08-05

Run against `~/.claude/projects/-home-jamada-code-personal-firstmate/`, claude 2.1.222:

| Transcript | Birth weight |
| --- | --- |
| `bca2a833-8f07-4877-a580-af71c2ef46dd.jsonl` | 61,468 |
| `ad4af8d4-344a-4099-8226-98b2b6e7d8a9.jsonl` | 61,602 |

Those two reproduce the published baseline pair exactly, which is what validates the command above as the instrument.

The wider history is the caution this record exists to state: the five next-older transcripts in the same directory read 62,046, 59,927, 56,490, 56,490, 56,142 and 56,916.
The 134-token spread between the two baselines is therefore the spread of two adjacent same-day readings, not a stable noise floor.
Interactive birth weight moves with everything else resident in a session, so an interactive before/after pair separated by real work does not isolate an `AGENTS.md` change.

### Headless matched-pair instrument, 2026-08-05

Headless mode holds the rest of the resident surface constant, so it isolates the file under test.
Run in the worktree whose `AGENTS.md` is being measured, claude 2.1.222:

```sh
claude -p 'Reply with exactly: OK' </dev/null >/dev/null
# then read the newest transcript in ~/.claude/projects/<slug-of-that-worktree>/
```

Three consecutive readings against an unmodified `AGENTS.md` at 65,903 bytes:

| Run | Birth weight |
| --- | --- |
| 1 | 54,136 |
| 2 | 54,136 |
| 3 | 54,136 |

The instrument repeats exactly, so its noise floor is zero tokens and any delta it reports is real.

Two properties bound how the number may be quoted.
The headless floor (54,136) is lower than the interactive floor (~61,500) because headless mode carries a smaller tool and hook surface, so the two are not interchangeable as absolute figures.
The delta between a matched headless pair is still the delta the same edit produces interactively, because the edit changes only the `AGENTS.md` share that both modes carry in full.
Quote deltas from the headless pair and absolute floors from the interactive readings; never mix the two.

### Measured result, section 2 layout-tree removal, 2026-08-05

`AGENTS.md` went from 65,903 to 54,405 bytes by deleting the duplicated operational-home tree.
Matched headless pair, same worktree, same prompt, three runs each:

| State | `AGENTS.md` bytes | Birth weight |
| --- | --- | --- |
| before | 65,903 | 54,136 / 54,136 / 54,136 |
| after | 54,405 | 49,908 / 49,908 / 49,908 |

Delta: 4,228 tokens off every call, from 11,498 bytes removed - about 2.7 bytes per token, which is the expected density for text this full of paths and identifiers.
The delta clears the interactive baseline's 134-token spread by more than thirty times and the headless instrument's own zero spread outright, so it is a real saving rather than measurement drift.

## A loaded skill is as resident as AGENTS.md

This is the fact that decides which blocks are worth moving, and it is easy to get backwards.

Measured 2026-08-05, headless, claude 2.1.222.
A session was asked to invoke the `firstmate-coding-guidelines` skill and then reply.
Successive `message.usage` sums in the resulting transcript:

| Turn | Birth-weight sum | What just happened |
| --- | --- | --- |
| 1 | 49,935 | initial context |
| 2 | 49,935 | skill tool call issued |
| 3 | 53,517 | skill body now in context |

The skill body added 3,582 tokens, and every turn after it pays that cost for the rest of the session, exactly as `AGENTS.md` text does.

The consequence for the diet is that moving a block into a skill does not save its tokens.
It defers them, and only for the sessions that never fire the trigger:

```
saving per session = block tokens x P(this session never loads the skill)
```

A trigger that fires in nearly every session therefore saves nearly nothing, and costs an extra tool round trip on top.
Session start, supervision, escalation, and backlog updates are all in that class, so those blocks are poor extraction candidates on economics alone, independent of whether they are law or verb.

This also bounds the birth-weight instrument.
Birth weight is read before any skill loads, so it will report the full nominal saving for a conversion that in practice saves nothing.
Read a birth-weight delta together with the trigger's real fire rate; the delta alone is an upper bound, not the achieved saving.
Removing a duplicate outright - as the section 2 tree was removed, in favor of an owner that is read on demand rather than loaded wholesale - has no such discount, which is why it is the preferred move wherever an owner already exists.

## Every skill carries a fixed resident tax

Measured 2026-08-05, and it is the finding that decides whether an extraction is worth doing at all.

Extracting the supersession sequence from section 7 was measured in three states, headless, two runs each and identical within each state:

| State | `AGENTS.md` bytes | Birth weight |
| --- | --- | --- |
| before the extraction | 54,405 | 49,908 |
| `AGENTS.md` trimmed, skill directory absent | 53,838 | 49,806 |
| `AGENTS.md` trimmed, skill directory present | 53,838 | 49,990 |

Removing the block from `AGENTS.md` saved 102 tokens.
The skill's presence then added 184, for a net **+82** - the extraction made the floor worse before it had ever been loaded.

The cause is that a skill's `description:` frontmatter is resident in the harness listing from the first turn.
A new skill therefore costs, permanently and unconditionally:

- its listing description, measured at 184 tokens for a four-sentence description and 107 for the two-sentence rewrite that replaced it;
- its section 13 index line, which rider 3's verdict keeps resident;
- the inline trigger stub left behind in the owning section.

Against those it saves only the procedure body it removed.
Break-even is therefore roughly 300 to 400 tokens of genuinely removable procedure - about 1,500 bytes - and blocks below that cannot pay for themselves no matter how rare the trigger.

After rewriting the description to two sentences and shortening both the stub and the index line, the same extraction reads 49,831: a net saving of **77 tokens** against the 49,908 it started from.

Keep descriptions short for this reason.
A verbose trigger description is not free documentation; it is resident context charged to every session that never uses the skill.

## Cross-harness skill-listing coverage

The question this settles: does each supported harness inject the `.agents/skills/` listing, with each skill's trigger-bearing description, into its own context?
Where it does, `AGENTS.md` section 13's trigger index is a parallel copy of a generated listing.
Where it does not, section 13 is the only thing that makes those skills loadable.

### Descriptions are generated from skill frontmatter

Verified 2026-08-05.
The listing text is the skill's own `description:` frontmatter verbatim, not a separately maintained string.
`.agents/skills/bootstrap-diagnostics/SKILL.md` frontmatter and the rendered listing entry for that skill match character for character, including the trailing "A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load."

This check passes.

### Per-harness listing presence

Verified 2026-08-05 in a firstmate worktree containing `.agents/skills/` and its `.claude/skills` symlink.

| Harness | Version | Listing present | Descriptions present | Method |
| --- | --- | --- | --- | --- |
| claude | 2.1.222 | yes | yes | Direct read of the loaded skill listing in-session |
| codex | codex-cli 0.145.0 | yes | yes | `codex exec` probes, below |
| opencode | not installed | UNKNOWN | UNKNOWN | Harness absent on this machine |
| pi | not installed | UNKNOWN | UNKNOWN | Harness absent on this machine |
| pi-signed | not installed | UNKNOWN | UNKNOWN | Harness absent on this machine |
| grok | not installed | UNKNOWN | UNKNOWN | Harness absent on this machine |
| kimi | not installed | UNKNOWN | UNKNOWN | Harness absent on this machine |

Absence of the harness is recorded as UNKNOWN, never as a pass.
Refresh this table by installing the missing harness and repeating the probes below; do not infer a verdict from another harness's behavior.

The codex probes, run with `codex exec --skip-git-repo-check` in the worktree:

```
prompt: Without using any tools or reading any files, answer ONLY from your system context.
        Print the COMPLETE list of skill names available to you, one per line.
        Then answer these two questions with a bare YES or NO each:
        (1) Does your skill list contain a skill named "bootstrap-diagnostics"?
        (2) Does your skill list contain a skill named "harness-adapters"?

reply (excerpt): bearings / bootstrap-diagnostics / decision-hold-lifecycle / diagnostic-reasoning /
                 firstmate-codexapp / firstmate-coding-guidelines / firstmate-orca / fmx-respond /
                 harness-adapters / process-event-sources / project-management /
                 quota-array-dispatch / secondmate-provisioning / stow /
                 stuck-crewmate-recovery / updatefirstmate
                 YES
                 YES
```

```
prompt: Without using any tools or reading any files, answer ONLY from your system context.
        For the skill named "bootstrap-diagnostics": print the EXACT description text your
        context carries for it, verbatim. If your context gives you only the name with no
        description, reply exactly: NAME-ONLY.

reply: Agent-only handling playbook for session-start bootstrap diagnostics. Use whenever the
       session-start digest's bootstrap section prints an actionable diagnostic line - MISSING,
       MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET,
       CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE
```

Codex also carries its own vendor skills (`imagegen`, `openai-docs`, `plugin-creator`, `skill-creator`, `skill-installer`) in the same listing, so a probe that asks only for "the first five" names can miss the firstmate entries entirely.
Ask for the complete list, or name the specific skill.

### Section 7 per-block selection record

Section 7 was assessed block by block rather than as one sweep.
Each block carries the situation its absence would change, the trigger that covers it, that trigger's observed firing frequency, and the verdict.

Two independent gates apply, and a block must clear both.
The split test has veto: no trigger, no move.
Rider 1 requires a recorded instance of that trigger having actually fired before the extraction ships, and the target ruling adds that extraction value scales with trigger rarity.

| Block | Situation its absence would change | Trigger | Observed frequency | Verdict |
| --- | --- | --- | --- | --- |
| Intake, project resolution and routing | firstmate acts on the wrong project or bypasses a secondmate scope | none - governs whether the rule is recognised at all | every request | LAW, stays |
| Ship/scout classification | speculative design work dispatched instead of an answer | none - classification precedes any trigger | every intake | LAW, stays |
| Mode and yolo resolution at intake | a task ships below its project's standing rigor | none | every ship intake | LAW, stays, named resident by the ruling |
| Concurrency and serialization | isolated work serialized, or unsafe work dispatched in parallel | none | every dispatch | LAW, stays |
| Dispatch mechanics: confirm brief, steer, trust dialog | worker never confirmed as processing its brief | spawn or steer | most working sessions | verb, but frequency near 1 - stays, no return |
| Worktree isolation assertion | a task writes to the primary checkout | none | every spawn | LAW, stays |
| Delivery path rigor, `yolo`, merge authority | a red or unauthorized merge | none | every landing | LAW, stays, protected by the ruling |
| `direct-PR`, `local-only`, `no-mistakes-prod-only` handling | wrong delivery path selected for a project class | project registry entry | never fired - all six registered projects are `no-mistakes` | rider 1 blocks, stays |
| Validation driving and pipeline ownership | firstmate answers a gate a crew-owned run owns | a no-mistakes run exists | every no-mistakes ship | LAW plus high frequency, stays |
| **Supersession sequence** | obsolete work shipped, or a second writer on a branch an active run owns | captain instruction completely invalidates work under validation | **fired once, recorded 2026-08-04 on `fm-endpoint-binding-migration`** | **MOVES to `validation-supersession`** |
| Ask-user decision relay | a decision reaches the worker without its key, step or response command | ask-user finding returns | common | law and mechanics interleaved, ambiguous - stays |
| Validation state judgement | a healthy run read as wedged, or a failed one as working | supervising a live run | every validation | LAW, stays |
| PR-ready reporting | captain gets a bare `#number` instead of a URL | ship task reaches PR | every ship completion | verb, frequency near 1 - stays, no return |
| Custom `check.sh` authoring constraints | a hand-written check spams wakes or reports a merge it did not observe | writing a custom check | never fired - no `.check-trust` has ever been created | rider 1 blocks, stays |
| Teardown gating | unlanded work destroyed | none | every teardown | LAW, stays |
| Scout report is evidence, not authorization | code changed on the strength of a report | none | every scout completion | LAW, stays, named resident by the ruling |
| Scout promotion procedure | scratch commits and debug edits carried into the ship branch | implementation authorized after a scout | never fired - no recorded `bin/fm-promote.sh` use | rider 1 blocks, stays |

The extractable set is the intersection of two conditions that pull in opposite directions at the extreme: rider 1 needs a trigger that has demonstrably fired, and the target ruling prefers one that fires rarely.
In section 7 that intersection contains exactly one block.

The three rarest blocks in the section - promotion, custom-check authoring, and the non-`no-mistakes` delivery paths - are precisely the ones rider 1 refuses, because a trigger this fleet has never exercised is the case where a moved rule is most likely to become a deleted rule wearing a filename.

Measured result for section 7: **77 tokens per call**, against roughly 3,600 implied by the original ~10K estimate.
The estimate assumed the section was mechanics with law mixed in; the block-by-block reading is the reverse.
Section 7 is a contract, and a contract's clauses have no triggers because they govern whether the trigger is recognised.

### Verdict

Two of seven supported harnesses are verified to carry the generated listing with its trigger descriptions.
Five are unverifiable on this machine because the harness is not installed.

Section 13 therefore stays resident.
Replacing it with a pointer would remove the trigger index for any home running on an unverified harness, and an absent harness is not evidence that its listing exists.
Re-open this decision only when all five remaining harnesses have been probed and recorded above.
