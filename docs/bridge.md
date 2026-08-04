# The Bridge

The Bridge is the captain's primary surface for fleet state.
It replaces the terminal stream as the place they read, because a scrolling stream loses captain-relevant items: an ask scrolls out of view and is not seen again until someone goes looking for it.

The whole design follows from one shape.

**One canonical ledger.**
**One fold.**
**The board is generated and never hand-edited.**

```
bin/fm-bridge.sh          writer  ->  data/bridge/ledger.jsonl   append-only JSONL
                                             |
                                    bin/fm-bridge-render.sh      the ONE fold
                                       /         |         \
                              --html        --state      --lifecycle
                             the board    folded state   typed answer
                                          (published)     about one id
```

Board freshness is supervision freshness: the board is rendered by the supervision cycle, so a stale timestamp on it means the cycle itself has stopped.

## Canonical paths

These are a published interface with an external consumer, not internal detail.
They resolve per home, so a secondmate reads and writes its own and never the parent's.

| What | Path | Notes |
| --- | --- | --- |
| Ledger | `$FM_HOME/data/bridge/ledger.jsonl` | append-only, one JSON object per line |
| Board | `$FM_HOME/data/bridge/bridge.html` | generated; overwritten every tick |
| Change stamp | `$FM_HOME/state/.bridge-render` | drives skip-when-unchanged |

Ask the scripts rather than hardcoding: `bin/fm-bridge.sh path ledger` and `bin/fm-bridge.sh path board`.

## Reading it: `--state` is the only supported reader

Do not write a second parser for the ledger.
Every consumer reads folded current state through the one fold:

```sh
bin/fm-bridge-render.sh --state                 # whole fleet, structured JSON
bin/fm-bridge-render.sh --state --id <id>       # the same document, one item
bin/fm-bridge-render.sh --lifecycle <id>        # typed answer about one id
```

The narrowed document is narrowed everywhere, not just in `items`: every list of item ids in the document names only the retained id, wherever it sits.
That holds by recognition rather than by a list of field names - a list whose members are ids the whole fold carried is narrowed because of what it holds - so a field added later is narrowed without anyone having to remember it.
The documented traversal is `for k in doc["asks"]: doc["items"][k]`, so a queue still naming a dropped id would hand a targeted consumer a `KeyError` on the document meant to be easier to read.
The ledger-wide `counts` stay ledger-wide, because conservation is a claim about the stream rather than about the slice.

The plural matters here.
A shared fold with a single consumer decays back into private logic, because nothing else exercises its contract.
On day one it has four: the HTML board, the co-captain's independent audit, firstmate's own record linter (`bin/fm-bridge.sh lint`), and targeted lifecycle queries.

This is also what makes an independent audit worth running.
With two folds, a check compares fold against fold, which can agree while both are wrong.
With one, the check compares **raw stream against folded state** - the only comparison that can catch a folding error.

## The record schema (`v1`)

One JSON object per line.
Only `ts` and `id` are required on every record.

| Field | Type | Meaning |
| --- | --- | --- |
| `v` | int | schema version, currently `2`; absent means pre-versioning and is tolerated. The bump is load-bearing: `v2` is where the writer gained the `outcome` vocabulary |
| `ts` | string | RFC3339 UTC, when the event happened |
| `id` | string | the fold key; `[a-z0-9._-]` |
| `kind` | string | `critical`, `decision`, `event`, `task`, `term`, `steering` |
| `project` | string | grouping key; defaults to `fleet` |
| `state` | string | WHO OWES THIS: `needs-captain`, `needs-cocaptain`, `fm-handling`, `resolved` |
| `outcome` | string | HOW IT ENDED: `in-flight`, `landed`, `discarded`, `unknown`. What ABSENCE means depends on `v` - see below |
| `severity` | string | `critical`, `high`, `normal`, `low` |
| `owner` | string | the reader it is addressed to: `captain`, `cocaptain`, `firstmate`, or a worker id |
| `title` | string | one line, the thing itself |
| `body` | string | detail |
| `pointer` | string | URL or path where the outcome lives; required in practice on a resolved decision |
| `answers` | array | the answer forms; a bare string is tolerated and coerced |
| `check` | string | a command that verifies this item |
| `note` | string | free text |
| `phase` | string | WHERE IT GOT TO mechanically, e.g. `dispatched`, `pr-open`, `merged`, `cleaned`, `force-cleaned`, or `sent`/`delivered`/`consumed`; not a disposition |
| `truncated` | bool | the writer had to shorten this record |

