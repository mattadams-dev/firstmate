# Session rebirth verification

Audience: maintainer verification.

This record supports the current session-rebirth guarantees in [`docs/session-rebirth.md`](../session-rebirth.md): the context-footprint reading, the 200,000-token threshold, and the quiescence boundary.
Operator behavior and active limits remain in that guide.
Task-specific chronology, temporary paths, and delivery transcripts remain in private reports or PR evidence.

## The reading, measured 2026-08-05

The reading is the last non-sidechain line in a session transcript carrying a `message.usage` object, summed as `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
Claude Code writes transcripts to `~/.claude/projects/<slugged-cwd>/<session-id>.jsonl`.

The reading is taken from a bounded tail of the file first, because it runs at every turn end against the one file that grows without bound, and the reading it wants is by construction near the end.
A tail that yields nothing falls back to the whole file, so the bound stays an optimisation rather than a correctness hole; `FM_REBIRTH_TAIL_BYTES` sets the window.

Command shape used to take a reading by hand:

```sh
tac "$transcript" | grep -m1 '"usage"' \
  | jq '.message.usage | .input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens'
```

Four readings taken from live firstmate sessions on 2026-08-05:

| Reading | Provider tokens | What it is |
| --- | --- | --- |
| Birth weight, session `ad4af8d4` | 61,602 | A session's first turn: ambient instruction weight before any orientation, and the floor no rebirth can go below. |
| After full orientation, same session | 104,521 | The same session once it had read the complete session-start digest. |
| Orientation cost | about 43,000 | The difference: what a successor pays to brief itself from the records. |
| Session `bca2a833` at death | 368,381 | Final usage line, 84% past the threshold. |

Growth was measured at roughly 93,000 provider tokens per hour at heavy working rate, which puts a 200,000-token threshold about two to three hours apart in a working day.

## Fixtures

`tests/fixtures/rebirth/` holds two of those readings, redacted to the provider usage object and its envelope with all prose replaced by `[redacted]`:

- `birth-weight.jsonl` - the 61,602 reading, session `ad4af8d4`'s first turn.
- `at-death.jsonl` - the 368,381 reading, session `bca2a833`'s final usage line, followed by that session's five real trailing non-usage lines (`system`, `system`, `bridge-session`, `last-prompt`, `file-history-snapshot`).

The trailing lines are kept because they are the reason the reader scans backwards: a reader that trusts the last line of a real transcript reads nothing at all.
The pair is nearly 6x apart, so the threshold is exercised from both sides with data the fleet actually produced rather than with invented numbers.

## Mutation evidence, 2026-08-05

Each mutant was applied to `bin/fm-rebirth-lib.sh` alone, every test in `tests/fm-rebirth.test.sh` was then run independently in its own shell, and the failing set was recorded.
The baseline run with no mutant applied fails nothing.

Detection - a mutant that lets a session past the threshold without marking it rebirth-due:

| Mutant | Tests failed |
| --- | --- |
| The threshold comparison is removed and every reading records `under` | `test_death_reading_marks_rebirth_due` |
| The threshold is multiplied by ten so only an absurd reading qualifies | `test_death_reading_marks_rebirth_due` |
| The due marker is never written even when the verdict is `due` | `test_death_reading_marks_rebirth_due` |
| The sidechain filter is dropped, so a subagent's context reads as the session's | `test_sidechain_usage_never_reports_the_session` |
| The whole-file fallback behind the bounded tail read is dropped | `test_a_reading_beyond_the_tail_window_is_still_found` |

Timing - a mutant that reborns a session mid-decision or over a live composer:

| Mutant | Tests failed |
| --- | --- |
| The open-decision check is removed | `test_arm_refuses_with_an_open_decision`, `test_arm_proceeds_once_the_decision_resolves`, `test_a_later_terminal_line_does_not_clear_an_open_decision` |
| The decision fold is truncated so no open decision is ever seen | the same three |
| A composer that is not proven empty is treated as safe | `test_arm_refuses_a_pending_composer`, `test_arm_refuses_an_unproven_composer` |
| An `unknown` composer verdict is counted as empty | `test_arm_refuses_an_unproven_composer` |
| The undelivered-escalation check is removed | `test_arm_refuses_an_undelivered_escalation` |

Execution - a mutant that terminates the wrong thing, or terminates it the wrong way.
These were applied to `bin/fm-session-launch.sh`:

| Mutant | Tests failed |
| --- | --- |
| The watcher pid is chosen by matching processes instead of read from the lock | `test_the_rebirth_path_never_terminates_the_session`, `test_the_predecessor_watcher_is_retired_through_the_helper` |
| The watcher retirement is dropped entirely | `test_the_predecessor_watcher_is_retired_through_the_helper`, `test_a_refused_watcher_retirement_is_escalated_not_worked_around` |
| A refusal is retried instead of escalated | `test_a_refused_watcher_retirement_is_escalated_not_worked_around` |

The pattern-match mutant is caught by the no-watcher case as well as the retirement case, and that is the point: in a home with no watcher lock a pattern match still finds something to signal, while reading the lock finds nothing to do.

Every failing set names the guard the mutant broke and nothing else.
The three-test sets are the decision guard's own pair plus the status-fold property it depends on: the paired positive exists so the negative cannot pass vacuously, so a mutant that disables the guard is expected to take both halves with it.

The timing tests do not run the threshold reader.
`armable_home` writes the due marker directly, because routing it through the reader would make a detection regression fail fifteen timing tests and present as a timing bug.
The handover between the two halves is pinned from both sides instead, by `test_death_reading_marks_rebirth_due` and `test_arm_refuses_when_not_due`.

## Full-cycle run, 2026-08-05

The four parts were driven end to end against a plain checkout with the real scripts, the real turn-end hook payload shape, and the two measured fixtures standing in for the predecessor's and successor's transcripts.
A `tmux` shim served the canned pane and a recorder stood in for the Bridge writer.

Observed, in order:

1. `bin/fm-turnend-guard.sh` fed a Stop payload naming the 368,381-token transcript exited 0 and recorded `verdict=due`, writing `state/.rebirth-due`.
2. `bin/fm-rebirth.sh arm` with an open `needs-decision` refused: `not armed: a decision is still open: work: needs-decision [key=shape] ...`, and nothing was typed into the pane.
3. After a matching `resolved` line the same command armed, typed `/exit`, and submitted it - the pane recorded `TYPED /exit` then `ENTER`.
4. `bin/fm-session-launch.sh` saw the session end, claimed the rebirth, and launched exactly one replacement.
5. `state/.safe-kill.log` did not exist: the home had no watcher lock, so there was nothing to retire and nothing was signalled.
6. `bin/fm-session-start.sh` printed the successor block naming the predecessor session, its 368,381 tokens, and the Bridge command for a records gap.
7. The successor's first turn end recorded its own 61,602 reading and posted `session reborn: 61602 tokens, down from 368381` to the Bridge, then removed the handoff and the due marker.

## Composer reads

The quiescence tests drive `bin/fm-tmux-lib.sh` and `bin/fm-composer-lib.sh` for real behind a `tmux` shim that serves a canned pane, rather than stubbing the composer verdict.
The verdict is the safety-critical judgement under test, and a stub can only confirm the assumption written into the stub.
The specimens used are the bare agent prompt glyph (`empty`), a glyph followed by typed text (`pending`), and a bare shell prompt (`unknown`, a dead shell rather than an idle agent).

## Exit commands

The per-harness exit commands in `fm_rebirth_exit_command` are the machine-readable form of the verified facts in `.agents/skills/harness-adapters/SKILL.md`, which remains the agent-facing owner.
`test_exit_commands_match_the_verified_adapters` pins them against that table.
An unverified harness returns no command and refuses, so no guessed command is ever typed into a live session.
Refreshing these after a harness upgrade means re-reading that skill's per-harness tables, not re-deriving them here.
