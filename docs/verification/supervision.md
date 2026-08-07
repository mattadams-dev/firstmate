# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
Firstmate-written project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while global `~/.codex/hooks.json` `SessionStart` hooks fired in the same runs.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs a real watcher and attached arm to verify that a delivered reason survives queue draining, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

### Arm-layer successor and parked check-in cadence

Captured 2026-07-31 from a live home's `state/.watch-cycle-exits.log`, preserved verbatim at `tests/fixtures/watch-cycle-exits/cycle-exits.log` because the file accumulates over days and cannot be regenerated.

```text
records                       499
exit_code=0                   499 / 499
signal=none                   499 / 499
successor=none                499 / 499
reason=actionable-stale       293
reason=actionable-signal      198
reason=actionable-check         8
exits within 5s               117 (23% of all cycles)
  of those, actionable-stale  112 (22% of all cycles)
  of those, actionable-check    5
```

Every cycle completed normally and delivered a wake; none armed a successor.
Supervision therefore ended on each delivered wake and resumed only when an adapter above the arm layer happened to re-arm.
The 112 actionable-stale sub-5s exits are parked lanes at independent phases, each ending a cycle of its own.

Guard-class mutation results, one mutation per protection, measured in full on 2026-07-31 against this tree.
The clean baseline it is read against: `tests/fm-watcher-lock.test.sh` reports 35 `ok -` lines and `tests/fm-watch-triage.test.sh` 42, both exiting 0.
Counts below are `ok -` lines rather than test functions, because a few lock cases report more than one.

A failing case aborts its suite, so each mutation was run at least twice: once to see which case it kills, and once with that case's invocation removed to prove nothing else in the suite breaks.
Where a further case then failed, its invocation was removed too and the suite re-run until it went clean, so a mutation several cases depend on is reported as such instead of forced into a one-to-one claim.
Each mutation was applied to its own copy of the tree, never to a working checkout.

| Mutation | Case killed | Rest of suite |
| --- | --- | --- |
| Deliver the wake before arming the successor | `test_delivered_wake_arms_its_successor_before_it_is_handled` | 34 clean |
| Drop the successor-output claim in `attach_and_wait` | `test_attached_arm_delivers_its_successor_cycle_wake` | 34 clean |
| Arm a successor regardless of supervision need | `test_successor_is_not_armed_without_supervision_need` | 34 clean |
| Arm a successor while away mode is active | `test_successor_is_not_armed_in_away_mode` | 34 clean |
| Ignore the shared parked check-in cadence | `test_parked_lanes_batch_into_one_checkin_on_a_shared_cadence` | 41 clean |
| Accumulate the due parked lanes without their record separator | `test_parked_lanes_batch_into_one_checkin_on_a_shared_cadence` | 41 clean |
| Flip 200 `successor=none` rows in the preserved capture | `test_preserved_capture_still_shows_the_defect_a_fresh_cycle_no_longer_has` | 34 clean |
| Never release a lane's pause markers, in `clear_pause_state` | `test_a_cleared_park_is_noticed_promptly_inside_a_closed_cadence` | then `test_secondmate_unpause_clears_pause_tracking`, `test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash`, `test_nonterminal_paused_rechecks_authoritative_state`, then 38 clean |

The last row is the one mutation more than one case shares, and it is four, not the two an earlier pass of this matrix recorded.
`clear_pause_state` is the single release primitive behind every exit from a declared pause - an ordinary parked lane inside a closed cadence, a resumed secondmate, a pause-to-working reclassification, and an authoritative recheck - so each of those four guards it from its own direction.
Nothing beyond that release depends on it: with all four removed the suite is clean.
The two parked check-in rows are the inverse pairing: one case carries both protections, because a batched check-in has to fire on the shared cadence *and* carry every lane that came due, and each is killed by its own mutation.
The second of those was added after review found the accumulator concatenating its lanes into a single glued record, which the case as first written passed over.

One surviving mutant is known, at the redundant release site in `surface_nonterminal_stale`: the `else` branch that drops `.paused-<key>`, `.paused-rechecked-<key>` and `.paused-resurfaced-<key>` when the lane's declared pause verb has gone.
Replacing that branch with `:` leaves `tests/fm-watch-triage.test.sh` entirely green, 42 `ok -` lines and exit 0, killing no case.
The cleared-park protection itself is proven at `clear_pause_state`, the single release primitive behind all four exits from a declared pause, which is why this second path can be neutered without a case noticing.
The site predates this change - it arrives with `ab8cea6` `fix(watcher): bound stale wakes for parked crew (#743)` - and closing it needs a case that does not exist yet, so it is recorded here as a known gap rather than claimed as covered.

An earlier pass of this matrix failed instead at `test_watch_restart_attaches_to_healthy_peer`, whose TERM-resistant peer must install its signal handler before `--restart` signals it.
The cause was host load from watcher successors left behind by leaked test temp roots, not the peer contract; with `fm_test_tmproot` registration repaired, both suites run with zero stray watcher processes and zero leftover temp roots, and the mutation matrix reproduces the table above.

