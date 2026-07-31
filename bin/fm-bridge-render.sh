#!/usr/bin/env bash
# fm-bridge-render.sh - the READER half of the Bridge: the ONE authoritative
# fold over the ledger, exposed in two output shapes.
#
#   fm-bridge-render.sh --state            folded current state, as structured JSON
#   fm-bridge-render.sh --state --id ID    the same fold, narrowed to one item
#   fm-bridge-render.sh --lifecycle ID     typed answer to "what happened to ID?"
#   fm-bridge-render.sh --html             the HTML board, on stdout
#   fm-bridge-render.sh --tick             the supervision-cycle entry point
#   fm-bridge-render.sh --path             print the canonical board path
#
# ONE FOLD, MANY CONSUMERS
# The fold is not logic buried in a renderer. It is a published interface with
# these consumers on day one:
#   1. the HTML board renders through it,
#   2. the co-captain (the dotfiles session) audits through it,
#   3. firstmate's own record linter (bin/fm-bridge.sh lint) checks through it,
#   4. targeted lifecycle questions are answered through it (--lifecycle).
# A shared implementation with a single consumer decays back into private logic
# because nothing else exercises its contract; the plural is the guarantee.
# "My reading disagrees with the board" is therefore not a class of bug here:
# the board is not a second opinion about the ledger, it is a rendering of the
# same answer everyone else gets. An independent audit can then compare RAW
# STREAM against FOLDED STATE - the only comparison that can catch a folding
# error - instead of comparing one fold against another, which can agree while
# both are wrong.
#
# HOW THE MODES ARE PROVEN NOT TO DIVERGE
# The fold runs ONCE per invocation, IN-PROCESS, and every output shape consumes
# that one result: `render_html(doc, checked_at)` is handed the fold's return
# value and takes no ledger path, so it cannot re-read or re-parse the stream.
# The board then embeds the exact state document it was drawn from in a
# <script type="application/json" id="fm-bridge-state"> block, so those bytes
# must equal `--state` output for the same ledger and clock. A seeded-ledger
# test asserts that byte identity; re-inlining a second fold breaks that test
# and nothing else.
#
# TOLERANCE
# Writers normalize (bin/fm-bridge-lib.sh); this reader tolerates everything
# ever written, forever. Its two hard rules exist because of the
# fm-decision-fold-key-blind incident, where 60 of 65 keyed records collapsed
# into one default slot because the key sat where the parser did not look:
#   1. CONSERVATION. Every non-blank ledger line is accounted for in the output:
#      lines_considered == records + malformed. The board prints the counts, so a
#      parser that stops reading a field cannot silently mask anything - the
#      numbers stop adding up on the visible surface.
#   2. NEVER DEFAULT AN UNRECOGNIZED VALUE. An unknown kind, state, or severity
#      is preserved verbatim and flagged unrecognized, never mapped into a
#      default bucket. Silent masking was the failure; visible strangeness is the
#      fix.
#
# See docs/bridge.md for the published record schema, the state-mode schema, the
# canonical paths, and the rendering caps.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bridge-lib.sh
. "$SCRIPT_DIR/fm-bridge-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STAMP="$STATE_DIR/.bridge-render"

usage() { sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; }

die() { printf 'fm-bridge-render: %s\n' "$1" >&2; exit 1; }

