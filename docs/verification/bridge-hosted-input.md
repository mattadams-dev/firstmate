# Verification - the Bridge board's input path when hosted in Lavish

Audience: maintainer-verification.
These are measured facts about Lavish's hosting behaviour that the board's design depends on.
Refresh them with the commands below after any `lavish-axi` upgrade.

Measured 2026-08-05 against `lavish-axi` 0.1.43 and Chromium 150.0.7871.128 on Linux (WSL2), driving a real hosted session with `chrome-devtools-axi`.

**Scope.** The vendor behaviours measured here still stand and the board is still built on them.
The design consequences the v1 board drew from them do not all survive the v2 split into a board and a history page: v2 spends a control's annotatability where a click is the point.
[`bridge-board-v2.md`](bridge-board-v2.md) is the authoritative record of what v2 renders, what stays annotatable, and what the live guard checks; where the two records differ about the board as it ships, that one is current.

## What was under test

The board carried a bespoke ruling composer whose only egress affordances were `copy` and `clear`.
Removing it makes Lavish's annotation layer plus its Conversation panel the single input path for the captain's rulings, so two things had to be measured rather than assumed:

1. which board elements Lavish will actually let the captain annotate, and
2. what a supervision tick's board rewrite does to a ruling the captain is in the middle of typing.

## Setup

```sh
# a probe artifact carrying one plain paragraph, one <button class="ans">,
# and one <span class="ans">, each inside a card with an id="item-..." anchor
lavish-axi .lavish/annotatability-probe.html          # -> session URL

chromium --headless=new --remote-debugging-port=9223 --user-data-dir=<scratch> about:blank &
export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9223
export CHROME_DEVTOOLS_AXI_SESSION=fm-annot-probe
chrome-devtools-axi open "http://127.0.0.1:4387/session/<session-id>"
```

Each measurement below re-snapshots immediately before every click, because element uids are only valid against the snapshot that produced them.

## 1. Native controls are not annotatable

`chrome-devtools-axi click @<uid>` on each target, then look for Lavish's annotation card
(`textbox "Tell the agent what to change about this element..."`) in the next snapshot:

```
=== control: plain <p> prose
  RESULT: annotation card OPENED
=== case A: <button class=ans>, the answer form the board used to render
  RESULT: no annotation card
=== case B: <span class=ans>, a plain non-control answer option
  RESULT: annotation card OPENED
=== case C: <span class=ref> inside an ask card
  RESULT: annotation card OPENED
```

Lavish's artifact SDK excludes anything matching
`button,input,select,textarea,option,optgroup,label,summary,[contenteditable]:not([contenteditable='false'])`
from its `mouseover`, `mouseup` and `click` capture handlers, by `closest()`, so a control and everything inside it is invisible to annotation.
The same list is what lets `link()`'s `data-lavish-action` anchors keep their native left-click.

**Consequence the board depends on:** an answer option rendered as `<button>` is the one thing on an ask row the captain cannot annotate.
v1 read that as a prohibition and rendered answer options as plain non-control elements; v2 spends it deliberately, because an option the captain cannot click is an ask that leaves by terminal instead.
What v2 keeps outside every control so a free-text ruling can still name its ask - the per-item anchor, the visible ref, the title - is recorded in [`bridge-board-v2.md`](bridge-board-v2.md), section 6.

The same exclusion covers `[data-lavish-action]`, which the board puts on links so their left-click navigates.
That makes a link non-annotatable by design - it is navigation - and it is why a ruling is placed on the **card**, where the ref, the title and the answer options live.

## 2. A board rewrite destroys an in-progress annotation

Lavish watches the hosted file (chokidar) and pushes a `reload` event on any change; the chrome answers it by resetting the artifact iframe.
The annotation card lives inside that iframe.

Typed text was planted in three places, then the hosted file was rewritten the way a supervision tick rewrites the board:

| where the text was | after the rewrite |
|---|---|
| an open annotation card, typed but **not queued** | **gone** |
| an annotation already queued into the Conversation panel | survived |
| the Conversation panel's own composer, typed but not sent | survived |

Verbatim, from the same run:

```
[2] open an annotation card and type an unqueued ruling into it
      textbox "Tell the agent what to change..." value="ANNOTATION-TEXT-DO-NOT-LOSE"
      textbox "Write a message for the agent..." value="CONVERSATION-TEXT-DO-NOT-LOSE"
[3] a supervision tick rewrites the hosted file
[4] state after the file change
      textbox "Write a message for the agent..." value="CONVERSATION-TEXT-DO-NOT-LOSE"
      (no annotation card, no ANNOTATION-TEXT)

[5b] the same ruling QUEUED first, then the same rewrite
  after queueing:          StaticText "QUEUED-RULING-A-KEEP-IT"
  after the tick rewrite:  StaticText "QUEUED-RULING-A-KEEP-IT"
```

The loss is silent: no warning, no draft restored, nothing in the panel.
The exposed window is exactly "typed into the annotation card and not yet queued".

