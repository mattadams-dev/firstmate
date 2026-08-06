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

Both rendered pages carry the bar, because both run the same poll.
The history page turned its freshness dot orange while emitting no bar, so it signalled a state it could neither explain nor let the reader act on.
Dropping the dot there would have removed the signal rather than the confusion, so the bar is what the two pages share, emitted from one construction site in the renderer.

## 6. Controls, and what stays annotatable

v1 was authored by forbidding every native control, because Lavish skips a control and everything inside it when deciding what can be annotated (`docs/verification/bridge-hosted-input.md`).
v2 trades that away **only** for the answer options, the Queue button, the context disclosure, and the stale bar's reload - deliberately, because a ruling had twice travelled by terminal instead of this board, once because the answer forms could not be selected.

What must stay outside every control, and is pinned by `tests/fm-bridge.test.sh`:

- the per-item anchor `id="item-<id>"`,
- the visible ref (`<span class="ref">F41</span>`),
- the one-line title.

Those three are what a free-text annotation needs in order to name the ask it was placed on.
The board still renders no free-text input of its own: no `input`, no `textarea`, no `contenteditable`.

## 7. The render's cost, because it runs on the supervision loop

`bin/fm-watch.sh` runs the tick from its own poll, so a slow render is a slow watcher.
Measured on this machine:

| Render | Wall clock |
| --- | --- |
| v1, no live readings | ~0.2s |
| v2, cold probe cache (host memory + quota both spawned) | 1.392s |
| v2, warm probe cache | 0.109s |

The 1.4s cold render was enough to push a one-second watcher poll past a three-second guard in `tests/fm-watch-triage.test.sh`, which is the fleet's supervision responsiveness being spent on a captain-facing number.

So the two probes that spawn a process are cached in `state/.bridge-probe-host` and `state/.bridge-probe-quota` for five minutes, with a two-second probe timeout; memory headroom is a file read and stays fresh every time.
A reused reading carries its age on the gauge.
Worst case on the watcher's thread is now one bounded probe per five-minute window, and the typical render is faster than v1's was.

## 8. The live guard, and what it covers

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

## 9. The guards, proven to fire against v2

A guard whose failing direction has never been observed under the rules it now enforces is unproven, and these guards protect the integrity of the captain's decision record.
The matrix that stood in `docs/verification/bridge-hosted-input.md` was recorded against the v1 board, and v1 is dead code: two of its rows described rules v2 inverted, so the mutation each recorded as a failure is now the shipped state.
That file now points here, and this section is the matrix's one home.
Every verdict below was observed on this branch on 2026-08-05.
Nothing is carried forward from the v1 sweep.

**Method, unchanged from how the v1 table was built.**
Each mutation was applied to `bin/fm-bridge-render.sh` on its own, `bash tests/fm-bridge.test.sh` was run, and the FIRST failing guard was recorded as the suite reported it.
The renderer was restored from git before and after every mutation, so no mutant could survive into the branch or contaminate the next one.
The suite stops at the first failure, so a mutant reaching its own guard is what proves nothing earlier caught it by accident.
Baseline before and after the 9a sweep: 100 assertions, all passing, and `git status` clean.
The guards added in 9b below take that baseline to 107.

### 9a. The portable matrix

