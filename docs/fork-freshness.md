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
- every entry in `config/maintained-forks`, for a fork this home neither owns nor
  has cloned,
- minus every entry in `config/fork-sweep-ignore`.

The sweep owner defaults to the account that owns this home's own `origin`.

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
FORK_FRESHNESS_COVERAGE: owner=acme repos=200 forks=12 swept=12 behind=0 unknown=0 ignored=0
FORK_FRESHNESS_COVERAGE: status=unknown reason=the repository list for acme returned 200 entries, the whole --limit 200 cap, so any fork past it was never read
```

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
FORK_FRESHNESS: acme/widget status=diverged behind=20 ahead=6 upstream=up/widget compare=main...main action=task fm-sync-acme-widget queued
```

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

- a backlog item,
- a durable notification, so the result survives a restart,
- a Bridge item addressed to the captain,
- and last, `data/<id>/brief.md`, carrying the proven sync procedure and the
  reading that opened the task.

The order is the contract, not an implementation detail. The brief is also the
idempotency guard, so it is rendered beside itself and moved into place - one
atomic move, same directory - only after the other three have been attempted. A
materialisation cut short by a timeout or a session kill therefore leaves no
guard and no half-written procedure, and the next sweep redoes the whole thing
rather than reporting `already queued` over a task nobody was told about.

`action=task <id> queued` asserts all four. Any of the first three that did not
happen is reported instead of assumed: a loud `BACKLOG_MANUAL:`, `WAKE_MANUAL:`
or `BRIDGE_MANUAL:` line on stderr saying what to do by hand, and a
`MANUAL=<step>[+<step>]` marker on the reading itself, so the line never claims
an artifact nobody observed. None of the three is fatal - a failed notification
never costs the task its brief.

Because the id is derived from the fork, a second sweep finds the first sweep's
task instead of creating another, and a sync already under way is left alone.

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
- **Weekly**: the locked session-start sweep in `bin/fm-bootstrap.sh` runs
  `sweep --if-due`, which is silent between cadences. A read-only session (one
  that could not take the fleet lock) never runs it, exactly like every other
  mutating sweep. It is bounded by `FM_FORK_SWEEP_BOOTSTRAP_TIMEOUT` (default 45
  seconds), and a timeout is reported as unknown coverage rather than silence.

The cadence stamps live at `state/.fork-freshness-last` (last fully determined
sweep) and `state/.fork-freshness-attempt` (last attempt). The completion stamp
is written only when coverage was fully determined, so an outage cannot buy a
week of silence: an incomplete sweep stays due, held back
only by a short retry floor (`FM_FORK_SWEEP_RETRY_MINUTES`, default 60) so a
persistently broken credential reports once an hour rather than once a session.

## Local configuration

All optional, all under this home's gitignored `config/`, one value per line.

| File | Meaning |
| --- | --- |
| `fork-sweep-owner` | login whose forks are swept; defaults to this home's own origin owner |
| `maintained-forks` | extra `owner/repo` (or bare `repo`) candidates, one per line |
| `fork-sweep-ignore` | `owner/repo` or bare `repo` candidates to skip; each is still reported |
| `fork-sweep-interval-days` | `--if-due` cadence in whole days, default 7 |
| `fork-sync-harness` | harness `--dispatch` launches the sync worker on |

`FM_FORK_SWEEP_INTERVAL_DAYS`, `FM_FORK_SWEEP_RETRY_MINUTES`,
`FM_FORK_SWEEP_BOOTSTRAP_TIMEOUT`, `FM_FORK_SWEEP_PR_TIMEOUT`,
`FM_FORK_SWEEP_LIST_LIMIT` and `FM_FORK_SYNC_HARNESS` override the corresponding
values for one run.