## 2b. The matrix, one session, one verdict per state

Sections 1 and 2 were measured on a probe artifact.
This run repeats the load-bearing states against **the board this renderer actually produces**, in a single hosted session, and records a verdict for each rather than inheriting any of them from the others.

Setup: a seeded ledger with ask `O1` (`retire the legacy poll`, project orca) and task ask `t-pr`.
Mid-run, two records land - a pinned critical in project `fleet` and an ask in a new project `alpha` - so the redraw moves `O1` down the page and renumbers nothing.

| # | state | verdict |
|---|---|---|
| 1 | a ruling **queued** into the conversation panel, then the board is redrawn | **present after the redraw, and delivered on `lavish-axi poll`** |
| 2 | a ruling **typed into the annotation box and not queued**, then the board is redrawn | **gone, silently** |
| 3 | the delivered reference, resolved against the **redrawn** board | **lands on the ask it was placed on** |

State 1 delivery, verbatim from `lavish-axi poll` after the redraw:

```
prompts[1]{uid,prompt,selector,tag,text}:
  "1",RULING-O1-RETIRE-IT,"div#item-o-one > div:nth-of-type(3) > span:nth-of-type(2)",span,"O1: A: retire it"
```

State 3, that exact selector evaluated in the browser against the redrawn board:

```
{"resolves":true,"text":"O1: A: retire it","lands_on_item":"item-o-one",
 "card_title":"retire the legacy poll","asks_on_board":["F1","O1","-","A1"]}
```

The reference holds because it is rooted at the per-item anchor `id="item-<id>"`, which the fold assigns from the ledger key and re-emits identically on every render, so sibling shifts above and around the ask cannot move it.
What identifies the ruling therefore is the anchor plus the text the annotation was placed on - which is why v1 carried the ask's visible ref into the option text itself (`O1: A: retire it`).
v2 places that burden on the card instead, because the option is now a control an annotation never sees: the ref and the title stay outside every control, and a clicked ruling carries its ref in the queued payload rather than in a selector ([`bridge-board-v2.md`](bridge-board-v2.md), sections 3 and 6).
The payload's `uid` is a per-load counter and does **not** survive a redraw; nothing should be keyed to it.

Bounding sub-case, same session: with the ask then **resolved** and the board redrawn, the board withdraws its answer options by design, so a selector that pointed at an *option* stops resolving while the ask anchor itself is still there:

```
{"option_selector_resolves":false,"ask_anchor_still_present":true,
 "card_title":"retire the legacy poll"}
```

So the promise is at ask granularity, not element granularity, and the delivered `text` is what preserves which answer was chosen when the row underneath has moved on.
That is what the board's footer claims, and no more.

## 3. An identical-bytes rewrite reloads too

The reload keys on the write, not on a content diff.
Rewriting the file with byte-identical content, through the same `mkstemp` + `os.replace` path the board writer uses, still destroyed the open annotation:

```
[6] identical-bytes atomic rewrite
  card text present before rewrite: 1
  card text present after:          0
```

**Consequence the writer depends on:** re-rendering an unchanged board is not free, and "write the same bytes" is not a safe substitute for "do not write".
The tick has to skip the write itself, which is why an unchanged ledger now leaves the board file untouched instead of restamping a freshness line into it.

## 4. The artifact title reaches the hosting page at page load, and not again

The board's open-ask count used to also ride a viewport-fixed counter in a reserved gutter, so an ask could not be scrolled past.
Removing the composer left that gutter holding one number, and the question became where that number belongs.

Measured in the same sessions: Lavish propagates the artifact's `<title>` into the hosting page's title, so the browser tab of a hosted board reads

```
Bridge · Lavish
```

That propagation happens **at page load**.
It does not happen again when the supervision tick rewrites the board and the artifact frame live-reloads underneath it.

The first measurement checked the title at load, after the board was scrolled, and after the window was put behind another one, and recorded that the count "stays visible" there.
That was **incomplete rather than wrong**: it never drove a COUNT CHANGE, which is the one event that moves the number, and is precisely the event that redraws the artifact without re-propagating the title.
A second session, against `lavish-axi` 0.1.43 in Chrome 145, drove exactly that:

```
step 1  board on disk: <title>Bridge - 1 need you</title>
step 2  browser tab at open: "Bridge - 1 need you · Lavish"

step 3  a second ask arrives; the supervision tick redraws the board
        board on disk now: <title>Bridge - 2 need you</title>
step 4  the page body did live-reload:
        link "2waiting on you longest 1m" ... #waiting
        StaticText "second ask"
step 5  browser tab title 20s and 90s after the redraw:
        "Bridge - 1 need you · Lavish"

        ^ the board says 2 need the captain; the tab still says 1.
          A manual reload of the hosting page re-syncs it.
```

So a count carried in the tab title was stale exactly when it changed, and correct only while it did not matter - and it bit hardest in the case the tab was kept for, the page not being in front.

