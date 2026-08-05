# AGENTS.md context-diet verification

This record holds the empirical facts the `AGENTS.md` context diet acts on: the birth-weight measurement instrument, and the cross-harness skill-listing coverage that decides whether section 13's trigger index may be replaced by a pointer.

`.agents/skills/firstmate-coding-guidelines/SKILL.md` owns the knowledge-placement policy this diet applies.

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

### Verdict

Two of seven supported harnesses are verified to carry the generated listing with its trigger descriptions.
Five are unverifiable on this machine because the harness is not installed.

Section 13 therefore stays resident.
Replacing it with a pointer would remove the trigger index for any home running on an unverified harness, and an absent harness is not evidence that its listing exists.
Re-open this decision only when all five remaining harnesses have been probed and recorded above.