**The state field is load-bearing.**
It exists so the captain never mistakes an fm-handled item for an open ask, and so an item that is not theirs to answer never reaches their queue at all.
`needs-captain` items are captain asks and nothing else is; `fm-handling` is visible so it is not forgotten but is not an ask; `resolved` means nobody owes anything further.
Disposition, not just existence, is the product.

## Two axes, and no precedence between them

`state` answers **who owes this**.
`outcome` answers **how it ended**.
`phase` answers **where it got to mechanically**, and is not a disposition at all.

They are independent questions with independent answers, and nothing in the fold, the board, or the linter ranks one against the other.
The reason is a defect this surface actually shipped: a single blended value meant a merged task that was later force-cleaned read as thrown away, because one fact overwrote the other at classification time.
Work can end with nobody owing it - merged, then cleaned up - and a ruling can still be owed on work that no longer exists.
Both facts are recordable, neither overwrites the other, and no consumer decides which one wins.

`outcome` has four values, and `unknown` is not decoration.

| Value | Means |
| --- | --- |
| `in-flight` | the default when no record has said otherwise: the work has not been observed to end |
| `landed` | it ended by being carried through, and the outcome exists |
| `discarded` | it ended by being thrown away, and nothing was kept |
| `unknown` | it ended and nobody could tell how |

A cleanup that could not run the landed-work test records `unknown` rather than guessing, because a guess recorded as `discarded` invents a loss and a guess recorded as `landed` invents an outcome.

### What absence on the outcome axis means, and why `v` is load-bearing

A record that says nothing about `outcome` is saying two completely different things depending on when it was written, and the record itself carries which.

| The record | What silence means | Folded outcome | `outcome_source` |
| --- | --- | --- | --- |
| `v` >= 2 | the writer HAD this vocabulary and used none of it, so nothing has been observed to end | `in-flight` | `unstated` |
| `v` < 2 or absent | the writer had no way to say, so the silence carries no information | `unknown` | `unobserved` |

Reading pre-axis silence as `in-flight` would assert in bulk that five rounds of already-written rows are still running, in a field built to be authoritative.
A blanket default is a translation table with one row, and it is worse than an explicit one because it is invisible at the call site.
Observation populates; assertion never does.

Only EVIDENCE may fill an unstated outcome, and each backfill names what it read.
A `merged` phase recorded together with a pointer to where it landed is an observation of an ending, so such an item folds to `landed` with `outcome_source: backfilled` and `outcome_evidence` naming the ledger line.
A recorded landed-test verdict arrives as a stated `outcome`, so it is `observed` rather than backfilled.

**An old `phase=discarded` is not evidence and never becomes `outcome=discarded`.**
That phase is the ambiguous field the two axes exist to split: it was written both for genuinely unlanded work and for merged work whose worktree was force-cleaned, and the record cannot say which.
Mapping it would dress the old ambiguity in the new axis's confidence, so such an item is `unknown`.

Rows that cannot be resolved are named on the board rather than quietly filled in, and `--state` lists them under `unobserved_outcomes` with the per-item source in `outcome_source`.

Where a definition needs both axes it is a **conjunction of independently necessary conditions**, never a tiebreak.
An ask is "someone owes a decision" AND "the work is still live": a discarded item is not an ask because there is nothing left to decide, and a merged item is not an ask because nobody owes it.
Those are two separate reasons, either sufficient on its own, and neither is a ranking of one axis over the other.

