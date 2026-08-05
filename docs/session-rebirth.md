# Session rebirth

Audience: operator, current behavior.

A firstmate primary session accumulates its own transcript, and that transcript becomes the largest single line in the context replayed on every turn.
Past a point, a fresh session that re-reads the durable records is worth more than the current one's memory of how it got here.
Rebirth is the machinery that finds that point, picks a safe moment, ends the session, and proves the result.

Measured evidence for the numbers below is in [`docs/verification/session-rebirth.md`](verification/session-rebirth.md).
Exact flags and mechanics stay in each script's header and `--help`.

## Why this is machinery and not a rule

The threshold was adopted after measuring a per-turn replay in which two-thirds of the context was the conversation about the work rather than the work.
A threshold that a human has to notice is a convention, and a convention is a control only for whoever remembers it when it matters.
Worse, the party best placed to notice is the session itself, and its judgement is exactly what degrades as the transcript grows.
So nothing here depends on anyone noticing.

## The reading

The provider writes its own token count into the session transcript on every turn.
The reading is the last non-sidechain line carrying a `message.usage` object, summed as `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
The default threshold is 200,000 provider tokens; `FM_REBIRTH_THRESHOLD` overrides it, and a value that cannot be parsed is ignored rather than obeyed.

This is the provider's count of what it actually billed for, not a proxy.
An earlier design read transcript bytes and needed two standing caveats - bytes over-counted persisted tool results and under-counted the system prompt - and both disappear here.

Three outcomes, never two.
A reading past the line is `due`, a reading under it is `under`, and a missing transcript, an absent usage line, a malformed counter, or a missing `jq` is `unknown`.
Unknown never marks a session due, because that would be a false alarm, and never records it as under, because that would be a false all-clear.
It is recorded as unknown, which is what was observed.

Two exclusions matter:

- **Sidechain turns.** A subagent's usage object records the subagent's context, not the session's. Reading one would report a small number for a large session, which fails in the direction that loses work.
- **A zero sum.** Every real turn bills something, so a total of zero means the counters were absent or malformed. Zero is under every threshold, so reporting it confidently would silently disarm the mechanism.

## The four parts

| Part | Who runs it | When |
| --- | --- | --- |
| Detection | `bin/fm-turnend-guard.sh` | every turn end |
| Timing | `bin/fm-supervise-daemon.sh` | every housekeeping tick, away mode only |
| Execution | `bin/fm-session-launch.sh` | when the session ends |
| Orientation | `bin/fm-session-start.sh`, then the guard | on the successor's first turn |

`bin/fm-rebirth.sh` is the command surface over all four, and `bin/fm-rebirth-lib.sh` owns the decisions.

### Detection

The turn-end guard already runs on every stop, so the reading costs one extra file read at a moment the process is already awake.
It records the reading in `state/.context-footprint` either way, and writes `state/.rebirth-due` only when the reading is past the line.
The reading never changes what the guard does: a session is not stopped mid-turn over a number, and a failed reading never blocks a turn from ending.

### Timing

Rebirth mid-decision or mid-delivery costs more than a large transcript does, so the moment is chosen from positive proof rather than the absence of a signal.
The away-mode daemon already reads both of the things quiescence needs, every cycle, for other reasons.
A moment is quiescent when all of these hold:

- no escalation is sitting undelivered in the away-mode buffer;
- no task in this home has an open decision, folded by the one owner of that contract, so a later terminal status line never clears an earlier `needs-decision`;
- the primary session is not mid-turn;
- the composer is **proven** empty by the shared classifier - `pending`, `unknown`, and unreadable are all unsafe, and a bare shell prompt is a dead shell rather than an idle agent.

Every refusal names its reason, because "not now" and "could not tell" are different answers.

Execution is gated on away mode for the same reason every injection is: with the captain present, their session is not something to end from underneath them.
Detection is not gated - a session is marked due whoever is watching - so an attended session that has crossed the line shows up in `bin/fm-rebirth.sh status`.

### Execution

Nothing is terminated anywhere in this path.
The exit is **asked for**: the harness's own exit command is typed into the composer that was just proven empty, which is why the composer read is load-bearing twice, as the proof and as the channel.

[`bin/fm-safe-kill.sh`](../bin/fm-safe-kill.sh), the fleet's single owner of termination, refuses to signal a live harness session, and that refusal is correct - whether ending a given process is safe was never something process inspection could establish.
So a session that ignores its exit command produces an armed record that expires and a rebirth the daemon re-attempts on its next tick.
Never a kill, never a pattern match, never a judgement made by looking at a process.

Start the session through the wrapper instead of running the harness directly:

```sh
bin/fm-session-launch.sh -- claude
```

Everything after `--` runs verbatim in the foreground, so the harness owns the terminal exactly as it does unwrapped.
When the session ends for any ordinary reason the wrapper exits with the harness's own status.
It relaunches on exactly one condition: a rebirth was armed, and this exit is that rebirth.
A launch command carrying a resume or continue flag is refused at startup, because it would restore the very transcript the rebirth exists to shed.

### Orientation

The successor's session-start digest is its whole inheritance.
There is no handoff note to find and no previous conversation to recover, by design.

The acceptance test is inverted on purpose: a question the successor cannot answer from the durable records is not an inconvenience to route around by asking a human.
It is the defect the rebirth exists to detect, and it goes to the Bridge as a records finding naming the specific thing that could not be resolved.

The successor's own footprint is measured automatically when its first turn ends, and the comparison against its predecessor's is posted to the Bridge - including when the footprint did **not** come down, which is reported as loudly as a success.
A reading that stays unreadable is reported as unverified after a bounded wait rather than quietly dropped, because an unchecked rebirth must not look like a verified one.
A rebirth that does not verify its own premise is a ritual, not a control.

## Inspecting it

```sh
bin/fm-rebirth.sh status      # the last reading, whether rebirth is due, what it is waiting on
bin/fm-rebirth.sh quiescent   # whether ending the session now is safe, and if not, what is in the way
```

Both are read-only.
`arm` refuses unless the session is both due and quiescent, and `--dry-run` reports what it would do without typing anything.

## Records

All under `state/`, all volatile:

| Record | Written by | Meaning |
| --- | --- | --- |
| `.context-footprint` | the guard, every turn end | the last reading, including `unknown` |
| `.rebirth-due` | the guard | this session is past the threshold |
| `.rebirth-armed` | `fm-rebirth.sh arm` | the exit has been asked for; expires if the session does not end |
| `.rebirth-handoff` | `fm-rebirth.sh claim` | what the successor inherits, until its footprint is verified |
