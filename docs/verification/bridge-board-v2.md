# Verification - the Bridge board v2, its rendering laws and its measured input path

Audience: maintainer-verification.
This file is the authoritative home of the board's six rendering laws and of the measurements the v2 design rests on.

The laws were approved as a mockup living in a gitignored `.lavish/` directory in a different repository.
A contract whose only home is an untracked file in another project is a pointer to nowhere, so they are transcribed here at implementation, verbatim in substance.
`bin/fm-bridge-render.sh` implements them and marks each at the code that keeps it; `docs/bridge.md` describes the surface and points here.

Measured 2026-08-05 against `lavish-axi` 0.1.43 and Chromium 150.0.7871.128 on Linux (WSL2), driving a real hosted Lavish session over the Chrome DevTools Protocol.
`docs/verification/bridge-hosted-input.md` holds the earlier v1 hosting measurements, which still stand; this file adds what v2 needed and did not inherit.

## The six rendering laws

**Law 1.** The default view renders open asks, the co-captain line, lanes, and admission.
Nothing else.
Resolved, landed, discarded, events, tallies, legends: absent - not collapsed, absent.
History is a separate view.

**Law 2.** Board length scales with open asks and nothing else.
Acceptance test: at 1080px wide, the first decision is fully visible with zero scrolling.

**Law 3.** An open critical is an ask card with a critical chip, sorted first.
A resolved critical does not render.
There is no pinned section.

**Law 4.** An ask covered by a standing word is never asked - it becomes a "merging under standing word" ledger line and a merge-line entry in the lane strip.

**Law 5.** A card carries: ref, project, age, one-line title (clamped), answers, and a collapsed **context** dropdown holding the 2-3 sentence detail needed to rule.
The full record stays in the ledger; the dropdown never scrolls the board when closed.

**Law 6.** Every value on the page is derived at fold time from an existing record or live reading - nothing hand-written, no constants (the capacity lesson).

### Why "absent" and not "collapsed" in Law 1

A collapsed section is still a row of chrome above the next decision, and length above the decisions is precisely what Law 2 caps.
The measurement in section 2 below is what makes that concrete: sixty non-ask records add exactly zero pixels, because they are not on the page at all.

### What Law 6 does and does not forbid

It forbids a **value on the page** that was typed rather than read - the capacity lesson, where a memory figure written into a document went on being quoted after the machine had changed.
It does not forbid a rule expressed as a threshold.
The renderer carries three, each named at its definition: the admission floor (2 GiB available), the supervision-beacon age past which lane health reads unknown (10 minutes), and the fold gap past which the freshness dot turns orange (2 minutes).
Each is compared against a reading taken live at fold time.

## 1. Acceptance test: the first decision is visible with zero scrolling

Measured on the real ledger of the captain's live home (two open asks at the time), hosted in Lavish, and separately on the standalone artifact.

```sh
chromium --headless=new --remote-debugging-port=9333 --user-data-dir=<scratch> about:blank &
export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9333
lavish-axi <scratch>/bridge.html                     # -> session URL
chrome-devtools-axi open "http://127.0.0.1:4387/session/<id>"
chrome-devtools-axi resize 1440 900                  # -> a 1080px artifact frame
```

The Lavish artifact frame is sandboxed **without `allow-same-origin`**, so the hosting page cannot read into it.
Measurements inside the board are taken by attaching to the frame's own CDP target.

Hosted, artifact frame 1080x844:

```json
{"frameW": 1080, "frameH": 844, "scrollTop": 0,
 "firstRef": "F41", "firstTop": 149, "firstBottom": 382,
 "firstFullyVisibleNoScroll": true,
 "allAsksBottom": 563, "allAsksVisibleNoScroll": true}
```

At a 1080x900 window the same session gives a 720px-wide frame - Lavish reserves the rest for its conversation panel - and the first decision is still fully visible with no scrolling (`firstTop` 168, `firstBottom` 435, frame height 844).

Standalone at a 1080x900 viewport, first decision `top` 40, `bottom` 280, document height 1144, `scrollTop` 0.

**Verdict: passes, hosted and standalone.**

## 2. Acceptance test: board length scales with open asks and nothing else

Three seeded homes rendered and measured at an identical 1080x900 viewport.

| Variant | Open asks | Other records | Document height |
| --- | --- | --- | --- |
| A | 2 | none | 1144px |
| B | 2 | 40 events, 10 resolved decisions, 10 landed tasks | 1144px |
| C | 3 | the same 60 non-ask records | 1284px |

