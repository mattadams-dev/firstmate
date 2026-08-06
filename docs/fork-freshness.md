# Fork freshness sweep

A fork that has fallen behind its upstream blocks its own merges, makes its pull
requests misreport their own diff, and sends investigations down paths the
upstream already changed. The rule that prevents it is simple - take the
compare-status reading before any fork pull request and once a week, and turn
`behind > 0` into a sync task - and it is exactly the kind of rule that a person
forgets at the moment it matters most.

`bin/fm-fork-freshness.sh` is that rule as a machine. It reads; it never syncs.
The script's own header and `--help` own the exact flags and output fields; this
page owns the contract, the cadence, and the local configuration.

## What it covers

Coverage is built from evidence rather than a list somebody has to remember to
extend:

- every fork owned by the sweep owner, read through the authenticated repository
  list so private repositories are included,
- every fork that is the origin of a clone under this home's `projects/`,
- every project registered in this home's `data/projects.md` that it has not
  cloned, qualified with the sweep owner,
- every entry in `config/maintained-forks`, for a fork this home neither owns nor
  has cloned,
- minus every entry in `config/fork-sweep-ignore`.

The sweep owner defaults to the account that owns this home's own `origin`.

A registered project this home *has* cloned is identified by its clone's origin,
which is the fork's real identity rather than a name qualified with a guessed
owner. For a project registered `local-only` and not cloned here, no forge
repository can be resolved at all - there is no clone to read an origin from, and
the posture does not promise a remote - so it is reported as ignored by name
rather than read as a 404: a permanent false unknown would withhold the
completion stamp on every sweep forever.

A registry name that does not resolve under the sweep owner - a project owned by
another organisation, a repository whose name differs from its project name, a
registry line left behind by a clone that was removed - reads as an honest
`status=unknown` for exactly the same structural reason, and that unknown
withholds the completion stamp, so the sweep stays due and re-runs at every
session start behind its retry floor. That is correct while the entry might be a
real fork nobody can reach, and pointless once it is known not to be: add the
name to `config/fork-sweep-ignore` (or `config/maintained-forks` with its real
`owner/repo`, if it is a fork after all). The ignore list is the documented way
to retire a registry entry from the sweep, and the entry stays reported as
ignored either way.

Nothing drops out silently. An ignored fork, an archived fork, and a fork whose
reading failed each get their own output line, and the closing
`FORK_FRESHNESS_COVERAGE` line accounts for every repository the sweep
considered. A fork that cannot be checked is an explicit unknown, never an
absence.

The repository list is one capped call, and a full list is indistinguishable from
a truncated one except by its size, so the size is checked. When the list comes
back at the cap the sweep prints the counts it did determine and, beside them, a
second coverage line declaring coverage unknown and naming the cap:

```
FORK_FRESHNESS_COVERAGE: owner=acme repos=200 forks=12 swept=12 behind=0 undischarged=0 unknown=0 ignored=0
FORK_FRESHNESS_COVERAGE: status=unknown reason=the repository list for acme returned 200 entries, the whole --limit 200 cap, so any fork past it was never read
```