# --- the one embedded program ----------------------------------------------
# Written to a temp file once per invocation so both modes run the SAME bytes.
PROGRAM=
program_path() {
  [ -n "$PROGRAM" ] && { printf '%s' "$PROGRAM"; return 0; }
  PROGRAM=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-prog.XXXXXX.py") || return 1
  cat > "$PROGRAM" <<'PY'
"""Bridge fold, targeted queries, and board renderer.

argv[1] selects the mode. Every mode that produces output folds exactly ONCE and
hands that one result to whatever shapes it:

  state     <ledger> <folded-at> [id]      the fold, whole or narrowed to one item
  lifecycle <ledger> <folded-at> <id>      typed answer about one item's lifecycle
  html      <ledger> <folded-at> <checked-at>
                                           folds once, then render_html(doc, ...)
  restamp   <board-path> <checked-at>      rewrites only the marked freshness line
  signature <ledger>                       cheap change signature for the tick

render_html takes the fold's RETURN VALUE and no ledger path, so the drawing
half cannot re-read or re-parse the stream.
"""
import html as _html
import json
import os
import sys

# `steering` is the second producer's kind (see docs/bridge.md "Second
# producer"). It is substrate, not a captain-facing zone: it never renders as a
# board item, but it folds through the identical path, which is the point - a
# new event kind is an ordinary addition here, never a migration.
KNOWN_KINDS = ("critical", "decision", "event", "task", "term", "steering")

# Kinds the captain reads. Everything else is substrate and is counted, but not
# tallied into the board's disposition summary, so machinery cannot inflate the
# numbers the captain triages against.
BOARD_KINDS = ("critical", "decision", "event", "task")

# The steering lifecycle, in order. Monotonic: a stage once recorded is never
# unrecorded, so out-of-order arrival cannot walk a message backwards.
LIFECYCLE_STAGES = ("sent", "delivered", "consumed")
KNOWN_STATES = ("needs-captain", "fm-handling", "resolved")
KNOWN_SEVERITIES = ("critical", "high", "normal", "low")
SEVERITY_RANK = {"critical": 0, "high": 1, "normal": 2, "low": 3}
STATE_RANK = {"needs-captain": 0, "fm-handling": 1, "resolved": 2}

# Fields this fold understands. Anything else survives under "extra" - an
# unrecognized field is never a reason to drop or ignore a record.
KNOWN_FIELDS = frozenset((
    "v", "ts", "id", "kind", "project", "state", "severity", "owner",
    "title", "body", "pointer", "check", "note", "phase", "answers",
    "truncated",
))

# Every position the fold key has ever occupied, in priority order. The reader
# looks in all of them forever; the writer only ever emits the first.
ID_ALIASES = ("id", "key", "item_id", "itemId")

# Merge-able scalar fields: a later record's present value replaces the earlier.
SCALARS = ("kind", "project", "state", "severity", "owner", "title", "body",
           "pointer", "check", "note", "phase")

MAX_MALFORMED_SHOWN = 25
MAX_RAW_ECHO = 240

# Presentation caps. Named here so the state document can publish them and the
# board can show the overflow pointer rather than truncating silently.
CAP_EVENTS = int(os.environ.get("FM_BRIDGE_CAP_EVENTS", "12"))
CAP_RESOLVED_DECISIONS = int(os.environ.get("FM_BRIDGE_CAP_RESOLVED_DECISIONS", "3"))
CAP_FLEET_RESOLVED = int(os.environ.get("FM_BRIDGE_CAP_FLEET_RESOLVED", "6"))


def _text(value):
    """Coerce any JSON scalar to a string; containers render as compact JSON."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value) if isinstance(value, float) else str(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _answers(value):
    """Tolerate answers written as a list, a bare string, or a scalar."""
    if value is None:
        return None
    if isinstance(value, list):
        return [_text(v) for v in value if _text(v) != ""]
    text = _text(value)
    return [text] if text else []


def _fold_key(obj):
    for alias in ID_ALIASES:
        if alias in obj:
            key = _text(obj[alias]).strip()
            if key:
                return key, alias
    return None, None


def fold(ledger_path, folded_at):
    """The ONE authoritative fold. Pure read; no side effects."""
    items = {}
    order = []
    malformed = []
    lines_total = 0
    lines_blank = 0
    records = 0
    present = os.path.exists(ledger_path)

    if present:
        with open(ledger_path, "r", encoding="utf-8", errors="replace") as handle:
            for lineno, raw in enumerate(handle, 1):
                lines_total += 1
                stripped = raw.strip()
                if not stripped:
                    lines_blank += 1
                    continue
                try:
                    obj = json.loads(stripped)
                except ValueError as exc:
                    malformed.append({
                        "line": lineno,
                        "reason": "not valid JSON: %s" % exc,
                        "raw": stripped[:MAX_RAW_ECHO],
                    })
                    continue
                if not isinstance(obj, dict):
                    malformed.append({
                        "line": lineno,
                        "reason": "record is a %s, not an object" % type(obj).__name__,
                        "raw": stripped[:MAX_RAW_ECHO],
                    })
                    continue
                key, alias = _fold_key(obj)
                if key is None:
                    malformed.append({
                        "line": lineno,
                        "reason": "no usable id in any known position (%s)"
                                  % ", ".join(ID_ALIASES),
                        "raw": stripped[:MAX_RAW_ECHO],
                    })
                    continue

                records += 1
                ts = _text(obj.get("ts"))
                item = items.get(key)
                if item is None:
                    item = {
                        "id": key,
                        "kind": "", "project": "", "state": "", "severity": "",
                        "owner": "", "title": "", "body": "", "pointer": "",
                        "check": "", "note": "", "phase": "",
                        "answers": [],
                        "truncated": False,
                        "first_ts": ts,
                        "ts": ts,
                        "updates": 0,
                        "first_line": lineno,
                        "last_line": lineno,
                        "lines": [],
                        "key_aliases": [],
                        # Every phase this item has EVER been recorded in, with
                        # the timestamp and ledger line that first recorded it.
                        # Accumulating instead of overwriting is what makes
                        # "was X consumed?" answerable regardless of the order
                        # records arrived in - and it is why a later unrelated
                        # record can never erase a lifecycle fact.
                        "phases_seen": {},
                        "extra": {},
                        "schema_versions": [],
                    }
                    items[key] = item
                    order.append(key)

                item["updates"] += 1
                item["last_line"] = lineno
                if len(item["lines"]) < 64:
                    item["lines"].append(lineno)
                phase_value = _text(obj.get("phase")).strip()
                if phase_value and phase_value not in item["phases_seen"]:
                    item["phases_seen"][phase_value] = {"ts": ts, "line": lineno}
                if ts:
                    if not item["first_ts"]:
                        item["first_ts"] = ts
                    item["ts"] = ts
                if alias not in item["key_aliases"]:
                    item["key_aliases"].append(alias)
                version = obj.get("v")
                version_text = _text(version) if version is not None else "unversioned"
                if version_text not in item["schema_versions"]:
                    item["schema_versions"].append(version_text)

                for field in SCALARS:
                    if field in obj:
                        item[field] = _text(obj[field])
                if "answers" in obj:
                    parsed = _answers(obj["answers"])
                    if parsed is not None:
                        item["answers"] = parsed
                if "truncated" in obj:
                    item["truncated"] = bool(obj["truncated"])
                for field, value in obj.items():
                    if field in KNOWN_FIELDS or field in ID_ALIASES:
                        continue
                    item["extra"][field] = value

    # Defaults are applied ONLY where the ledger said nothing at all. A value
    # the ledger DID carry is never replaced by a default, however strange it
    # looks - it is preserved and flagged, so it shows up as strange instead of
    # disappearing into a default slot.
    for item in items.values():
        item["recognized"] = {
            "kind": item["kind"] in KNOWN_KINDS,
            "state": item["state"] in KNOWN_STATES,
            "severity": item["severity"] in KNOWN_SEVERITIES,
        }
        if not item["kind"]:
            item["kind"] = "event"
            item["recognized"]["kind"] = True
            item["defaulted_kind"] = True
        if not item["state"]:
            # Mirrors fm_bridge_default_state in bin/fm-bridge-lib.sh. Firstmate's
            # own writer always states this explicitly; the backstop exists for
            # other producers, and it must land an ask kind on `needs-captain` -
            # a decision quietly defaulted to fm-handling would read as handled.
            if item["kind"] in ("decision", "critical"):
                item["state"] = "needs-captain"
            elif item["kind"] == "task":
                item["state"] = "fm-handling"
            else:
                item["state"] = "resolved"
            item["recognized"]["state"] = True
            item["defaulted_state"] = True
        if not item["severity"]:
            item["severity"] = "critical" if item["kind"] == "critical" else "normal"
            item["recognized"]["severity"] = True
            item["defaulted_severity"] = True
        if not item["owner"]:
            item["owner"] = "captain" if item["state"] == "needs-captain" else "firstmate"
        if not item["project"]:
            item["project"] = "fleet"

    # Stable per-project display prefixes. A project's prefix is the shortest
    # uppercase prefix of its slug that is unique among the projects that
    # appeared at or before it, so an existing project's prefix never changes
    # when a new, colliding project arrives later - the newcomer takes the
    # longer prefix. A bare ref therefore never needs disambiguating, and never
    # silently means something different than it did yesterday.
    projects = []
    taken = {}
    for key in order:
        slug = items[key]["project"]
        if slug in taken:
            continue
        upper = slug.upper() or "X"
        prefix = upper[0]
        length = 1
        while prefix in taken.values() and length < len(upper):
            length += 1
            prefix = upper[:length]
        while prefix in taken.values():
            prefix = prefix + "X"
        taken[slug] = prefix
        projects.append({"slug": slug, "prefix": prefix})

    # Refs are assigned to the kinds the captain actually rules on, in
    # first-appearance order per project. Append-only order makes them stable:
    # a resolved item keeps its number forever rather than renumbering its
    # successors.
    counters = {}
    for key in order:
        item = items[key]
        if item["kind"] in ("decision", "critical"):
            slug = item["project"]
            counters[slug] = counters.get(slug, 0) + 1
            item["ref"] = "%s%d" % (taken.get(slug, "X"), counters[slug])
        else:
            item["ref"] = ""

    index = {key: position for position, key in enumerate(order)}

    def recency(key):
        return (items[key]["ts"], index[key])

    def disposition(key):
        item = items[key]
        return (STATE_RANK.get(item["state"], 3),
                SEVERITY_RANK.get(item["severity"], 4),
                -index[key])

    criticals = [k for k in order
                 if items[k]["kind"] == "critical" and items[k]["state"] != "resolved"]
    criticals.sort(key=disposition)
    criticals_resolved = sorted(
        [k for k in order if items[k]["kind"] == "critical" and items[k]["state"] == "resolved"],
        key=recency, reverse=True)

    decisions = []
    for project in projects:
        slug = project["slug"]
        keys = [k for k in order
                if items[k]["kind"] == "decision" and items[k]["project"] == slug]
        if not keys:
            continue
        open_keys = sorted([k for k in keys if items[k]["state"] != "resolved"],
                           key=disposition)
        done_keys = sorted([k for k in keys if items[k]["state"] == "resolved"],
                           key=recency, reverse=True)
        decisions.append({
            "project": slug,
            "prefix": project["prefix"],
            "open": open_keys,
            "resolved": done_keys,
        })

    events = sorted([k for k in order if items[k]["kind"] == "event"],
                    key=recency, reverse=True)
    fleet_open = sorted([k for k in order
                         if items[k]["kind"] == "task" and items[k]["state"] != "resolved"],
                        key=disposition)
    fleet_done = sorted([k for k in order
                         if items[k]["kind"] == "task" and items[k]["state"] == "resolved"],
                        key=recency, reverse=True)
    terms = [k for k in order if items[k]["kind"] == "term"]
    steering = [k for k in order if items[k]["kind"] == "steering"]
    unzoned = [k for k in order if not items[k]["recognized"]["kind"]]

    # A term defined by more than one project is a collision: the board defines
    # those up front AND repeats them locally, so the reader never scrolls back.
    by_term = {}
    for key in terms:
        by_term.setdefault(items[key]["title"].strip().lower(), []).append(key)
    glossary = []
    for label in sorted(by_term):
        keys = by_term[label]
        glossary.append({
            "term": label,
            "collision": len({items[k]["project"] for k in keys}) > 1,
            "entries": [{"project": items[k]["project"],
                         "means": items[k]["body"] or items[k]["note"]} for k in keys],
        })

    lines_considered = lines_total - lines_blank
    # The summary is what the captain triages against, so it counts only the
    # kinds they read. Substrate is reported separately rather than folded in,
    # because a machinery record inflating "resolved" would quietly change what
    # the tallies mean.
    summary = {"needs-captain": 0, "fm-handling": 0, "resolved": 0, "unrecognized": 0}
    for item in items.values():
        if item["kind"] not in BOARD_KINDS:
            continue
        if item["state"] in summary:
            summary[item["state"]] += 1
        else:
            summary["unrecognized"] += 1

    lifecycle_counts = {stage: 0 for stage in LIFECYCLE_STAGES}
    for key in steering:
        for stage in LIFECYCLE_STAGES:
            if stage in items[key]["phases_seen"]:
                lifecycle_counts[stage] += 1
    substrate = {
        "steering": {"items": len(steering), "stages": lifecycle_counts},
        "terms": len(terms),
    }

    return {
        "schema": "fm-bridge.state.v1",
        "folded_at": folded_at,
        "ledger": {
            "path": ledger_path,
            "present": present,
            "signature": signature(ledger_path),
        },
        "counts": {
            "lines_total": lines_total,
            "lines_blank": lines_blank,
            "lines_considered": lines_considered,
            "records": records,
            "malformed": len(malformed),
            "items": len(items),
        },
        # The conservation invariant, stated as data so every consumer can check
        # it without re-deriving it.
        "conserved": lines_considered == records + len(malformed),
        "malformed": malformed[:MAX_MALFORMED_SHOWN],
        "malformed_omitted": max(0, len(malformed) - MAX_MALFORMED_SHOWN),
        "projects": projects,
        "order": order,
        "items": {k: items[k] for k in order},
        "zones": {
            "criticals": criticals,
            "criticals_resolved": criticals_resolved,
            "decisions": decisions,
            "events": events,
            "fleet_open": fleet_open,
            "fleet_resolved": fleet_done,
            "unzoned": unzoned,
            "substrate": steering,
        },
        "glossary": glossary,
        "summary": summary,
        "substrate": substrate,
        "caps": {
            "events": CAP_EVENTS,
            "resolved_decisions": CAP_RESOLVED_DECISIONS,
            "fleet_resolved": CAP_FLEET_RESOLVED,
        },
        "checks": {
            "folded state": "bin/fm-bridge-render.sh --state",
            "conservation": "bin/fm-bridge-render.sh --state | jq '.counts, .conserved'",
            "open asks": "bin/fm-bridge-render.sh --state | jq -r "
                         "'.items|to_entries[]|select(.value.state==\"needs-captain\")"
                         "|\"\\(.value.ref) \\(.value.title)\"'",
            "record hygiene": "bin/fm-bridge.sh lint",
            "one item": "bin/fm-bridge-render.sh --lifecycle <id>",
            "raw stream": "tail -n 40 %s" % ledger_path,
        },
    }


def narrow(doc, item_id):
    """The whole fold, narrowed to one item. Same document shape, so a targeted
    consumer parses exactly what a whole-fleet consumer parses."""
    item = doc["items"].get(item_id)
    doc = dict(doc)
    doc["query"] = {"id": item_id, "found": item is not None}
    doc["items"] = {item_id: item} if item is not None else {}
    doc["order"] = [item_id] if item is not None else []
    return doc


def lifecycle(doc, item_id):
    """Answer "what happened to <id>?" as a typed, three-valued claim.

    The rule this encodes, and the reason the record exists at all: CONSUMED and
    NEVER-ARRIVED look identical on screen. An empty composer is produced by both,
    so a checker reading the screen can only honestly say UNKNOWN. Absence is
    therefore assertable only from a durable consumption record, never from UI
    state - which is what `absence_explained` means here, and why it is false
    for every verdict except `consumed`.

    Conservation feeds straight into this: if the fold could not read every
    line, the verdict is `unknown` no matter what was found, because an
    unreadable line may be the very record being asked about. A confident answer
    over a partially-read stream is exactly the false-negative this whole design
    exists to prevent.
    """
    answer = {
        "schema": "fm-bridge.lifecycle.v1",
        "id": item_id,
        "folded_at": doc["folded_at"],
        "source": {"ledger": doc["ledger"]["path"], "lines": []},
        "conserved": doc["conserved"],
        "stages": {},
        "verdict": "unknown",
        "absence_explained": False,
        "reason": "",
    }
    item = doc["items"].get(item_id)
    if item is not None:
        answer["source"]["lines"] = item.get("lines", [])
        answer["stages"] = {stage: info["ts"]
                            for stage, info in sorted(item["phases_seen"].items())}
        answer["kind"] = item["kind"]
        answer["state"] = item["state"]

    if not doc["conserved"]:
        answer["reason"] = (
            "%d of %d ledger lines could not be read, so any record for this id "
            "may be among them" % (doc["counts"]["malformed"],
                                   doc["counts"]["lines_considered"]))
        return answer
    if item is None:
        answer["reason"] = ("no record for this id in the ledger; that means "
                            "unknown, not absent - nothing was ever written "
                            "either way")
        return answer

    for stage in reversed(LIFECYCLE_STAGES):
        if stage in item["phases_seen"]:
            answer["verdict"] = stage
            break
    else:
        answer["verdict"] = "recorded"
        answer["reason"] = ("the id exists but carries no lifecycle stage; "
                            "phases seen: %s"
                            % (", ".join(sorted(item["phases_seen"])) or "none"))
        return answer

    if answer["verdict"] == "consumed":
        answer["absence_explained"] = True
        answer["reason"] = ("a durable consumption record exists at ledger line "
                            "%d, so this having vanished from the screen is "
                            "explained" % item["phases_seen"]["consumed"]["line"])
    else:
        answer["reason"] = ("last recorded stage is %s; no consumption record "
                            "exists, so an empty screen means unknown, not absent"
                            % answer["verdict"])
    return answer


def signature(path):
    """Cheap change signature for the skip-when-unchanged tick."""
    try:
        info = os.stat(path)
    except OSError:
        return "absent"
    return "%d:%d" % (info.st_size, int(info.st_mtime))


# --- board -----------------------------------------------------------------
#
# Everything below draws. It is handed the state document and nothing else - it
# has no ledger path and never opens a file.

FRESH_OPEN = "<!--FM-FRESH-->"
FRESH_CLOSE = "<!--/FM-FRESH-->"

# The tokyonight-storm token block from the canonical scaffold in
# ~/code/personal/dotfiles/docs/labs/. The scaffold's DaisyUI/Tailwind CDN layer
# is deliberately NOT reused here: the board is regenerated from disk every few
# minutes and must render identically with no network, so its styling is inlined.
# The palette and the one-meaning-per-accent discipline are unchanged.
CSS = """
:root {
  --tn-bg:#24283b; --tn-panel:#1f2335; --tn-deep:#1a1b26; --tn-fg:#c0caf5;
  --tn-muted:#565f89; --tn-line:#3b4261;
  --tn-blue:#7aa2f7; --tn-purple:#bb9af7; --tn-green:#9ece6a;
  --tn-orange:#ff9e64; --tn-red:#f7768e; --tn-cyan:#7dcfff;
  --tn-dim:color-mix(in srgb, var(--tn-fg) 70%, var(--tn-muted));
}
* { box-sizing:border-box; }
body {
  margin:0; padding:0 0 4rem; background:var(--tn-deep); color:var(--tn-fg);
  font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
}
code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.86em; }
.wrap { max-width:1080px; margin:0 auto; padding:0 1.25rem; }
a { color:var(--tn-cyan); }