Sixty non-ask records add **0px**.
One further open ask adds **140px**, one card.
`firstBottom` is 280px in all three.

**Verdict: passes. Length is a function of the open-ask count alone.**

## 3. The queue path, measured in the hosted board

This is the measurement that gated the design: `window.lavish.queuePrompt` with `queueKey` set to the ask's ref, checked in a **hosted** board rather than a local file, because that distinction is where this surface has failed before.

**Pinned version: `lavish-axi` 0.1.43.**
Everything in this section is a claim about that version.

The API surface the frame actually sees:

```
Object.keys(window.lavish) ->
  ["endSession", "getQueuedPrompts", "queuePrompt", "sendQueuedPrompts", "setStatus", "snapshot"]
```

Select answer A on ask F41, press Queue:

```json
{"queuedLabel": "A", "queuedCount": 1,
 "note": "queued: A - one entry per ask; re-queueing replaces it; Send to Agent delivers every queued ruling"}
```

The hosting page's conversation panel, immediately after:

```
.annotation-pills -> 1 pill: "F41: A  Context data: { "ref": "F41", "id": "...", "answer": "A", "text": "..." }"
```

Change of mind - select answer B on the **same** ask, press Queue again (the button relabels itself to `Update queued answer`):

```json
{"queueBtnLabelBeforeClick": "Update queued answer", "queuedLabel": "B", "queuedCount": 1}
```

```
.annotation-pills -> 1 pill: "F41: B  Context data: { "ref": "F41", ... }"
```

A second ask queues its own entry rather than replacing the first:

```
.annotation-pills -> 2 pills: ["F41: B", "F44: A"]
```

**Verdict: `queueKey` replacement works in the hosted board.**
One entry per ask, always the latest, and distinct asks do not collide.
**The board ships the queue path; the annotation-prefill fallback was not needed and is not implemented.**

### The link symptom, measured separately

`fm-lavish-links-unclickable` records two symptoms and explicitly forbids crediting one fix for both.
They are separate defects with separate roots, and this section is the evidence for the link half only.

Left-clicking an anchor in the hosted board, with a bubble-phase listener reading `event.defaultPrevented`:

```json
{"href": "history.html", "hasLavishAction": true, "defaultPreventedAtBubble": false}
```

and the frame then went where it was pointed:

```json
{"url": "/artifact/<id>/history.html", "title": "Bridge - history", "backLink": true}
```

So `data-lavish-action` is Lavish's own pass-through and it works: left-click is not prevented, the navigation happens, and the history page's `← board` link completes the round trip.
Every anchor carries it because they all go through one `link()` helper, which `tests/fm-bridge.test.sh` enforces.

The **root** of the link symptom is Lavish's capture-phase `preventDefault()` on everything outside its exclusion list.
The root of the answer-selection symptom is different and is in this repo: v1 rendered options as inert `<span>` elements and the page had no send path at all, by design.
Nothing was shared between them, so the queue path in section 3 fixes the second and this attribute fixes the first.

## 4. What a redraw does to a queued ruling

Lavish reloads the hosted frame **itself** when the file changes.
Measured by rewriting the hosted board with a later fold time and touching nothing in the browser:

```
folded_at in the frame before : 2026-08-06T00:54:41Z
board file rewritten with FM_BRIDGE_NOW=2099-01-01T00:00:00Z
folded_at in the frame ~4s later, no manual reload : 2099-01-01T00:00:00Z
```

Across that reload:

| What | Survives? |
| --- | --- |
| Queued pills in the conversation panel | **yes** - both pills still present, still "F41: B" and "F44: A" |
| The card's own green queued tick | no - `.ansbtn.queued` count is 0 in the reloaded frame |
| `window.lavish.getQueuedPrompts()` inside the frame | returns 0 - the API is per frame instance; the panel is where they live |

The consequence is benign and is the reason `queueKey` is load-bearing rather than a nicety: a captain who no longer sees the tick may queue the same answer again, and that **replaces** the existing entry instead of sending a second ruling.
The board's footer states this in the captain's words.

## 5. Why the board does not reload itself

The mockup's stale bar offered to auto-reload "when no annotation is open".
Two measurements say the board must not do that, and the deviation is deliberate:

1. Lavish already reloads the frame on write (section 4), so an auto-reload here would be a second owner of an action that already has one.
2. The frame is sandboxed without `allow-same-origin`, and `window.lavish` exposes no annotation-state accessor (section 3), so the board **cannot** observe whether an annotation card is open in the host.
   It could only guess, and a wrong guess destroys a ruling in progress.