The fields are three different questions and none of them stands in for another.
`unknown=` counts readings that could not be **taken**. `behind=` counts forks
the forge reported behind. `undischarged=` counts how many of those ended with no
sync task the backlog confirms open - work this sweep owed and did not deliver,
on a forge reading that succeeded. That last count is what withholds the
completion stamp; see [When it runs](#when-it-runs).

That is unknown coverage, not a clean sweep: the exit code carries it, the
completion stamp is withheld, and the sweep stays due. `FM_FORK_SWEEP_LIST_LIMIT`
raises the cap for a run.

The public `users/<login>/repos` endpoint is deliberately not used: it returns
only public repositories, so an enumeration built on it silently truncates the
sweep's whole reason to exist. [`verification/fork-freshness.md`](verification/fork-freshness.md)
records the measurement.

## What a reading says

Each fork produces one line naming both directions, because "behind 20, ahead 6,
diverged" is actionable where a single number is not:

```
FORK_FRESHNESS: acme/widget status=diverged behind=20 ahead=6 upstream=up/widget compare=main...main action=task fm-sync-acme-widget queued FOUND=absent
```

`FOUND=` is the state the backlog was in when this episode **started** -
`absent` or `closed` - and it is labelled rather than phrased because by the time
the line prints, the sweep has changed that state and confirmed it changed. An
unlabelled `(the backlog has no such task)` after the word `queued` would be the
instrument denying what it had just observed. When a brief was filed away the
same fact rides on the `SUPERSEDED=<file> (<reason>)` clause instead, where the
present tense is right: that state is why the file was kept, at the moment it was
kept. A reading carries one form or the other, never both.

A reading that could not be taken says so and carries no counts at all:

```
FORK_FRESHNESS: acme/widget status=unknown reason=compare against up/widget failed: gh: API rate limit exceeded (HTTP 403)
```

Unknown is a real outcome, not a soft failure. A missing `gh`, an expired
credential, a rate limit, an unreachable forge, a renamed upstream and a payload
that does not parse all read as unknown, and none of them may render as
in-sync - a check that cannot run must never look like a check that passed. The
exit code carries the same distinction: 0 for a complete sweep with nothing
behind, 3 when something is behind, 4 when something is unknown, 5 for both.
Coverage that could not be fully determined counts as unknown for that exit code
even when every reading the sweep did take was clean.

## What happens when a fork is behind

The sweep creates the work rather than describing it. On `behind > 0` it
materialises, idempotently, under the deterministic task id
`fm-sync-<owner>-<repo>` (owner-qualified so two forks sharing a repository name
under different accounts cannot collide into one task):

- `data/<id>/brief.md`, carrying the proven sync procedure and the reading that
  opened the task,
- a durable notification, so the result survives a restart,
- a Bridge item addressed to the captain,
- and last, the backlog item itself.

The order is the contract, not an implementation detail, and the rule behind it
is that **whatever the sweep gates on must be the last artifact it creates**. The
sweep short-circuits on an open task, so a task existing while the wake and the
Bridge row do not would be skipped by every later sweep and nobody would ever be
told this fork is behind. Creating the task last makes an open task imply the
three artifacts before it.

The brief is rendered beside itself and moved into place in one atomic move, same
directory, so a materialisation cut short by a timeout or a session kill can
never leave a half-written procedure for a worker to act on. It comes first
because a task that is discoverable before its instructions are readable is the
harmful order; a brief with no task behind it suppresses nothing, and the next
sweep simply rewrites it.

`action=task <id> queued` asserts all four. Any of the first three that did not
happen is reported instead of assumed: a loud `ARCHIVE_MANUAL:`, `WAKE_MANUAL:`
or `BRIDGE_MANUAL:` line on stderr saying what to do by hand, and a
`MANUAL=<step>[+<step>]` marker on the reading itself, so the line never claims
an artifact nobody observed. A notification that failed never costs the task its
brief; instructions that could not be written do withhold the task, because
queueing work nobody can execute is worse than not queueing it - and the fork's
`status=behind` reading still goes out either way.

Because the id is derived from the fork, a second sweep addresses the first
sweep's task instead of creating another, and a sync already under way is left
alone.

### A marker existing is not the work being owed

Two questions, and no file answers both:

- **Is a sync owed?** The forge answers it: `behind > 0`.
- **Does open work already carry it?** The **task system** answers it, asked
  directly by id on every reading, with nothing on disk gating the question.

Keying the second on the first is the conflation this instrument carried through
three rounds, one layer further downstream each time - a file existing read as a
task existing, then retiring on observation read as retiring on completion, then
`add` read as reopening.

So `data/<id>/brief.md` guards nothing. It is the worker's instructions, and the
atomic move above is creation-atomicity alone; liveness is not its job and the
two no longer share an artifact. That separation matters because `data/<id>/` is
never deleted - teardown keeps it as the task's evidence custodian - so anything
that meant only "this file exists" would outlive the episode that created it.

Every reading resolves the task question to one of four answers:

| Answer | Evidence | What the sweep does |
| --- | --- | --- |
| open | a worker holds `state/<id>.meta`, or the backlog reports the task queued or in flight | short-circuits: `action=task <id> already queued (<evidence>)` |
| closed | the backlog reports the task done | **reopens** it for a fresh episode |
| absent | the backlog has no such task | creates it |
| unknown | the task system could not be asked (no `tasks-axi`, an unreadable backlog, a state it does not recognise) | creates nothing, files nothing away, and says which two worlds it could not tell apart |

Hold is an orthogonal field, not a state: the CLI reports a held task as
`state: queued` with `held: yes`, and there is no state named `held` anywhere in
it. A held sync task is therefore open work somebody paused on purpose, and it
short-circuits like any other open task.

### Making the task exist, and confirming that it did

The primitive is matched to the answer, because `tasks-axi add` is **create-only**:
over an id that already exists it returns `already: true` **at exit 0**, having
transitioned nothing and discarded the new body. Only `reopen` returns a closed
task to the queue.

Exit status therefore cannot distinguish "a sync is now owed" from "nothing was
queued at all", so the sweep does not use it as the result. Whichever primitive
ran, the post-state is read back from the task system and the reading is keyed on
what was actually found:

| Post-state | Reading |
| --- | --- |
| confirmed open | `action=task <id> queued <pre-state>` |
| confirmed still closed or absent | `action=task <id> NOT queued: <state now> after <create\|reopen> <pre-state>`, plus `TASK_MANUAL:` on stderr |
| could not be read | `action=task <id> queue-state unknown after <create\|reopen> <pre-state>`, plus `TASK_UNCONFIRMED:` on stderr |

`<pre-state>` is the labelled `FOUND=<absent\|closed>` above, or the
`SUPERSEDED=<file> (<reason>)` clause when a brief was filed away. The middle row
is why it is labelled at all rather than merely re-tensed: the state now and the
state found can be the same words - `NOT queued: the backlog has no such task
after create FOUND=absent` - and the label is the only thing telling a reader
which clause is which.

The word `queued` is reachable only from a confirmed reading. Without that, a
guard that correctly detects a stale state and then fails to act on it is not
half-working - it is a false-success generator, and a false success outranks a
false failure here because nothing prompts a look.

`reopen` is reached only from a confirmed **closed** reading. It moves Done *or
In flight* back to Queued, so calling it on an open task would pull that work
back to the queue underneath the crewmate holding it.

### Superseding and retiring instructions

A brief is never silently deleted. When a closed episode's brief is replaced by a
new one it is kept as `data/<id>/brief.retired-<stamp>.md`, and the reading names
both the file and why a new episode started:

```
FORK_FRESHNESS: acme/widget status=behind behind=50 ahead=0 upstream=up/widget compare=main...main action=task fm-sync-acme-widget queued SUPERSEDED=brief.retired-20260805T101500Z.md (the backlog reports it done)
```

A fork that reads `behind=0` while its brief stands beside a closed task has a
stale instruction sheet, so that reading files it away there and then:
`action=task <id> retired RETIRED=<file> (<reason>)`. This is record hygiene and
is no longer load-bearing - the behind path supersedes its own brief, so the two
paths are independent, where previously the behind path could only recover if a
`behind=0` reading happened to be observed first. That never getting its chance
is what kept a stale marker alive against an actively moving upstream.

A liveness question that could not be answered prints `TASK_UNKNOWN:` on stderr
and says on the reading that nothing was created and why; a brief that could not
be filed away prints `ARCHIVE_MANUAL:` and continues, because it blocks no sync.

That continuation costs the on-disk copy of the previous reading, and how much
else survives depends on which path is running. Reopening a closed task also
archives the superseded reading into the task's own body, through `reopen`'s
accompanying `update --archive-body`, so the record survives there. Creating a
task the backlog no longer has does not: there is no previous body to archive,
so that copy is simply lost. The reading and the stderr line say the archive
failed either way rather than promising a record that may not exist.

When the reopen itself lands but that body refresh does not, the task is open and
owed but still describes the **previous** episode's reading. That is a stale
instruction, not a missing task, so it is reported as its own step: `NOTE_MANUAL:`
on stderr naming the reading the body should have carried, and `note` in the
`MANUAL=` set on the reading. Refresh the body by hand so nobody picks the task
up and works to a superseded number.

### A retry adds nothing

An undischarged behind fork withholds the completion stamp, so the sweep comes
back at the retry floor rather than the weekly cadence. That is the point of the
stamp rule, and it means a condition nobody has resolved is re-swept roughly
every hour instead of every week. Every artifact is therefore keyed on the
**condition**, not on the attempt, so a hundred retries over one unresolved
situation leave exactly what one leaves:

| Artifact | What makes two attempts the same | What a repeat does |
| --- | --- | --- |
| `data/<id>/brief.md` | the brief's whole content **except the observation timestamp** on its `Taken <when>: **behind N, ahead M - <status>**` line | nothing: the standing brief is left in place, not archived and not rewritten, and the reading carries the bare `FOUND=` rather than a `SUPERSEDED=` clause |
| the wake entry | the sync task id, asked of `fm_wake_queued_keys` - a key is listed there exactly while a record for it is queued and unconsumed | nothing: no second entry is appended while the first is still unread |
| the Bridge ask | the ask title, which names the fork and the upstream it is behind; the current numbers live in the row's body | nothing: no second ask is written while an open row for that fork stands |

The timestamp is excluded from the brief comparison deliberately, and the
exclusion is load-bearing rather than cosmetic: it is re-read from the clock on
every attempt, so comparing whole files would find two attempts at an identical
situation different every single time - a check that can never fire, which is a
false success wearing the shape of a fix. Everything else in that line - the
behind count, the ahead count, the status - **is** compared, along with every
other byte of the procedure, so the question the comparison actually answers is
"would rewriting this change what it tells a worker to do?"

The identity in each row above is read from a record that already exists: the
brief's own content, the wake queue, the board. Nothing new is stored to track
episodes - no marker, no attempt counter - because a marker that can outlive what
it describes is the failure this instrument has spent four rounds removing.

The Bridge half is worth stating precisely, because the board alone would hide
it. The fold derives an item's id from its title, so asking the same question
every hour has always folded to ONE row - the visible board was never the thing
growing. The append-only ledger under it was, one record per retry, and that
stream is what every audit reads raw. Skipping the ask is what keeps it flat.

The two idempotence keys are read qualitatively on purpose. A fork that is behind
by 3 and the same fork behind by 9 an hour later are the same unresolved
condition, so keying the wake or the board on the exact count would raise a fresh
one every retry and buy nothing - an upstream that moves is the normal case. The
brief is the one artifact that does track the numbers, because they are part of
what it instructs, so a genuinely changed reading still supersedes the old
instructions and still names the file it kept.

The sweep does not launch the worker by default. The sync pushes a merge commit
straight to a default branch, which is not something this fleet does without a
person saying go; the task waits, tracked, until someone does. A home that wants
it hands-off passes `--dispatch` and sets `config/fork-sync-harness`, and even
then the launch only happens where this home has a clone of that fork.

The procedure in the generated instructions is the hard-won one, and its
alternatives are known-broken rather than merely worse:

1. Push a true merge commit directly. Never through a pull request - a squashed
   sync fossilises the divergence permanently, because the merged-away commits
   never become ancestors and every later comparison still reports the fork
   behind.
2. `gh repo sync` fails on commits that touch workflow files, and upstreams
   carry workflow commits.
3. Push over the SSH alias remote form.
4. The old fast-forward procedure is retired, not conditioned.

## When it runs

Both triggers named by the rule fire it, and each is owned by the surface that
cannot be bypassed:

- **Before any fork pull request**: `bin/fm-pr-check.sh` takes a single-repository
  reading for the PR's own repository. That script is the only writer of the
  `pr=` line that `bin/fm-pr-merge.sh` requires, so no merge through the
  sanctioned path can skip the reading. It is silent when the repository is
  determinately not a fork, so ordinary non-fork PRs stay quiet. It is bounded by
  `FM_FORK_SWEEP_PR_TIMEOUT` (default 45 seconds), so an unreachable forge costs
  an unknown reading rather than a hung task, and it can never fail arming the
  merge watch.

  This gate reports and creates work; it never blocks or fails the pull request,
  and there is nothing to override. It is also deliberately **un-ignorable**: it
  does not consult `config/fork-sweep-ignore`, because a pull request landing
  against an ignored fork is precisely the moment the reading is wanted. Ignoring
  a fork means "do not chase this one weekly", not "do not tell me when I am
  about to merge into it".
- **Weekly**: the locked session-start sweep in `bin/fm-bootstrap.sh` runs
  `sweep --if-due`, which is silent between cadences. A read-only session (one
  that could not take the fleet lock) never runs it, exactly like every other
  mutating sweep. It is bounded by `FM_FORK_SWEEP_BOOTSTRAP_TIMEOUT` (default 45
  seconds), and a timeout is reported as unknown coverage rather than silence.

The cadence stamps live at `state/.fork-freshness-last` (last complete sweep) and
`state/.fork-freshness-attempt` (last attempt). The completion stamp asserts two
things, and both have to hold:

- **coverage was fully determined** - every candidate produced a reading, and the
  enumeration was not truncated;
- **everything this sweep owed was discharged** - every fork read as behind ended
  with a sync task the backlog confirms open (`undischarged=0`).

So neither an outage nor a failed materialisation can buy a week of silence: an
incomplete sweep stays due, held back only by a short retry floor
(`FM_FORK_SWEEP_RETRY_MINUTES`, default 60) so a persistently broken credential
reports once an hour rather than once a session.

The second half is the one that is easy to lose. A sweep that reads a fork behind
and then cannot make its task exist - no `tasks-axi` to ask, a post-state it
could not read back, a remediation the backlog confirms did not take, or
instructions it could not write - exits 3 like any other behind sweep, having
tracked nothing. Stamping that as complete would go quiet for a full cadence over
a fork nobody is carrying, which is a false success, and this fleet ranks a false
success below a false failure because nothing prompts a look at it. A behind fork
whose task **is** confirmed open is a different case entirely: that sweep is
complete, it stamps, and the next one runs on the normal cadence, because the
open task is what carries the work forward.

## Local configuration

All optional, all under this home's gitignored `config/`, one value per line.

| File | Meaning |
| --- | --- |
| `fork-sweep-owner` | login whose forks are swept; defaults to this home's own origin owner |
| `maintained-forks` | extra `owner/repo` (or bare `repo`) candidates, one per line |
| `fork-sweep-ignore` | `owner/repo` or bare `repo` candidates the **weekly sweep** skips; each is still reported. The pre-PR gate ignores this file by design (see above) |
| `fork-sweep-interval-days` | `--if-due` cadence in whole days, default 7 |
| `fork-sync-harness` | harness `--dispatch` launches the sync worker on |

`FM_FORK_SWEEP_INTERVAL_DAYS`, `FM_FORK_SWEEP_RETRY_MINUTES`,
`FM_FORK_SWEEP_BOOTSTRAP_TIMEOUT`, `FM_FORK_SWEEP_PR_TIMEOUT`,
`FM_FORK_SWEEP_LIST_LIMIT` and `FM_FORK_SYNC_HARNESS` override the corresponding
values for one run.