Because the axes are independent, so are the published keys.
Every zone that means "over" is keyed on the outcome axis alone, and no key mixes two endings: `zones.fleet_landed`, `zones.fleet_discarded` and `zones.fleet_unknown` are separate lists, as are `zones.criticals_landed`, `zones.criticals_discarded` and `zones.criticals_unknown`, and each project's decision group carries `open`, `landed`, `discarded` and `unknown`.
An auditor reading `landed` never has to check whether a row under it was actually thrown away.
`summary` tallies the state axis and `outcomes` tallies the outcome axis; neither is a rollup of both, and each counts EVERY board item, so both sum to `counts.board_items`.
The ask count is a third, separate number - the conjunction, owed AND still live - published as `asks_count` and labelled as its own thing on the board.
A tally that quietly dropped items would be the same failure as a fold that dropped lines: on a surface whose discipline is that the numbers add up in public, a silent gap is where a wrong reading hides.

`needs-cocaptain` is a **routing** target, not a fourth flavour of "open".
Machine and repo-infrastructure work is addressed to the co-captain - the dotfiles session, which reads this ledger directly - and never joins the captain's ask list.
The cost being avoided is captain attention: a machine-config item once sat on their queue for a full day when its whole resolution was one reader away.

Route with `--to`, which sets both the queue and the owner:

```sh
bin/fm-bridge.sh ask --project machine --title "..." --answer "A: ..." --to cocaptain
bin/fm-bridge.sh route --id <id> --to cocaptain     # re-address an existing item
```

A routed item is absent from the captain's tab-title count, sticky counter, and tally, and present in `queues.cocaptain` and `cocaptain_asks` in `--state`.
It still appears on the board in its own "With the co-captain" section, so the captain can see where work went rather than wonder - visible as routed, never as an ask.

### How records fold

A record is a partial statement about `id`.
Fields present in a later record replace the item's earlier values; absent fields are left alone.
So opening an item and later resolving it is two small appends, not a rewrite:

```
{"v":1,"ts":"...","id":"o-1","kind":"decision","project":"orca","state":"needs-captain","title":"...","answers":["A: keep","B: drop"]}
{"v":1,"ts":"...","id":"o-1","state":"resolved","pointer":"https://github.com/o/r/pull/12"}
```

`phase` is the exception: every phase an item has ever been recorded in is accumulated with its timestamp, never overwritten.
That is what makes a lifecycle question answerable regardless of the order records arrived in.

### Display refs (`O1`, `D2`, ...)

Refs are assigned by the fold, not written by hand, to `decision` and `critical` items.
A project's prefix is the shortest uppercase prefix of its slug unique among projects that appeared **at or before** it, so an existing project's refs never change when a later colliding project arrives - the newcomer takes the longer prefix (`orca` keeps `O`; a later `opencode` becomes `OP`).
Numbers are assigned in first-appearance order and are never recycled, so a bare ref never needs disambiguating and never quietly comes to mean something else.

## Writing to it

An append is a side effect of a turn that is already happening, and it **replaces** the equivalent prose in the terminal stream.
It is never separate bookkeeping and never a turn of its own.

```sh
bin/fm-bridge.sh note     --project orca --title "..." [--pointer URL]
bin/fm-bridge.sh ask      --project orca --title "..." --answer "A: ..." --answer "B: ..." [--to WHO]
bin/fm-bridge.sh route    --id ID --to captain|cocaptain|firstmate
bin/fm-bridge.sh critical --project fleet --title "..." --answer "A: ..."
bin/fm-bridge.sh handling --id ID [--note "..."]
bin/fm-bridge.sh resolve  --id ID --pointer URL
bin/fm-bridge.sh task     --id ID --project P --phase PH [--state S]
bin/fm-bridge.sh term     --project P --term WORD --means "..."
```

Omit `--id` and one is derived from kind, project, and title, so re-appending the same fact updates that item instead of duplicating it.
`ask` refuses without an answer form and `resolve` refuses without a pointer, because an ask nobody can answer and an outcome nobody can find are the two failures that make this surface useless.