So the freshness poll reports and never acts: the bar names both times and offers a button the reader presses.
Its value is the case Lavish's own reload does not cover - a copy opened as a plain file, or a write the host missed - where nothing else would ever say the page had gone stale.
A poll that fails or returns something unparseable changes nothing on the page: unknown is neither fresh nor stale.

## 6. Controls, and what stays annotatable

v1 was authored by forbidding every native control, because Lavish skips a control and everything inside it when deciding what can be annotated (`docs/verification/bridge-hosted-input.md`).
v2 trades that away **only** for the answer options, the Queue button, the context disclosure, and the stale bar's reload - deliberately, because a ruling had twice travelled by terminal instead of this board, once because the answer forms could not be selected.

What must stay outside every control, and is pinned by `tests/fm-bridge.test.sh`:

- the per-item anchor `id="item-<id>"`,
- the visible ref (`<span class="ref">F41</span>`),
- the one-line title.

Those three are what a free-text annotation needs in order to name the ask it was placed on.
The board still renders no free-text input of its own: no `input`, no `textarea`, no `contenteditable`.

## 7. The live guard, and what it covers

`tests/fm-bridge-lavish-annotation-live-e2e.test.sh` is the opt-in guard that re-checks the vendor-dependent half against the **installed** `lavish-axi` and a real hosted session.
Run it after every `lavish-axi` upgrade: `FM_BRIDGE_LAVISH_LIVE_E2E=1 bash tests/fm-bridge-lavish-annotation-live-e2e.test.sh`, with `CHROME_DEVTOOLS_AXI_BROWSER_URL` pointing at a Chrome with remote debugging.

Result on 2026-08-05 against `lavish-axi` 0.1.43:

```
lavish-axi 0.1.43 at /home/jamada/.local/lib/node_modules/lavish-axi/dist/cli.mjs
ok - the installed lavish-axi still excludes exactly the controls the board avoids
ok - the installed lavish-axi still carries the queue API and its replace-by-key option
ok - the hosted board renders its answer options as controls, so a click can queue a ruling
ok - the ask's visible ref is annotatable, so an annotation can name what it ruled on
ok - the ask's title is annotatable, so a ruling the buttons cannot say still has somewhere to go
all live Lavish annotation guards passed against lavish-axi 0.1.43
```

**One limitation, stated rather than papered over.**
The guard pins `queuePrompt`, `queueKey` and `sendQueuedPrompts` by reading the installed binary, and it does not exercise the queue path in the browser.
It cannot: the artifact frame is sandboxed without `allow-same-origin`, so the hosting page - which is what `chrome-devtools-axi eval` reaches - is the wrong document.
The behavioural measurement is section 3 above, taken by attaching to the frame's own CDP target, and the binary pin is what says whether that measurement is still about the version installed.
If those names leave the binary, the guard fails naming the version rather than passing quietly over a queue path nobody has re-measured.

## Refreshing these measurements

Re-run after any `lavish-axi` upgrade, and after any change to the board's layout or queue path.

```sh
# 1 and 2 - geometry
chromium --headless=new --remote-debugging-port=9333 --user-data-dir=<scratch> about:blank &
export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9333
bin/fm-bridge-render.sh --html > <scratch>/board.html
chrome-devtools-axi open "file://<scratch>/board.html"
chrome-devtools-axi resize 1080 900
chrome-devtools-axi eval '() => { const se=document.scrollingElement, c=document.querySelectorAll(".ask"); const f=c[0].getBoundingClientRect(); return JSON.stringify({docHeight: se.scrollHeight, asks: c.length, firstBottom: Math.round(f.bottom), firstVisibleNoScroll: se.scrollTop===0 && f.bottom<=innerHeight}); }'

# 3, 4 and 5 - the hosted queue path. The artifact frame is sandboxed, so
# attach to its own CDP target rather than reaching in from the hosting page:
#   curl -s http://127.0.0.1:9333/json/list   -> the iframe target for /artifact/<id>/index.html
# then drive Runtime.evaluate against that target's webSocketDebuggerUrl.
```

The portable half of these guarantees - which regions render where, which controls exist, that a queued class is only applied after an observed success - is enforced in CI by `tests/fm-bridge.test.sh` and needs no browser.
What needs a browser is geometry and the Lavish API's real behaviour, which is what this file records.
