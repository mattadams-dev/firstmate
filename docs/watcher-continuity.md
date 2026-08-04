# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Singleton at birth

Both supervision layers - `bin/fm-watch.sh` and `bin/fm-supervise-daemon.sh` - acquire their singleton lock as the first act of their runtime, before any other work.
`bin/fm-wake-lib.sh`'s `fm_supervisor_singleton_acquire` is the single owner of that decision for both.

The lock publishes its holder's role, home, supervised state directory, executable path, and process identity into the owner directory *before* the symlink that makes the lock visible.
A peer therefore never observes a lock it cannot identify, which is what lets the gate be decided from the lock alone.
The decision is total and has exactly three outcomes: acquired, held by a verified-live holder, or undecidable.
An undecidable lock is reported and nothing starts; it is never resolved by inspecting or terminating the holder.

No liveness beacon, mtime, or age threshold participates in that decision.
A threshold cannot distinguish a peer that is alive and working from one that is alive and wedged, and a supervisor that guesses wrong in either direction either duplicates itself or evicts the only healthy cycle.
Supervision *health* remains a separate question with its own owner: `bin/fm-guard.sh` raises the stale-beacon alarm, and `bin/fm-watch-arm.sh` reports `watcher: FAILED` when it cannot confirm a live watcher with a fresh beacon.
A wedged incumbent therefore keeps its singleton quietly and is surfaced loudly one layer up.

A holder that is provably not the process the lock recorded - dead, reaped, or a reused pid - is reclaimed, serialized through the same sibling steal token the dead-holder path uses and re-verified while holding it.
That reclaim is what keeps supervision recoverable; without it a home whose watcher died could never start another.

### Nothing before the gate

Whatever a supervisor does before its singleton gate, it does as an unaccountable second supervisor.
`bin/fm-watch.sh` previously ran `bin/fm-pr-check-migrate.sh` ahead of its lock, and that migration stops a live watcher to take the watcher exclusion for itself.
A starting watcher therefore terminated the incumbent as its first act, deciding from process inspection exactly what must never be decided that way.
The migration now runs behind the gate in `--watcher-owned <pid>` mode, which verifies the calling watcher really holds the lock and then neither stops anything nor acquires anything.
The standalone migration path still needs its own exclusion, and its stop goes through `bin/fm-safe-kill.sh`.

### An address is not an identity

`FM_STATE_OVERRIDE` moves the supervised fleet without changing `FM_HOME`, so two supervisors can record an identical home while watching entirely different state directories.
The lock used to record a home identity it was never keyed by, and nothing cross-checked it.
Two such supervisors are not duplicates - each is the only supervisor of its own fleet - but a process-table census cannot tell them apart, which is how one home gets reported as running two.
The lock and `state/.watch-cycle-exits.log` now both record the resolved home *and* the supervised state directory, so that question is answerable from the record rather than from a pattern scan.

## Arming authorities

Several things in this repo can cause a watcher cycle to start.
They are, in the order they sit above the process:

| Authority | Mode | Role |
| --- | --- | --- |
| `bin/fm-claude-stop-autoarm.sh` | normal, Claude primary | The routine tokenless re-arm; fires on every Stop, admits one home-scoped owner |
| `.pi/extensions/fm-primary-pi-watch.ts`, `.opencode/plugins/fm-primary-watch-arm.js` | normal, Pi and OpenCode primaries | Adapter-owned re-arm after an actionable child close |
| `bin/fm-turnend-guard.sh` | normal | Bounded backstop at turn end when no cycle and no auto-arm claim exist |
| `bin/fm-watch-arm.sh` | normal | The shared floor every adapter goes through, and the manual repair entry point |
| `bin/fm-watch-checkpoint.sh` | normal | Codex's bounded foreground checkpoint |
| `bin/fm-supervise-daemon.sh` | away | Owns the cycle entirely while `state/.afk` exists |
| `bin/fm-afk-start.sh`, `bin/fm-afk-launch.sh` | away | Start the daemon; they do not arm watchers themselves |
| `bin/fm-bootstrap.sh`, `bin/fm-spawn.sh`, `bin/fm-pr-check-migrate.sh` | either | Touch watcher state as part of another job; none is an arming authority |

Exactly one is authoritative per mode: the primary harness's own continuity adapter in normal mode, and the away-mode daemon while `state/.afk` exists.
Every other caller defers **through the lock**, never through its own judgment about whether a peer exists - and that is now literally true rather than a convention, because `fm_supervisor_singleton_acquire` is the only way into either loop and it decides from the lock alone.
A caller that believes it should arm therefore cannot be wrong in a way that produces a second supervisor; the worst it can do is start a process that immediately stands down.

