---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, FORK_FRESHNESS, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `gh-axi`, this also covers an installed version below the bootstrap-owned floor; treat it as an upgrade request so non-interactive PR merges keep a working bare `--squash` shorthand.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `FORK_FRESHNESS: <owner/repo> status=behind|diverged behind=<n> ahead=<m> ... action=task <id> queued` - a maintained fork has fallen behind its upstream, and the sweep has already created that sync task with the proven procedure; it is queued, not launched, because the sync pushes a merge commit straight to a default branch.
  Relay the outcome to the captain in project terms (which fork, how far behind and ahead, that a PR against it would misreport its own diff until it is synced) and get a decision on running the sync now; `action=task <id> already queued` or `already under way` means an earlier sweep already raised it, so re-check that task before re-escalating.
- `FORK_FRESHNESS: <owner/repo> status=unknown reason=<text>` or `FORK_FRESHNESS_COVERAGE: status=unknown reason=<text>` - the reading could not be taken (no forge client, an expired credential, a rate limit, an unreachable forge, a renamed upstream, a timeout).
  This is not a clean sweep and must never be reported as one: fix the named cause, or tell the captain that fork's freshness is currently unknown.
  The sweep stays due until a reading actually succeeds, so an unresolved cause reappears rather than lapsing into silence.
- `FORK_FRESHNESS: <owner/repo> status=ignored reason=<text>` - an archived fork, one listed in `config/fork-sweep-ignore`, or a project registered `local-only` in `data/projects.md` and not cloned here, for which no forge repository could be resolved; no action, it is printed only so a skipped fork is never a silent absence.
  `docs/fork-freshness.md` owns the contract.
- `... action=task <id> retired RETIRED=<file> (<reason>)`, or `action=task <id> queued SUPERSEDED=<file> (<reason>)` on a behind reading - that fork's instruction sheet was left over from an episode the backlog reports done (or has no task for), so the sweep filed the stale brief at `data/<id>/<file>` and, when the fork is behind, opened a fresh sync task for it.
  No action; the line exists so the previous episode's reading stays discoverable from the reading that replaced it and the kept file.
  A behind reading with NO `SUPERSEDED=` is not a missing report: a re-sweep of an unchanged condition leaves the standing brief exactly as it is, so nothing was superseded and the reading correctly claims nothing. Expect the same of the wake and the Bridge row - a repeated undischarged sweep raises one of each in total, not one per hour, so a single row for a fork you know has been re-swept several times is the instrument working, not a lost notification.
- `... action=task <id> queued FOUND=absent` or `FOUND=closed` on a behind reading, in place of the `SUPERSEDED=<file> (<reason>)` clause - the state the backlog was in when this episode STARTED, which the sweep has since changed and confirmed changed; no action, it is the reading saying what it acted on.
  Read it as past tense however it sits in the sentence: `queued FOUND=absent` means the task did not exist and now does, NOT that it is still missing. The label is there because on a `NOT queued: <state now> after <create|reopen> FOUND=<state found>` reading the two states can be the same words, and `FOUND=` is the only thing telling a reader which clause is the before and which is the after.
- `TASK_UNKNOWN: <owner/repo> is behind and whether sync task <id> is already open could not be read (<reason>)` beside an `action=task <id> not queued: ...` reading - the fork is behind and the sweep created NOTHING this run, because it could not tell an open sync task from one that closed long ago.
  Resolve the named cause (usually a missing or unreadable `tasks-axi` backlog) and check that task by hand in this session: this is one of the two reading shapes where a behind fork raises no new work.
- `TASK_UNCONFIRMED: <owner/repo> is behind and the <create|reopen> of sync task <id> could not be confirmed afterwards (<reason>)` beside an `action=task <id> queue-state unknown after <create|reopen>` reading - the sweep tried to raise the task and then could not read back whether it worked, so it reports neither success nor failure.
  Check that task in the backlog by hand now. Do not read this as queued: the sweep is refusing to guess precisely because a created task and a discarded call look identical from the exit status.
- `TASK_MANUAL: <owner/repo> is behind but sync task <id> did not <create|reopen> - <what the backlog reports>; queue it by hand`, or `... was not created - its instructions could not be <written|placed>` - the sweep confirmed the task is NOT open, so this fork is behind with nothing tracking it.
  Queue that task by hand now, in this session. This is the reading the whole confirm-the-post-state path exists to produce instead of a false `queued`, so an unhandled line here leaves a behind fork completely untracked.
- Any of the three lines above is counted in the closing `FORK_FRESHNESS_COVERAGE: ... undischarged=<n>` field, and a non-zero `undischarged=` withholds the sweep's completion stamp - so the sweep stays due behind its retry floor and reports again rather than going quiet for the week over a fork nobody is carrying.
  That is why the line reappears until it is handled: do not read the repetition as noise.
- `NOTE_MANUAL: <owner/repo> reopened sync task <id>, but its body still holds the previous episode reading (behind <n>, <status>) rather than this one` beside a queued reading carrying `MANUAL=...note` - the task IS open and correctly owed; only its body was not refreshed, so it describes the episode that closed rather than the one now running.
  Paste the current reading into that task's body by hand, so nobody picks it up and works to a superseded number. Nothing is untracked here - unlike the three lines above, this one does not withhold the completion stamp.
- `WAKE_MANUAL: <owner/repo> raised no wake entry; carry sync task <id> forward by hand`, or `BRIDGE_MANUAL: <owner/repo> has no Bridge row; put sync task <id> to the captain by hand` beside a `FORK_FRESHNESS:` reading whose action carries `MANUAL=<step>[+<step>]` - the sync task and its instructions exist, but that many of its notifications did not land.
  Do the named step by hand now, in this session: the task is real and the brief is at `data/<id>/brief.md`, but nothing else will raise it again, so an unhandled line here is exactly the tracked-but-untracked item the sweep exists to prevent.
- `ARCHIVE_MANUAL: <owner/repo> ... data/<id>/brief.md ... could not be moved aside` beside an `action=task <id> NOT retired: ...` reading, or beside a queued reading carrying `MANUAL=...brief` - a stale instruction sheet could not be filed away, so it still reads as the current procedure for that fork.
  Move that brief aside by hand. It blocks no sync - nothing gates on it any more - but a worker picking up the task could act on the wrong episode's reading.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after same-host connectivity returns; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