| mutation | first failing guard |
| --- | --- |
| a sendable-looking composer returns to the board | `input path: see the reported element` - `the board renders textarea, which is either an input it cannot send or a spot the captain cannot annotate` |
| answer options go back to being inert spans | `mode drift: a task-kind ask is shown but not answerable where it lands` - `the PR card lists its answers but offers no way to queue one` |
| a button with no accounted-for role is added to the board | `input path: see the reported element` - `the board renders a button with no accounted-for role, so something on it promises an action nobody has checked` |
| the queue key is dropped from the ask card | `annotation anchors: see the reported ask` - `ask l1 carries no queue key, so a queued ruling could not name the ask it answers, or replace its own earlier answer` |
| the per-item anchors are stripped from the cards | `mode drift: an ask present in folded state is missing from the board` |
| the visible ref is dropped from the ask cards | `annotation anchors: see the reported ask` - `ask l1 renders no visible ref outside its controls, so a free-text ruling on it arrives unquotable` |
| the signpost is removed with the composer | `signpost: see the reported gap` - `the board never names where a queued or annotated ruling is sent from` |
| the tick rewrites the board on an unchanged ledger | `tick: an unchanged ledger changed the board's bytes` |
| the writer stops comparing before it replaces | `write: a byte-identical render replaced the page anyway, which reloads the hosted copy for nothing` |
| a board-kind item renders on neither page (decisions zone) | `pointer: see the report` - caught, but by a different guard; see below |
| a board-kind item renders on neither page (fleet zone) | `pages: see the reported item` - `these items are on NEITHER page, so the record holds them and no surface shows them: [('gap-task', 'fm-handling', 'in-flight')]` |
| a board-kind item renders on both pages | `pages: see the reported item` - `these items render on BOTH pages, so the captain triages them twice: ['gap-ev-cap', 'gap-ev-co']` |
| the decisions-zone label drifts from the severity-first sort | `sort label: see the report` - `the label does not say the queue is ordered by severity` |
| an option is marked queued without an observed queue verdict | `queueing: see the reported path` - `an answer is marked queued without checking that the queue call actually succeeded` |
| the renderer leaks the fold program it staged | `--state left 1 file(s) behind in its temp dir: fm-bridge-prog.NxrefL.py` |
| the probe cache is bypassed, so every render spawns the subprocess again | `the second render ignored the cached reading and probed again, so every render on the watcher's poll pays the subprocess cost` |
| the critical chip is rendered twice | `criticals: see the report` - `the critical card carries the same chip twice (['critical', 'critical']), which reads as two facts where the record made one` |

Two of these rows are the ones v2 inverted, and they are stated in their v2 direction rather than carried over.
v1 failed a board that rendered answer options as controls; v2 ships them as controls deliberately, so the mutation worth proving is the return of the inert span - and it breaks the queue path, which is what the suite reported.
v1 carried the ask's visible ref inside the option text; v2 carries ask identity in `data-ask-ref`, so the mutation worth proving is dropping the queue key from the card.

**The partition guard, and why it has two rows.**
The first neither-page mutation dropped every open-elsewhere decision from the history page, which is the complement-vs-zone-list error the guard exists for.
It was caught, but by the pointer guard rather than the partition guard: the pointer guard's own fixture contains a resolved-with-no-pointer decision, that decision is exactly the item the mutation hid, and its warning left the page along with it.
So the mutation is caught twice over, and the partition guard's own missing-direction had still not been observed.
The second row narrows the same error to the fleet zone, where it disturbs no earlier fixture, and it reaches the partition guard.
Both rows are kept: the first is the honest record of what fired, the second is the proof the guard fires at all.

**The blind spot this matrix has already caught once**, carried here with the table it belongs to.
The dropped-ref mutant passed the FIRST version of the anchor guard, because the refs also appeared in the v1 asks index at the top of the page and a document-wide search found them there.
An annotation is rooted where it was placed and never sees an index, so the guard now searches the ask's own card or row.
A guard that reads the whole page answers a question nobody asked.

### 9b. The two invariants the sweep found unguarded, and the guards that now cover them

Three mutations SURVIVED the sweep in 9a: the full suite passed with each of them applied.

| mutation | result at the time of the sweep |
| --- | --- |
| lane health falls through to green when the watcher key does not resolve | SURVIVED - 100 assertions passed |
| a lapsed supervision beacon no longer forces lane health to unknown | SURVIVED - 100 assertions passed |
| the freshness bar is removed from the history page | SURVIVED - 100 assertions passed |

That was an observed negative result, not a reading that could not be taken - no guard failed to answer, there was no guard.
The first two are the two arms of one rule, so the whole rule was unguarded rather than half of it.
`if not live or key is None: health = "unknown"` is the line, and each arm was deleted on its own.
An unresolved key matches no marker, so the watcher's verdict was never read; a lapsed beacon means nobody is maintaining the markers, so the absence of a warning stopped being good news.
A green dot over a lane supervision has flagged as wedged is precisely the state both arms exist to prevent, and either deletion restored that green with the suite still green too.
The third is the rule section 5 above ends on: both pages carry the bar because both run the poll, and a page that changes its freshness dot without the bar signals a state it can neither explain nor let the reader act on.

**Both gaps are closed in this change**, because a guard that cannot fail is indistinguishable from a guard that passes, and this one reports fleet health on the captain's only decision surface.
Filing it forward would have knowingly shipped a health indicator that provably could not go red.
`tests/fm-bridge.test.sh` gained sections 31, 32 and 33, and the suite is now 107 assertions.
Every guard drives the renderer through a fixture `FM_HOME` - a `.meta` file, a beacon file, watcher marker files - and asserts on the RENDERED page.
None of them reads the renderer's source, because a guard that grepped `bin/fm-bridge-render.sh` for a line of Python would pass a renderer that carried the line and ignored it.