Deterministic entry points for this contract:

```sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-triage.test.sh
```

## Declared-wait recheck cadence split

Verified 2026-08-07 against this tree, on Linux, with tasks-axi 0.2.3 available.

The recheck cadence is no longer uniform: a wait only a human ruling can end uses `FM_PAUSE_CAPTAIN_RESURFACE_SECS`, a wait expected to clear on its own keeps `FM_PAUSE_RESURFACE_SECS`, and a ruling routed through `bin/fm-decision-hold.sh` records a durable recheck request that brings the lanes it gated due at the next poll regardless of remaining cadence.
Widening one half without the event trigger would be a regression rather than a fix, so all three are guarded, in both the always-on watcher and the away-mode daemon.
That recheck request carries a bounded lifetime, guarded from both sides here as well, because a request nobody ever reads is otherwise still there for whatever crew next takes that task id.

Each mutation was applied to a working copy, run, and reverted before the next.
A failing case aborts its suite, so each case was invoked on its own for this matrix rather than read from a single suite run; that is what makes the "other cases" column an observation instead of an inference.

| Mutation | Case killed | Other cadence cases |
| --- | --- | --- |
| `bin/fm-watch.sh`: use the captain-gated window for every declared wait | `test_bounded_wait_keeps_its_ordinary_cadence` | both still ok |
| `bin/fm-watch.sh`: never select the captain-gated window | `test_captain_gated_wait_waits_out_the_long_cadence` | both still ok |
| `bin/fm-watch.sh`: never read the pending recheck request | `test_a_landed_ruling_rechecks_the_lane_it_gated` | both still ok |
| `bin/fm-supervise-daemon.sh`: drop the captain-gated window from housekeeping | `test_housekeeping_splits_captain_gated_from_bounded_waits` | ruling and bounded cases still ok |
| `bin/fm-supervise-daemon.sh`: use the captain-gated window for every declared wait | `test_housekeeping_splits_captain_gated_from_bounded_waits`, and the pre-existing `test_housekeeping_paused_resurfaces_and_resets` | ruling case still ok |
| `bin/fm-supervise-daemon.sh`: never read the pending recheck request | `test_housekeeping_landed_ruling_rechecks_the_lane_it_gated` | split and bounded cases still ok |
| `bin/fm-classify-lib.sh`: let a recorded recheck request live forever | `test_an_expired_ruling_request_is_reaped_rather_than_faking_a_wake` | the other eight still ok, run across all three suites |
| `bin/fm-watch.sh`: read the recheck request against the bounded window rather than the captain-gated one | `test_a_ruling_recorded_before_its_lane_parked_still_rechecks_it` | the other four watcher cases still ok |
| `bin/fm-classify-lib.sh`: reap the request when the CALLER's lifetime cannot be read | `test_an_unreadable_lifetime_does_not_destroy_a_pending_recheck_request` | the other six request cases still ok, run across all three suites |
| `bin/fm-classify-lib.sh`: leave a request whose own STAMP cannot be read in place | `test_a_recheck_request_with_an_unreadable_stamp_is_reaped` | the other six request cases still ok, run across all three suites |

Every mutation kills exactly its own case except the daemon-side widen-both, which kills its own case and one more, and is reported that way because that is what it does.
It fails `test_housekeeping_splits_captain_gated_from_bounded_waits` at that case's bounded half - its captain-gated half passes under the same mutation, so which property died is measured rather than inferred - and it also fails the pre-existing `test_housekeeping_paused_resurfaces_and_resets`.
That second kill is not a gap in this work and cannot be tuned away: that case asserts the daemon's bounded cadence with a 5000s marker and no captain-cadence override, so the 21600s default puts any widen-both mutation under its threshold by construction.
A diagonal was reachable only by pinning a short captain cadence inside that pre-existing case, which was measured and does make it pass under the mutation - that is, it would buy the diagonal by making an existing guard blind to the widening, so it was not done.
Redundant coverage of the ruling's load-bearing half is the stronger record, and this document reports redundantly-guarded mutations as such elsewhere rather than forcing them into a one-to-one claim.

Rows seven and eight are the recheck request's LIFETIME, and they are exact mirrors of each other.
A request that never expires eventually fires against whatever crew next takes that task id, reporting a ruling that landed on nothing - the mutation prints it verbatim, `ruling landed after a 61s wait` against a lane no ruling ever gated.
A request expired too eagerly instead drops a recheck that is genuinely owed, which is the world where the ruling arrived before its lane was ever dispatched.
Those two worlds are indistinguishable from a marker and a clock, so the lifetime honors the second for as long as it tolerates the first, and errs toward dropping: a dropped request costs a lane its ordinary cadence under a backstop that is still finite, while a kept one fabricates an event.

The last two rows are the two ways that judgement can fail to be readable at all, and they are mirrors as well, because they distrust different things.
An unreadable LIFETIME is the caller being wrong - a home writing its captain cadence as `6h` rather than `21600` - which says nothing about the request, so the read declines to fire and leaves the request for a correctly configured read to judge.
An unreadable STAMP is the record being wrong, and a request that cannot say when its ruling landed can never be judged by any caller, so that read reaps it.
Each case drives its own world and neither mutation reached the other's, which is what says the two branches are genuinely separate rather than one branch written twice.