Most fleet-strip rows are never written by hand at all: `fm-spawn.sh`, `fm-pr-check.sh`, `fm-pr-merge.sh`, and `fm-teardown.sh` append at the moment they cause the event.
Those appends are best-effort and can never fail their caller.
A persistent secondmate is not a work item, so neither spawn nor teardown ever gives one a row.
A cleanup records both axes, and takes the outcome from the landed-work determination itself rather than from whether `--force` was used.
`--force` means the checks were SKIPPED; it does not mean the work was THROWN AWAY, and for work that already merged a forced cleanup discards nothing - it reclaims a working copy.
So a forced cleanup still evaluates that determination without refusing on it: the test would have passed means `outcome=landed`, would have failed means `outcome=discarded`, and could not reach a verdict means `outcome=unknown`.
Both paths record the verdict that determination actually returned - the gate and the record read ONE evaluation, so a refusal an operator reads and an outcome the board shows can never disagree about the same worktree.
An ordinary cleanup additionally records `state=resolved`, because it ran every check that applies; a forced one records `phase=force-cleaned` with the reason that authorized the override and leaves the state axis exactly as the row had earned it, because skipping the checks says nothing about who owes what.
Where no landed-work test applies at all - no worktree left, or a scout or secondmate kind - both paths record `unknown`, since "the gate let it through" is not the same statement as "the test passed".
Uncommitted changes are unlanded work on every path: teardown removes the worktree, so those changes are gone.
A forced retirement of a persistent secondmate records the same provenance as a `kind=event` note against `fleet`, because a secondmate is not a work item and must never become a strip row.
The events zone renders that note on the board, so the most destructive override in the fleet is not the one whose reason is hardest to read.

**Work that ended is still shown, and still shows both axes.**
An item whose outcome is `landed`, `discarded` or `unknown` leaves the ask queues, the `needs-captain` and `needs-cocaptain` tallies, the tab-title count, the rail badge and the aging flag, and its answer forms are withdrawn - nobody can rule on work that has ended.
That is the ask conjunction doing its job, not the outcome axis overruling the state axis: the state it earned stays in the ledger and in `--state` for audit, and the board renders it as its own chip beside the outcome chip so a reader sees both answers rather than guessing the second from the first.
When work ended and the ledger never said who owed it, the fold declines to invent a state rather than defaulting one - every value would be a claim nothing observed.
Each closed group is capped with a visible overflow pointer to the record (`caps.fleet_closed`, default 6, `FM_BRIDGE_CAP_FLEET_RESOLVED`; `caps.closed_decisions` for decisions and criticals, default 3, `FM_BRIDGE_CAP_RESOLVED_DECISIONS`), because a rare override must not grow into a permanent wall of rows, and a cap that hides rows silently would be its own lie.
`bin/fm-bridge.sh lint` reads the same two axes, so it never asks for an answer form on work that has ended.

### Why append-only, and why records are bounded

An append must be one write with no read, no rewrite, and no lock.
A single write to an `O_APPEND` file is atomic up to `PIPE_BUF` (4096 bytes), so concurrent lanes cannot interleave a record while records stay under that bound.
`FM_BRIDGE_MAX_RECORD_BYTES` (default 3800) enforces it by assembling the record, measuring it **in bytes**, and shortening one field at a time - `body`, `note`, answer forms, `check`, `pointer`, `phase`, `owner`, then `title` last - until the line fits, marking any record that lost something `truncated`.
Bytes, not characters: a multibyte title that a character count calls small is exactly the line a concurrent append can tear.

## Tolerance, and the incident behind it

**Writers normalize; the reader tolerates everything ever written, forever.**

On 2026-07-31, 60 of 65 keyed records in `bin/fm-classify-lib.sh` collapsed into a single default slot because the key sat in a position the parser did not read.
Decisions silently masked each other and the authoritative reader announced 1 open where 3 were.
Two rules in this fold exist because of that, and both are asserted by `tests/fm-bridge.test.sh`:

1. **Conservation.** Every non-blank line is accounted for: `lines_considered == records + malformed`.
   The counts are published in `--state` and printed on the board, so a parser that stops reading a field stops adding up in public on the very next tick.
2. **Never default an unrecognized value.** An unknown `kind`, `state`, or `severity` is preserved verbatim and flagged in `recognized`, never mapped into a known bucket.
   An unknown kind renders in its own "Unrecognized records" section rather than being filed somewhere convenient.
   Silent masking was the failure; visible strangeness is the fix.