header.top { border-bottom:1px solid var(--tn-line); background:var(--tn-bg); padding:1.4rem 0 1rem; }
h1 { margin:0; font-size:1.5rem; letter-spacing:.02em; }
h1 .sub { color:var(--tn-dim); font-weight:400; font-size:.85rem; margin-left:.6rem; }
.fresh { margin-top:.5rem; font-size:.82rem; color:var(--tn-dim); }
.fresh .clock { color:var(--tn-fg); }
.fresh.stale { color:var(--tn-orange); }
.fresh.stale .clock { color:var(--tn-orange); }

.tallies { display:flex; flex-wrap:wrap; gap:.5rem; margin-top:.75rem; }
.tally {
  border:1px solid var(--tn-line); border-radius:.4rem; padding:.3rem .6rem;
  font-size:.8rem; background:var(--tn-panel); min-width:0;
}
.tally b { font-size:1rem; margin-right:.3rem; }
.tally.ask { border-color:var(--tn-red); } .tally.ask b { color:var(--tn-red); }
.tally.fm  { border-color:var(--tn-blue); } .tally.fm b { color:var(--tn-blue); }
.tally.ok  { border-color:var(--tn-green); } .tally.ok b { color:var(--tn-green); }
.tally.warn{ border-color:var(--tn-orange); } .tally.warn b { color:var(--tn-orange); }