The 2026-08-04 arms are consistent with that inventory: `state/.claude-autoarm-epoch` was frozen days earlier, so the Stop auto-arm claimed the home for none of them.
A forked session does not hold `state/.lock` - the pre-fork session still does - so its hook is inert by design, and the arms came from the manual and adapter paths instead.
That the auto-arm refused is correct behavior, not the defect.

## Wedge alarms count back down

A wedge escalation used to ratchet 1 -> 2 -> 3 -> 4 with nothing counting it back.
Past the demand-deep-inspection threshold every wake insists the lane must not be waved through on a cheap read, which is right in isolation but had no counterpart: proven health never cleared it.
A test-heavy lane is static for minutes at a time in the ordinary course of working, so it reached the threshold just by doing its job and then stayed under deep inspection permanently.
Measured on the live fleet: four deep inspections of one healthy lane inside twenty minutes, all four confirming health, a fifth already queued.

Evidence of health now resets the alarm, and `bin/fm-health-evidence-lib.sh` is the single owner of what counts as evidence.
Three signals, each seeing through a blind spot of the others: rendered pane output changing, the pane process tree consuming CPU, and live descendants under its foreground command.
Any one advancing between two samples is a healthy worker; frozen on all three is what a wedge looks like.
The reset clears both the escalation count and the wedge timer, and logs the transition with the count it cleared, so the alarm history stays reconstructable.

Elapsed time is never a signal, and must not become one.
A time-based amnesty would pardon exactly the slow wedge the alarm exists to catch, silently.
An unreadable sample is `unknown`, which neither resets the alarm nor accelerates it.

This is deliberately a different question from busy state, and does not cross that boundary: `bin/fm-busy-lib.sh` still owns the semantic turn lifecycle and still excludes CPU and child processes as state signals.
Busy state answers whether a turn is in progress; this answers whether anything moved.
A lane can be outside a model turn and still be genuinely computing, which is the case that breaks a pane read.

## Ownership

`bin/fm-watch-arm.sh` owns the harness-independent floor: on an actionable close it arms and verifies one detached successor BEFORE it delivers the wake, so a home that still needs supervision is never blind for the handling turn no matter which adapter sits above it.
The adapters below layer their own restoration on top of that floor rather than being the only thing standing between a delivered wake and no supervision at all.

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook still starts its own arm at the next Stop after the handling turn rather than before notification, but that is no longer what covers the turn: the arm layer has already armed a detached successor before the wake reached the model, and the next Stop's arm attaches to it instead of starting cold.
This matters most where the hook cannot run at all - a forked session leaves `state/.lock` naming the still-live pre-fork harness, so the forked session's hook stays inert by design and no adapter re-arm ever happens.
The durable wake queue preserves actionable events during the residual active-turn window, and the unchanged bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
No PreToolUse hook denies fleet commands based on watcher status.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.
The arm layer's own successor is not that pattern: it is deliberately double-forked so it outlives the arm that delivers the wake, and it is then verified through the same live-process-plus-fresh-beacon gate as an owned child, so it is never reported off a process that is already dying.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.
An attached cycle that closes on a genuine wake is not that case: the successor writes its one reason to `state/.watch-successor-output.<pid>` before releasing the singleton, and the attached arm claims and delivers it, arming the next successor first.
A successor is armed only for a delivered actionable wake in a home that still needs supervision and is not away, so a typed failure stays loud and unarmed and an idle home is never left with a detached watcher.

Post-sync 2026-08-04, two delivery-record mechanisms coexist: the fork's pid-keyed `state/.watch-successor-output.<pid>` handoff (above) and upstream's identity-matched `state/.watch-deliveries.log` ledger (below). Both are live in `bin/fm-watch-arm.sh`; their unification is owned by the supervisor-singleton lane's subsumption round. This coexistence is declared so it reads as known state, not drift.

A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after the durable wake queue was drained, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, the resolved home and supervised state directory, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The home and state fields exist because their absence made a real duplication report unanswerable after the fact: the ledger could show two cycles but never say whether they belonged to one home or to two.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
The same suite proves the arm layer's own floor: a delivered wake has a live successor holding the singleton at the moment it is delivered, an attached arm delivers its successor cycle's wake instead of a false empty-close failure, an idle home is left with no detached watcher, and the preserved 499-record capture in `tests/fixtures/watch-cycle-exits/cycle-exits.log` still shows the `successor=none` defect that a fresh cycle no longer reproduces.
`tests/fm-watch-triage.test.sh` proves the parked check-in cadence: overdue lanes batch into one wake per window, a fresh cycle inside that window no longer dies on them, the cadence still comes due, and a lane whose declared wait has actually cleared surfaces at once regardless.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
