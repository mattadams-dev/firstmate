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

Two consequences follow, and both are load-bearing:

- `bin/fm-lock.sh` runs as an ordinary tool call, so it reads the session id from `CLAUDE_CODE_SESSION_ID` in its own environment.
- The Stop hooks receive the same session id as `.session_id` in the hook payload, which `bin/fm-turnend-guard.sh` already parsed for its per-session block budget before this change.

The session id therefore reaches both the writer and the readers of the lock, and it is the same value on both sides of the CLI/harness split that defeats a process id.

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

## Both mutation directions

Guard-class code fails in two directions and both are tested.
`tests/fm-session-identity.test.sh` carries the mutation table: a mutant that weakens the identity comparison must break its own test, and a mutant that refuses a legitimate session must break a different one.
A guard that refuses everything is not safe, because it is disabled by the next person under time pressure.