section { margin:2rem 0 0; }
h2 {
  font-size:.78rem; text-transform:uppercase; letter-spacing:.13em;
  color:var(--tn-dim); margin:0 0 .1rem; font-weight:600;
}
.zone-note { color:var(--tn-muted); font-size:.78rem; margin:0 0 .8rem; }

.card {
  background:var(--tn-panel); border:1px solid var(--tn-line);
  border-left:3px solid var(--tn-line); border-radius:.5rem;
  padding:.8rem .95rem; margin:0 0 .6rem;
}
.card.needs-captain { border-left-color:var(--tn-red); }
.card.fm-handling   { border-left-color:var(--tn-blue); }
.card.resolved      { border-left-color:var(--tn-green); opacity:.72; }
.card.odd           { border-left-color:var(--tn-orange); }
.card.pinned { background:linear-gradient(90deg,rgba(247,118,142,.09),transparent 60%); }

.head { display:flex; gap:.55rem; align-items:baseline; flex-wrap:wrap; }
.ref {
  color:var(--tn-purple); font-weight:700; font-family:ui-monospace,monospace;
  font-size:.85rem; flex:none;
}
.title { font-weight:600; min-width:0; overflow-wrap:anywhere; }
.chip {
  font-size:.68rem; letter-spacing:.06em; text-transform:uppercase;
  border-radius:.25rem; padding:.1rem .4rem; border:1px solid currentColor;
  white-space:nowrap; flex:none;
}
.chip.needs-captain { color:var(--tn-red); }
.chip.fm-handling   { color:var(--tn-blue); }
.chip.resolved      { color:var(--tn-green); }
.chip.odd           { color:var(--tn-orange); }
.chip.sev           { color:var(--tn-dim); }
.meta { color:var(--tn-dim); font-size:.76rem; margin-top:.3rem; }
.meta .sep { color:var(--tn-line); margin:0 .35rem; }
.body { margin-top:.4rem; color:var(--tn-dim); font-size:.88rem; overflow-wrap:anywhere; }
.pointer { margin-top:.4rem; font-size:.82rem; overflow-wrap:anywhere; }
.pointer .lbl { color:var(--tn-muted); margin-right:.35rem; }