The fold also reads the key from any position it has ever occupied (`id`, `key`, `item_id`, `itemId`), preserves unknown fields under `extra`, and accepts records with no `v`, no trailing newline, or `answers` written as a bare string.

Note that conservation is **weaker** than readability: a malformed line is still counted, so a stream can be conserved while partially unreadable.
Anything that needs to have actually *read* the stream must check `counts.malformed`, not `conserved`.

## Second producer: steering-message lifecycle

`kind: "steering"` records a steering message's lifecycle - `sent`, `delivered`, `consumed` - one line each, at the moment each happens, keyed by correlation id.
Adding it required no migration and no second fold, which is the property to preserve: **a new event kind must stay an ordinary addition here.**

Steering records are substrate.
They fold through the identical path but never render as board items and are kept out of the captain's disposition tallies, so machinery cannot inflate the numbers they triage against.
The board reports their count in the footer so the record's contents are not misrepresented.

**The epistemic point, which is the reason these records exist at all:** consumed and never-arrived present identically on screen.
A message that was delivered and acted on leaves an empty composer; so does a message that never arrived.
The screen cannot distinguish them, so a verifier reading the screen can only honestly say *unknown*.

`--lifecycle <id>` therefore answers in three values, and `absence_explained` is true only when a durable consumption record exists:

```json
{
  "schema": "fm-bridge.lifecycle.v1",
  "id": "steer-abc123",
  "verdict": "consumed",
  "absence_explained": true,
  "fully_readable": true,
  "stages": {"sent": "...", "delivered": "...", "consumed": "..."},
  "source": {"ledger": "...", "lines": [7, 8, 10]},
  "reason": "a durable consumption record exists at ledger line 10, ..."
}
```

- a consumption record exists -> `consumed`, and the absence claim is licensed
- the id is recorded but not consumed -> `sent` or `delivered`, and absence is **not** licensed
- the id is not in the ledger -> `unknown`, never "absent"
- any line was unreadable -> `unknown` at every id, because the unreadable line may be the record being asked about

The steering fix itself (`fm-send-false-failure-guard`) is a separate lane.
This is the substrate it can be built on: schema room for the event kinds, and a fold that answers targeted questions.

## The board

Zones, in the order the captain reads them:

1. **Waiting on you** - every open *captain* ask across every project, oldest first, as an index that links to each full card.
   An index rather than a second set of cards, so nothing is triaged twice.
2. **With the co-captain** - items routed away, shown so the captain can see where they went.
3. **Pinned criticals** - security, data loss, fleet blocked, outward-facing anomalies.
4. **Decisions, by project** - with per-project refs, and any colliding term repeated locally.
5. **Notable events** - capped, with a visible overflow pointer to the record.
6. **Fleet** - one row per task.

Because an ask that scrolls out of view is the failure this surface exists to prevent, the open-ask count rides in the browser tab title and in a counter that travels with the viewport.
That counter lives in a reserved right-hand gutter, not across the top.
Chrome that travels with a vertically scrolling page and spans the content column ends up over every row that passes it, and parks an anchor target underneath itself - two browser layout audits proved exactly that, on rows in two different zones.
A gutter the content is never laid out inside is the one place viewport-fixed chrome cannot come to cover it, so the ruling composer docks there too and widens the gutter instead of covering the board.
Asks carry their age, and one older than `FM_BRIDGE_AGING_SECONDS` (default 24h) is flagged: an ask that old is usually one that was already answered and never closed, and nothing about "open" distinguishes those from the rest.

Answer forms are mandatory on asks.
Clicking one queues a ready-to-paste ruling; several can be queued and copied together.
There is deliberately **no ack machinery in v1** - no read receipts, no dismissal state, no interactivity beyond those forms.

The board embeds the exact state document it was drawn from in `<script type="application/json" id="fm-bridge-state">`, so it can be audited without trusting the renderer, and so `--state` and the board provably cannot diverge.

### Links, and the Lavish annotation layer

