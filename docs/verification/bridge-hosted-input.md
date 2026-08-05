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

## Upstream

The silent loss of unqueued annotation text across a live reload is a Lavish behaviour, not a board behaviour: every hosted artifact its agent regenerates has the same hole, and a live reload that discards a draft the reviewer is still typing is worth fixing where it happens.
The report belongs at https://github.com/kunchenguid/lavish-axi/issues, carries the reproduction in sections 2 and 3 verbatim, and is **not posted yet** - it is outward-facing, so it waits on the captain's word.
Record the issue URL here once it is filed.

Firstmate's own guard does not depend on that report: section 3 is why the tick skips the write, and that holds whatever upstream decides.