**Both directions were observed for each guard, on 2026-08-05, by the same method as 9a.**
The mutation that breaks the protection must fail that guard's OWN test, and the mutation that makes the guard over-strict must fail a DIFFERENT one - otherwise the guard is satisfiable by a renderer that reports the alarm state unconditionally, which is the false-alarm twin of the defect being fixed.
Nothing here is a COULD NOT OBSERVE: every mutation below reached a failing assertion and the first failure is quoted as the suite printed it.

| mutation | direction | first failing guard |
| --- | --- | --- |
| the `key is None` arm is deleted from the lane-health rule | breaks the protection | 32 - `not ok - lane health: a lane whose meta names no backend target read green, so a verdict nobody took became good news - the board rendered [keyed ok/keyless ok]` |
| the `not live` arm is deleted from the lane-health rule | breaks the protection | 32 - `not ok - lane health: a lapsed supervision beacon left a lane green, inheriting a verdict nobody is standing behind - the board rendered [keyed ok/keyless unknown]` |
| the marker key is derived from `window` alone, missing every Orca lane | breaks the protection | 31 - `not ok - lane health: an Orca lane's marker was not found, so the board reported a health it never read - the board rendered [flagged warn/moving ok/orcalane unknown]` |
| lane health reports `unknown` unconditionally | over-strict | 31 - `not ok - lane health: a supervised lane with a resolving key and nothing filed against it did not read ok - the board rendered [flagged unknown/moving unknown/orcalane unknown]` |
| the freshness bar is removed from the history page | breaks the protection | 33 - `the history page runs the freshness poll and carries no bar, so it can turn its dot orange with nothing beside it to explain the state or let the reader act on it` |
| the freshness bar no longer starts hidden | over-strict | 21 - `not ok - layout: the freshness bar is missing, or no longer starts hidden` |

**Why lane health is two sections rather than one.**
The positive direction lives in 31 and the unknown arms live in 32, and that split is what makes the over-strict row above land on a different test than the two arm deletions.
A single section asserting only that `unknown` is reachable would be passed by a board that says `unknown` to every lane, which is a health indicator that cannot go green - the same instrument failure in the other direction.
Section 32 keeps a lane whose key does resolve beside the keyless one for the same reason, so a blanket-unknown board fails there too rather than sliding through on the assertion it was aimed at.

**What each fixture is, so the next hand can tell a broken guard from a broken renderer.**
Section 31 renders a fresh beacon with three lanes: one tmux lane with no marker against it, one tmux lane with `.stale-since-firstmate_4` filed against it, and one Orca lane whose meta names `terminal=` and whose `.wedge-escalations-orca-term-1` marker must still be found.
Section 32 renders a lane whose meta names no backend target at all beside one whose key resolves, first under a fresh beacon, then under a beacon aged past `WATCHER_BEACON_MAX_AGE`, then with no beacon file at all.
Section 33 renders both pages and asserts the conditional the invariant actually states: a page that carries the fold-time meta and the freshness dot must carry the bar and its reload button, and must start it hidden.

The renderer was restored from git before and after every mutation, and `git status` showed only `tests/fm-bridge.test.sh` modified when the sweep finished - no mutant survived into the branch.

### 9c. The live guard

Measured against the INSTALLED `lavish-axi` 0.1.43 and Chromium 150.0.7871.128, headless, with `FM_BRIDGE_LAVISH_LIVE_E2E=1` and `CHROME_DEVTOOLS_AXI_BROWSER_URL` pointed at its remote-debugging port.
The guard reached its browser assertions in both runs, so neither verdict is a COULD NOT OBSERVE.

| mutation | live guard verdict |
| --- | --- |
| none - the v2 board as it ships | `all live Lavish annotation guards passed against lavish-axi 0.1.43` |
| answer options rendered as inert spans | `not ok - the board renders its answer option as something other than a native control: uid=g3:1_29 StaticText "A: retire it"` |

That second row is the v1 row inverted.
v1 failed when an option rendered as `<button>`; v2 requires exactly that shape, so the failing direction to prove is the span, and it fires.
Section 8 above records the guard's full passing output; this sweep re-ran it and got that output back byte for byte, which is the baseline the second row is measured against.

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
