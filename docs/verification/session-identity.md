# Session-identity verification

Audience: maintainer verification.

This record supports the session-lock identity contract in `bin/fm-session-lock-lib.sh`, the lock record written by `bin/fm-lock.sh`, and the Claude Stop auto-arm identity gate in `bin/fm-claude-stop-autoarm.sh`.
It records why session identity is read from a session id rather than from a process id, and where that session id is observable.

## Why a process id cannot answer the ownership question

A Claude Code primary is two layers, and the split breaks the ancestry chain by construction rather than by accident.
The interactive CLI is one process; the session harness that runs hooks and tool calls can be a different process on unrelated ancestry, reached through a detached pty host.
An ancestry walk started from a hook therefore cannot reach the CLI process, so a lock recording either process's id is unresolvable from the other.

Measured on 2026-08-05 in the primary firstmate home, with the session live and unable to exit:

```
state/.lock            = 3638271, alive, cmdline `claude --dangerously-skip-permissions -n firstmate`
this session's harness = 849887,  ancestry: bash -> claude 2.1.222 -> claude bg-pty-host -> init
```

Both processes belonged to one session.
Neither could be reached from the other by walking parents, so `fm_session_lock_owned_by_self` was false for the session that genuinely owned the home.
The auto-arm refused to arm, the turn-end guard demanded supervision, and no command inside the session could resolve the conflict.

A more careful process check cannot fix this, because there is no correct answer to be had from a process id here.
Only changing the identity basis can.

## Where the session id is observable

Probed on 2026-08-05, Linux 6.18.33.2 (WSL2), Claude Code 2.1.223.
The unedited probe output is kept beside this record at [`session-identity-probe-2026-08-05.txt`](session-identity-probe-2026-08-05.txt), because the live processes behind it cannot be re-observed later.

The harness process's own environment does **not** carry the session id:

```
lock pid 392881 cmdline: claude --dangerously-skip-permissions -n firstmate
lock pid 392881 environ: 0 variables matching ^CLAUDE
```

Every tool-call child of that harness does, alongside the harness process id:

```
shell pid 51380   parent 3874878 (claude ...)
    CLAUDE_CODE_SESSION_ID=b20a76b2-0464-4db9-82ec-983f51125e24
    CLAUDE_PID=3874878
shell pid 138017  parent 3568128 (claude ...)
    CLAUDE_CODE_SESSION_ID=e880a734-41e2-44b1-9c11-4dbd7a2b6077
    CLAUDE_PID=3568128
```

Claude Code also keeps one directory per session under `~/.claude/session-env/`, named by the session id (484 present at probe time).
That directory is a Claude Code internal and is not read by firstmate; it is recorded here only as independent confirmation that the session id is the durable per-session identifier.

Because the variable is injected into every child, it is also inherited by processes that are not that session.
Firstmate launches Codex, Kimi, and the other harnesses from inside a Claude tool call, so a non-Claude primary sees a `CLAUDE_CODE_SESSION_ID` naming a session in a different home entirely.
`bin/fm-lock.sh` therefore trusts the environment source only when the harness it resolved is genuinely Claude Code, and records no session id otherwise.
That is a provenance question about a variable, not an ownership decision, and an unresolvable answer records nothing and lands on the unchanged legacy basis.

That decision is keyed on the resolved harness NAME, never on an occurrence of the string in the arguments.
For a bare-interpreter harness the name is read from the script path it is running - the first non-option word after `argv[0]` - so `node .../opencode --model claude-sonnet-...` resolves to `opencode` and records nothing, while `node .../claude/versions/2.1.223/cli.js` resolves to `claude` and records its own session.
Harness DETECTION for a bare interpreter still scans the whole argument string, because narrowing it would stop recognizing harnesses that are already recognized; only the Claude classification is tightened.
An interpreter option that takes a separate path value can make the script-path read miss, and that direction only ever loses the classification, never invents it.

Two consequences follow, and both are load-bearing:

- `bin/fm-lock.sh` runs as an ordinary tool call, so it reads the session id from `CLAUDE_CODE_SESSION_ID` in its own environment.
- The Stop hooks receive the same session id as `.session_id` in the hook payload, which `bin/fm-turnend-guard.sh` already parsed for its per-session block budget before this change.

The session id therefore reaches both the writer and the readers of the lock, and it is the same value on both sides of the CLI/harness split that defeats a process id.

## Live-harness confirmation

`CLAUDE_CODE_SESSION_ID` is a vendor-emitted signal, so only a real session can confirm it is still emitted, still a session-id token, and still the same id the Stop payload carries.
`tests/fm-claude-stop-autoarm-live-e2e.test.sh` is the guard that refreshes this claim; it is opt-in because standard CI has neither harness binaries nor credentials.