The cases are separated by the classifier fixture and the two cadence knobs only, so what produced each verdict is not in doubt.
The captain-gated case additionally asserts that the lane still comes due once its own cadence elapses, so a mutation that turned the long cadence into silence would be caught by the same case that proves the cadence is long.

`test_wait_class_reads_the_backlog_once_per_window` guards the cost rather than the verdict: the recheck path runs on every poll for as long as a lane stays parked, and the backlog lookup is a subprocess, so it is throttled to one read per bounded window and the case counts the lookups through a fixture that logs them.

Deterministic entry points for this contract:

```sh
tests/fm-watch-triage.test.sh
tests/fm-daemon.test.sh
tests/fm-decision-hold-lifecycle.test.sh
```

## Away-mode composer read on a live claude-on-herdr pane

Captured 2026-08-04 with Herdr 0.7.1 against two live Claude Code panes in the running session, using `fm_backend_herdr_capture_ansi <target> 20`.
This record supports the guarantee that a healthy idle Claude composer classifies `empty` while an unreadable pane and a dead shell stay `unknown`.

Claude 2.x draws its composer as three rows with no side borders: a top horizontal rule, the input row, and a bottom horizontal rule.
The captured input row is byte-identical on both panes, and its trailing byte pair is the load-bearing detail:

```
$ sed -n '17p' cap-ansi.raw | od -c
0000000 342 235 257 302 240  \r  \n
```

`342 235 257` is `❯` (U+276F) and `302 240` is a NO-BREAK SPACE (U+00A0), not an ASCII space.
The two panes differ only in whether the top rule carries a label:

```
row 16 (pane A, labelled top rule)  ...342 224 200 342 224 200  f i r s t m a t e  <ESC>[38;5;14m 342 224 200 342 224 200 <ESC>[0m
row 16 (pane B, plain top rule)     <ESC>[0m<ESC>[38;5;7m 342 224 200 342 224 200 ... 342 224 200 <ESC>[0m
row 18 (both panes, plain rule)     <ESC>[0m<ESC>[38;5;14m 342 224 200 ... 342 224 200 <ESC>[0m
```

`342 224 200` is `─` (U+2500).

Observed classification of both live panes before the fix:

```
1:w9:p1 (labelled top rule) -> unknown
1:w9:p7 (plain top rule)    -> pending
```

Neither verdict is `empty`, so the away-mode injector's composer guard deferred on every healthy idle pane.
Instrumenting the two structural stages separates the two independent causes:

```
pane A: structural scan  shape=bare generic_line=17 found=1
pane A: PI_PAIR_FOUND=0  PI_LAST_SEPARATOR_LINE=18
pane B: PI_PAIR_FOUND=1  PI_LAST_SEPARATOR_LINE=18
```

Cause 1, reaching `unknown`: the Pi separated-composer shape treats any all-`─` row as a separator.
Claude's bottom rule is such a row, and a labelled top rule is not, so no separator pair completes and the lone lower separator on row 18 outranks the live composer on row 17.
The stale-separator branch then clears the match and the verdict falls through to `unknown`.
This fires on every Claude pane whose top rule carries a label, which is the shape the primary firstmate pane always renders.

Cause 2, reaching `pending`: when the pair does complete, the composer row survives to content classification as `❯` followed by U+00A0.
The trimming in the herdr adapter and in `fm_composer_classify_content` used ASCII `[[:space:]]` only, so the no-break space survived the leading-glyph strip and read as real unsubmitted text.

Both causes are structural and independent: fixing either alone still leaves one live pane shape misclassified.

### Guard-class mutation coverage

Run 2026-08-04 against the two guard tests in `tests/fm-backend-herdr.test.sh` and the two in `tests/fm-composer-lib.test.sh`, each executed in isolation because `fail` aborts a suite at its first failure.
All four pass unmutated.

| Mutation | Direction | Failing tests |
| --- | --- | --- |
| Delete the closing-rule exemption | restores always-`unknown` | rule-framed content read |
| Drop the exemption's shape and identity gate | makes more panes look deliverable | exemption-stays-narrow |
| Drop the Unicode blanks from the trim | restores always-`pending` | Unicode-padding read, plus the two below |
| Treat every non-ASCII byte as trimmable | makes more panes look deliverable | Unicode-padding-never-hides-real-content |

Both mutations in the dangerous direction - the ones that would let a non-empty or unreadable composer read as `empty` and so type into a live composer - break exactly one test each.
Removing the Unicode blanks additionally breaks the rule-framed content read and the padding-safety test.
That is genuine coupling rather than weak isolation: the trim is load-bearing for three separate guarantees, because the live composer shape needs both fixes to read `empty`, and a dead-shell prompt must lose its padding before the bare-glyph rule recognises it.

## Wedge-alarm command-channel argv