The board is read inside Lavish, whose annotation layer installs a capture-phase click handler that calls `preventDefault()` on everything except `[data-lavish-ui]`, `[data-lavish-action]`, and native controls (`button`, `input`, `select`, `textarea`, `option`, `optgroup`, `label`, `summary`, `[contenteditable]`).

**`a` is not on that list**, so a plain anchor swallows left-clicks - both the PR links and the in-page asks-index jumps.
This is not a blocker: right-click still opens a link.
But `data-lavish-action` is Lavish's own pass-through, so making left-click work is a one-attribute authoring fix, and there is no reason to leave it unused.
It exempts that one anchor from annotation capture and nothing else, so every other element stays annotatable and rulings still queue through the annotation layer.
Answer forms need nothing: they are `<button>`, already native-exempt.

Every anchor goes through one `link()` helper in `bin/fm-bridge-render.sh`, which also opens external links with `target="_blank" rel="noopener noreferrer"` - the board is served in an iframe, so a same-tab navigation would replace it.
External link text is the full URL because that is the most useful label for a pointer, not as a fallback affordance; there is deliberately no second link mechanism.

`tests/fm-bridge.test.sh` fails on any anchor that skips the helper.

### Styling

The board reuses the tokyonight-storm token block from the canonical scaffold in `~/code/personal/dotfiles/docs/labs/`, with one deliberate departure: the scaffold's DaisyUI and Tailwind CDN layer is not used.
The board is regenerated from disk every few minutes and must render identically with no network, so its styling is inlined.
Accents keep one meaning each: red needs the captain, purple needs the co-captain, blue firstmate has it, green resolved or landed, orange discarded, ended-unknown, aging or otherwise off, cyan pointer or command.
Ordinary secondary text, including a record's `note`, is dim rather than accented - `--note` is a general field on every write command, so accenting it would make a routine event read as a problem and give orange a second meaning.

## Cadence and cost

- The renderer is a deterministic script with **zero model involvement**.
  A model is never woken to update the Bridge and never hand-writes the HTML.
- The supervision cycle owns the tick, every `FM_BRIDGE_INTERVAL` seconds (default 180, inside the captain's 2-5 minute window).
- When the ledger is unchanged the body is **not** regenerated; only the marked freshness line is restamped.
- The freshness line keys to the **render clock** and shows two times: `checked` advances every tick, `content as of` advances only when the ledger changed.
  A frozen board and a dead supervision cycle must not look the same.

## Checking it

The board carries these commands in its own footer.

```sh
bin/fm-bridge-render.sh --state | jq '.counts, .conserved'   # conservation
bin/fm-bridge.sh lint                                        # record hygiene
bin/fm-bridge.sh lint --strict                               # same, non-zero on problems
bin/fm-bridge-render.sh --lifecycle <id>                     # one item
bin/fm-bridge-render.sh --state | jq -r '.cocaptain_asks[]'  # the co-captain's queue
tail -n 40 "$(bin/fm-bridge.sh path ledger)"                 # the raw stream
```

`lint` keeps clean, dirty, and could-not-read apart.
Default mode forgives problems it could see and exits 0; `--strict` exits 1 on problems; either mode exits **3** when the fold itself could not be read, because "the record is clean" and "the lint never ran" must never share an exit status.

`lint` flags a resolved decision with no pointer, an ask with no answer form, an unrecognized value, a truncated record, and any conservation or readability failure.
It reads through `--state` and never opens the ledger itself: a linter with its own parser would be exactly the second reading this design exists to make impossible.

## The rule that keeps the two surfaces honest

The terminal stream stays firstmate's record, but **captain-relevant material that exists only there is a delivery failure**.
The ledger append replaces the equivalent stream prose rather than duplicating it.

In the other direction: **a fact on the board but not in the ledger is a bug.**
Because the board is a pure function of the ledger, it cannot happen - which is what lets the co-captain audit from the ledger side and know they are seeing everything the captain sees.

## Related

- `bin/fm-bridge-lib.sh` - writer contract, normalization, the append primitive.
- `bin/fm-bridge-render.sh` - the fold, the query modes, the board, the tick.
- `bin/fm-bridge.sh --help` - current command syntax.
- `tests/fm-bridge.test.sh` - the guard-class tests behind every claim above.