```sh
FM_CLAUDE_LIVE_E2E=1 bash tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Result on 2026-08-05, Claude 2.1.223:

```
ok - Claude 2.1.223 (Claude Code) live E2E reclaimed a stale session lock through session start,
recorded a session id matching this session (ac23ea91-15da-4f43-8852-bb7dcff74c6e), completed two
tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary with a recorded
refusal
```

Run it after every Claude Code upgrade.
It fails naming the harness and version, so a vendor change that stopped emitting the variable is loud rather than a silent slide back to the process basis.

## The refusal bias, and what it costs when a refusal is silent

The identity gate must keep refusing a session that does not own the home.
That refusal has twice prevented firstmate from ending the captain's own CLI, and only the basis for deciding ownership changes here.

A refusal must also be recorded.
Measured across three consecutive turn-end blocks in the same incident:

```
state/.turnend-claude-blocks : count=1, epoch=1778   frozen across all three blocks
state/.claude-autoarm-epoch  : epoch=1778 outcome=rewake, updated_at unchanged
failure markers              : notified=no  alarmed=no
beacon                       : 365s, past the 300s grace
```

The auto-arm's identity refusal exited 0 before writing any epoch.
The guard's bounded fail-open advances on a fresh epoch, so nothing advanced, and the mechanism designed to survive an unavailable auto-arm never learned an arm had failed.
One silent exit defeated both the primary path and its backstop, because the backstop was keyed on a record the silent exit never wrote.

An exit that changes nothing observable is indistinguishable from an exit that never ran.
The identity refusal therefore writes a `refused` epoch and one operator notice per episode, and the guard accepts `refused` as a verified failure episode so its bounded, alarmed fail-open remains reachable.

### Two withheld outcomes, because they are two observed worlds

A refusal and a failed acquisition are not the same event, and reporting one as the other sends the operator after the wrong defect.

- `refused` - another session owns this home, proven by a live lock holder naming a different session (or by a lock nothing can be proven from). The hook is working; repairing it changes nothing.
- `acquire-failed` - the recorded owner failed the harness-liveness check, so nobody owns this home, and reclaiming the lock through `bin/fm-lock.sh` still failed or left ownership unproven. Telling the operator to "reacquire the lock" here names the step that was just attempted and failed.

Both are verified failure episodes for `failure_episode_verified`, and both raise the one-per-episode notice, so the bounded escape is reachable on either path rather than starved under a new name.
The `block_stop` banner and the terminal fail-open `systemMessage` both branch on the recorded outcome, so the last message before a session is allowed to end blind describes the world that was actually observed rather than exhausted retries that never ran.

### The record belongs to the home, so it may not clobber a fresher one

`state/.claude-autoarm-epoch` and `state/.claude-autoarm-failure-notified` are the HOME's, shared by every session whose Stop fires there, and a session recording a withheld outcome deliberately holds no owner lock.
An unconditional write therefore fails in the mirror direction: session A owns the home and records a fresh `rewake`; session B's Stop refuses and overwrites it; A's own `autoarm_owns_recovery` then fails, A's turn is blocked, and A is told to hand back a home it already owns.
B's notice also suppresses A's block-budget reset.
That is not a more permissive path - it is a legitimate session made worse off, which breaks the refusal bias just as surely.

A withheld outcome is therefore declined when the current epoch is a NON-withheld outcome that is still fresh by the guard's own `EPOCH_FRESH` window, and declining leaves the home's shared auto-arm state byte-for-byte unchanged and still exits 0.
Withheld-over-withheld and withheld-over-stale must still record, and that half is load-bearing: the bounded escape advances on fresh epochs, so a refusal that could not replace a refusal would make the escape unreachable again.

## Both mutation directions

Guard-class code fails in two directions, so both are mutated.
A mutant that weakens the identity comparison must break its own test, and a mutant that makes the check refuse a legitimate session must break a different one.
A guard that refuses everything is not safe; it is the same failure one mirror over, because it is disabled by the next person under time pressure.

Every mutant below was applied one at a time to a clean tree, with each test run in its own shell and the tree restored before the next.
All 19 rows were re-measured in full against the final branch state on 2026-08-05, so no row records a verdict from an earlier revision.
Each suite halts at its first failing assertion, so a run observes only the first fixture a mutant kills; where a row names more than one, the extras were measured on their own.
`tests/fm-session-identity.test.sh` owns these fixtures unless another suite is named.

Weakening - the identity check admits something it must refuse:

| Mutant | File | Change | Broke |
| --- | --- | --- | --- |
| W1 | `bin/fm-session-lock-lib.sh` | any established session matches the lock | `test_refuse_lock_naming_another_session`, and `test_identity_refusal_is_recorded` |
| W2 | `bin/fm-session-lock-lib.sh` | a caller whose own session id is unestablishable inherits the lock's | `test_refuse_when_own_session_unestablishable` |
| W3 | `bin/fm-safe-kill.sh` | read the lock file whole again instead of its pid line | `test_safe_kill_still_refuses_the_lock_holder` |
| W4 | `bin/fm-lock.sh` | acquire over a live holder naming another session | `test_lock_refuses_a_different_live_session` |
| W5 | `bin/fm-claude-stop-autoarm.sh` | the identity refusal exits 0 without writing its epoch | `test_identity_refusal_is_recorded` |
| W6 | `bin/fm-turnend-guard.sh` | drop `refused` from the verified failure episode | `test_recorded_refusal_reaches_the_bounded_escape` |
| W7 | `bin/fm-lock.sh` | trust an inherited `CLAUDE_CODE_SESSION_ID` on any harness | `test_lock_ignores_an_inherited_session_id_on_another_harness` |
| W8 | `bin/fm-session-lock-lib.sh` | classify a bare interpreter as Claude Code from any `claude` substring in its argv | `test_lock_ignores_a_claude_model_flag_on_a_bare_interpreter` |
| W9 | `bin/fm-claude-stop-autoarm.sh` | let a withheld outcome clobber a fresher non-withheld epoch | `test_refusal_does_not_clobber_a_fresher_owner_epoch` |
| W10 | `bin/fm-claude-stop-autoarm.sh` | record the recovery-failure branches as `refused` again | `test_recovery_failure_records_a_distinct_outcome` |
| W11 | `bin/fm-claude-stop-autoarm.sh` | the recovery-failure branches write their epoch but no failure notice | `test_recovery_failure_records_a_distinct_outcome` |
| W12 | `bin/fm-turnend-guard.sh` | drop `acquire-failed` from the verified failure episode | `test_recovery_failure_reaches_the_bounded_escape` |

W9 is a weakening in the mirror direction, and it is filed here rather than under over-refusal on purpose: the mutant makes the auto-arm write MORE than it observed, and the session it then penalizes is the legitimate owner.
Which side of the table a mutant sits on is decided by what the code does wrong, not by who ends up worse off.

Over-refusal - the identity check refuses something it must admit:

| Mutant | File | Change | Broke |
| --- | --- | --- | --- |
| R1 | `bin/fm-session-lock-lib.sh` | demand the ancestry test as well as the session id | `test_admit_same_session_across_changed_process_identity` |
| R2 | `bin/fm-session-lock-lib.sh` | refuse every lock that records no session id | `test_admit_legacy_session_less_lock_by_ancestry` |
| R3 | `bin/fm-lock.sh` | refuse to acquire at all when no session id is observable | `test_lock_without_a_session_id_stays_on_the_pid_basis` |
| R4 | `bin/fm-lock.sh` | refuse a session's own lock whenever the recorded pid is live | `test_lock_is_reacquired_by_its_own_session` |
| R5 | `bin/fm-claude-stop-autoarm.sh` | refuse before ownership is tested at all | `tests/fm-claude-stop-autoarm.test.sh`, nested-ancestry arm |
| R6 | `bin/fm-claude-stop-autoarm.sh` | decline every withheld record whenever any epoch already exists | `test_refusal_still_records_over_a_refused_or_stale_epoch` |
| R7 | `bin/fm-session-lock-lib.sh` | read the bare interpreter's own argv[0] as its script path | `test_lock_records_a_node_launched_claude_install` |

R6 is the mirror of W9 and is the reason the two are separate fixtures: a rule that never clobbers is not safe either, because withheld-over-withheld is what advances the bounded escape.
A refusal that cannot replace a refusal restores the 2026-08-05 deadlock by a different route.

R5 is killed by the auto-arm suite rather than by this one, and that is the right owner: "a legitimate owner still arms" is the auto-arm's own contract, and duplicating its fixture here would give the two copies room to drift.

R4 is worth keeping in mind when editing these fixtures.
It survived the first version of `test_lock_is_reacquired_by_its_own_session`, because that fixture recorded an ordinary live shell as the prior holder and the harness-liveness predicate rejects a shell - so the live-holder branch the mutant changes was never reached.
The specimen only reproduces when the recorded holder is alive AND reads as a real harness, which is what it was in the field.
A fixture that exercises the wrong branch reports a coverage it does not have.