Captured 2026-08-04 on Linux/WSL2 with `sh` as dash.
The alarm's `command:` channel invoked `sh -c "$cmd" fm-wedge-alarm "$summary"`, which supplies positional parameters to the `sh -c` shell itself, not to a command that shell then executes:

```
$ sh -c "/tmp/argvprobe.sh" fm-wedge-alarm "THE SUMMARY" </dev/null
argv_count=0 argv1=[<EMPTY>]

$ sh -c 'printf "argv_count=%s argv1=[%s]\n" "$#" "${1:-<EMPTY>}"' fm-wedge-alarm "THE SUMMARY" </dev/null
argv_count=1 argv1=[THE SUMMARY]
```

A directive naming a bare script path therefore received empty argv, while a directive whose body is an inline snippet received the summary on `$1`.
Only the inline shape was covered by an automated test, so the suite could not distinguish a channel that receives the summary from one that never does, and a directive of the bare-script shape logged its own fallback text on every alarm.
The `command:` channel now runs a directive that resolves to a single executable file, with no arguments and no shell syntax, directly, so the summary lands in that program's own argv, while every other directive keeps its exact `sh -c` invocation with the summary on `$1`; every shape still receives the summary on stdin.
A name that resolves to a shell function, builtin, alias, or keyword is refused that branch, so a directive colliding with one of the daemon's own functions cannot run in-process and be reported as a delivered channel.
Narrowing it that way is what keeps a directive that already carries its own arguments from being handed an extra one, which the existing hung-notifier test rejected.
[`wedge-alarm.md`](../wedge-alarm.md) owns that dispatch contract, and the regression test covers both directive shapes.

## Supervisor singleton at birth

Measured 2026-08-04 on Linux 6.18.33.2-microsoft-standard-WSL2, against the tree that introduced `fm_supervisor_singleton_acquire`.

### Cause, decided by probe rather than by plausibility

Three hypotheses were proposed for why the pre-existing singleton locks did not prevent a reported supervisor duplication.
The probes that decide them are preserved with their pre-fix capture in `tests/fixtures/supervisor-singleton/`; each takes the repo root as its one argument.
Each ends on an explicit `RESULT:` line and exits from that verdict rather than from its last cleanup command: zero when the tree it is pointed at is in the state this round left it in, nonzero when the defect reproduces or the measurement is inconclusive.

| Hypothesis | Probe | Verdict |
| --- | --- | --- |
| A dying predecessor's release-by-path unlinks a rotated successor's lock | `h2-release-by-path.sh` | KILLED. `fm_lock_release` resolves the symlink to the owner directory it currently points at and releases only when that owner's `pid` names the releasing process, so a rotated lock is left alone. |
| Work performed before the lock widens the window | `h3-prelock-evicts.sh` | PROVEN, and stronger than proposed. The pre-lock PR-check migration does not merely widen a window; it SIGTERMs the incumbent watcher. A newcomer that had passed no singleton gate terminated the incumbent as its first act. |
| The lock is keyed by an address rather than a home identity | `h1-lock-path-identity.sh` | PROVEN. Path variation for one physical state directory still resolves to one lock, but two different state directories each take their own lock while both record the SAME `fm-home`. The lock recorded an identity it was never keyed by. |

Two further generators were found in the daemon layer while tracing the same shape, both in `bin/fm-afk-start.sh`:
a live daemon whose lock failed an identity match had that lock unlinked outright before a replacement was started, unserialized and outside the lock it was overriding;
and the identity match itself fell back to a command-line substring test when no identity was published.

What remains `unknown`: which of these fired during the original incident.
`state/.watch-cycle-exits.log` recorded arm and watcher pids and lock identity but never the resolved home or state address of a cycle, so the record cannot distinguish two cycles in one home from one cycle each in two homes.
That is treated as a defect in the instrument rather than as evidence in either direction, and both fields are now recorded per cycle.

A pattern-based census run during the same incident reported four supervise daemons where zero existed.
It matched each process's whole command line as a substring and so counted two live crewmates - whose briefs quote the script names on argv - and the inspecting shell itself.
This is why `bin/fm-safe-kill.sh` accepts only a pid a role lock already names, and compares identity as whole-command-line bytes rather than testing for containment.

### Guard-class mutation results

One mutation per protection, each applied to its own copy of the tree, never to a working checkout.
Baselines read against: `tests/fm-watcher-lock.test.sh` 39 `ok -` lines, `tests/fm-safe-kill.test.sh` 13, `tests/fm-arm-pretool-check.test.sh` 205, all exiting 0.
A failing case aborts its suite, so each mutation was run twice: once to see which case it kills, once with that case's invocation removed to prove nothing else depends on the mutated protection.
Both directions are covered deliberately: a guard that refuses everything is the same failure as one that permits everything, and it is the direction that gets missed.