**What the board does about it:** the open-ask count is rendered content, in the page's own header, drawn from the fold on every render.
Rendered content survives a redraw by construction - the redraw is what produces it - which is why moving the count is the fix rather than re-propagating the title.
The title now names the board and states no count, because the affordance rule reaches browser chrome too: a surface may only claim what it can keep, and a title Lavish copies once may not carry a number that changes.
`tests/fm-bridge.test.sh` pins both halves against a count change: the rendered count moves with the ledger, and the title is byte-identical across it.

The count is therefore at the top of the page rather than following the viewport.
v1 linked it to a separate asks index; v2 retired that index, because the ask cards themselves are now the first thing under the header and a link to what is already there buys nothing.
Nothing on either page is out of flow at all, which is the property the two layout audits made non-negotiable.

## Upstream

The silent loss of unqueued annotation text across a live reload is a Lavish behaviour, not a board behaviour: every hosted artifact its agent regenerates has the same hole, and a live reload that discards a draft the reviewer is still typing is worth fixing where it happens.
The report belongs at https://github.com/kunchenguid/lavish-axi/issues, carries the reproduction in sections 2 and 3 verbatim, and is **not posted yet** - it is outward-facing, so it waits on the captain's word.
Record the issue URL here once it is filed.

Firstmate's own guard does not depend on that report: section 3 is why the tick skips the write, and that holds whatever upstream decides.

## Running the live guard

`tests/fm-bridge-lavish-annotation-live-e2e.test.sh` (opt-in: `FM_BRIDGE_LAVISH_LIVE_E2E=1`) re-checks the vendor-owned facts against the INSTALLED lavish-axi.
Its current coverage and how to run it are recorded in [`bridge-board-v2.md`](bridge-board-v2.md), section 8; what belongs here is the reason it can report a third outcome.

Its browser half needs a browser that will actually render the page.
Lavish holds an artifact behind a "waiting for fonts and final geometry" curtain until its layout check settles, and that check needs animation frames - which a browser does not give a tab that is not in front.
In a headless browser with the tab backgrounded, the frame can stay blank indefinitely.

The guard therefore reports **three** outcomes, not two: a card opened, a card did not open while the page was demonstrably ready, or the page was never in a state that could answer the question (exit 2, `COULD NOT OBSERVE`).
That distinction is the point - the two failures look identical from the outside, and reporting a headless rendering problem as "the captain cannot answer an ask" would send the next reader hunting a defect in the board.

So point `CHROME_DEVTOOLS_AXI_BROWSER_URL` at a browser that renders in the foreground before running it.

## The guards, proven to fire

Each mutation was applied to `bin/fm-bridge-render.sh` on its own, the suite run, and the renderer restored.
"First failing guard" is what `tests/fm-bridge.test.sh` reported; the suite stops at the first failure, so a mutant reaching its own guard means nothing earlier caught it by accident.

These runs were taken against the **v1** board and have not been re-measured since.
Every guard named here still exists in `tests/fm-bridge.test.sh`, but two of the mutations describe a rule v2 replaced; they are marked rather than dropped, because a recorded result is worth more than a tidy table.
What the guards forbid now is in [`bridge-board-v2.md`](bridge-board-v2.md), section 6.

| mutation | first failing guard |
|---|---|
| a sendable-looking composer returns to the board | `input path: see the reported element` |
| answer options go back to being controls (**v1 rule; v2 renders them as controls on purpose**) | `input path: see the reported element` |
| the per-item anchors are stripped from the cards | `mode drift: an ask present in folded state is missing from the board` |
| the visible ref is dropped from the ask cards | `annotation anchors: see the reported ask` |
| the answer options stop naming their own ask (**v1 rule; in v2 the ref and title carry that, outside the control**) | `annotation anchors: see the reported ask` |
| the signpost is removed with the composer | `signpost: see the reported gap` |
| the tick rewrites the board on an unchanged ledger | `tick: an unchanged ledger rewrote the board file` |
| the writer stops comparing before it replaces | `write: a byte-identical render replaced the board file anyway` |

The live guard was mutation-checked the same way, against the real vendor and a real browser rather than against the pinned list:

| mutation | live guard verdict |
|---|---|
| none - the v1 board as it shipped | `all live Lavish annotation guards passed against lavish-axi 0.1.43` |
| answer options rendered as `<button>` | `the board renders its answer option as a native control: uid=... button "O1: A: retire it"` |

That second row is the one v2 inverted: the same shape is now what the guard requires rather than what it rejects, and its current output is recorded in [`bridge-board-v2.md`](bridge-board-v2.md), section 8.

The ref mutant is the one worth keeping in mind: it passed the first version of the anchor guard, because the refs also appeared in the v1 asks index at the top of the page and a document-wide search found them there.
An annotation is rooted where it was placed and never sees the index, so the guard now searches the ask's own card or row.
A guard that reads the whole page answers a question nobody asked.