.answers { margin-top:.6rem; display:flex; gap:.4rem; flex-wrap:wrap; align-items:center; }
.answers .lbl { color:var(--tn-muted); font-size:.74rem; margin-right:.15rem; }
button.ans {
  font:inherit; font-size:.82rem; cursor:pointer; color:var(--tn-fg);
  background:var(--tn-deep); border:1px solid var(--tn-line);
  border-radius:.3rem; padding:.25rem .55rem; text-align:left;
}
button.ans:hover { border-color:var(--tn-red); color:var(--tn-red); }
button.ans.picked { border-color:var(--tn-red); color:var(--tn-red); background:rgba(247,118,142,.12); }

.checkline { margin-top:.5rem; font-size:.76rem; color:var(--tn-muted); overflow-x:auto; }
.checkline code { color:var(--tn-cyan); }

table.strip { width:100%; border-collapse:collapse; font-size:.85rem; }
table.strip th {
  text-align:left; font-size:.7rem; text-transform:uppercase; letter-spacing:.09em;
  color:var(--tn-muted); font-weight:600; padding:.3rem .5rem; border-bottom:1px solid var(--tn-line);
}
table.strip td { padding:.42rem .5rem; border-bottom:1px solid rgba(59,66,97,.45); vertical-align:top; }
table.strip td.st { white-space:nowrap; width:1%; }
.stripwrap { overflow-x:auto; border:1px solid var(--tn-line); border-radius:.5rem; background:var(--tn-panel); }

ul.events { list-style:none; margin:0; padding:0; }
ul.events li {
  display:flex; gap:.6rem; padding:.4rem 0; border-bottom:1px solid rgba(59,66,97,.4);
  font-size:.88rem; align-items:baseline;
}
ul.events li .when { color:var(--tn-muted); font-size:.74rem; flex:none; font-family:ui-monospace,monospace; }
ul.events li .what { min-width:0; overflow-wrap:anywhere; }
.overflow { margin-top:.55rem; font-size:.8rem; color:var(--tn-orange); }

.glossary { border:1px dashed var(--tn-line); border-radius:.5rem; padding:.7rem .9rem; background:var(--tn-bg); }
.glossary dl { margin:0; }
.glossary dt { font-weight:600; color:var(--tn-purple); font-size:.85rem; margin-top:.5rem; }
.glossary dt:first-child { margin-top:0; }
.glossary dd { margin:.15rem 0 0 0; font-size:.83rem; color:var(--tn-dim); }
.glossary .collide { color:var(--tn-orange); font-size:.72rem; text-transform:uppercase; letter-spacing:.07em; margin-left:.4rem; }
.local-terms { margin:0 0 .8rem; font-size:.79rem; color:var(--tn-dim); border-left:2px solid var(--tn-purple); padding-left:.6rem; }

#queue {
  position:sticky; top:0; z-index:5; background:var(--tn-bg);
  border-bottom:1px solid var(--tn-line); padding:.6rem 0; display:none;
}
#queue.on { display:block; }
#queue .inner { display:flex; gap:.6rem; align-items:flex-start; }
#queue textarea {
  flex:1 1 auto; min-width:0; min-height:3.4rem; resize:vertical; font-family:ui-monospace,monospace;
  font-size:.82rem; background:var(--tn-deep); color:var(--tn-fg);
  border:1px solid var(--tn-line); border-radius:.4rem; padding:.45rem .55rem;
}
#queue button {
  font:inherit; font-size:.82rem; cursor:pointer; border-radius:.35rem; padding:.4rem .7rem;
  border:1px solid var(--tn-red); background:transparent; color:var(--tn-red); flex:none;
}
#queue button.clear { border-color:var(--tn-line); color:var(--tn-dim); }

.legend { display:flex; flex-wrap:wrap; gap:.9rem; font-size:.76rem; color:var(--tn-dim); margin-top:.6rem; }
.legend span::before {
  content:""; display:inline-block; width:.6rem; height:.6rem; border-radius:.15rem;
  margin-right:.35rem; vertical-align:baseline; background:currentColor;
}
.legend .l-red{color:var(--tn-red);} .legend .l-blue{color:var(--tn-blue);}
.legend .l-green{color:var(--tn-green);} .legend .l-orange{color:var(--tn-orange);}
.legend .l-purple{color:var(--tn-purple);} .legend .l-cyan{color:var(--tn-cyan);}

footer { margin-top:2.5rem; border-top:1px solid var(--tn-line); padding-top:1rem;
         font-size:.78rem; color:var(--tn-muted); }