| Mutation | Direction | Cases killed, in the order the suite reaches them | Tail |
| --- | --- | --- | --- |
| A verified-live peer no longer stops a second acquisition | permits too much | `test_singleton_start`, then `test_wedged_incumbent_is_loud_from_the_arm_layer` | see below |
| Restore the pre-lock PR-check migration | permits too much | `test_a_starting_watcher_never_evicts_the_incumbent` | 37 clean |
| Publish the command substitution's identity instead of the holder's | permits too much | `test_stale_watch_lock_reclaimed`, then `test_a_starting_watcher_never_evicts_the_incumbent`, then `test_lock_publishes_its_real_holder_identity`, then `test_watch_restart_rejects_reused_pid` | not chased to clean |
| The migration's exclusion publishes the watcher's path AND the watcher predicate stops checking the published role | permits too much | `test_migration_exclusion_never_reads_as_a_healthy_watcher` | redundantly guarded; see below |
| Never reclaim a provably-dead or reused holder | refuses too much | `test_stale_watch_lock_reclaimed`, then `test_lock_steals_dead_pid_lock` | see below |
| Drop the session-lock refusal in the kill helper | permits too much | `test_refuses_the_session_lock_holder`, then `test_every_outcome_is_recorded` | 10 clean |
| The kill helper can never complete a stop | refuses too much | `test_authorized_supervisor_stop_succeeds`, `test_daemon_role_stop_succeeds`, `test_every_outcome_is_recorded` | 9 clean |
| The policy stops classifying terminations | permits too much | matrix `K01` (`kill -TERM 17907`) | 158 clean |
| The policy denies signal-0 probes and job specs too | refuses too much | matrix `L01` (`kill -0 17907`) | 172 clean |
| The unmodelled-grammar fallback stops exempting the sanctioned helper | refuses too much | matrix `L13`, and `L14`-`L17` with it | 181 clean |
| The unmodelled-grammar fallback stops exempting signal-0 probes | refuses too much | matrix `L18`, and `L19`-`L22` with it | 192 clean |
| The signal-0 exemption stops requiring plain targets after the signal | permits too much | matrix `K25` (`kill -0 -TERM $p`) | 196 clean |
| The modelled watcher-pid guard stops exempting signal-0 probes | refuses too much | matrix `L24` (`pid=$(pgrep -f fm-watch); kill -0 $pid`) | 204 clean |
| The raw fallback stops exempting signal-0 probes beside `fm-watch` text | refuses too much | matrix `L23`, then `L25` | 203 clean |
| The watcher-pid guard exempts every kill, not signal 0 alone | permits too much | none alone; redundantly guarded, see below | 205, unchanged |
| The stand-down line reports every holder as a running watcher | permits too much | `test_migration_exclusion_never_reads_as_a_healthy_watcher` (its stand-down half) | 38 clean |
| A real watcher peer gets the non-watcher holder wording | refuses too much | `test_singleton_start` | not chased to a clean suite |
| Elapsed time alone resets the wedge alarm | permits too much | `test_a_frozen_lane_is_never_pardoned` | 2 before the kill |
| Nothing resets the wedge alarm | refuses too much | `test_a_busy_pane_still_escalates_while_its_cpu_advances` (its liveness half) | 7 before the kill |
| The pane reset also clears the home's failure episode | boundary crossing | `test_the_two_resets_do_not_touch_each_others_state` | 6 before the kill |
| The home reset also clears a pane's wedge ratchet | boundary crossing | `test_the_two_resets_do_not_touch_each_others_state` | 6 before the kill |
| The busy alarm accepts movement as its counterpart | permits too much | `test_a_busy_pane_still_escalates_while_its_cpu_advances` | 7 before the kill |

### The exemption the helper's own name required

The termination policy directs every kill through `bin/fm-safe-kill.sh`, and that name ends in the same bytes the raw fallback scans for.
Grammar this parser does not model - a `for` loop, an `if`, a `while` - falls back to that scan, so every mention of the one mandated command inside ordinary shell control flow was denied.
A recovery kill is written in exactly that grammar, which made the escape hatch unreachable at the moment it exists for.
The refusal named a rule rather than a missing capability, so nothing about it read as a defect.

This was not found by review.
It fired twice against ordinary work in this repo within minutes of each other, once as `broad-watcher-kill` and once as `unverified-kill`, on commands whose only offence was naming a watcher test file and a safe-kill test file in the same loop.
That is the mirror-image direction this matrix exists to catch: a guard that refuses a legitimate recovery is the same failure as one that permits an illegitimate kill, and it is the direction that presents as working.

`L13`-`L17` are the fixture, and the mutation that removes the exemption kills `L13` first and all five together, with the remaining 181 clean.

`K21`-`K23` are the laundering direction.
`K22` (`fm-safe-killall`) is reported here as redundantly guarded rather than as a single-mutation proof, because it is: the pattern scan deliberately does not take this exemption, and the exemption's own trailing boundary refuses the token independently.
Removing either alone left `K22` denied with the rest of the matrix clean - measured at 186 cases, before `K24`-`K29` and `L18`-`L22` were added - and removing both together kills it.
Defence in depth is the intended design, so the honest record is that no single mutation kills that case, not a proof shaped to look like the others.

### The same mirror one command over: signal-0 probes

