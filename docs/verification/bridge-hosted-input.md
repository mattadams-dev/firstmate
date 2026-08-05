# Verification - the Bridge board's input path when hosted in Lavish

Audience: maintainer-verification.
These are measured facts about Lavish's hosting behaviour that the board's design depends on.
Refresh them with the commands below after any `lavish-axi` upgrade.

Measured 2026-08-05 against `lavish-axi` 0.1.43 and Chromium 150.0.7871.128 on Linux (WSL2), driving a real hosted session with `chrome-devtools-axi`.

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
With the composer gone, that would have left the ask rows as the only dead spots on the surface, so the board renders answer options as plain non-control elements.

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
What identifies the ruling therefore is the anchor plus the option's own text - and the option text carries the ask's visible ref (`O1: A: retire it`) for exactly this reason.
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

## The tab title carries the count when the board is hosted

The board's open-ask count used to also ride a viewport-fixed counter in a reserved gutter, so an ask could not be scrolled past.
Removing the composer left that gutter holding one number, and the question became whether the tab title alone does the never-lose-sight job.

Measured in the same sessions: Lavish propagates the artifact's `<title>` into the hosting page's title, so the browser tab of a hosted board reads

```
Bridge - 1 need you · Lavish
```

and the count stays visible while the board is scrolled, while it is behind another window, and after it has been open for a day - from a place that cannot come to cover a row, which is the failure the gutter was built to avoid in the first place.

That is what let the counter move into the page header in normal flow, and the board now has nothing out of flow at all.

## Upstream

The silent loss of unqueued annotation text across a live reload is a Lavish behaviour, not a board behaviour: every hosted artifact its agent regenerates has the same hole, and a live reload that discards a draft the reviewer is still typing is worth fixing where it happens.
The report belongs at https://github.com/kunchenguid/lavish-axi/issues, carries the reproduction in sections 2 and 3 verbatim, and is **not posted yet** - it is outward-facing, so it waits on the captain's word.
Record the issue URL here once it is filed.

Firstmate's own guard does not depend on that report: section 3 is why the tick skips the write, and that holds whatever upstream decides.

## The guards, proven to fire

Each mutation was applied to `bin/fm-bridge-render.sh` on its own, the suite run, and the renderer restored.
"First failing guard" is what `tests/fm-bridge.test.sh` reported; the suite stops at the first failure, so a mutant reaching its own guard means nothing earlier caught it by accident.

| mutation | first failing guard |
|---|---|
| a sendable-looking composer returns to the board | `input path: see the reported element` |
| answer options go back to being controls | `input path: see the reported element` |
| the per-item anchors are stripped from the cards | `mode drift: an ask present in folded state is missing from the board` |
| the visible ref is dropped from the ask cards | `annotation anchors: see the reported ask` |
| the answer options stop naming their own ask | `annotation anchors: see the reported ask` |
| the signpost is removed with the composer | `signpost: see the reported gap` |
| the tick rewrites the board on an unchanged ledger | `tick: an unchanged ledger rewrote the board file` |
| the writer stops comparing before it replaces | `write: a byte-identical render replaced the board file anyway` |

The ref mutant is the one worth keeping in mind: it passed the first version of the anchor guard, because the refs also appear in the asks index at the top of the page and a document-wide search found them there.
An annotation is rooted where it was placed and never sees the index, so the guard now searches the ask's own card or row.
A guard that reads the whole page answers a question nobody asked.