footer code { color:var(--tn-cyan); }
footer .row { margin:.3rem 0; overflow-x:auto; white-space:nowrap; }
.banner {
  border:1px solid var(--tn-orange); color:var(--tn-orange); background:rgba(255,158,100,.08);
  border-radius:.5rem; padding:.7rem .9rem; margin:1rem 0 0; font-size:.85rem;
}
.banner code { color:var(--tn-orange); }
.empty { color:var(--tn-muted); font-size:.85rem; font-style:italic; }
"""

JS = """
(function () {
  var picks = [];
  var box = document.getElementById('queue');
  var out = document.getElementById('queue-text');
  function redraw() {
    if (!picks.length) { box.className = ''; out.value = ''; return; }
    box.className = 'on';
    out.value = picks.join('\\n');
  }
  document.addEventListener('click', function (event) {
    var button = event.target.closest ? event.target.closest('button.ans') : null;
    if (!button) { return; }
    var line = button.getAttribute('data-line');
    var index = picks.indexOf(line);
    if (index >= 0) { picks.splice(index, 1); button.classList.remove('picked'); }
    else { picks.push(line); button.classList.add('picked'); }
    redraw();
  });
  var copy = document.getElementById('queue-copy');
  if (copy) {
    copy.addEventListener('click', function () {
      out.select();
      try { document.execCommand('copy'); } catch (err) { /* selection still works */ }
      copy.textContent = 'copied';
      setTimeout(function () { copy.textContent = 'copy'; }, 1200);
    });
  }
  var clear = document.getElementById('queue-clear');
  if (clear) {
    clear.addEventListener('click', function () {
      picks = [];
      var picked = document.querySelectorAll('button.ans.picked');
      for (var i = 0; i < picked.length; i++) { picked[i].classList.remove('picked'); }
      redraw();
    });
  }
  // Board freshness IS supervision freshness, so an old check has to look old.
  var fresh = document.getElementById('fm-fresh');
  if (fresh) {
    var checked = Date.parse(fresh.getAttribute('data-checked'));
    if (!isNaN(checked)) {
      var mins = Math.floor((Date.now() - checked) / 60000);
      var rel = document.getElementById('fm-fresh-rel');
      if (rel) { rel.textContent = mins < 1 ? 'just now' : mins + ' min ago'; }
      if (mins >= 10) { fresh.className = 'fresh stale'; }
    }
  }
})();
"""


def esc(text):
    return _html.escape(_text(text), quote=True)


def state_class(item):
    if not item.get("recognized", {}).get("state", True):
        return "odd"
    return item["state"]


def chip(item):
    cls = state_class(item)
    label = item["state"] if cls != "odd" else item["state"] + " ?"
    return '<span class="chip %s">%s</span>' % (cls, esc(label))


def sev_chip(item):
    if item["severity"] in ("normal", ""):
        return ""
    cls = "odd" if not item.get("recognized", {}).get("severity", True) else "sev"
    return '<span class="chip %s">%s</span>' % (cls, esc(item["severity"]))


def meta_line(item):
    bits = ["owner %s" % esc(item["owner"])]
    if item["phase"]:
        bits.append("phase %s" % esc(item["phase"]))
    if item["ts"]:
        bits.append(esc(item["ts"]))
    if item["updates"] > 1:
        bits.append("%d updates" % item["updates"])
    if item["truncated"]:
        bits.append("record truncated at write time")
    return '<div class="meta">%s</div>' % '<span class="sep">|</span>'.join(bits)


def pointer_line(item):
    if not item["pointer"]:
        if item["state"] == "resolved" and item["kind"] in ("decision", "critical"):
            return ('<div class="pointer"><span class="lbl">outcome</span>'
                    '<span style="color:var(--tn-orange)">resolved with no pointer '
                    '- see record hygiene</span></div>')
        return ""
    target = item["pointer"]
    if target.startswith("http://") or target.startswith("https://"):
        shown = '<a href="%s">%s</a>' % (esc(target), esc(target))
    else:
        shown = '<code>%s</code>' % esc(target)
    return '<div class="pointer"><span class="lbl">outcome</span>%s</div>' % shown


def answer_forms(item):
    """The mandatory answer forms. Clicking queues a ready-to-paste ruling."""
    if item["state"] == "resolved" or not item["answers"]:
        return ""
    label = item["ref"] or item["id"]
    buttons = []
    for answer in item["answers"]:
        line = "%s: %s" % (label, answer)
        buttons.append('<button class="ans" type="button" data-line="%s">%s</button>'
                       % (esc(line), esc(answer)))
    return ('<div class="answers"><span class="lbl">answer</span>%s</div>'
            % "".join(buttons))


def check_line(item):
    if not item["check"]:
        return ""
    return '<div class="checkline">check <code>%s</code></div>' % esc(item["check"])


def card(item, pinned=False):
    classes = ["card", state_class(item)]
    if pinned:
        classes.append("pinned")
    ref = '<span class="ref">%s</span>' % esc(item["ref"]) if item["ref"] else ""
    parts = [
        '<div class="%s">' % " ".join(classes),
        '<div class="head">%s<span class="title">%s</span>%s%s</div>'
        % (ref, esc(item["title"] or item["id"]), chip(item), sev_chip(item)),
        meta_line(item),
    ]
    if item["body"]:
        parts.append('<div class="body">%s</div>' % esc(item["body"]))
    if item["note"]:
        parts.append('<div class="body">%s</div>' % esc(item["note"]))
    parts.append(pointer_line(item))
    parts.append(answer_forms(item))
    parts.append(check_line(item))
    parts.append("</div>")
    return "".join(part for part in parts if part)


def freshness_html(checked_at, content_at):
    """One physical line, delimited by markers, so the skip path can restamp it
    without regenerating - and without touching - the body."""
    return ("%s<div class=\"fresh\" id=\"fm-fresh\" data-checked=\"%s\" data-content=\"%s\">"
            "checked <span class=\"clock\">%s</span> "
            "(<span id=\"fm-fresh-rel\">-</span>)"
            "<span class=\"sep\"> &middot; </span>content as of "
            "<span class=\"clock\">%s</span></div>%s"
            % (FRESH_OPEN, esc(checked_at), esc(content_at),
               esc(checked_at), esc(content_at), FRESH_CLOSE))


def render_html(doc, checked_at):
    items = doc["items"]
    zones = doc["zones"]
    caps = doc["caps"]
    counts = doc["counts"]
    summary = doc["summary"]
    out = []
    add = out.append

    add("<!doctype html>")
    add('<html lang="en"><head><meta charset="utf-8">')
    add('<meta name="viewport" content="width=device-width,initial-scale=1">')
    add("<title>Bridge</title>")
    add("<style>%s</style></head><body>" % CSS)

    add('<div id="queue"><div class="wrap"><div class="inner">')
    add('<textarea id="queue-text" spellcheck="false" '
        'aria-label="queued rulings"></textarea>')
    add('<button id="queue-copy" type="button">copy</button>')
    add('<button id="queue-clear" class="clear" type="button">clear</button>')
    add("</div></div></div>")

    add('<header class="top"><div class="wrap">')
    add('<h1>Bridge<span class="sub">fleet state, generated from the ledger</span></h1>')
    add(freshness_html(checked_at, doc["folded_at"]))
    add('<div class="tallies">')
    add('<div class="tally ask"><b>%d</b>need you</div>' % summary.get("needs-captain", 0))
    add('<div class="tally fm"><b>%d</b>firstmate has</div>' % summary.get("fm-handling", 0))
    add('<div class="tally ok"><b>%d</b>resolved</div>' % summary.get("resolved", 0))
    if summary.get("unrecognized", 0):
        add('<div class="tally warn"><b>%d</b>unrecognized state</div>'
            % summary["unrecognized"])
    add('<div class="tally"><b>%d</b>records folded</div>' % counts["records"])
    add("</div>")
    add('<div class="legend">'
        '<span class="l-red">needs you</span>'
        '<span class="l-blue">firstmate has it</span>'
        '<span class="l-green">resolved</span>'
        '<span class="l-orange">something is off</span>'
        '<span class="l-purple">project / ref</span>'
        '<span class="l-cyan">pointer or command</span>'
        "</div>")
    add("</div></header>")

    add('<div class="wrap">')

    # Conservation is reported on the surface, not just in the data. A fold that
    # goes key-blind stops adding up here, in public, on the next tick.
    if not doc["conserved"] or counts["malformed"]:
        add('<div class="banner"><b>Ledger records not accounted for.</b> '
            "%d non-blank lines, %d folded, %d unreadable. "
            "The board can only show what the fold could read."
            % (counts["lines_considered"], counts["records"], counts["malformed"]))
        for bad in doc["malformed"][:5]:
            add('<div class="row"><code>line %d: %s</code></div>'
                % (bad["line"], esc(bad["reason"])))
        if doc["malformed_omitted"]:
            add("<div>+%d more unreadable lines.</div>" % doc["malformed_omitted"])
        add("</div>")
    if not doc["ledger"]["present"]:
        add('<div class="banner">No ledger at <code>%s</code> yet. '
            "The board is empty because nothing has been written, not because "
            "nothing happened.</div>" % esc(doc["ledger"]["path"]))

    collisions = [g for g in doc["glossary"] if g["collision"]]
    if collisions:
        add("<section><h2>Terms that mean different things by project</h2>")
        add('<p class="zone-note">Defined here once, and repeated in each project '
            "section below so you never scroll back.</p>")
        add('<div class="glossary"><dl>')
        for entry in collisions:
            add("<dt>%s<span class=\"collide\">collision</span></dt>" % esc(entry["term"]))
            for sub in entry["entries"]:
                add("<dd><b>%s</b>: %s</dd>" % (esc(sub["project"]), esc(sub["means"])))
        add("</dl></div></section>")

    # Zone 1 - pinned criticals.
    add("<section><h2>Pinned criticals</h2>")
    add('<p class="zone-note">Security, data loss, fleet blocked, or anything '
        "outward-facing that looks wrong. These stay pinned until resolved.</p>")
    if zones["criticals"]:
        for key in zones["criticals"]:
            add(card(items[key], pinned=True))
    else:
        add('<p class="empty">Nothing pinned.</p>')
    for key in zones["criticals_resolved"][:caps["resolved_decisions"]]:
        add(card(items[key]))
    add("</section>")

    # Zone 2 - decisions, grouped by project, with per-project refs.
    add("<section><h2>Decisions</h2>")
    add('<p class="zone-note">Grouped by project. A ref like <b>O1</b> is unique '
        "to its project and never renumbers, so a bare number is safe to quote. "
        "Only the red ones are asks.</p>")
    if not zones["decisions"]:
        add('<p class="empty">No decisions on the board.</p>')
    for group in zones["decisions"]:
        add("<h3 style=\"margin:1.2rem 0 .1rem;font-size:.95rem;color:var(--tn-purple)\">"
            "%s <span style=\"color:var(--tn-muted);font-weight:400;font-size:.8rem\">"
            "refs %s1, %s2, &hellip;</span></h3>"
            % (esc(group["project"]), esc(group["prefix"]), esc(group["prefix"])))
        local = [g for g in doc["glossary"]
                 if any(sub["project"] == group["project"] for sub in g["entries"])]
        if local:
            bits = []
            for entry in local:
                means = next(sub["means"] for sub in entry["entries"]
                             if sub["project"] == group["project"])
                bits.append("<b>%s</b> here means %s" % (esc(entry["term"]), esc(means)))
            add('<p class="local-terms">%s</p>' % "; ".join(bits))
        if not group["open"] and not group["resolved"]:
            add('<p class="empty">Nothing open.</p>')
        for key in group["open"]:
            add(card(items[key]))
        shown = group["resolved"][:caps["resolved_decisions"]]
        for key in shown:
            add(card(items[key]))
        hidden = len(group["resolved"]) - len(shown)
        if hidden > 0:
            add('<div class="overflow">+%d more resolved in %s - the record has them: '
                '<code>%s</code></div>'
                % (hidden, esc(group["project"]), esc(doc["checks"]["raw stream"])))
    add("</section>")

    # Zone 3 - notable events, capped, overflowing to the record.
    add("<section><h2>Notable events</h2>")
    add('<p class="zone-note">Newest first, capped. Nothing here is an ask.</p>')
    shown_events = zones["events"][:caps["events"]]
    if shown_events:
        add('<ul class="events">')
        for key in shown_events:
            item = items[key]
            add('<li><span class="when">%s</span><span class="what">%s %s</span></li>'
                % (esc((item["ts"] or "")[:16].replace("T", " ")),
                   esc(item["title"] or item["id"]),
                   chip(item) if item["state"] != "resolved" else ""))
        add("</ul>")
    else:
        add('<p class="empty">No events recorded.</p>')
    hidden = len(zones["events"]) - len(shown_events)
    if hidden > 0:
        add('<div class="overflow">+%d older events. They are not lost - the record '
            'has every one: <code>%s</code></div>'
            % (hidden, esc(doc["checks"]["raw stream"])))
    add("</section>")

    # Zone 4 - the fleet strip.
    add("<section><h2>Fleet</h2>")
    add('<p class="zone-note">Every task firstmate is carrying. Red rows are '
        "waiting on you.</p>")
    rows = zones["fleet_open"] + zones["fleet_resolved"][:caps["fleet_resolved"]]
    if rows:
        add('<div class="stripwrap"><table class="strip">')
        add("<tr><th>task</th><th>project</th><th>phase</th><th>state</th>"
            "<th>where it is</th></tr>")
        for key in rows:
            item = items[key]
            target = item["pointer"]
            if target.startswith("http"):
                where = '<a href="%s">%s</a>' % (esc(target), esc(target))
            elif target:
                where = "<code>%s</code>" % esc(target)
            else:
                where = '<span style="color:var(--tn-muted)">-</span>'
            add("<tr><td><b>%s</b></td><td>%s</td><td>%s</td><td class=\"st\">%s</td>"
                "<td>%s</td></tr>"
                % (esc(item["title"] or item["id"]), esc(item["project"]),
                   esc(item["phase"] or "-"), chip(item), where))
        add("</table></div>")
    else:
        add('<p class="empty">No tasks on the board.</p>')
    hidden = len(zones["fleet_resolved"]) - len(zones["fleet_resolved"][:caps["fleet_resolved"]])
    if hidden > 0:
        add('<div class="overflow">+%d older landed tasks in the record.</div>' % hidden)
    add("</section>")

    if zones["unzoned"]:
        add("<section><h2>Unrecognized records</h2>")
        add('<p class="zone-note">These carry a kind this board does not know. '
            "They are shown rather than filed somewhere convenient, because a "
            "record quietly placed in the wrong bucket is how a surface starts "
            "lying.</p>")
        for key in zones["unzoned"]:
            add(card(items[key]))
        add("</section>")

    add("<footer>")
    add("<div><b>Check this board against its own source.</b></div>")
    for label in sorted(doc["checks"]):
        add('<div class="row">%s &nbsp; <code>%s</code></div>'
            % (esc(label), esc(doc["checks"][label])))
    add('<div class="row" style="margin-top:.8rem">ledger &nbsp; <code>%s</code></div>'
        % esc(doc["ledger"]["path"]))
    steering = doc.get("substrate", {}).get("steering", {})
    if steering.get("items"):
        stages = steering.get("stages", {})
        add("<div>%d steering-lifecycle records are in the record but not on this "
            "board - they are machinery, not something for you to read "
            "(sent %d, delivered %d, consumed %d). Ask about one with "
            "<code>bin/fm-bridge-render.sh --lifecycle &lt;id&gt;</code>.</div>"
            % (steering["items"], stages.get("sent", 0),
               stages.get("delivered", 0), stages.get("consumed", 0)))
    add("<div class=\"row\">This page is generated. Edits to it are overwritten on "
        "the next tick; facts belong in the ledger.</div>")
    add("</footer></div>")

    # The exact state document this board was drawn from rides along, so the
    # board can be audited without trusting the renderer.
    add('<script type="application/json" id="fm-bridge-state">')
    add(state_json(doc))
    add("</script>")
    add("<script>%s</script>" % JS)
    add("</body></html>")
    return "\n".join(out) + "\n"


def state_json(doc):
    return json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False)


def restamp(board_path, checked_at):
    """Skip path: rewrite ONLY the marked freshness line, leaving every other
    byte of the board untouched."""
    with open(board_path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()
    hit = False
    for index, line in enumerate(lines):
        if FRESH_OPEN not in line:
            continue
        content_at = ""
        marker = 'data-content="'
        start = line.find(marker)
        if start >= 0:
            start += len(marker)
            end = line.find('"', start)
            if end > start:
                content_at = _html.unescape(line[start:end])
        newline = "\n" if line.endswith("\n") else ""
        lines[index] = freshness_html(checked_at, content_at) + newline
        hit = True
        break
    if not hit:
        return 1
    tmp = board_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
    os.replace(tmp, board_path)
    return 0


def main(argv):
    mode = argv[1]
    if mode == "state":
        doc = fold(argv[2], argv[3])
        if len(argv) > 4 and argv[4]:
            doc = narrow(doc, argv[4])
        sys.stdout.write(state_json(doc) + "\n")
        return 0
    if mode == "lifecycle":
        doc = fold(argv[2], argv[3])
        sys.stdout.write(json.dumps(lifecycle(doc, argv[4]), indent=2,
                                    sort_keys=True, ensure_ascii=False) + "\n")
        return 0
    if mode == "html":
        # ONE fold, shared in-process: render_html consumes the return value
        # directly. It is handed no path and opens no file, so the drawing half
        # cannot become a second reader of the stream.
        doc = fold(argv[2], argv[3])
        sys.stdout.write(render_html(doc, argv[4]))
        return 0
    if mode == "restamp":
        return restamp(argv[2], argv[3])
    if mode == "signature":
        sys.stdout.write(signature(argv[2]) + "\n")
        return 0
    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
  printf '%s' "$PROGRAM"
}

cleanup() { [ -n "$PROGRAM" ] && rm -f "$PROGRAM"; }
trap cleanup EXIT

require_python() {
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to fold the ledger; refusing to render a board that would look empty"
}

# The single seam every consumer goes through.
emit_state() {  # <folded-at> [id]
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  python3 "$prog" state "$(fm_bridge_ledger_path)" "$1" "${2:-}"
}

emit_lifecycle() {  # <folded-at> <id>
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  python3 "$prog" lifecycle "$(fm_bridge_ledger_path)" "$1" "$2"
}

emit_html() {  # <folded-at> <checked-at>
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  # One process, one fold, shared in-process with the renderer.
  python3 "$prog" html "$(fm_bridge_ledger_path)" "$1" "$2"
}

ledger_signature() {
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  python3 "$prog" signature "$(fm_bridge_ledger_path)"
}

write_board() {  # <folded-at> <checked-at>
  local board tmp
  board=$(fm_bridge_board_path)
  mkdir -p "$(dirname "$board")" || return 1
  tmp="$board.tmp.$$"
  emit_html "$1" "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$board" || { rm -f "$tmp"; return 1; }
  return 0
}

# --- the supervision-cycle tick --------------------------------------------
#
# Zero model involvement, and no model is ever woken to update the Bridge.
# When the ledger has not changed, the body is NOT regenerated - only the
# marked freshness line is restamped, because board freshness is how the captain
# reads supervision freshness and a frozen clock would be indistinguishable from
# a dead cycle.
do_tick() {
  local verbose=$1 now sig prev board rc
  require_python
  now=$(fm_bridge_now)
  board=$(fm_bridge_board_path)
  sig=$(ledger_signature)
  prev=$(cat "$STAMP" 2>/dev/null || true)

  if [ "$sig" = "$prev" ] && [ -f "$board" ]; then
    local prog
    prog=$(program_path) || die "cannot stage the fold program"
    if python3 "$prog" restamp "$board" "$now"; then
      [ "$verbose" -eq 1 ] && printf 'bridge: unchanged; restamped %s\n' "$board"
      return 0
    fi
    # The marker is missing (hand-edited or an older board): fall through to a
    # full render rather than leaving a board nobody can date.
  fi

  write_board "$now" "$now" || return 1
  rc=$?
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s' "$sig" > "$STAMP" 2>/dev/null || true
  [ "$verbose" -eq 1 ] && printf 'bridge: rendered %s\n' "$board"
  return $rc
}

MODE=html
VERBOSE=0
OUT=
ITEM_ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --state) MODE=state; shift ;;
    --html) MODE=html; shift ;;
    --tick) MODE=tick; shift ;;
    --write) MODE=write; shift ;;
    --path) MODE=path; shift ;;
    --ledger-path) MODE=ledger-path; shift ;;
    --id) [ $# -gt 1 ] || die "--id needs an item id"; ITEM_ID=$2; shift 2 ;;
    --lifecycle)
      [ $# -gt 1 ] || die "--lifecycle needs an item id"
      MODE=lifecycle; ITEM_ID=$2; shift 2 ;;
    --out) [ $# -gt 1 ] || die "--out needs a path"; OUT=$2; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

NOW=$(fm_bridge_now)
case "$MODE" in
  path) fm_bridge_board_path; echo ;;
  ledger-path) fm_bridge_ledger_path; echo ;;
  state)
    require_python
    if [ -n "$OUT" ]; then
      emit_state "$NOW" "$ITEM_ID" > "$OUT"
    else
      emit_state "$NOW" "$ITEM_ID"
    fi
    ;;
  lifecycle)
    require_python
    if [ -n "$OUT" ]; then
      emit_lifecycle "$NOW" "$ITEM_ID" > "$OUT"
    else
      emit_lifecycle "$NOW" "$ITEM_ID"
    fi
    ;;
  html)
    require_python
    if [ -n "$OUT" ]; then emit_html "$NOW" "$NOW" > "$OUT"; else emit_html "$NOW" "$NOW"; fi
    ;;
  write)
    require_python
    write_board "$NOW" "$NOW" || die "could not write the board"
    printf '%s\n' "$(fm_bridge_board_path)"
    ;;
  tick) do_tick "$VERBOSE" ;;
esac