The fallback denied `if kill -0 "$pid"; then`, and its own refusal text said `kill -0` remained available for probing.
The classifier comment asserted the opposite invariant explicitly, and so did the allowed-forms list in `docs/arm-pretool-check.md`.
Three statements of the contract, one implementation, and all three disagreed with it.

The cost is not the refusal itself; it is where a refused caller goes next.
Liveness in shell is written as `kill -0` inside an `if` or a loop, and with that denied the remaining way to ask is `ps | grep`, the census that counted four supervise daemons in this fleet where zero existed.
A guard whose refusal pushes callers onto the road it was built to close is a safety regression wearing a safety guard's clothes.

Signal 0 is now exempt in every grammar position, and it is exactly one signal wide.
`L18`-`L22` are the probe direction; `K24`-`K29` are the laundering direction, and each one is a shape that textually contains a probe: a probe standing next to a real kill, a second signal riding behind the `-0` (`kill -0 -TERM $p`), a `-0` glued to a signal by quoting (`kill -0"9" 5`), a kill inside the probe's own substitution, a non-null `-s`, and a `pkill` sharing the loop.
Only the kill VERB is dropped by the exemption, never its arguments, which is what keeps the substitution case denied.

### The last refusal was drawn on proximity, not on targeting

The first pass at the exemption withheld it from the broad-watcher guard, on the reasoning that the modelled path denies a kill naming a watcher pid at any signal, so a fallback taking the exemption would be more permissive than the grammar it stands in for.
Measured, that reasoning was inverted for the case that actually bites.
The raw scan fires on the CO-OCCURRENCE of the bytes `fm-watch` with a kill verb, not on a reference to a watcher pid, so the fallback was STRICTER than the modelled path, not looser: `kill -0 5; echo fm-watch-arm` allowed, and the same two commands inside a loop denied as `broad-watcher-kill`.
That second shape is fixture `L17` plus a liveness check - naming a watcher test file and a safe-kill test file in one loop is the exact command pair recorded above as having fired twice against ordinary work.

The boundary belongs on what a command DOES - observe versus act - and never on what text it happens to sit near.
Refusing an observation primitive because `fm-watch` appears elsewhere in the same command re-draws it on proximity, which is the substring-versus-position defect tracked as `fm-guard-command-vs-data-position`.
So signal 0 is now exempt from the watcher-pid guard on both its paths, and the deny text, the policy comment, and the behaviour say the same thing.
This concedes nothing: signal 0 cannot terminate a watcher any more than it can terminate anything else.

What the guard exists for is untouched, and `K30`-`K33` hold it: a pid resolved off a watcher `pgrep` into a variable and then sent `-TERM`, the same pid sent a bare `kill` with no signal named, `kill -0 $(pgrep -f fm-watch)` - which is target selection by pattern with a harmless signal attached, still the census shape - and a real `kill -9` beside a watcher test file in unmodelled grammar.
`pattern-kill` therefore keeps no exemption at all, since `pkill` and `killall` select by matching text whatever signal they carry.
`L23`-`L26` are the probe direction, including the modelled `pid=$(pgrep -f fm-watch); kill -0 $pid` that both paths used to deny.
The guard has two paths and each has its own fixture: removing the modelled exemption kills `L24` alone with 204 clean, and removing the raw fallback's kills `L23` and then `L25` with 203 clean.

The permits-too-much direction here is REDUNDANTLY GUARDED, and it is recorded that way rather than dressed up as a proof.
Exempting every kill from the watcher-pid guard regardless of signal changes nothing the suite can see: `kill -TERM $pid` and `kill $pid` off a watcher `pgrep` are still denied, by the by-pid termination rule instead, and the matrix stays at 205.
Dropping the probe test's requirement that the target be a word this layer can see is the same story: `kill -0 $(pgrep -f fm-watch)` falls to `pattern-kill` instead, and the matrix stays at 205.
Only the combined mutation - the watcher guard exempting everything AND the termination classifier disabled - lets those commands through, and it does: both classify as `allow`, with `D30` the first case the suite reaches.
`K30`-`K33` are therefore held by two independent rules each.
That is the intended design, so the honest statement is that no single mutation kills them, not a number shaped to look like the rows above.

### The stand-down line said "watcher" about something that was not one

While the standalone migration holds the lock, a starting watcher correctly stands down - and printed `watcher: already running pid N`, which `bin/fm-watch-checkpoint.sh` then reported as a watcher running outside the checkpoint.
The behaviour was right and the report was not: no watcher was running in that window.
That is the same false-confidence class this round fixed on the health-predicate side, one layer up, and `FM_SINGLETON_PEER_ROLE` - populated only once the seed and the reader agreed on the field name - is the only thing that can tell the two worlds apart.
A non-watcher holder now gets a line that names it, a holder publishing no role keeps the peer wording that is honest for the pre-upgrade case, and the checkpoint's own summary claims only what it established: that this checkpoint does not own the cycle.

