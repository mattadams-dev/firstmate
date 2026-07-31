# The Bridge

The Bridge is the captain's primary surface for fleet state.
It replaces the terminal stream as the place they read, because a scrolling stream loses captain-relevant items: an ask scrolls out of view and is not seen again until someone goes looking for it.

The whole design follows from one shape.

**One canonical ledger. One fold. The board is generated and never hand-edited.**

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

The plural matters here.
A shared fold with a single consumer decays back into private logic, because nothing else exercises its contract.
On day one it has four: the HTML board, the co-captain's independent audit, firstmate's own record linter (`bin/fm-bridge.sh lint`), and targeted lifecycle queries.

This is also what makes an independent audit worth running.
With two folds, a check compares fold against fold, which can agree while both are wrong.
With one, the check compares **raw stream against folded state** - the only comparison that can catch a folding error.

## The record schema (`v1`)

One JSON object per line. Only `ts` and `id` are required on every record.

| Field | Type | Meaning |
| --- | --- | --- |
| `v` | int | schema version, currently `1`; absent means pre-versioning and is tolerated |
| `ts` | string | RFC3339 UTC, when the event happened |
| `id` | string | the fold key; `[a-z0-9._-]` |
| `kind` | string | `critical`, `decision`, `event`, `task`, `term`, `steering` |
| `project` | string | grouping key; defaults to `fleet` |
| `state` | string | `needs-captain`, `needs-cocaptain`, `fm-handling`, `resolved` |
| `severity` | string | `critical`, `high`, `normal`, `low` |
| `owner` | string | the reader it is addressed to: `captain`, `cocaptain`, `firstmate`, or a worker id |
| `title` | string | one line, the thing itself |
| `body` | string | detail |
| `pointer` | string | URL or path where the outcome lives; required in practice on a resolved decision |
| `answers` | array | the answer forms; a bare string is tolerated and coerced |
| `check` | string | a command that verifies this item |
| `note` | string | free text |
| `phase` | string | lifecycle position, e.g. `dispatched`, `pr-open`, `merged`, or `sent`/`delivered`/`consumed` |
| `truncated` | bool | the writer had to shorten this record |

**The state field is load-bearing.**
It exists so the captain never mistakes an fm-handled item for an open ask, and so an item that is not theirs to answer never reaches their queue at all.
`needs-captain` items are captain asks and nothing else is; `fm-handling` is visible so it is not forgotten but is not an ask; `resolved` carries a pointer to where the outcome lives.
Disposition, not just existence, is the product.

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

### Why append-only, and why records are bounded

An append must be one write with no read, no rewrite, and no lock.
A single write to an `O_APPEND` file is atomic up to `PIPE_BUF` (4096 bytes), so concurrent lanes cannot interleave a record while records stay under that bound.
`FM_BRIDGE_MAX_RECORD_BYTES` (default 3800) enforces it by shortening `body`, then `title`, and marking the record `truncated`.

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

Because an ask that scrolls out of view is the failure this surface exists to prevent, the open-ask count rides in the browser tab title and in a sticky counter that travels with the viewport.
Asks carry their age, and one older than `FM_BRIDGE_AGING_SECONDS` (default 24h) is flagged: an ask that old is usually one that was already answered and never closed, and nothing about "open" distinguishes those from the rest.

Answer forms are mandatory on asks.
Clicking one queues a ready-to-paste ruling; several can be queued and copied together.
There is deliberately **no ack machinery in v1** - no read receipts, no dismissal state, no interactivity beyond those forms.

The board embeds the exact state document it was drawn from in `<script type="application/json" id="fm-bridge-state">`, so it can be audited without trusting the renderer, and so `--state` and the board provably cannot diverge.

### Links, and the Lavish annotation layer

The board is read inside Lavish, whose annotation layer installs a capture-phase click handler that calls `preventDefault()` on everything except `[data-lavish-ui]`, `[data-lavish-action]`, and native controls (`button`, `input`, `select`, `textarea`, `option`, `optgroup`, `label`, `summary`, `[contenteditable]`).

**`a` is not on that list.**
A plain anchor therefore renders as a link, hovers as a link, and does nothing when clicked.
On a board whose job is getting the captain to a PR, that is a silent failure of the core job - and it silently breaks the in-page asks-index jumps too, which are the mechanism that makes an ask impossible to scroll past.

`data-lavish-action` is Lavish's own pass-through, and using it is the whole fix.
It exempts that one anchor from annotation capture and nothing else, so every other element stays annotatable and rulings still queue through the annotation layer.
Answer forms need nothing: they are `<button>`, which is already native-exempt.

Every anchor goes through one `link()` helper in `bin/fm-bridge-render.sh`, which also:

- opens external links with `target="_blank" rel="noopener noreferrer"`, because the board is served in an iframe and a same-tab navigation would replace it;
- uses the **full URL as the visible link text**, so on any surface that honours none of this - an exported copy, an older Lavish, a plain `file://` open - the URL is still readable and selectable. A selectable plain-text URL beats an unclickable one that looks clickable.

`tests/fm-bridge.test.sh` fails on any anchor that skips the helper.

### Styling

The board reuses the tokyonight-storm token block from the canonical scaffold in `~/code/personal/dotfiles/docs/labs/`, with one deliberate departure: the scaffold's DaisyUI and Tailwind CDN layer is not used.
The board is regenerated from disk every few minutes and must render identically with no network, so its styling is inlined.
Accents keep one meaning each: red needs the captain, purple needs the co-captain, blue firstmate has it, green resolved, orange something is off, cyan pointer or command.

## Cadence and cost

- The renderer is a deterministic script with **zero model involvement**. A model is never woken to update the Bridge and never hand-writes the HTML.
- The supervision cycle owns the tick, every `FM_BRIDGE_INTERVAL` seconds (default 180, inside the captain's 2-5 minute window).
- When the ledger is unchanged the body is **not** regenerated; only the marked freshness line is restamped.
- The freshness line keys to the **render clock** and shows two times: `checked` advances every tick, `content as of` advances only when the ledger changed. A frozen board and a dead supervision cycle must not look the same.

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