Both directions are single-mutation proofs here, and the observation is taken inside the real window: a watcher is started while the real migration holds the lock, from the same `stat` shim, and its stand-down line is read from that run.
Making the stand-down report every holder as a running watcher kills that half with the defect printed verbatim - `role=pr-check-migration` alongside `watcher: already running pid 921121`, the same pid.
Giving a real watcher peer the non-watcher wording instead kills `test_singleton_start`, which is the mirror: a guard that can never say "a watcher is already running" breaks the arm layer's attach path as surely as one that always says it.
That mirror mutation was not chased to a clean suite, and that is recorded as measured rather than assumed.

### A non-watcher holder of the watcher lock

`fm_watcher_lock_matches_pid` answers "is this home's watcher alive?" from three published fields: the home, the watcher's executable path, and the holder's pid identity.
The PR-check migration takes that same lock as an exclusion and published all three - it passed the watcher's path as its own - so for the length of a migration the health check answered yes and named a process that is not a watcher.
This is the false-report direction of the same instrument the wedge alarm depends on: unknown collapsed into a confident yes.

The fix is on both sides of the seam.
The migration publishes its own executable path, and the predicate now also refuses a lock whose published `supervisor-role` names something other than a watcher - a lock with no role at all predates the field and is still judged on the remaining evidence, because refusing those would leave every pre-upgrade home unable to recognize its own running watcher.

`test_migration_exclusion_never_reads_as_a_healthy_watcher` takes its verdict WHILE the real migration holds the lock, from inside a `stat` shim the migration itself invokes as its first act after acquiring, and it is the production predicate that answers.
Asserting after the migration returns would have passed for the wrong reason: the holder is gone by then, so the health check fails on liveness and never reaches the question.
The liveness beacon is seeded fresh for the same reason - a watcher that was just paused leaves one - so the case cannot pass on a stale-beacon technicality either.

Like `K22`, this case is reported as redundantly guarded rather than as a single-mutation proof, and for the same reason: it is.
Measured, each half alone leaves the case passing at `ok`, and only the pair kills it.
Reverting just the published path leaves the role check refusing the lock; removing just the role check leaves the published path failing to match the watcher's.
Mutating both prints the defect verbatim - `role=pr-check-migration path=.../bin/fm-watch.sh` with `verdict=healthy-watcher` naming the migration's own pid - which is the shape the live incident would have produced.
Two independent refusals on a false-health report is the intended design, so the honest record is that no single mutation kills this case.

The last five rows are the alarm-reset rule, proven against the COMPOSED result rather than against this lane's half.
Two of them are boundary crossings that exist only because the one-reset-owner amendment was made: without them the separation between the home-level and pane-level resets is unenforced however carefully it is documented.

Two fixtures in that group were vacuous before they were fixed, and both failed the same way, which is worth recording because the failure is invisible from a green run.
The original busy-alarm case passed because its fake backend made CPU and children unreadable, so the comparison went unknown for a reason unrelated to the scoping it claimed to prove.
Its first replacement passed for a second, different version of the same reason: the busy path deliberately never samples, so neither call established a predecessor and the comparison was unknown again.
The working fixture seeds a predecessor sample directly and drives a live CPU burner through a substituted `fm_health_target_pid`, so every layer below that one seam runs for real against evidence that genuinely advances.
A mutation matrix is the only thing that surfaced either defect; both suites were green throughout.

A third defect in the same fixture surfaced only from a full-suite sweep: the drivers observed the test shell itself, a live process doing work, so every frozen-pane assertion held only while the harness burned less than one clock tick between two calls.
It passed standalone and failed under load - a verdict that depended on ambient load rather than on its subject.
Each test now observes the process it claims to: a `sleep` for a frozen pane, a spin loop for a busy one.
Verified by six consecutive runs against four competing CPU loaders, zero failures.

Eleven of the twenty-two are the mirror-image or boundary-crossing direction on purpose.
A supervisor that can never arm and a helper that can never terminate anything are the same failure as their opposites, one mirror over, and they fail silently rather than loudly.

Two mutations are broad by nature and are reported as such rather than forced into a one-to-one claim.
Published holder identity and dead-holder reclaim are load-bearing under most of the lock suite, so each kills a chain: the identity mutation was followed through four cases and the reclaim mutation through two.
The identity chain was not chased to a clean suite, and that is recorded here as measured rather than assumed.

The identity mutation is the one this work found in its own first implementation, which is why the seed takes the identity as a parameter instead of computing it.
`test_lock_publishes_its_real_holder_identity` fails it with the difference visible: `linux-starttime=34502521` published against `34502518` actual, three clock ticks apart on an identical command line.
A fork landing inside the same tick would have matched, so the defect reproduces roughly never under test and is invisible to every assertion that does not compare the two values directly.

The time-alone-resets and nothing-resets rows are the wedge-alarm ratchet, and they are exact mirrors.
Letting time alone reset the alarm pardons a lane frozen on every signal, which is what a real slow wedge looks like; letting nothing reset it restores the ratchet that put a healthy lane under permanent deep inspection.
Both mutants also kill the receding-counter case, because a shrinking process tree and a still one are the two things a time-based pardon stops distinguishing.

The session-lock refusal is shared by two cases because the durable-record case uses that refusal to produce a recorded refusal; both guard it from their own direction.
The kill-helper success path is shared by three for the same reason.

Deterministic entry points for this contract:

```sh
tests/fm-watcher-lock.test.sh
tests/fm-safe-kill.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-health-evidence.test.sh
tests/fixtures/supervisor-singleton/h1-lock-path-identity.sh .
tests/fixtures/supervisor-singleton/h2-release-by-path.sh .
tests/fixtures/supervisor-singleton/h3-prelock-evicts.sh .
```

## Step-transition wedge-alarm reset

Verified 2026-08-05.
The pane wedge alarm gained a second kind of evidence: a step this lane's own no-mistakes run record marks completed since the previous escalation.
Both directions are mandatory here, and the mirror is the dangerous one.
A completed step that fails to reset restores the ratchet that put a healthy lane under permanent deep inspection; a reset that fires on anything at all pardons a lane wedged inside a step, and that direction presents as working.

The defect fixture was written before the fix and run against the unmodified default branch, which failed it:

```text
not ok - a completed step still escalated: stale: test:fm-stepping (idle 500s, possible wedge, escalation 2)
```

The lane's run record showed the test step completed between the two escalations and the counter still climbed 1 to 2, which is the shape measured on the live fleet.

One mutation per protection, each applied to its own extracted copy of the tree, never to a working checkout.
Baselines read against: `tests/fm-watch-triage.test.sh` 53 `ok -` lines, `tests/fm-crew-state.test.sh` 53, both exiting 0.
A failing case aborts its suite, so each mutation was run again with the killed case's invocation removed.

| Mutation | Direction | Cases killed, in the order the suite reaches them | Tail |
| --- | --- | --- | --- |
| A completed step no longer clears the ratchet - the shipped defect | refuses too much | `test_completed_step_transition_clears_wedge_escalation` | 52 clean |
| Any readable run record clears the ratchet, completed step or not | permits too much | `test_completed_step_transition_clears_wedge_escalation` at its first escalation, then `test_unchanged_run_record_does_not_clear_wedge_escalation` | not chased to a clean suite |
| The evidence baseline is recorded once and never advances | permits too much | `test_completed_step_transition_clears_wedge_escalation` at its post-reset round | 52 clean |
| Every step row counts as completed, not only a `completed` one | permits too much | `test_steps_lists_only_completed_steps`, then `test_steps_excludes_uncompleted_steps` | crew-state suite |

The baseline-never-advances mutation is the one worth recording in its own right.
It clears the alarm correctly the first time and then pardons the lane on every later escalation, so the alarm reads as working while it can no longer sound.
Nothing in the suite caught it until the reset case was extended to run one more round with no further step completed, which is the property that separates clearing an alarm from disabling it.

### The alarm window the baseline belongs to

Verified 2026-08-05, in review of the above.
A fourth mutant of the same eager direction survived that matrix: the baseline was dropped nowhere the escalation count was dropped except by the step reset itself.
A count cleared by proven health ends an alarm window, so a baseline that outlived it let a step completed while the lane was demonstrably healthy pardon the wedge raised afterwards.
The count and the baseline are one piece of state and are now dropped together, through `clear_wedge_escalation` in `bin/fm-watch.sh`, at every site that drops the count - including the away-mode daemon's `clear_pause_tracking`.

`test_health_reset_drops_the_step_evidence_baseline` builds exactly that path: escalation 1 records the baseline, the lane proves its health through the CPU channel behind a static pane, the test step then completes, and the lane hangs inside the next step.
It proves health through CPU rather than rendered output deliberately, because that is what keeps the lane on the same-hash path where the baseline could survive - and it is the shape measured on the live fleet.
Run against the fix removed (`rm -f "$since_file" "$escalation_file"` restored in `health_evidence_reset`), it is the only case that fails, after 21 clean ones:

```text
not ok - a step completed before the health reset pardoned a later wedge:
```

The wedge absorbed silently, which is why the reported reason is empty: a pardoned alarm produces no output at all.
With the fix in place: `tests/fm-watch-triage.test.sh` 54 `ok -` lines, `tests/fm-crew-state.test.sh` 53, `tests/fm-health-evidence.test.sh` 8, all exiting 0.
That suite drives `health_evidence_reset` by extracting it from `bin/fm-watch.sh`, so it now extracts `clear_wedge_escalation` with it, and pins the same invariant one level down: the baseline survives every look that leaves the count standing and is gone the moment proven health clears it.

The away-mode daemon's side of the same drop is pinned by `test_handle_wake_terminal_signal_clears_pause_tracking` in `tests/fm-daemon.test.sh`: a terminal signal that clears the watcher's wedge count must not leave the baseline behind it.
That suite reads 113 `ok -` lines, exiting 0.

Deterministic entry points for this contract:

```sh
tests/fm-watch-triage.test.sh
tests/fm-crew-state.test.sh
tests/fm-health-evidence.test.sh
tests/fm-daemon.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
