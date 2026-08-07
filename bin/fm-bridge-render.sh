#!/usr/bin/env bash
# fm-bridge-render.sh - the READER half of the Bridge: the ONE authoritative
# fold over the ledger, exposed in several output shapes.
#
#   fm-bridge-render.sh --state            folded current state, as structured JSON
#   fm-bridge-render.sh --state --id ID    the same fold, narrowed to one item
#   fm-bridge-render.sh --lifecycle ID     typed answer to "what happened to ID?"
#   fm-bridge-render.sh --html             the HTML board, on stdout
#   fm-bridge-render.sh --history          the HTML history page, on stdout
#   fm-bridge-render.sh --write            render both pages to their canonical paths
#   fm-bridge-render.sh --tick             the supervision-cycle entry point
#   fm-bridge-render.sh --path             print the canonical board path
#   fm-bridge-render.sh --history-path     print the canonical history path
#   fm-bridge-render.sh --ledger-path      print the canonical ledger path
#
# --out PATH sends any output shape to a file instead of stdout, and --verbose
# (-v) makes --tick report whether it re-rendered the board or left it alone.
#
# TWO PAGES, ONE SURFACE
# The board is the captain's ACTION surface: open asks, the co-captain line,
# lanes in flight, admission. Nothing else - resolved, landed, discarded,
# events, tallies and legends are absent from it rather than collapsed, because
# a collapsed section is still a row of chrome above the next decision. All of
# that lives on the history page, which is a second output of the same fold and
# is written in the same pass, so the two can never be readings of different
# records. docs/verification/bridge-board-v2.md states the six rendering laws
# in full and is the durable home of that contract.
#
# The board also draws live readings the ledger does not carry - lanes in
# flight, and the admission denominators. Those are collected BESIDE the fold
# and handed to the renderer as a second document; they never enter `--state`,
# which stays a pure function of the ledger for the linter, the co-captain's
# audit and every lifecycle query.
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
# that one result: `render_html(doc)` is handed the fold's return
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
# Resolved exactly as every other firstmate script resolves it, including the
# FM_ROOT_OVERRIDE fallback. Resolving it any other way would let this script's
# state dir point at a different home than its caller's - so a secondmate's
# board and its supervision cycle could end up reading different homes.
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STAMP="$STATE_DIR/.bridge-render"

usage() { sed -n '2,76p' "$0" | sed 's/^# \{0,1\}//'; }

die() { printf 'fm-bridge-render: %s\n' "$1" >&2; exit 1; }

# --- the one embedded program ----------------------------------------------
# Written to a temp file once per invocation so both modes run the SAME bytes.
#
# STAGE IT IN THE CALLER'S OWN SHELL, NEVER THROUGH COMMAND SUBSTITUTION. This
# used to be a `program_path()` whose callers read it as `prog=$(program_path)`,
# and the substitution is a subshell: the assignment to PROGRAM landed in a
# process that then exited, so the parent's PROGRAM stayed empty. Two things
# followed from that one fact, and both were invisible - every call re-staged a
# fresh ~90KB file because the memo was never seen, and the EXIT trap below
# found nothing to remove because it reads the same empty variable. A single
# home leaked 6,972 files and 600 MiB over two days of supervision ticks.
#
# So the contract is: stage_program is called from the top-level shell, sets
# PROGRAM there, and every consumer reads "$PROGRAM". A consumer may then be
# called from inside a substitution safely, because by then there is nothing
# left to assign.
PROGRAM=
stage_program() {
  [ -n "$PROGRAM" ] && return 0
  local staged
  staged=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-prog.XXXXXX.py") || return 1
  cat > "$staged" <<'PY'
"""Bridge fold, targeted queries, and board renderer.

argv[1] selects the mode. Every mode that produces output folds exactly ONCE and
hands that one result to whatever shapes it:

  state     <ledger> <folded-at> [id]      the fold, whole or narrowed to one item
  lifecycle <ledger> <folded-at> <id>      typed answer about one item's lifecycle
  html      <ledger> <folded-at>           folds once, then render_html(doc)
  signature <ledger>                       content signature of the ledger, for the tick

render_html takes the fold's RETURN VALUE and no ledger path, so the drawing
half cannot re-read or re-parse the stream.
"""
import hashlib
import html as _html
import json
import os
import re
import sys

# The two rendered pages, by the basenames the board and the history page link
# each other with. Overridden from argv so an override that moves the board
# moves the link with it - see fm_bridge_history_path in bin/fm-bridge-lib.sh.
BOARD_FILENAME = "bridge.html"
HISTORY_FILENAME = "history.html"

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

# TWO AXES, AND NO RANKING BETWEEN THEM.
#
# `state` answers WHO OWES THIS. `outcome` answers HOW IT ENDED. They are
# independent questions with independent answers: work can end with nobody
# owing it (merged, then cleaned up), and a ruling can still be owed on work
# that no longer exists (discarded mid-review). Collapsing them into one value
# is how a merged task came to read as thrown away and a discarded one came to
# read as a live ask - the same fact wearing two hats, with a reader picking
# which hat wins.
#
# So nothing here ranks them. Where a definition needs both, it says so as a
# CONJUNCTION of independently necessary conditions - an ask is "someone owes a
# decision" AND "the work is still live", and either condition alone can
# disqualify without overriding the other.
KNOWN_OUTCOMES = ("in-flight", "landed", "discarded", "unknown")
IN_FLIGHT = "in-flight"
# The endings. `unknown` is one of them: it means the work ended and nobody
# could tell how, which is a different claim from "still going".
ENDED_OUTCOMES = ("landed", "discarded", "unknown")

# The schema version at which a writer gained the outcome vocabulary. Below it,
# a record's silence on the axis says nothing at all; at or above it, silence is
# the writer declining to report an ending it could have reported.
OUTCOME_AXIS_VERSION = 2

# Where an item's outcome came from. A reader has to be able to tell a value the
# ledger stated from one this fold worked out, and a legitimate in-flight from a
# row that predates the axis entirely - which is why this is four values and not
# a boolean.
#   observed    - a record stated it
#   backfilled  - derived from evidence in the item's own history, named in
#                 `outcome_evidence`
#   unstated    - a writer that HAD the vocabulary said nothing, so nothing has
#                 been observed to end
#   unobserved  - every writer predates the axis and no evidence resolves it, so
#                 the honest value is `unknown`
OUTCOME_SOURCES = ("observed", "backfilled", "unstated", "unobserved")


def owed_by(item):
    """The state axis alone: who owes something on this, whatever became of it."""
    return item["state"]


def ended(item):
    """The outcome axis alone: has the work been OBSERVED to stop?

    Observed is the load-bearing word, and it is why this is not just
    `outcome != in-flight`. `unknown` reaches an item two ways that look
    identical in the value and are opposite in what they license:

      a cleanup ran and could not tell how the work ended - the ending WAS
      observed, only its manner was not, so there is nothing left to decide;

      every record for the item predates the outcome axis - NOTHING was
      observed, so the fold knows neither that it ended nor that it is running.

    Retiring an ask on the second one would silently empty the captain's queue
    of everything written before this axis existed - the missing-alarm failure
    this whole surface is built to prevent, dressed as tidiness. An unrecognized
    value is treated the same way, because a value the fold cannot read is not
    an observation either.
    """
    if item["outcome"] in ("landed", "discarded"):
        return True
    if item["outcome"] == "unknown":
        return item["outcome_source"] in ("observed", "backfilled")
    return False


def resolve_outcome(item):
    """Fill the outcome axis for an item that never stated one, from EVIDENCE.

    THE RULE, and the reason for it: five rounds of rows were written before
    this axis existed, by writers that had no way to say how work ended.
    Reading their silence as `in-flight` would assert that all of it is still
    running - a claim, applied in bulk, in a field built to be authoritative.
    A blanket default is a translation table with one row, and it is worse than
    an explicit one because it is invisible at the call site.

    So absence is read against what the WRITER could say, which the record
    itself records as `v`:

      v >= 2 and silent  ->  the writer had the vocabulary and used none of it.
                             Nothing has been observed to end: `in-flight`.
      v <  2, or no v    ->  the writer could not have said. Silence carries no
                             information, so the value is `unknown` unless
                             evidence in the item's own history resolves it.

    Evidence, and only evidence, may populate a value. The one that exists in
    old data is a `merged` phase recorded together with a pointer to where it
    landed - a merge is an observation of an ending, and the pointer is where
    that ending lives. A recorded landed-test verdict arrives as a stated
    outcome and is therefore `observed`, not backfilled.

    AND THE ONE THAT MATTERS MOST: an old `phase=discarded` is NOT evidence of
    a discard and never maps to one. That phase is precisely the ambiguous
    field the two axes exist to split - it was written both for genuinely
    unlanded work and for merged work whose worktree was force-cleaned, and the
    record cannot say which. Laundering it into `outcome=discarded` would dress
    the old ambiguity in the new axis's confidence. Such an item is `unknown`.
    """
    if item["outcome"]:
        item["outcome_source"] = "observed"
        return
    if "merged" in item["phases_seen"] and item["pointer"]:
        item["outcome"] = "landed"
        item["outcome_source"] = "backfilled"
        item["outcome_evidence"] = (
            "a merged phase recorded at ledger line %d, with a pointer to where "
            "it landed" % item["phases_seen"]["merged"]["line"])
        return
    if item["schema_version_max"] >= OUTCOME_AXIS_VERSION:
        item["outcome"] = IN_FLIGHT
        item["outcome_source"] = "unstated"
        return
    item["outcome"] = "unknown"
    item["outcome_source"] = "unobserved"
    item["outcome_evidence"] = (
        "every record for this item predates the outcome axis (schema v%s), so "
        "its silence says nothing about how the work ended"
        % (item["schema_version_max"] or "unversioned"))
# `needs-cocaptain` is a ROUTING target, not a second flavour of "open". An
# item addressed to the co-captain (the dotfiles session, which reads this
# ledger directly) never joins the captain's ask list, because the cost being
# avoided is the captain's attention: a machine-config item once sat on their
# queue all day when its whole resolution was one reader away.
KNOWN_STATES = ("needs-captain", "needs-cocaptain", "fm-handling", "resolved")
KNOWN_SEVERITIES = ("critical", "high", "normal", "low")
SEVERITY_RANK = {"critical": 0, "high": 1, "normal": 2, "low": 3}
STATE_RANK = {"needs-captain": 0, "needs-cocaptain": 1, "fm-handling": 2, "resolved": 3}

# Which disposition puts an item on which reader's queue.
READER_STATE = {"captain": "needs-captain", "cocaptain": "needs-cocaptain",
                "firstmate": "fm-handling"}

# Fields this fold understands. Anything else survives under "extra" - an
# unrecognized field is never a reason to drop or ignore a record.
KNOWN_FIELDS = frozenset((
    "v", "ts", "id", "kind", "project", "state", "outcome", "severity", "owner",
    "title", "body", "pointer", "check", "note", "phase", "answers",
    "truncated",
))

# Every position the fold key has ever occupied, in priority order. The reader
# looks in all of them forever; the writer only ever emits the first.
ID_ALIASES = ("id", "key", "item_id", "itemId")

# Merge-able scalar fields: a later record's present value replaces the earlier.
SCALARS = ("kind", "project", "state", "outcome", "severity", "owner", "title",
           "body", "pointer", "check", "note", "phase")

MAX_MALFORMED_SHOWN = 25
MAX_RAW_ECHO = 240

# An ask older than this is called out as aging. The captain's evidence for why:
# eight captain-kind items sitting queued, two of them already ruled and never
# closed. Nothing about "open" distinguishes those two from the other six - only
# age does.
AGING_SECONDS = int(os.environ.get("FM_BRIDGE_AGING_SECONDS", str(24 * 3600)))

# Presentation caps. Named here so the state document can publish them and the
# board can show the overflow pointer rather than truncating silently.
CAP_EVENTS = int(os.environ.get("FM_BRIDGE_CAP_EVENTS", "12"))
CAP_RESOLVED_DECISIONS = int(os.environ.get("FM_BRIDGE_CAP_RESOLVED_DECISIONS", "3"))
CAP_FLEET_CLOSED = int(os.environ.get("FM_BRIDGE_CAP_FLEET_CLOSED", "6"))


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


# RECOMMENDER ATTRIBUTION, in the answer text itself.
#
# An answer form may end with a `[rec: worker]`, `[rec: fm]` or
# `[rec: worker+fm]` marker naming who recommends it. The fold splits it out so
# every consumer reads one parse, and the board renders it as a muted chip.
#
# MORE THAN ONE ANSWER MAY CARRY ONE, AND NOTHING HERE COLLAPSES THAT. When the
# worker and firstmate recommend different options, the disagreement is the
# single most useful thing on the card - the captain is being asked precisely
# because two readings exist. A fold that picked a winner would delete the
# reason the question reached them.
#
# The recommender token is preserved VERBATIM, whatever it says. This fold never
# defaults an unrecognized value into a known bucket, and a recommender is no
# exception: an unfamiliar name renders as itself rather than being dropped.
REC_MARKER = re.compile(r"\s*[\[(]\s*rec:\s*([^\])]+?)\s*[\])]\s*$", re.IGNORECASE)
# The option's own label - the letter the captain quotes back. Written by the
# writer as "A: ...", and where a form carries none the fold supplies the
# position, because a queued ruling has to name something.
ANSWER_LABEL = re.compile(r"^\s*([A-Za-z0-9]{1,3})\s*[:.)]\s+")


def _answer_forms(answers):
    """Answer strings, split into label, body and recommender."""
    forms = []
    for position, answer in enumerate(answers):
        text = _text(answer)
        rec = ""
        marked = REC_MARKER.search(text)
        if marked:
            rec = marked.group(1).strip()
            text = text[:marked.start()].rstrip()
        labelled = ANSWER_LABEL.match(text)
        if labelled:
            label = labelled.group(1)
            body = text[labelled.end():].strip()
        else:
            label = chr(ord("A") + position) if position < 26 else str(position + 1)
            body = text
        forms.append({"label": label, "body": body, "text": text, "rec": rec})
    return forms


def _epoch(stamp):
    """RFC3339 UTC to epoch seconds, or None when unparseable. Never raises: a
    malformed timestamp must cost an age label, not the whole fold."""
    import calendar
    import time
    text = _text(stamp).strip()
    if not text:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return calendar.timegm(time.strptime(text, fmt))
        except ValueError:
            continue
    return None


def _age_seconds(stamp, now_epoch):
    then = _epoch(stamp)
    if then is None or now_epoch is None:
        return None
    return max(0, now_epoch - then)


def _age_label(seconds):
    """Deliberately coarse. The reader needs "this has been sitting for days",
    not a duration to the second."""
    if seconds is None:
        return "age unknown"
    if seconds < 90 * 60:
        return "%dm" % max(1, seconds // 60)
    if seconds < 36 * 3600:
        return "%dh" % (seconds // 3600)
    return "%dd" % (seconds // 86400)


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
                        "kind": "", "project": "", "state": "", "outcome": "",
                        "severity": "",
                        "owner": "", "title": "", "body": "", "pointer": "",
                        "check": "", "note": "", "phase": "",
                        "answers": [],
                        "truncated": False,
                        "first_ts": ts,
                        "ts": ts,
                        "state_since": ts,
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
                        # Highest schema version any record for this item was
                        # written at, as a number. It is what tells silence on
                        # the outcome axis apart from a writer that had no way
                        # to speak it.
                        "schema_version_max": 0,
                        "outcome_source": "",
                        "outcome_evidence": "",
                        "extra": {},
                        "schema_versions": [],
                    }
                    items[key] = item
                    order.append(key)

                # When the disposition last CHANGED, not when the item was last
                # touched. An ask that has been waiting three days must be able
                # to say so: age measured from the last unrelated update would
                # make a long-forgotten ask look fresh, which is the exact way
                # these get scrolled past and lost.
                if "state" in obj:
                    new_state = _text(obj["state"])
                    if new_state != item["state"]:
                        item["state_since"] = ts or item.get("state_since", "")
                elif not item.get("state_since"):
                    item["state_since"] = ts

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
                try:
                    numeric_version = int(version)
                except (TypeError, ValueError):
                    numeric_version = 0
                if numeric_version > item["schema_version_max"]:
                    item["schema_version_max"] = numeric_version

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
            "outcome": item["outcome"] in KNOWN_OUTCOMES,
            "severity": item["severity"] in KNOWN_SEVERITIES,
        }
        stated_outcome = bool(item["outcome"])
        resolve_outcome(item)
        if not stated_outcome:
            item["recognized"]["outcome"] = item["outcome"] in KNOWN_OUTCOMES
        if not item["kind"]:
            # An outcome is only ever recorded about work, so a kind-less record
            # that carries one folds to a task rather than to the generic event
            # default - it belongs on the fleet strip, where a reader looks for
            # what happened to a task.
            item["kind"] = "task" if ended(item) else "event"
            item["recognized"]["kind"] = True
            item["defaulted_kind"] = True
        if not item["state"] and ended(item):
            # DELIBERATELY NO DEFAULT. Every value in the state set would be a
            # claim about who owes something, and work that ended without any
            # record of who owed it supports none of them. The fold reports the
            # state axis as unstated rather than picking the one that reads
            # best; the outcome axis still says how the work ended, which is the
            # question a reader of a finished item is actually asking.
            item["recognized"]["state"] = False
        elif not item["state"]:
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
            item["owner"] = {"needs-captain": "captain",
                             "needs-cocaptain": "cocaptain"}.get(item["state"], "firstmate")
        # ONE PREDICATE FOR ONE RULE. The board draws this warning and
        # bin/fm-bridge.sh's lint reports it; when each spelled the rule for
        # itself they disagreed about which axis it tested, so the fold states
        # it once and both read the same field. The phrase names the axis that
        # actually triggered, because "resolved" and "landed" are answers to
        # different questions.
        # Published, not left to be re-derived. Every consumer that needs to
        # know whether the work has been observed to end - the board, the
        # linter, the co-captain's audit - reads this one answer, because a
        # second spelling of it is how two readers of one fact drift apart.
        item["ended"] = ended(item)
        item["pointer_gap"] = ""
        if item["kind"] in ("decision", "critical") and not item["pointer"]:
            closed_by = []
            if item["state"] == "resolved":
                closed_by.append("state resolved")
            if item["outcome"] == "landed":
                closed_by.append("outcome landed")
            if closed_by:
                item["pointer_gap"] = " and ".join(closed_by)
        if not item["project"]:
            item["project"] = "fleet"
        # Parsed once, here, so the board, the history page and any other
        # consumer read one split rather than each writing a second parser of
        # the same string.
        item["answer_forms"] = _answer_forms(item["answers"])

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

    def triage(key):
        item = items[key]
        return (STATE_RANK.get(owed_by(item), 3),
                SEVERITY_RANK.get(item["severity"], 4),
                -index[key])

    # Every zone that means "still here" is the outcome axis saying the work has
    # not ended; every zone that means "over" is the outcome axis saying how it
    # ended. No key mixes two endings, because a reader auditing `landed` must
    # never find thrown-away work under it - and the state axis stays visible on
    # each row rather than being folded into which list the row sits in.
    def by_outcome(kind, outcome):
        return sorted([k for k in order if items[k]["kind"] == kind
                       and items[k]["outcome"] == outcome],
                      key=recency, reverse=True)

    criticals = [k for k in order if items[k]["kind"] == "critical"
                 and not ended(items[k])]
    criticals.sort(key=triage)
    criticals_landed = by_outcome("critical", "landed")
    criticals_discarded = by_outcome("critical", "discarded")
    criticals_unknown = [k for k in order if items[k]["kind"] == "critical"
                         and ended(items[k])
                         and items[k]["outcome"] not in ("landed", "discarded")]
    criticals_unknown.sort(key=recency, reverse=True)

    decisions = []
    for project in projects:
        slug = project["slug"]
        keys = [k for k in order
                if items[k]["kind"] == "decision" and items[k]["project"] == slug]
        if not keys:
            continue
        open_keys = sorted([k for k in keys if not ended(items[k])], key=triage)
        landed_keys = sorted([k for k in keys if items[k]["outcome"] == "landed"],
                             key=recency, reverse=True)
        discarded_keys = sorted([k for k in keys if items[k]["outcome"] == "discarded"],
                                key=recency, reverse=True)
        unknown_keys = sorted([k for k in keys if ended(items[k])
                               and items[k]["outcome"] not in ("landed", "discarded")],
                              key=recency, reverse=True)
        decisions.append({
            "project": slug,
            "prefix": project["prefix"],
            "open": open_keys,
            "landed": landed_keys,
            "discarded": discarded_keys,
            "unknown": unknown_keys,
        })

    events = sorted([k for k in order if items[k]["kind"] == "event"],
                    key=recency, reverse=True)
    # Three fleet groups, because thrown-away work is neither open nor landed.
    # Open work is uncapped - all of it has to be listed - while landed and
    # discarded work is capped with a visible overflow pointer, so a rare
    # forced discard cannot grow into a permanent wall of rows on the surface
    # the captain reads first.
    fleet_open = sorted([k for k in order if items[k]["kind"] == "task"
                         and not ended(items[k])],
                        key=triage)
    fleet_landed = by_outcome("task", "landed")
    fleet_discarded = by_outcome("task", "discarded")
    fleet_unknown = sorted([k for k in order if items[k]["kind"] == "task"
                            and ended(items[k])
                            and items[k]["outcome"] not in ("landed", "discarded")],
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

    # How long each item has held its current disposition, and - for asks - the
    # thing the captain actually needs to see. The Bridge exists because a
    # scrolling stream loses captain-relevant items: an ask that has been open
    # for days looks exactly like one raised a minute ago unless the surface
    # says otherwise, and a stream cannot say otherwise.
    now_epoch = _epoch(folded_at)
    for item in items.values():
        item["age_seconds"] = _age_seconds(item.get("state_since") or item["first_ts"],
                                           now_epoch)
        item["age_label"] = _age_label(item["age_seconds"])
        # Aging is about asks, so it is the ask conjunction with a clock on it:
        # someone owes it, AND the work is still live, AND it has been that way
        # too long. Work that ended cannot age - there is nothing left to do.
        item["aging"] = (owed_by(item) in ("needs-captain", "needs-cocaptain")
                         and not ended(item)
                         and item["age_seconds"] is not None
                         and item["age_seconds"] >= AGING_SECONDS)

    # Every open ask, across every project and kind, SEVERITY FIRST and then
    # longest waiting. Severity leads because this is a surface triaged from,
    # and age breaks the tie so the forgotten ones rise within their severity
    # instead of sinking under whatever arrived most recently. The rendered
    # label states this same ordering, and a guard holds the two together: a
    # claim about the sort that the sort does not keep is a false claim on the
    # one surface whose job is collecting rulings.
    # AN ASK IS A CONJUNCTION, NOT A RANKING. Someone owes a decision AND the
    # work is still live. Both conditions are necessary and neither overrides
    # the other: a discarded item is not an ask because there is nothing left to
    # decide, and a merged item is not an ask because nobody owes it. Two
    # independent reasons, either sufficient to disqualify on its own.
    def _queue(state):
        queue = [k for k in order
                 if items[k]["kind"] in BOARD_KINDS
                 and owed_by(items[k]) == state
                 and not ended(items[k])]
        queue.sort(key=lambda k: (SEVERITY_RANK.get(items[k]["severity"], 4),
                                  -(items[k]["age_seconds"] or 0),
                                  index[k]))
        return queue

    # Two queues, addressed to two readers. Keeping them separate IS the
    # routing: an item on the co-captain's queue must never be counted, pinned,
    # or listed as something the captain owes.
    asks = _queue("needs-captain")
    cocaptain_asks = _queue("needs-cocaptain")

    lines_considered = lines_total - lines_blank
    # The summary is what the captain triages against, so it counts only the
    # kinds they read. Substrate is reported separately rather than folded in,
    # because a machinery record inflating "resolved" would quietly change what
    # the tallies mean.
    # ONE TALLY PER AXIS, AND EACH TALLY COUNTS EVERY ITEM.
    #
    # `summary` partitions the board's items by who owes them; `outcomes`
    # partitions the SAME items by how they ended. Both sum to
    # `counts.board_items`, so a reader who sees a needs-captain chip can find
    # that item in the state tally and read on the other axis why it is not an
    # ask. A tally that drops items is the same failure as a fold that drops
    # lines: on a surface whose discipline is that the numbers add up in public,
    # a silent gap is where a wrong reading hides.
    #
    # The ASK COUNT is a third, separate number - the conjunction the queues
    # use, owed AND still live - and it is labelled as one rather than being
    # folded into either axis.
    summary = {"needs-captain": 0, "needs-cocaptain": 0, "fm-handling": 0,
               "resolved": 0, "unstated": 0, "unrecognized": 0}
    outcomes = {outcome: 0 for outcome in KNOWN_OUTCOMES}
    outcomes["unrecognized"] = 0
    outcome_sources = {source: 0 for source in OUTCOME_SOURCES}
    board_items = 0
    unobserved_outcomes = []
    for key in order:
        item = items[key]
        if item["kind"] not in BOARD_KINDS:
            continue
        board_items += 1
        state = owed_by(item)
        if state in summary and state != "unstated":
            summary[state] += 1
        elif not state:
            summary["unstated"] += 1
        else:
            summary["unrecognized"] += 1
        if item["recognized"]["outcome"]:
            outcomes[item["outcome"]] += 1
        else:
            outcomes["unrecognized"] += 1
        outcome_sources[item["outcome_source"]] = \
            outcome_sources.get(item["outcome_source"], 0) + 1
        if item["outcome_source"] == "unobserved":
            unobserved_outcomes.append(key)

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
            "board_items": board_items,
        },
        # The conservation invariant, stated as data so every consumer can check
        # it without re-deriving it.
        "conserved": lines_considered == records + len(malformed),
        "malformed": malformed[:MAX_MALFORMED_SHOWN],
        "malformed_omitted": max(0, len(malformed) - MAX_MALFORMED_SHOWN),
        "projects": projects,
        "asks": asks,
        "cocaptain_asks": cocaptain_asks,
        "queues": {"captain": asks, "cocaptain": cocaptain_asks},
        "aging_seconds": AGING_SECONDS,
        "order": order,
        "items": {k: items[k] for k in order},
        "zones": {
            "criticals": criticals,
            "criticals_landed": criticals_landed,
            "criticals_discarded": criticals_discarded,
            "criticals_unknown": criticals_unknown,
            "decisions": decisions,
            "events": events,
            "fleet_open": fleet_open,
            "fleet_landed": fleet_landed,
            "fleet_discarded": fleet_discarded,
            "fleet_unknown": fleet_unknown,
            "unzoned": unzoned,
            "substrate": steering,
        },
        "glossary": glossary,
        "summary": summary,
        "outcomes": outcomes,
        "outcome_sources": outcome_sources,
        # Items whose ending nobody could observe, named rather than folded
        # away: a row the fold cannot resolve is worth the captain seeing once.
        "unobserved_outcomes": unobserved_outcomes,
        "asks_count": len(asks),
        "substrate": substrate,
        "caps": {
            "events": CAP_EVENTS,
            "closed_decisions": CAP_RESOLVED_DECISIONS,
            "fleet_closed": CAP_FLEET_CLOSED,
        },
        "checks": {
            "folded state": "bin/fm-bridge-render.sh --state",
            "conservation": "bin/fm-bridge-render.sh --state | jq '.counts, .conserved'",
            "open asks": "bin/fm-bridge-render.sh --state | jq -r "
                         "'.items|to_entries[]|select(.value.state==\"needs-captain\")"
                         "|\"\\(.value.ref) \\(.value.title)\"'",
            "record hygiene": "bin/fm-bridge.sh lint",
            "one item": "bin/fm-bridge-render.sh --lifecycle <id>",
            "co-captain queue": "bin/fm-bridge-render.sh --state | "
                                "jq -r '.cocaptain_asks[]'",
            "raw stream": "tail -n 40 %s" % ledger_path,
        },
    }


def narrow(doc, item_id):
    """The whole fold, narrowed to one item. Same document shape, so a targeted
    consumer parses exactly what a whole-fleet consumer parses.

    Every list of item keys is narrowed with `items`, never just `items` itself:
    the documented traversal is `for k in doc["asks"]: doc["items"][k]`, so a
    queue or zone still naming a dropped id hands that consumer a KeyError on
    the very document that was supposed to be easier to read. The ledger-wide
    counts stay ledger-wide on purpose - conservation is a claim about the
    stream, not about the slice.

    The narrowing is by RECOGNITION, not by a list of key names: any list whose
    every member is an id the full fold carried IS a list of item ids, wherever
    it sits in the document. Naming the lists worked until a field added later
    was not added to the list of names, twice - a new id-list must be narrowed
    because of what it holds, not because someone remembered it.
    """
    known = set(doc["items"])
    item = doc["items"].get(item_id)
    kept = {item_id} if item is not None else set()

    def is_id_list(value):
        return (isinstance(value, list) and value
                and all(isinstance(entry, str) and entry in known
                        for entry in value))

    def carries_ids(value):
        if is_id_list(value):
            return True
        if isinstance(value, dict):
            return any(carries_ids(inner) for inner in value.values())
        if isinstance(value, list):
            return any(carries_ids(entry) for entry in value)
        return False

    def narrowed(value):
        if is_id_list(value):
            return [key for key in value if key in kept]
        if isinstance(value, dict):
            return {key: narrowed(inner) for key, inner in value.items()}
        if isinstance(value, list):
            # A grouping that existed only to hold ids and now holds none goes
            # with them - a project heading over an empty list is not the slice
            # the caller asked for.
            entries = []
            for entry in value:
                shrunk = narrowed(entry)
                if carries_ids(entry) and not carries_ids(shrunk):
                    continue
                entries.append(shrunk)
            return entries
        return value

    doc = {key: value if key == "items" else narrowed(value)
           for key, value in doc.items()}
    doc["query"] = {"id": item_id, "found": item is not None}
    doc["items"] = {item_id: item} if item is not None else {}
    return doc


def lifecycle(doc, item_id):
    """Answer "what happened to <id>?" as a typed, three-valued claim.

    The rule this encodes, and the reason the record exists at all: CONSUMED and
    NEVER-ARRIVED look identical on screen. An empty composer is produced by both,
    so a checker reading the screen can only honestly say UNKNOWN. Absence is
    therefore assertable only from a durable consumption record, never from UI
    state - which is what `absence_explained` means here, and why it is false
    for every verdict except `consumed`.

    Readability feeds straight into this: if ANY line could not be read, the
    verdict is `unknown` no matter what was found, because an unreadable line
    may be the very record being asked about. Note that this is a stricter
    condition than conservation - a malformed line is still ACCOUNTED for, so
    the stream stays conserved while remaining partially unreadable. Accounting
    for a line you could not parse is exactly not the same as having read it,
    and a confident answer over the difference is the false negative this whole
    design exists to prevent.
    """
    answer = {
        "schema": "fm-bridge.lifecycle.v1",
        "id": item_id,
        "folded_at": doc["folded_at"],
        "source": {"ledger": doc["ledger"]["path"], "lines": []},
        "conserved": doc["conserved"],
        "fully_readable": doc["counts"]["malformed"] == 0 and doc["conserved"],
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
        answer["outcome"] = item["outcome"]

    if not answer["fully_readable"]:
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
    """Change signature for the skip-when-unchanged tick, over CONTENT.

    Size and mtime would be cheaper and would answer a different question. A
    ledger rewritten to the same bytes, or merely touched, changes mtime without
    changing anything the board would show - and rewriting the board is what
    reloads it out from under a ruling the captain is annotating. The digest
    costs one read of a file the fold is about to read anyway.
    """
    try:
        with open(path, "rb") as handle:
            digest = hashlib.sha256()
            for block in iter(lambda: handle.read(1 << 16), b""):
                digest.update(block)
    except OSError:
        return "absent"
    return digest.hexdigest()


# --- board -----------------------------------------------------------------
#
# Everything below draws. It is handed the state document and nothing else - it
# has no ledger path and never opens a file.

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
* { box-sizing:border-box; min-width:0; }
body {
  margin:0; padding:0 0 4rem; background:var(--tn-deep); color:var(--tn-fg);
  font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
}
code, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:.86em; }
.wrap { max-width:1080px; margin:0 auto; padding:0 1.25rem; }
a { color:var(--tn-cyan); }

/* THE HEADER IS THE WHOLE BUDGET ABOVE THE FIRST DECISION. Law 2 is a length
   rule, and length above the fold is what it costs: every row of chrome here
   pushes the first ask down, and the acceptance test measures exactly that.
   So the header carries the fold clock and one counts line, and nothing else -
   the tally rows, the legend, and the two-axis note all moved to history. */
header.top { border-bottom:1px solid var(--tn-line); background:var(--tn-bg); padding:1.1rem 0 .9rem; }
.toprow { display:flex; flex-wrap:wrap; align-items:baseline; gap:.7rem; }
h1 { margin:0; font-size:1.4rem; letter-spacing:.02em; }
h1 .sub { color:var(--tn-dim); font-weight:400; font-size:.82rem; margin-left:.55rem; }
.fresh { margin-left:auto; display:flex; align-items:center; gap:.45rem; font-size:.8rem; color:var(--tn-dim); }
.dot { width:.55rem; height:.55rem; border-radius:50%; background:var(--tn-green); display:inline-block; flex:none; }
.dot.stale { background:var(--tn-orange); }
.countline { margin-top:.45rem; font-size:.82rem; color:var(--tn-dim); }
.countline b.you { color:var(--tn-red); }
.countline b.co { color:var(--tn-purple); }
.countline b.fm { color:var(--tn-blue); }
.countline .sep { margin:0 .5rem; color:var(--tn-muted); }

section { margin:1.6rem 0 0; }
h2 {
  font-size:.78rem; text-transform:uppercase; letter-spacing:.13em;
  color:var(--tn-dim); margin:0 0 .55rem; font-weight:600;
}
h2 .note { text-transform:none; letter-spacing:0; font-weight:400; color:var(--tn-muted); margin-left:.5rem; }

/* --- an ask card -------------------------------------------------------- */
.ask {
  background:var(--tn-panel); border:1px solid var(--tn-line);
  border-left:3px solid var(--tn-red); border-radius:.5rem;
  padding:.7rem .9rem .65rem; margin:0 0 .55rem;
}
.askhead { display:flex; align-items:baseline; gap:.6rem; flex-wrap:wrap; }
.ref { font-family:ui-monospace,Menlo,monospace; font-size:.8rem; color:var(--tn-red); font-weight:700; flex:none; }
.proj { font-size:.72rem; color:var(--tn-muted); flex:none; }
.age { margin-left:auto; font-size:.75rem; color:var(--tn-muted); flex:none; }
.ask.aging .age { color:var(--tn-orange); }
/* FULL WRAP (Law 5, amended by the captain 2026-08-06). The title is the
   information the captain rules on; clipping it optimized scan density at
   the cost of the one thing the card exists to convey. Wraps completely -
   the ledger remains the full record, but nothing on the card truncates. */
.asktitle {
  margin:.15rem 0 .5rem; font-size:.95rem; line-height:1.4;
  overflow-wrap:anywhere;
}
.answers { display:flex; flex-wrap:wrap; gap:.4rem; align-items:center; }
.ansbtn {
  font:inherit; font-size:.8rem; line-height:1.3; padding:.3rem .65rem; border-radius:.4rem;
  background:var(--tn-bg); color:var(--tn-fg); border:1px solid var(--tn-line); cursor:pointer;
  max-width:100%; text-align:left;
}
.ansbtn:hover { border-color:var(--tn-cyan); }
.ansbtn.selected { border-color:var(--tn-fg); background:rgba(192,202,245,.08); }
/* GREEN MEANS QUEUED, AND NOTHING ELSE ON THIS CARD. A recommendation is a
   muted chip inside the option, never a colour state, so a rec can never be
   mistaken for something the captain chose. */
.ansbtn.queued { border-color:var(--tn-green); background:rgba(158,206,106,.12); color:var(--tn-green); }
.ansbtn.queued::before { content:"\\2713 "; }
.qbtn {
  font:inherit; font-size:.78rem; margin-top:.45rem; padding:.3rem .7rem; border-radius:.4rem;
  border:1px solid var(--tn-green); background:transparent; color:var(--tn-green); cursor:pointer;
}
.qbtn:hover { background:rgba(158,206,106,.12); }
.qbtn[hidden] { display:none; }
.rectag {
  font-size:.68rem; color:var(--tn-dim); border:1px solid var(--tn-line); border-radius:.3rem;
  padding:.05rem .35rem; margin-left:.35rem; vertical-align:.08em; white-space:nowrap;
}
.qnote { display:block; font-size:.74rem; color:var(--tn-green); margin-top:.45rem; }
.qnote.warn { color:var(--tn-orange); }
.qnote[hidden] { display:none; }
details.ctxd { margin-top:.5rem; font-size:.83rem; }
details.ctxd summary { cursor:pointer; color:var(--tn-cyan); font-size:.78rem; user-select:none; }
details.ctxd summary:hover { text-decoration:underline; }
details.ctxd .ctxbody {
  margin:.4rem 0 .1rem; color:var(--tn-dim); border-left:2px solid var(--tn-line);
  padding-left:.7rem; overflow-wrap:anywhere;
}
.chip {
  font-size:.68rem; letter-spacing:.06em; text-transform:uppercase;
  border-radius:.25rem; padding:.1rem .4rem; border:1px solid currentColor;
  white-space:nowrap; flex:none;
}
.chip.critical { color:var(--tn-red); }
.chip.aging { color:var(--tn-orange); }
.chip.odd { color:var(--tn-orange); }
.chip.needs-captain { color:var(--tn-red); }
.chip.needs-cocaptain { color:var(--tn-purple); }
.chip.fm-handling { color:var(--tn-blue); }
.chip.resolved { color:var(--tn-green); }
.chip.landed { color:var(--tn-green); }
.chip.discarded { color:var(--tn-orange); }
.chip.unknown { color:var(--tn-orange); }
.chip.sev { color:var(--tn-dim); }
.chip.was { color:var(--tn-muted); }

/* --- co-captain --------------------------------------------------------- */
.corow {
  display:flex; align-items:baseline; gap:.6rem; background:var(--tn-panel);
  border:1px solid var(--tn-line); border-left:3px solid var(--tn-purple);
  border-radius:.5rem; padding:.5rem .9rem; font-size:.85rem; margin:0 0 .4rem;
}
.corow .ref { color:var(--tn-purple); }
.corow .t { white-space:normal; overflow-wrap:anywhere; }
.corow .who { margin-left:auto; flex:none; font-size:.75rem; color:var(--tn-muted); }

/* --- lanes -------------------------------------------------------------- */
.lanes { display:grid; grid-template-columns:1fr; gap:.55rem; }
.lanegroup { background:var(--tn-panel); border:1px solid var(--tn-line); border-radius:.5rem; padding:.6rem .9rem; }
.lanegroup.quiet { padding:.4rem .9rem; }
.lanegroup.quiet .lghead { margin-bottom:0; }
.lghead { display:flex; align-items:baseline; gap:.6rem; margin-bottom:.35rem; flex-wrap:wrap; }
.lghead .p { font-weight:600; font-size:.9rem; color:var(--tn-blue); }
.lghead .n { font-size:.78rem; color:var(--tn-muted); }
/* Explicit grid tracks, every one intrinsic or minmax(0,...), so no cell can
   be pushed over its neighbour at any width - the collision two browser layout
   audits caught on flex rows in the v1 board. */
.lane {
  display:grid; grid-template-columns:minmax(0,1.4fr) minmax(0,.9fr) minmax(0,.5fr) auto;
  gap:.6rem; align-items:baseline; font-size:.83rem; padding:.18rem 0;
  border-top:1px dashed color-mix(in srgb, var(--tn-line) 55%, transparent);
}
.lane:first-of-type { border-top:0; }
.lane .nm { font-family:ui-monospace,Menlo,monospace; font-size:.78rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.lane .ph { color:var(--tn-dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.lane .la { color:var(--tn-muted); font-size:.76rem; }
.hd { width:.5rem; height:.5rem; border-radius:50%; display:inline-block; background:var(--tn-green); }
.hd.warn { background:var(--tn-orange); }
.hd.unknown { background:var(--tn-muted); }
.idle { color:var(--tn-muted); font-size:.83rem; }
.mergeline {
  margin-top:.5rem; font-size:.8rem; color:var(--tn-dim);
  border-top:1px solid var(--tn-line); padding-top:.45rem; overflow-wrap:anywhere;
}

/* --- admission ---------------------------------------------------------- */
.adm { display:flex; flex-wrap:wrap; gap:.55rem; align-items:stretch; }
.gauge { flex:1 1 10rem; background:var(--tn-panel); border:1px solid var(--tn-line); border-radius:.5rem; padding:.5rem .8rem; font-size:.8rem; }
.gauge .lbl { color:var(--tn-muted); font-size:.72rem; text-transform:uppercase; letter-spacing:.08em; }
.gauge .val { font-size:1rem; margin-top:.1rem; }
.gauge .sub { color:var(--tn-muted); font-size:.74rem; overflow-wrap:anywhere; }
.gauge.ok .val { color:var(--tn-green); }
.gauge.warn .val { color:var(--tn-orange); }
/* An unreadable denominator is its own state, never a reassuring one and never
   an alarm: the gauge says it could not read, in muted text, and the verdict
   below names it as an unknown it could not account for. */
.gauge.unknown .val { color:var(--tn-muted); }
.verdict {
  flex:1 1 100%; border:1px solid var(--tn-green); background:rgba(158,206,106,.07);
  border-radius:.5rem; padding:.6rem .9rem; font-size:.95rem; color:var(--tn-green);
  overflow-wrap:anywhere;
}
.verdict.hold { border-color:var(--tn-orange); background:rgba(255,158,100,.07); color:var(--tn-orange); }
.verdict.unknown { border-color:var(--tn-muted); background:rgba(86,95,137,.12); color:var(--tn-dim); }
.verdict b { letter-spacing:.04em; }

/* --- the stale bar ------------------------------------------------------ */
/* IN NORMAL FLOW, like everything else on this page. Chrome that travels with
   a scrolling page ends up over the rows it announces - two browser layout
   audits proved it on the v1 board - so nothing here is fixed, absolute, or
   sticky, and the rule is kept by having nothing viewport-fixed to place. */
.stalebar {
  display:flex; align-items:center; gap:.7rem; flex-wrap:wrap;
  background:rgba(255,158,100,.09); border:1px solid var(--tn-orange);
  border-radius:.5rem; padding:.5rem .9rem; font-size:.85rem; color:var(--tn-orange);
  margin:.8rem 0 0;
}
.stalebar[hidden] { display:none; }
.stalebar button {
  font:inherit; font-size:.78rem; padding:.25rem .6rem; border-radius:.4rem;
  border:1px solid var(--tn-orange); background:transparent; color:var(--tn-orange); cursor:pointer;
}
.stalebar .why { margin-left:auto; font-size:.75rem; }

footer {
  margin-top:1.6rem; padding-top:.7rem; border-top:1px solid var(--tn-line);
  font-size:.78rem; color:var(--tn-muted);
}
footer .cols { display:flex; flex-wrap:wrap; gap:1.2rem; }
footer code { color:var(--tn-cyan); }
footer .row { margin:.3rem 0; overflow-x:auto; white-space:nowrap; }
.promises { margin:.9rem 0 0; padding-left:.6rem; border-left:2px solid var(--tn-blue);
            color:var(--tn-dim); font-size:.8rem; line-height:1.5; }
.promises div { margin:.25rem 0; }
.promises b { color:var(--tn-fg); }

.banner {
  border:1px solid var(--tn-orange); color:var(--tn-orange); background:rgba(255,158,100,.08);
  border-radius:.5rem; padding:.7rem .9rem; margin:1rem 0 0; font-size:.85rem;
}
.banner code { color:var(--tn-orange); }
.empty { color:var(--tn-muted); font-size:.85rem; font-style:italic; }
.allclear { color:var(--tn-green); font-size:.9rem; }
.overflow { margin-top:.55rem; font-size:.8rem; color:var(--tn-orange); }

/* --- history page ------------------------------------------------------- */
.backlink { margin:0 0 .8rem; font-size:.82rem; }
.tallies { display:flex; flex-wrap:wrap; gap:.5rem; margin-top:.75rem; }
.tally {
  border:1px solid var(--tn-line); border-radius:.4rem; padding:.3rem .6rem;
  font-size:.8rem; background:var(--tn-panel); min-width:0;
}
.tally b { font-size:1rem; margin-right:.3rem; }
.tallylbl {
  flex-basis:100%; font-size:.7rem; text-transform:uppercase; letter-spacing:.09em;
  color:var(--tn-muted); margin-bottom:-.2rem;
}
.tally.ask { border-color:var(--tn-red); } .tally.ask b { color:var(--tn-red); }
.tally.fm  { border-color:var(--tn-blue); } .tally.fm b { color:var(--tn-blue); }
.tally.ok  { border-color:var(--tn-green); } .tally.ok b { color:var(--tn-green); }
.tally.warn{ border-color:var(--tn-orange); } .tally.warn b { color:var(--tn-orange); }
.tally.co  { border-color:var(--tn-purple); } .tally.co b { color:var(--tn-purple); }
.zone-note { color:var(--tn-muted); font-size:.78rem; margin:0 0 .8rem; }
.hrow {
  display:grid; grid-template-columns:minmax(2.4rem,max-content) minmax(0,7rem) minmax(0,1fr) max-content;
  gap:.7rem; align-items:baseline; padding:.45rem .2rem;
  border-bottom:1px solid rgba(59,66,97,.4); font-size:.87rem;
}
.hrow .ref { color:var(--tn-dim); }
.hrow .proj { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hrow .what { min-width:0; overflow-wrap:anywhere; }
.hrow .ends { white-space:nowrap; display:flex; gap:.3rem; flex-wrap:wrap; justify-content:flex-end; }
/* A group label inside a section - "landed", "discarded", "open, and not
   waiting on you". It sat as ordinary dim prose and read as a stray word
   dropped between two rows; a label the reader skims past is a group boundary
   they do not see, which on this page means reading a discarded row as a
   landed one. */
.grouplabel {
  margin:1.1rem 0 .3rem; font-size:.7rem; text-transform:uppercase;
  letter-spacing:.11em; color:var(--tn-muted); font-weight:600;
  border-top:1px solid var(--tn-line); padding-top:.5rem;
}
.grouplabel:first-of-type { border-top:0; margin-top:.2rem; }
.hitem { border-bottom:1px solid rgba(59,66,97,.4); padding:.15rem 0 .5rem; }
.hitem details.ctxd { margin:0 0 0 .2rem; }
.hbody { color:var(--tn-dim); font-size:.85rem; overflow-wrap:anywhere; }
.hbody .lbl { color:var(--tn-muted); margin-right:.35rem; }
.legend { display:flex; flex-wrap:wrap; gap:.9rem; font-size:.76rem; color:var(--tn-dim); margin-top:.6rem; }
.legend span::before {
  content:""; display:inline-block; width:.6rem; height:.6rem; border-radius:.15rem;
  margin-right:.35rem; vertical-align:baseline; background:currentColor;
}
.legend .l-red{color:var(--tn-red);} .legend .l-blue{color:var(--tn-blue);}
.legend .l-green{color:var(--tn-green);} .legend .l-orange{color:var(--tn-orange);}
.legend .l-purple{color:var(--tn-purple);} .legend .l-cyan{color:var(--tn-cyan);}
.glossary { border:1px dashed var(--tn-line); border-radius:.5rem; padding:.7rem .9rem; background:var(--tn-bg); }
.glossary dl { margin:0; }
.glossary dt { font-weight:600; color:var(--tn-fg); font-size:.85rem; margin-top:.5rem; }
.glossary dt:first-child { margin-top:0; }
.glossary dd { margin:.15rem 0 0 0; font-size:.83rem; color:var(--tn-dim); }
.glossary .collide { color:var(--tn-orange); font-size:.72rem; text-transform:uppercase; letter-spacing:.07em; margin-left:.4rem; }
h3.projhead {
  margin:1.6rem 0 .55rem; font-size:.95rem; font-weight:600; line-height:1.45;
  color:var(--tn-fg); overflow-wrap:anywhere;
}
h3.projhead .refs { color:var(--tn-muted); font-weight:400; font-size:.8rem; white-space:nowrap; }
.local-terms { margin:0 0 .8rem; font-size:.79rem; line-height:1.5; color:var(--tn-dim); border-left:2px solid var(--tn-line); padding-left:.6rem; }
/* Secondary text under a history row. Dim by default because a note is an
   ordinary field on every write command; the override accent is the one
   exception, and it belongs to the judgement that authorized skipping the
   landed-work test. */
.hbody .why { color:var(--tn-dim); }
.hbody .why.override { color:var(--tn-orange); }
.checkline { margin-top:.5rem; font-size:.76rem; color:var(--tn-muted); overflow-x:auto; }
.checkline code { color:var(--tn-cyan); }
"""



def esc(text):
    return _html.escape(_text(text), quote=True)


def link(href, label=None, external=None):
    """Every anchor on this board, and the ONLY way one should be emitted.

    Read inside Lavish, whose annotation layer installs a capture-phase click
    handler that calls preventDefault() on everything except
    `[data-lavish-ui]`, `[data-lavish-action]`, and native controls -
    `button,input,select,textarea,option,optgroup,label,summary,[contenteditable]`.
    `a` is not on that list, so a plain anchor swallows left-clicks. Not a
    blocker - right-click still opens the link - but `data-lavish-action` is
    Lavish's own pass-through, so left-click working is a one-attribute
    authoring fix rather than something to route around.

    It exempts that anchor from annotation capture and nothing else: every other
    element stays annotatable, which is the whole input path this board has.
    ANCHORS ARE THE ONLY THING ON THIS BOARD THAT CARRY THE ATTRIBUTE, and an
    anchor is the only thing that earns it - an anchor's own job is to navigate,
    so trading its annotatability for a working left-click is a fair trade
    nothing else on the board can make. This function is the only place either
    page builds an anchor, so the rule has one enforcement point rather than a
    convention, and the guard suite pins both halves of it - every anchor
    carries the attribute, and nothing that is not an anchor does.

    External links open in a new tab because the board is served in an iframe,
    and a same-tab navigation would replace the board with the PR.

    The visible text of an external link is the full URL, which is how this
    board has always rendered pointers - the URL is the most useful label for
    one. It is not a fallback affordance, and no second link mechanism exists.
    """
    if external is None:
        external = href.startswith("http://") or href.startswith("https://")
    text = href if label is None else label
    extra = ' target="_blank" rel="noopener noreferrer"' if external else ""
    return ('<a href="%s" data-lavish-action%s>%s</a>'
            % (esc(href), extra, esc(text)))


def state_class(item):
    if not item.get("recognized", {}).get("state", True):
        return "odd"
    return item["state"] or "odd"


def chip(item):
    """The state axis: who owes this. Never the outcome - see outcome_chip."""
    cls = state_class(item)
    if not item["state"]:
        # The ledger never said who owed it, and the fold will not invent one.
        return '<span class="chip odd">owner unstated</span>'
    label = item["state"] if cls != "odd" else item["state"] + " ?"
    return '<span class="chip %s">%s</span>' % (cls, esc(label))


def outcome_chip(item):
    """The outcome axis: how it ended. Rendered BESIDE the state chip, never
    instead of it, because a row that shows one axis makes the reader guess the
    other - and every guess so far has been wrong in an expensive direction."""
    outcome = item["outcome"]
    if outcome == IN_FLIGHT:
        return ""
    if not item.get("recognized", {}).get("outcome", True):
        return '<span class="chip odd">%s ?</span>' % esc(outcome)
    return '<span class="chip %s">%s</span>' % (esc(outcome), esc(outcome))


def sev_chip(item):
    if item["severity"] in ("normal", ""):
        return ""
    cls = "odd" if not item.get("recognized", {}).get("severity", True) else "sev"
    return '<span class="chip %s">%s</span>' % (cls, esc(item["severity"]))


# --- the live readings the board draws beside the ledger --------------------
#
# LAW 6: every value on the page is derived at fold time from an existing record
# or a live reading. Nothing hand-written, no constants - that is the capacity
# lesson, where a number typed into a document went on being quoted long after
# the machine it described had changed.
#
# These readings are NOT part of the fold and never enter the state document.
# `--state` is a pure function of the ledger, read by the linter, the
# co-captain's audit and every lifecycle query; making it shell out to a quota
# CLI would put a subprocess behind every one of those. So the board collects
# them separately, embeds what it drew, and says when it could not read one.
#
# WHERE A READING CANNOT BE TAKEN, THE ANSWER IS "COULD NOT READ", NEVER A
# REASSURING DEFAULT AND NEVER AN ALARM. An admission verdict that treats an
# unreadable denominator as headroom is the missing-alarm failure; one that
# treats it as exhaustion is the false alarm. They are the same defect, and the
# only honest third value is the one that names the gap.

# How long the watcher's beacon may go untouched before this page stops
# treating its per-lane health verdicts as current. A rule, not a rendered
# value: past it, lane health reads `unknown` rather than inheriting a stale
# green from records nobody is maintaining.
WATCHER_BEACON_MAX_AGE = 600

# The admission floor, in MiB. It is the ONE capacity number the captain states
# as a rule rather than a reading ("do not start heavy work below 2 GiB
# available"), and the ceiling it is compared against is read live every time.
ADMISSION_FLOOR_MIB = 2048

# A SUBPROCESS ON THIS PATH IS A SUBPROCESS ON THE SUPERVISION LOOP.
#
# The board renders from bin/fm-watch.sh's own poll, so every second spent
# probing here is a second the watcher is not watching. Measured: the host
# probe alone cost 0.5s and the whole render went from 0.2s to 1.4s, which was
# enough to push a one-second poll past a three-second guard.
#
# So the two subprocess probes are cached in state/ with a TTL, and their
# timeout is short. A render reuses a recent reading; at most one render per
# TTL window pays for a fresh one, and it pays at most PROBE_TIMEOUT. The
# gauges say how old a reused reading is, because a cached number presented as
# a live one is the capacity lesson with a shorter half-life.
PROBE_TIMEOUT = 2
PROBE_CACHE_TTL = 300


def _cache_path(state_dir, name):
    return os.path.join(state_dir, ".bridge-probe-%s" % name)


def _cached_probe(state_dir, name, reader, now_epoch):
    """A recent reading and its age, or a fresh one, or an honest reason.

    A stale cache is never served silently: `age_seconds` travels with the
    value so the gauge can say when it was taken, and a failed refresh falls
    back to the last good reading rather than blanking the gauge - with its
    real age attached, so nothing about it reads as current.

    WITH NO USABLE CLOCK THERE IS NO FRESHNESS SHORTCUT. `now_epoch` is None
    when the fold's own timestamp could not be parsed, and an age that cannot be
    computed is unknown, not zero: serving the cache as under-TTL then would
    present a reading of any age as one taken just now. So the TTL test fails
    closed, the reading is retaken, and a cache that cannot be stamped is not
    written - a record with no `at` is a reading whose age nothing can recover.
    """
    path = _cache_path(state_dir, name)
    cached, age = None, None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
        taken_at = int(record["at"])
        cached = record["value"]
        age = None if now_epoch is None else max(0, now_epoch - taken_at)
    except (OSError, ValueError, KeyError, TypeError):
        cached, age = None, None

    if cached is not None and age is not None and age < PROBE_CACHE_TTL:
        return cached, "", age

    value, why = _probe(reader)
    if value is None:
        if cached is not None:
            return cached, "", age
        return None, why, None
    if now_epoch is not None:
        try:
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"at": now_epoch, "value": value}, handle)
        except OSError:
            pass                  # a cache that cannot be written is not fatal
    # Zero here is this reading's own age - it was taken a moment ago - and not
    # a stand-in for a clock that could not be read.
    return value, "", 0


def _run(argv, timeout=PROBE_TIMEOUT):
    """A probe, or an honest reason there is no reading. Never raises."""
    import subprocess
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except FileNotFoundError:
        return None, "%s is not installed here" % argv[0]
    except subprocess.TimeoutExpired:
        return None, "%s did not answer within %ds" % (argv[0], timeout)
    except OSError as exc:
        return None, "%s could not be run: %s" % (argv[0], exc)
    if done.returncode != 0:
        return None, "%s exited %d" % (argv[0], done.returncode)
    return done.stdout.decode("utf-8", "replace"), ""


def _probe(reader):
    """One reading, or the reason there is none. Never raises, so one gauge
    that fails cannot take the other two - or the decisions above them - with
    it."""
    try:
        return reader()
    except Exception as exc:  # deliberately broad; a gauge is not worth a page
        return None, "%s could not be read: %s" % (reader.__name__.strip("_"), exc)


def _meminfo():
    """Available and total memory, in MiB, from the kernel's own accounting.

    /proc/meminfo rather than `free -m`: it is the same numbers without a
    subprocess, and MemAvailable is the kernel's estimate of what a new
    allocation can actually have - which is the question the floor asks.
    """
    fields = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                name, _, rest = line.partition(":")
                value = rest.strip().split(" ")[0]
                if value.isdigit():
                    fields[name] = int(value) // 1024
    except OSError as exc:
        return None, "the kernel's memory accounting could not be read: %s" % exc
    if "MemAvailable" not in fields or "MemTotal" not in fields:
        return None, "the kernel reported no MemAvailable figure"
    return {"available_mib": fields["MemAvailable"],
            "total_mib": fields["MemTotal"]}, ""


def _host_memory():
    """The memory of the machine underneath, when there is one to ask.

    Under WSL the kernel above reports the VM's allocation, not the Windows
    host's, and the two answer different questions. Where no host probe exists
    the gauge says so rather than reusing the VM's numbers under a host label.
    """
    import shutil
    probe = shutil.which("powershell.exe")
    if not probe:
        return None, "no host probe on this machine - the readings above are the whole machine"
    text, why = _run([probe, "-NoProfile", "-NonInteractive", "-Command",
                      "$m=Get-CimInstance Win32_OperatingSystem;"
                      "'{0} {1}' -f $m.FreePhysicalMemory,$m.TotalVisibleMemorySize"])
    if text is None:
        return None, why
    parts = text.split()
    if len(parts) < 2 or not parts[0].strip().isdigit() or not parts[1].strip().isdigit():
        return None, "the host probe answered in a shape this page cannot read"
    free_mib = int(parts[0]) // 1024
    total_mib = int(parts[1]) // 1024
    return {"free_mib": free_mib, "total_mib": total_mib,
            "used_mib": total_mib - free_mib}, ""


def _quota():
    """Provider headroom and pace, from the one tool that owns that reading.

    quota-axi is data-only and is the single owner of how a model window relates
    to its bounding account window. This page summarises what it returns and
    never re-derives it; where it cannot be read, the gauge says so.
    """
    text, why = _run(["quota-axi", "--json"])
    if text is None:
        return None, why
    try:
        parsed = json.loads(text)
    except ValueError as exc:
        return None, "quota-axi returned something this page could not parse: %s" % exc
    providers = []
    for entry in parsed.get("providers", []) or []:
        windows = entry.get("windows") or []
        tightest = None
        for window in windows:
            remaining = window.get("percentRemaining")
            if not isinstance(remaining, (int, float)):
                continue
            if tightest is None or remaining < tightest.get("percentRemaining", 101):
                tightest = window
        row = {"name": _text(entry.get("provider") or entry.get("label")),
               "status": _text(entry.get("status") or "")}
        if tightest is not None:
            row["window"] = _text(tightest.get("label") or tightest.get("id"))
            row["remaining_percent"] = tightest.get("percentRemaining")
            pace = tightest.get("pace") or {}
            row["pace"] = _text(pace.get("status") or "")
        providers.append(row)
    if not providers:
        return None, "quota-axi reported no providers"
    return {"providers": providers}, ""


def _watcher_live(state_dir, now_epoch):
    """Whether the fleet's own health records are being maintained right now.

    Lane health is the WATCHER's verdict, read from the markers it writes, not
    a second opinion computed here - two readers of one fact drift. Which means
    the absence of a warning marker is only good news while something is
    actually maintaining them, so this is checked first and a lapsed beacon
    makes every lane read `unknown` rather than green.

    A fold whose own timestamp could not be parsed leaves nothing to age the
    beacon against, and that is reported as unreadable too. Substituting zero
    for the missing clock would make every beacon read as newer than now, so a
    supervision that stopped days ago would still render green.
    """
    if now_epoch is None:
        return False, "the fold carries no readable clock to age the beacon against"
    beacon = os.path.join(state_dir, ".last-watcher-beat")
    try:
        age = now_epoch - int(os.path.getmtime(beacon))
    except (OSError, TypeError):
        return False, "no supervision beacon"
    if age > WATCHER_BEACON_MAX_AGE:
        return False, "supervision has not checked in for %s" % _age_label(age)
    return True, ""


def _meta_fields(path):
    fields = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                name, sep, value = line.strip().partition("=")
                if sep:
                    fields[name] = value
    except OSError:
        return None
    return fields


def _marker_key(fields):
    """The key the watcher files this lane's verdicts under, or None.

    ONE DERIVATION, TAKEN FROM THE WATCHER'S. bin/fm-watch.sh keys
    `.stale-since-<key>` and `.wedge-escalations-<key>` off the lane's backend
    TARGET, which fm_backend_target_of_meta in bin/fm-backend.sh resolves as the
    `terminal` field for an Orca lane and the `window` field otherwise. Reading
    `window` alone here would silently miss every Orca lane's markers, and a
    missed marker is indistinguishable from an absent one.

    None when the meta names no target at all, because a key that cannot match
    any marker is a verdict that was never read - which the caller renders as
    unknown rather than as the absence of a warning.
    """
    backend = fields.get("backend") or "tmux"
    target = ""
    if backend == "orca":
        target = fields.get("terminal", "")
    if not target:
        target = fields.get("window", "")
    if not target:
        return None
    for bad in ":/.":
        target = target.replace(bad, "_")
    return target


def _last_status(path):
    """The last supervisor-actionable line a lane reported, and when.

    Status appends are sparse events by contract, so this is what the lane last
    SAID, and the column says so. It is not a claim that nothing has happened
    since - only the lane's own last word, with its age.
    """
    try:
        stamp = int(os.path.getmtime(path))
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = [line.strip() for line in handle if line.strip()]
    except OSError:
        return "", None
    if not lines:
        return "", stamp
    return lines[-1], stamp


def _registry_projects(fm_home):
    """Every project the fleet is carrying, so an idle one says idle.

    A project with no lanes is omitted from state/ entirely, and omitting it
    from the strip would make "no lanes" and "no such project" look identical.
    """
    path = os.path.join(fm_home, "data", "projects.md")
    slugs = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line.startswith("- "):
                    continue
                slug = line[2:].split(" ")[0].strip()
                if slug and slug not in slugs:
                    slugs.append(slug)
    except OSError:
        return []
    return slugs


def collect_env(fm_home, state_dir, folded_at):
    """The live half of the board, and it can never cost the ledger half.

    Every probe below already returns a reason instead of raising, but this
    wrapper is what makes that a guarantee rather than a review finding: a
    quota CLI that dies in a new way, a host probe that returns something
    unimagined, any of it - the board still renders, with gauges that say they
    could not be read. A render that fails because a gauge misbehaved would
    take the captain's open decisions down with it, which inverts what the two
    halves are worth.
    """
    try:
        return _collect_env(fm_home, state_dir, folded_at)
    except Exception as exc:  # deliberately broad; see the docstring
        reason = "the live readings could not be collected: %s" % exc
        return {
            "collected_at": folded_at,
            "lanes": {"projects": [], "count": 0, "health_readable": False,
                      "health_unreadable_because": reason},
            "admission": {"floor_mib": ADMISSION_FLOOR_MIB,
                          "memory": None, "memory_unreadable_because": reason,
                          "host": None, "host_unreadable_because": reason,
                          "host_age_seconds": None,
                          "quota": None, "quota_unreadable_because": reason,
                          "quota_age_seconds": None},
        }


def _collect_env(fm_home, state_dir, folded_at):
    """The live half of the board: lanes in flight, and the admission gauges.

    Collected once, beside the fold and never inside it, then handed to the
    renderer as data. Every field that could not be read carries the reason it
    could not, because a board that silently drops a gauge and a board whose
    gauge reads zero are the same page to whoever is reading it.
    """
    # AN UNPARSEABLE FOLD TIME IS AN ABSENT CLOCK, NOT ZERO. Every age below is
    # measured against this, and zero is a real instant in 1970 - substituting it
    # would make every marker on disk read as freshly written, which is the one
    # direction a freshness reading must never round.
    now_epoch = _epoch(folded_at)
    live, why_not = _watcher_live(state_dir, now_epoch)

    lanes = {}
    warned = set()
    try:
        names = sorted(os.listdir(state_dir))
    except OSError:
        names = []
    for name in names:
        # The watcher's own per-lane verdicts, keyed by the window with its
        # separators flattened - the same key bin/fm-watch.sh writes them under.
        for prefix in (".stale-since-", ".wedge-escalations-"):
            if name.startswith(prefix):
                warned.add(name[len(prefix):])
    for name in names:
        if not name.endswith(".meta"):
            continue
        task = name[:-len(".meta")]
        fields = _meta_fields(os.path.join(state_dir, name))
        if fields is None:
            continue
        # A persistent secondmate is not a work item and never becomes a lane.
        if fields.get("kind") == "secondmate":
            continue
        project = os.path.basename(fields.get("project", "").rstrip("/")) or "fleet"
        line, stamp = _last_status(os.path.join(state_dir, task + ".status"))
        state_word, _, note = line.partition(":")
        note = note.strip()
        if state_word and note and state_word != "working":
            phase = "%s: %s" % (state_word, note)
        else:
            phase = note or state_word or "no word yet"
        age = (None if stamp is None or now_epoch is None
               else max(0, now_epoch - stamp))
        key = _marker_key(fields)
        if not live or key is None:
            # An unresolved key matches no marker, so the watcher's verdict was
            # never read. That is an unknown verdict and it renders as one: a
            # green dot over a lane supervision has flagged as wedged is exactly
            # the reading this state exists to prevent.
            health = "unknown"
        elif key in warned:
            health = "warn"
        else:
            health = "ok"
        lanes.setdefault(project, []).append({
            "id": task,
            "phase": phase,
            # What the lane last SAID, and when. Where it has said nothing the
            # phase column already says so, and repeating it here would read as
            # two separate silences rather than one.
            "reported_label": "" if age is None else _age_label(age),
            "reported_seconds": age,
            "health": health,
            "pr": fields.get("pr", ""),
        })

    projects = []
    for slug in _registry_projects(fm_home):
        projects.append({"project": slug, "lanes": lanes.pop(slug, [])})
    # A lane whose project is not in the registry is still a lane. It is listed
    # rather than dropped, because an unregistered project is a gap to see.
    for slug in sorted(lanes):
        projects.append({"project": slug, "lanes": lanes[slug]})

    # Memory is a file read, so it is always taken fresh. The two that spawn a
    # process are cached, because this runs on the supervision loop's thread.
    memory, memory_why = _probe(_meminfo)
    host, host_why, host_age = _cached_probe(state_dir, "host", _host_memory, now_epoch)
    quota, quota_why, quota_age = _cached_probe(state_dir, "quota", _quota, now_epoch)
    return {
        "collected_at": folded_at,
        "lanes": {
            "projects": projects,
            "count": sum(len(entry["lanes"]) for entry in projects),
            "health_readable": live,
            "health_unreadable_because": why_not,
        },
        "admission": {
            "floor_mib": ADMISSION_FLOOR_MIB,
            "memory": memory, "memory_unreadable_because": memory_why,
            "host": host, "host_unreadable_because": host_why,
            "host_age_seconds": host_age,
            "quota": quota, "quota_unreadable_because": quota_why,
            "quota_age_seconds": quota_age,
        },
    }


# --- board ------------------------------------------------------------------
#
# Everything below draws. It is handed the state document and the environment
# document, and nothing else - it has no ledger path and never opens a file.

# THE SIX RENDERING LAWS, transcribed from the captain-approved mockup and
# stated in full in docs/verification/bridge-board-v2.md. They are the contract
# this renderer implements, and each is marked at the code that keeps it:
#
#   Law 1  the default view renders open asks, the co-captain line, lanes and
#          admission. Nothing else. History is a separate view.
#   Law 2  board length scales with open asks and nothing else.
#   Law 3  an open critical is an ask card with a critical chip, sorted first.
#          A resolved critical does not render. There is no pinned section.
#   Law 4  an ask covered by a standing word is never asked.
#   Law 5  a card carries ref, project, age, a clamped one-line title, answers,
#          and a collapsed context dropdown.
#   Law 6  every value is derived at fold time from a record or a live reading.

SCRIPT = r"""
(function () {
  "use strict";

  // ---- select, then queue -------------------------------------------------
  //
  // Two states, and the card shows the difference. Clicking an option only sets
  // local SELECTED state; a per-card Queue button is the only thing that calls
  // queuePrompt, exactly once. Queueing from an option click would send a
  // ruling the captain is still in the middle of changing their mind about.
  //
  // queueKey is the ask's ref, so a re-queue REPLACES the prior unsent entry
  // for that ask instead of adding a second one: one entry per ask, always the
  // latest, and Send to Agent delivers them all.
  //
  // NOTHING HERE EVER CLAIMS A SEND IT DID NOT OBSERVE. If the API is missing
  // or throws, the option does not turn green and the card says plainly that
  // the ruling has not gone anywhere - a green tick over a dropped ruling is
  // the exact failure this surface exists to prevent.
  function queueRuling(prompt, options) {
    var api = window.lavish && window.lavish.queuePrompt;
    if (typeof api !== "function") { return "absent"; }
    try { api.call(window.lavish, prompt, options); } catch (err) { return "failed"; }
    return "queued";
  }

  var cards = document.querySelectorAll(".ask");
  Array.prototype.forEach.call(cards, function (card) {
    var ref = card.getAttribute("data-ask-ref") || "";
    var id = card.getAttribute("data-ask-id") || "";
    var note = card.querySelector(".qnote");
    var qbtn = card.querySelector(".qbtn");
    var options = card.querySelectorAll(".ansbtn");

    function selected() { return card.querySelector(".ansbtn.selected"); }
    function queued() { return card.querySelector(".ansbtn.queued"); }

    function say(text, warn) {
      if (!note) { return; }
      note.hidden = !text;
      note.textContent = text || "";
      if (warn) { note.classList.add("warn"); } else { note.classList.remove("warn"); }
    }

    function sync() {
      var sel = selected(), qd = queued();
      if (qbtn) {
        qbtn.hidden = !(sel && sel !== qd);
        qbtn.textContent = qd ? "Update queued answer" : "Queue answer";
      }
    }

    Array.prototype.forEach.call(options, function (btn) {
      btn.addEventListener("click", function () {
        var was = btn.classList.contains("selected");
        Array.prototype.forEach.call(options, function (other) {
          other.classList.remove("selected");
        });
        if (!was) { btn.classList.add("selected"); }
        sync();
      });
    });

    if (qbtn) {
      qbtn.addEventListener("click", function () {
        var sel = selected();
        if (!sel) { return; }
        var label = sel.getAttribute("data-answer-label") || "";
        var body = sel.getAttribute("data-answer-text") || "";
        var verdict = queueRuling(ref + ": " + label, {
          queueKey: ref,
          tag: "ruling",
          text: ref + ": " + label + " - " + body,
          element: card,
          data: { ref: ref, id: id, answer: label, text: body }
        });
        if (verdict === "queued") {
          Array.prototype.forEach.call(options, function (other) {
            other.classList.remove("queued");
          });
          sel.classList.add("queued");
          say("queued: " + label + " - one entry per ask; re-queueing replaces it; "
              + "Send to Agent delivers every queued ruling", false);
        } else if (verdict === "absent") {
          say("this copy of the board has no send path, so nothing was queued - "
              + "rule by annotating this card, or tell firstmate directly", true);
        } else {
          say("queueing failed, so nothing was sent - rule by annotating this "
              + "card, or tell firstmate directly", true);
        }
        sync();
      });
    }

    sync();
  });

  // ---- freshness ----------------------------------------------------------
  //
  // The page states the fold it was drawn from, ages it live, and polls its own
  // URL for a newer one. A newer fold there means the copy on screen is not
  // current, and the bar says so with both times.
  //
  // THIS PAGE NEVER RELOADS ITSELF, and the reason is measured rather than
  // cautious. Hosted in Lavish, the host reloads the frame itself within
  // seconds of the file changing, so an auto-reload here would be a second
  // owner of an action that already has one. And the frame is sandboxed
  // WITHOUT allow-same-origin: it cannot see the host's annotation card, so it
  // could never satisfy "reload only when nothing is being written" - it would
  // be guessing, and a wrong guess costs the captain a ruling in progress.
  //
  // What is left is a bar that reports the gap and a button the reader presses.
  // That is the whole value in the case the host does not cover: a copy opened
  // as a plain file, or a write the host missed, where nothing else would ever
  // say the page had gone stale.
  var meta = document.querySelector('meta[name="fm-folded-at"]');
  var mine = meta ? meta.getAttribute("content") : "";
  var ageEl = document.getElementById("fm-fresh-age");
  var dot = document.getElementById("fm-fresh-dot");
  var bar = document.getElementById("fm-stale");
  var barTimes = document.getElementById("fm-stale-times");
  var reload = document.getElementById("fm-stale-reload");
  var STALE_GAP = 120;

  function coarse(seconds) {
    if (seconds < 90) { return seconds + "s"; }
    if (seconds < 5400) { return Math.round(seconds / 60) + "m"; }
    if (seconds < 129600) { return Math.round(seconds / 3600) + "h"; }
    return Math.round(seconds / 86400) + "d";
  }

  function ageOfMine() {
    var then = Date.parse(mine);
    if (isNaN(then)) { return null; }
    return Math.max(0, Math.round((Date.now() - then) / 1000));
  }

  function paint() {
    var age = ageOfMine();
    if (ageEl && age !== null) { ageEl.textContent = coarse(age) + " ago"; }
  }

  function showStale(theirs, gap) {
    if (bar) { bar.hidden = false; }
    if (barTimes) {
      barTimes.textContent = "you are viewing " + mine + "; the record is at " + theirs;
    }
    if (dot && gap >= STALE_GAP) { dot.classList.add("stale"); }
  }

  function poll() {
    if (!mine || !window.fetch) { return; }
    fetch(location.href, { cache: "no-store" }).then(function (response) {
      return response.ok ? response.text() : null;
    }).then(function (body) {
      // A failed or unreadable poll says nothing about freshness, so nothing
      // on the page changes. Unknown is not stale, and it is not fresh either.
      if (!body) { return; }
      var found = /<meta name="fm-folded-at" content="([^"]+)"/.exec(body);
      if (!found) { return; }
      var theirs = found[1];
      if (theirs === mine) { return; }
      var gap = Math.round((Date.parse(theirs) - Date.parse(mine)) / 1000);
      if (isNaN(gap) || gap <= 0) { return; }
      showStale(theirs, gap);
    }).catch(function () { /* unknown, so nothing changes */ });
  }

  if (reload) { reload.addEventListener("click", function () { location.reload(); }); }
  paint();
  setInterval(paint, 15000);
  setInterval(poll, 30000);
})();
"""


def page_open(title, doc):
    """Everything above <body>, shared by the two pages this renderer emits."""
    out = ["<!doctype html>",
           '<html lang="en"><head><meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width,initial-scale=1">']
    # THE FOLD TIME, IN A MACHINE-READABLE PLACE. The freshness poll reads this
    # out of the copy on disk to answer "is what I am looking at current?"; it
    # is the one field that has to survive being fetched and string-matched
    # rather than parsed, so it lives in a meta element of its own.
    out.append('<meta name="fm-folded-at" content="%s">' % esc(doc["folded_at"]))
    # THE TITLE NAMES THE PAGE AND COUNTS NOTHING. Lavish copies the artifact's
    # <title> into the HOSTING page at load and does not re-propagate it when
    # the tick rewrites the board and the frame live-reloads, so a count kept
    # here would go on reporting the old number after the redraw that changed
    # it (docs/verification/bridge-hosted-input.md). A count change is the only
    # event that moves the number and is exactly the event that leaves the tab
    # stale, so the count lives in rendered content instead.
    out.append("<title>%s</title>" % esc(title))
    out.append("<style>%s</style></head><body>" % CSS)
    return out


def rec_chip(rec):
    """Recommender attribution, and never a colour state.

    Green means queued on this card and nothing else, so a recommendation is a
    muted chip inside the option - it can never be mistaken for something the
    captain selected. More than one option may carry one when the seats
    disagree, and that disagreement is shown rather than resolved: picking a
    winner here would hide from the captain the one fact they most need.
    """
    if not rec:
        return ""
    return '<span class="rectag">rec: %s</span>' % esc(rec)


def local_terms(item, glossary):
    """Colliding terms, repeated where the ruling is made.

    A term that means different things in different projects is defined once up
    front on the history page - and repeated locally, because the reader
    arriving at a decision must never have to scroll back to find out which
    meaning is in play. On this board "locally" is inside the card's context
    dropdown: exactly where the detail needed to rule already lives, and costing
    the board no height while it is closed.
    """
    bits = []
    for entry in glossary:
        if not entry["collision"]:
            continue
        for sub in entry["entries"]:
            if sub["project"] == item["project"]:
                bits.append("<b>%s</b> here means %s"
                            % (esc(entry["term"]), esc(sub["means"])))
    return "; ".join(bits)


def ask_card(item, glossary=()):
    """One open decision (Law 5).

    Ref, project, age, a clamped one-line title, the answers, and a collapsed
    context dropdown holding what is needed to rule. The full record stays in
    the ledger, and the dropdown adds no height to the board while closed -
    which is what lets Law 2 hold with a card that still carries enough to
    decide on.
    """
    classes = ["ask"]
    if item.get("aging"):
        classes.append("aging")
    ref = item["ref"] or item["id"]
    head = ['<span class="ref">%s</span>' % esc(ref),
            '<span class="proj">%s</span>' % esc(item["project"])]
    # Law 3: an open critical is an ask card with a critical chip. It is not a
    # separate zone, and a resolved one does not render at all.
    #
    # ONE CHIP, NOT TWO. A critical's severity defaults to critical, so kind and
    # severity say the same word - and two identical chips side by side read as
    # two separate facts, which is the reader inventing a distinction the record
    # never made. The severity chip is dropped only when it would repeat the
    # kind; a critical marked at some other severity still shows both, because
    # then they genuinely differ.
    if item["kind"] == "critical":
        head.append('<span class="chip critical">critical</span>')
        if item["severity"] != "critical":
            head.append(sev_chip(item))
    else:
        head.append(sev_chip(item))
    if item.get("aging"):
        head.append('<span class="chip aging">waiting %s</span>' % esc(item["age_label"]))
    head.append('<span class="age">%s</span>' % esc(item["age_label"]))

    parts = ['<div class="%s" id="item-%s" data-ask-ref="%s" data-ask-id="%s">'
             % (" ".join(classes), esc(item["id"]), esc(ref), esc(item["id"])),
             '<div class="askhead">%s</div>' % "".join(bit for bit in head if bit),
             '<div class="asktitle">%s</div>' % esc(item["title"] or item["id"])]

    forms = item.get("answer_forms") or []
    if forms:
        options = []
        for form in forms:
            # The ref rides on the queued prompt, not on the visible option
            # text: the option is a control now, so what identifies the ask
            # travels in the data the button sends rather than in words the
            # captain has to read twice.
            options.append(
                '<button class="ansbtn" data-answer-label="%s" data-answer-text="%s">'
                "%s%s</button>"
                % (esc(form["label"]), esc(form["body"]),
                   esc(form["text"]), rec_chip(form["rec"])))
        parts.append('<div class="answers">%s</div>' % "".join(options))
        parts.append('<button class="qbtn" hidden>Queue answer</button>')
        parts.append('<span class="qnote" hidden></span>')

    context = []
    if item["body"]:
        context.append(esc(item["body"]))
    if item["note"]:
        context.append(esc(item["note"]))
    if item["pointer"]:
        target = item["pointer"]
        if target.startswith("http://") or target.startswith("https://"):
            context.append(link(target))
        else:
            context.append("<code>%s</code>" % esc(target))
    if item["check"]:
        context.append("check <code>%s</code>" % esc(item["check"]))
    terms = local_terms(item, glossary)
    if terms:
        context.append('<span class="local-terms">%s</span>' % terms)
    if context:
        parts.append('<details class="ctxd"><summary>context</summary>'
                     '<div class="ctxbody">%s</div></details>'
                     % "<br>".join(context))
    parts.append("</div>")
    return "".join(parts)


def lanes_section(env):
    """Work in flight, grouped by project, from state/ at fold time.

    Health is the WATCHER's verdict, read from the markers it maintains rather
    than recomputed here - and never CPU, which measures whether a process is
    busy and not whether the work is moving. When nothing is maintaining those
    markers the dots read unknown rather than inheriting a green nobody is
    standing behind.
    """
    lanes = env.get("lanes") or {}
    groups = lanes.get("projects") or []
    out = ['<section><h2>Lanes in flight <span class="note">'
           'from the fleet\'s own records at fold time &middot; health is step '
           'evidence, never CPU</span></h2>']
    if not lanes.get("health_readable", True) and lanes.get("health_unreadable_because"):
        out.append('<p class="zone-note">Lane health is unread: %s. The dots '
                   "below say unknown rather than green.</p>"
                   % esc(lanes["health_unreadable_because"]))
    if not groups:
        out.append('<p class="empty">No projects and no lanes recorded.</p>')
        out.append("</section>")
        return "".join(out)
    out.append('<div class="lanes">')
    for group in groups:
        rows = group["lanes"]
        # AN IDLE PROJECT IS ONE LINE, NOT A CARD WITH A LINE IN IT. It is
        # listed rather than omitted, because "no lanes" and "no such project"
        # must not look the same - but a project with nothing dispatched has
        # nothing to lay out, and four of them stacked as full cards is height
        # spent on the absence of news.
        idle = "" if rows else '<span class="idle">idle - nothing dispatched</span>'
        out.append('<div class="lanegroup%s"><div class="lghead">'
                   '<span class="p">%s</span><span class="n">%d %s</span>%s</div>'
                   % (" quiet" if idle else "", esc(group["project"]), len(rows),
                      "lane" if len(rows) == 1 else "lanes", idle))
        merges = []
        for row in rows:
            out.append('<div class="lane"><span class="nm">%s</span>'
                       '<span class="ph">%s</span><span class="la">%s</span>'
                       '<span class="hd %s" title="%s"></span></div>'
                       % (esc(row["id"]), esc(row["phase"]),
                          esc("reported %s" % row["reported_label"]
                              if row["reported_label"] else ""),
                          esc(row["health"]),
                          esc({"ok": "moving", "warn": "supervision has flagged this lane",
                               "unknown": "health unread"}[row["health"]])))
            if row["pr"]:
                merges.append("%s %s" % (esc(row["id"]), link(row["pr"])))
        # Law 4's other half: an ask covered by a standing word never becomes a
        # card. Where it landed is a merge-line entry here, so the captain sees
        # what is riding on their standing word without being asked again.
        if merges:
            out.append('<div class="mergeline">merge: %s</div>'
                       % " &middot; ".join(merges))
        out.append("</div>")
    out.append("</div></section>")
    return "".join(out)


def _as_of(age_seconds):
    """How old a reused reading is, whenever it is not from this fold.

    A cached number shown without its age is the capacity lesson again: a value
    that was true once, presented as a value that is true now. An age that could
    not be worked out says so, for the same reason and one step further along:
    unknown age and taken-just-now are different facts about the reading.
    """
    if age_seconds is None:
        return " · reused, and how old it is could not be worked out"
    if not age_seconds:
        return ""
    return " · read %s ago" % _age_label(age_seconds)


def admission_section(env):
    """The denominators, read live, and one verdict that accounts for all three.

    An unreadable gauge is never rounded toward comfort or toward alarm. The
    verdict names what it could not read, so "admissible" and "admissible as
    far as anything here can tell" are never the same sentence.
    """
    adm = env.get("admission") or {}
    floor = adm.get("floor_mib") or ADMISSION_FLOOR_MIB
    out = ['<section><h2>Admission <span class="note">the denominators, read at '
           "fold time</span></h2>", '<div class="adm">']

    memory = adm.get("memory")
    unknowns = []
    if memory:
        headroom_ok = memory["available_mib"] >= floor
        out.append('<div class="gauge %s"><div class="lbl">Memory headroom</div>'
                   '<div class="val">%.1f GiB free</div>'
                   '<div class="sub">of %.1f GiB &middot; floor %.1f GiB</div></div>'
                   % ("ok" if headroom_ok else "warn",
                      memory["available_mib"] / 1024.0,
                      memory["total_mib"] / 1024.0, floor / 1024.0))
    else:
        headroom_ok = None
        unknowns.append("memory headroom")
        out.append('<div class="gauge unknown"><div class="lbl">Memory headroom</div>'
                   '<div class="val">could not read</div><div class="sub">%s</div></div>'
                   % esc(adm.get("memory_unreadable_because", "")))

    host = adm.get("host")
    if host:
        out.append('<div class="gauge ok"><div class="lbl">Host memory</div>'
                   '<div class="val">%.1f / %.1f GiB used</div>'
                   '<div class="sub">the machine underneath%s</div></div>'
                   % (host["used_mib"] / 1024.0, host["total_mib"] / 1024.0,
                      _as_of(adm.get("host_age_seconds"))))
    else:
        out.append('<div class="gauge unknown"><div class="lbl">Host memory</div>'
                   '<div class="val">not read</div><div class="sub">%s</div></div>'
                   % esc(adm.get("host_unreadable_because", "")))

    quota = adm.get("quota")
    if quota:
        # THE TIGHTEST READABLE PROVIDER LEADS, because that is the one that
        # decides what can be dispatched. Providers with no reading are counted
        # rather than listed one by one: four names each saying "unread" is a
        # wall of nothing, and the count says the same thing in three words
        # without pretending the gap is not there.
        read, unread = [], []
        for row in quota["providers"]:
            remaining = row.get("remaining_percent")
            if isinstance(remaining, (int, float)):
                read.append((remaining, "%s %d%% left%s"
                             % (row["name"], remaining,
                                " (%s)" % row["pace"].replace("_", " ")
                                if row.get("pace") else "")))
            elif row.get("status"):
                read.append((101, "%s %s" % (row["name"], row["status"])))
            else:
                unread.append(row["name"])
        read.sort(key=lambda pair: pair[0])
        tight = bool(read) and read[0][0] < 20
        lead = read[0][1] if read else "no provider could be read"
        rest = [text for _, text in read[1:]]
        if unread:
            rest.append("%d unread: %s" % (len(unread), ", ".join(unread)))
        out.append('<div class="gauge %s"><div class="lbl">Provider headroom</div>'
                   '<div class="val">%s</div><div class="sub">%s</div></div>'
                   % ("warn" if tight or not read else "ok", esc(lead),
                      esc((" · ".join(rest) if rest else "quota-axi")
                          + _as_of(adm.get("quota_age_seconds")))))
    else:
        tight = False
        unknowns.append("provider headroom")
        out.append('<div class="gauge unknown"><div class="lbl">Provider headroom</div>'
                   '<div class="val">could not read</div><div class="sub">%s</div></div>'
                   % esc(adm.get("quota_unreadable_because", "")))

    lanes = (env.get("lanes") or {}).get("count", 0)
    if headroom_ok is False:
        verdict, cls = ("NEW WORK: HOLD", "hold")
        why = ("available memory is under the %.1f GiB floor - a spike here has "
               "killed concurrent runs" % (floor / 1024.0))
    elif headroom_ok is None:
        verdict, cls = ("NEW WORK: UNKNOWN", "unknown")
        why = "the memory floor could not be read, so admissibility is unproven"
    else:
        verdict, cls = ("NEW WORK: ADMISSIBLE", "")
        why = "%d %s in flight" % (lanes, "lane" if lanes == 1 else "lanes")
        if tight:
            why += "; a provider window is tight - prefer a routable alternative"
    if unknowns and headroom_ok is not None:
        why += "; %s could not be read" % " and ".join(unknowns)
    out.append('<div class="verdict %s"><b>%s</b> &middot; %s</div>'
               % (cls, esc(verdict), esc(why)))
    out.append("</div></section>")
    return "".join(out)


def problem_banners(doc):
    """The fold's own honesty, which outranks the length rule.

    Law 2 caps what the board spends on routine content; it does not licence
    hiding a stream the fold could not account for. These render only when
    something is actually wrong, so an ordinary board never pays for them.
    """
    counts = doc["counts"]
    items = doc["items"]
    out = []
    if not doc["conserved"] or counts["malformed"]:
        out.append('<div class="banner"><b>Ledger records not accounted for.</b> '
                   "%d non-blank lines, %d folded, %d unreadable. The board can "
                   "only show what the fold could read."
                   % (counts["lines_considered"], counts["records"],
                      counts["malformed"]))
        for bad in doc["malformed"][:5]:
            out.append('<div class="row"><code>line %d: %s</code></div>'
                       % (bad["line"], esc(bad["reason"])))
        if doc["malformed_omitted"]:
            out.append("<div>+%d more unreadable lines.</div>" % doc["malformed_omitted"])
        out.append("</div>")
    if doc["unobserved_outcomes"]:
        unresolved = doc["unobserved_outcomes"]
        out.append('<div class="banner"><b>%d %s written before the outcome axis '
                   "existed.</b> Nothing in the record says how they ended, so the "
                   "board says unknown rather than guessing: %s.%s</div>"
                   % (len(unresolved),
                      "row was" if len(unresolved) == 1 else "rows were",
                      ", ".join(esc(items[key]["ref"] or key) for key in unresolved[:8]),
                      "" if len(unresolved) <= 8 else " +%d more" % (len(unresolved) - 8)))
    if not doc["ledger"]["present"]:
        out.append('<div class="banner">No ledger at <code>%s</code> yet. The '
                   "board is empty because nothing has been written, not because "
                   "nothing happened.</div>" % esc(doc["ledger"]["path"]))
    return "".join(out)


def stale_bar():
    """The freshness bar, emitted identically by both pages.

    THE POLL RUNS ON BOTH PAGES, SO THE EXPLANATION MUST TOO. The shared script
    turns the freshness dot orange wherever it detects a newer fold; a page that
    changed the dot without this bar would signal a state it could neither
    explain nor let the reader act on. A signal with no explanation is the
    defect - dropping the dot on one page would remove the signal rather than
    the confusion, so the bar is what gets shared, from one construction site so
    the two pages cannot drift.

    Hidden by default and in normal flow like everything else on both pages:
    nothing here is fixed, absolute or sticky, so it can never come to cover the
    rows it sits over. It names both times, offers the button, and never reloads
    by itself.
    """
    return "\n".join([
        '<div class="stalebar" id="fm-stale" hidden>',
        '<span><b>STALE</b> - <span id="fm-stale-times"></span></span>',
        '<button id="fm-stale-reload">reload now</button>',
        '<span class="why">this page never reloads itself - nothing you have '
        "part-way written is at risk from it</span>",
        "</div>",
    ])


def render_board(doc, env):
    """The captain's action surface (Laws 1 and 2).

    Open asks, the co-captain line, lanes, admission. Nothing else - resolved,
    landed, discarded, events, tallies and legends are ABSENT rather than
    collapsed, because a collapsed section is still a row of chrome above the
    next decision. Board length therefore scales with open asks and nothing
    else, and the first decision is fully visible at 1080px with no scrolling.
    """
    items = doc["items"]
    asks = doc.get("asks", [])
    cocaptain = doc.get("cocaptain_asks", [])
    lanes = (env.get("lanes") or {}).get("count", 0)
    out = page_open("Bridge", doc)
    add = out.append

    add('<header class="top"><div class="wrap">')
    add('<div class="toprow">')
    add('<h1>Bridge<span class="sub">captain\'s action surface &middot; '
        "generated from the ledger</span></h1>")
    add('<div class="fresh"><span class="dot" id="fm-fresh-dot"></span>'
        '<span>fold <span class="mono">%s</span> &middot; '
        '<span id="fm-fresh-age">just now</span></span></div>'
        % esc(doc["folded_at"]))
    add("</div>")
    # THE COUNTS LINE IS THE WHOLE HEADER SUMMARY. One line, three numbers, and
    # the way to history. It is rendered content, which is the only surface on
    # a hosted board that a redraw is guaranteed to refresh.
    add('<div class="countline">'
        '<b class="you">%d</b> waiting on you<span class="sep">&middot;</span>'
        '<b class="co">%d</b> with the co-captain<span class="sep">&middot;</span>'
        '<b class="fm">%d</b> %s in flight<span class="sep">&middot;</span>%s</div>'
        % (len(asks), len(cocaptain), lanes,
           "lane" if lanes == 1 else "lanes",
           link(HISTORY_FILENAME, "history →", external=False)))
    add("</div></header>")

    add('<div class="wrap">')
    add(problem_banners(doc))

    # THE LABEL STATES THE SORT THE CODE ACTUALLY USES, on one line, so the
    # guard that holds the two together can read it. Its predecessor said
    # "oldest first" over a severity-first ordering - a false claim about its
    # own ordering, on the surface whose entire job is collecting rulings, where
    # a reader who trusts it takes the top row for the oldest outstanding ask.
    # Severity first is the right ordering for a surface triaged from; the label
    # was the defect.
    add("<section>")
    if asks:
        add('<h2>Your decisions<span class="note">severity first, then longest '
            "waiting &middot; pick an answer, press Queue, Send delivers all "
            "&middot; or annotate the card to say it your way</span></h2>")
        for key in asks:
            add(ask_card(items[key], doc["glossary"]))
    else:
        add("<h2>Your decisions</h2>")
        add('<p class="allclear">Nothing is waiting on you.</p>')
    add("</section>")

    if cocaptain:
        add('<section><h2>With the co-captain <span class="note">not yours to '
            "answer - shown so you see where it went</span></h2>")
        for key in cocaptain:
            item = items[key]
            add('<div class="corow" id="item-%s"><span class="ref">%s</span>'
                '<span class="t">%s</span>'
                '<span class="who">reads via the record &middot; %s</span></div>'
                % (esc(item["id"]), esc(item["ref"] or item["id"]),
                   esc(item["title"] or item["id"]), esc(item["age_label"])))
        add("</section>")

    add(lanes_section(env))
    add(admission_section(env))

    add(stale_bar())

    add("<footer>")
    add('<div class="cols">')
    add("<span>%s</span>" % link(HISTORY_FILENAME,
                                 "history: resolved, landed and events live there",
                                 external=False))
    add("<span>record: <code>%s</code></span>" % esc(doc["ledger"]["path"]))
    add("<span>rule by click, annotation, or terminal relay - all three land "
        "in the record</span>")
    add("</div>")
    # WHAT THIS SURFACE PROMISES, AND WHAT IT DOES NOT. Every line is a measured
    # verdict rather than a design intention; the measurements and their exact
    # output are in docs/verification/bridge-hosted-input.md and
    # docs/verification/bridge-board-v2.md. A reader who trusts the wrong half
    # loses a ruling and does not find out.
    add('<div class="promises">')
    add("<div><b>What this page does, and does not.</b></div>")
    add("<div>Pick an answer and press Queue, and the ruling waits in the "
        "conversation panel until you press Send to Agent. Re-queueing the "
        "same decision replaces what was there, so changing your mind never "
        "sends two answers.</div>")
    add("<div>A queued ruling survives this page being redrawn, though the "
        "card stops showing its tick afterwards. It has not been lost: it is "
        "still in the conversation panel, and re-queueing the same decision "
        "replaces that entry rather than sending a second one.</div>")
    add("<div>A ruling still sitting in the annotation box does not survive. "
        "This page is rewritten whenever the record changes, and an unqueued "
        "annotation goes with it, not saved anywhere. Queue it, then keep "
        "reading.</div>")
    add("<div>To say it in your own words instead, annotate the card and send "
        "from the conversation panel.</div>")
    add("<div>Opened as a plain file with nothing behind it, this page has no "
        "input path at all. Tell firstmate directly.</div>")
    add("</div>")
    add('<div class="row">This page is generated. Edits to it are overwritten '
        "the next time the record changes; facts belong in the record.</div>")
    add("</footer></div>")

    # The exact state document this board was drawn from rides along, so the
    # board can be audited without trusting the renderer, and the live readings
    # beside it so a gauge can be checked against what was actually read.
    add('<script type="application/json" id="fm-bridge-state">')
    add(state_json(doc))
    add("</script>")
    add('<script type="application/json" id="fm-bridge-env">')
    add(state_json(env))
    add("</script>")
    add("<script>%s</script>" % SCRIPT)
    add("</body></html>")
    return "\n".join(out) + "\n"


def history_row(item):
    """One closed item, in the same one-line form the board uses for an ask."""
    ends = chip(item) + outcome_chip(item) + sev_chip(item)
    parts = ['<div class="hitem" id="item-%s">' % esc(item["id"]),
             '<div class="hrow"><span class="ref">%s</span>'
             '<span class="proj">%s</span><span class="what">%s</span>'
             '<span class="ends">%s</span></div>'
             % (esc(item["ref"] or "-"), esc(item["project"]),
                esc(item["title"] or item["id"]), ends)]
    detail = []
    if item["body"]:
        detail.append(esc(item["body"]))
    if item["note"]:
        # ONE MEANING PER ACCENT. A note is an ordinary field on every write
        # command, so it is dim by default - accenting it would make a routine
        # event read as a problem and give orange a second job. The exception
        # is the judgement that authorized an override: a forced cleanup skipped
        # the landed-work test, and the reason someone gave for skipping it is
        # the most destructive decision in the fleet. That one earns the accent.
        detail.append('<span class="why%s">%s</span>'
                      % (" override" if item["outcome"] in ("discarded", "unknown")
                         else "", esc(item["note"])))
    if item["pointer"]:
        target = item["pointer"]
        if target.startswith("http://") or target.startswith("https://"):
            detail.append('<span class="lbl">outcome</span>' + link(target))
        else:
            detail.append('<span class="lbl">outcome</span><code>%s</code>' % esc(target))
    elif item["pointer_gap"]:
        detail.append('<span class="lbl">outcome</span>%s, with no pointer to '
                      "where it went - see record hygiene" % esc(item["pointer_gap"]))
    if item["answers"]:
        detail.append("answers offered: %s"
                      % esc(" | ".join(item["answers"])))
    detail.append("recorded %s &middot; %d %s"
                  % (esc(item["ts"] or "at an unrecorded time"), item["updates"],
                     "update" if item["updates"] == 1 else "updates"))
    parts.append('<details class="ctxd"><summary>context</summary>'
                 '<div class="ctxbody hbody">%s</div></details>' % "<br>".join(detail))
    parts.append("</div>")
    return "".join(parts)


def render_history(doc):
    """Everything the board excludes, on its own page.

    Named history rather than archive: it says what the page is, not a storage
    action nobody performed. It carries the return link in its header, because
    the captain must never have to scroll their way back to the decisions.
    """
    items = doc["items"]
    zones = doc["zones"]
    caps = doc["caps"]
    counts = doc["counts"]
    summary = doc["summary"]
    outcomes = doc["outcomes"]
    total = counts["board_items"]
    out = page_open("Bridge - history", doc)
    add = out.append

    # BETWEEN THE TWO PAGES THERE IS NO GAP. The board renders open asks and
    # the co-captain's routed rows; this page renders everything else, and
    # "everything else" has to be defined as the complement rather than as a
    # list of closed zones - or an item that is neither an ask nor closed, like
    # a decision marked resolved that nothing has yet observed to end, would
    # appear on neither page and be quietly lost from both.
    on_board = set(doc.get("asks", [])) | set(doc.get("cocaptain_asks", []))

    def elsewhere(keys):
        return [key for key in keys if key not in on_board]

    add('<header class="top"><div class="wrap">')
    add('<div class="toprow"><h1>History<span class="sub">everything the board '
        "leaves out &middot; generated from the ledger</span></h1>")
    add('<div class="fresh"><span class="dot" id="fm-fresh-dot"></span>'
        '<span>fold <span class="mono">%s</span> &middot; '
        '<span id="fm-fresh-age">just now</span></span></div></div>'
        % esc(doc["folded_at"]))
    add('<div class="countline">%s</div>'
        % link(BOARD_FILENAME, "← board", external=False))
    add("</div></header>")

    add('<div class="wrap">')
    add(problem_banners(doc))

    # TWO TALLIES, EACH COUNTING EVERY ITEM, AND THE ASK COUNT APART FROM BOTH.
    # They live here rather than on the board: a tally is something a reader
    # consults, not something they act on, and every row of it above the first
    # decision is length Law 2 does not allow.
    add('<section><h2>Tallies</h2>')
    add('<div class="tallies"><div class="tallylbl">who owes it, all %d</div>' % total)
    for state, label, cls in (("needs-captain", "needs-captain", "ask"),
                              ("needs-cocaptain", "needs-cocaptain", "co"),
                              ("fm-handling", "firstmate has", "fm"),
                              ("resolved", "resolved", "ok"),
                              ("unstated", "never said", "warn"),
                              ("unrecognized", "unrecognized", "warn")):
        if summary.get(state, 0) or state in ("needs-captain", "fm-handling", "resolved"):
            add('<div class="tally %s"><b>%d</b>%s</div>'
                % (cls, summary.get(state, 0), esc(label)))
    add("</div>")
    add('<div class="tallies"><div class="tallylbl">how it ended, all %d</div>' % total)
    for outcome, label, cls in (("in-flight", "still going", "fm"),
                                ("landed", "landed", "ok"),
                                ("discarded", "discarded", "warn"),
                                ("unknown", "ended, how unknown", "warn"),
                                ("unrecognized", "unrecognized", "warn")):
        if outcomes.get(outcome, 0) or outcome in ("in-flight", "landed"):
            add('<div class="tally %s"><b>%d</b>%s</div>'
                % (cls, outcomes.get(outcome, 0), esc(label)))
    add('<div class="tally"><b>%d</b>records folded</div>' % counts["records"])
    add("</div>")
    add('<p class="zone-note">Two things about every row, kept apart: who owes '
        "it, and how it ended. Neither answers the other, so each tally counts "
        "every item and both total the same number.</p>")
    add('<div class="legend">'
        '<span class="l-red">needs the captain</span>'
        '<span class="l-purple">needs the co-captain</span>'
        '<span class="l-blue">firstmate has it</span>'
        '<span class="l-green">resolved, or landed</span>'
        '<span class="l-orange">discarded, ended unknown, aging, or otherwise off</span>'
        '<span class="l-cyan">pointer or command</span>'
        "</div></section>")

    collisions = [g for g in doc["glossary"] if g["collision"]]
    if collisions:
        add("<section><h2>Terms that mean different things by project</h2>")
        add('<p class="zone-note">Defined here once, and repeated in each '
            "project section below so you never scroll back.</p>")
        add('<div class="glossary"><dl>')
        for entry in collisions:
            add('<dt>%s<span class="collide">collision</span></dt>' % esc(entry["term"]))
            for sub in entry["entries"]:
                add("<dd><b>%s</b>: %s</dd>" % (esc(sub["project"]), esc(sub["means"])))
        add("</dl></div></section>")

    add("<section><h2>Criticals</h2>")
    shown_any = False
    still_open = elsewhere(zones["criticals"])
    if still_open:
        add('<p class="grouplabel">open, and not waiting on you</p>')
        for key in still_open:
            add(history_row(items[key]))
        shown_any = True
    for group, label in (("criticals_landed", "landed"),
                         ("criticals_discarded", "discarded"),
                         ("criticals_unknown", "ended, how unknown")):
        shown = zones[group][:caps["closed_decisions"]]
        if not shown:
            continue
        shown_any = True
        add('<p class="grouplabel">%s</p>' % esc(label))
        for key in shown:
            add(history_row(items[key]))
        hidden = len(zones[group]) - len(shown)
        if hidden > 0:
            add('<div class="overflow">+%d more %s - the record has them: '
                "<code>%s</code></div>"
                % (hidden, esc(label), esc(doc["checks"]["raw stream"])))
    if not shown_any:
        add('<p class="empty">No critical is open or closed.</p>')
    add("</section>")

    add("<section><h2>Decisions, by project</h2>")
    add('<p class="zone-note">A ref like <b>O1</b> is unique to its project and '
        "never renumbers, so a bare number is safe to quote. The ones waiting "
        "on you are on the board; everything else about them is here.</p>")
    any_group = False
    for group in zones["decisions"]:
        closed = [side for side in ("landed", "discarded", "unknown") if group[side]]
        open_elsewhere = elsewhere(group["open"])
        local = [g for g in doc["glossary"]
                 if any(sub["project"] == group["project"] for sub in g["entries"])]
        # A project with no closed decisions still gets its heading when a term
        # collides there: the definition has to appear beside that project's
        # material, not only in the list up top.
        if not closed and not open_elsewhere and not local:
            continue
        any_group = True
        add('<h3 class="projhead">%s <span class="refs">refs %s1, %s2, '
            "&hellip;</span></h3>"
            % (esc(group["project"]), esc(group["prefix"]), esc(group["prefix"])))
        if local:
            bits = []
            for entry in local:
                means = next(sub["means"] for sub in entry["entries"]
                             if sub["project"] == group["project"])
                bits.append("<b>%s</b> here means %s" % (esc(entry["term"]), esc(means)))
            add('<p class="local-terms">%s</p>' % "; ".join(bits))
        if open_elsewhere:
            add('<p class="grouplabel">open, and not waiting on you</p>')
        for key in open_elsewhere:
            add(history_row(items[key]))
        for side, label in (("landed", "landed"), ("discarded", "discarded"),
                            ("unknown", "ended, how unknown")):
            shown = group[side][:caps["closed_decisions"]]
            if shown:
                add('<p class="grouplabel">%s</p>' % esc(label))
            for key in shown:
                add(history_row(items[key]))
            hidden = len(group[side]) - len(shown)
            if hidden > 0:
                add('<div class="overflow">+%d more %s in %s - the record has '
                    "them: <code>%s</code></div>"
                    % (hidden, esc(side), esc(group["project"]),
                       esc(doc["checks"]["raw stream"])))
    if not any_group:
        add('<p class="empty">No decision has closed.</p>')
    add("</section>")

    add("<section><h2>Notable events</h2>")
    add('<p class="zone-note">Newest first, capped. Nothing here is an ask.</p>')
    # THROUGH THE COMPLEMENT LIKE EVERY OTHER SECTION. An event routed to a
    # reader - `note --to captain`, or a later `route` - is on that reader's
    # queue and therefore an ask card on the board, so rendering the zone
    # unfiltered here put the same item on both pages and had the captain
    # triaging it twice. The overflow count is taken from the filtered list for
    # the same reason: counting board rows as hidden history overstates what is
    # left behind.
    events_elsewhere = elsewhere(zones["events"])
    shown_events = events_elsewhere[:caps["events"]]
    if shown_events:
        for key in shown_events:
            add(history_row(items[key]))
    else:
        add('<p class="empty">No events recorded.</p>')
    hidden = len(events_elsewhere) - len(shown_events)
    if hidden > 0:
        add('<div class="overflow">+%d older events. They are not lost - the '
            "record has every one: <code>%s</code></div>"
            % (hidden, esc(doc["checks"]["raw stream"])))
    add("</section>")

    add("<section><h2>Fleet</h2>")
    add('<p class="zone-note">Every task in the record. Live work is on the '
        "board as a lane; how each closed task ended is here.</p>")
    open_rows = elsewhere(zones["fleet_open"])
    closed_shown = {}
    for group in ("fleet_landed", "fleet_discarded", "fleet_unknown"):
        closed_shown[group] = zones[group][:caps["fleet_closed"]]
    groups = [("still going", open_rows),
              ("landed", closed_shown["fleet_landed"]),
              ("discarded", closed_shown["fleet_discarded"]),
              ("ended, how unknown", closed_shown["fleet_unknown"])]
    if any(rows for _, rows in groups):
        for label, rows in groups:
            if not rows:
                continue
            add('<p class="grouplabel">%s</p>' % esc(label))
            for key in rows:
                add(history_row(items[key]))
    else:
        add('<p class="empty">No tasks in the record.</p>')
    for group, label in (("fleet_landed", "landed"),
                         ("fleet_discarded", "discarded"),
                         ("fleet_unknown", "ended, how unknown")):
        hidden = len(zones[group]) - len(closed_shown[group])
        if hidden > 0:
            add('<div class="overflow">+%d older %s tasks in the record. They '
                "are capped here, not dropped - <code>%s</code> has every "
                "one.</div>" % (hidden, esc(label), esc(doc["checks"]["raw stream"])))
    add("</section>")

    if zones["unzoned"]:
        add("<section><h2>Unrecognized records</h2>")
        add('<p class="zone-note">These carry a kind this board does not know. '
            "They are shown rather than filed somewhere convenient, because a "
            "record quietly placed in the wrong bucket is how a surface starts "
            "lying.</p>")
        for key in zones["unzoned"]:
            add(history_row(items[key]))
        add("</section>")

    add(stale_bar())

    add("<footer>")
    add("<div><b>Check this page against its own source.</b></div>")
    for label in sorted(doc["checks"]):
        add('<div class="row">%s &nbsp; <code>%s</code></div>'
            % (esc(label), esc(doc["checks"][label])))
    add('<div class="row" style="margin-top:.8rem">ledger &nbsp; <code>%s</code></div>'
        % esc(doc["ledger"]["path"]))
    steering = doc.get("substrate", {}).get("steering", {})
    if steering.get("items"):
        stages = steering.get("stages", {})
        add("<div>%d steering-lifecycle records are in the record but on neither "
            "page - they are machinery, not something for you to read "
            "(sent %d, delivered %d, consumed %d). Ask about one with "
            "<code>bin/fm-bridge-render.sh --lifecycle &lt;id&gt;</code>.</div>"
            % (steering["items"], stages.get("sent", 0),
               stages.get("delivered", 0), stages.get("consumed", 0)))
    add('<div class="row">%s</div>'
        % link(BOARD_FILENAME, "← board", external=False))
    add("</footer></div>")

    add('<script type="application/json" id="fm-bridge-state">')
    add(state_json(doc))
    add("</script>")
    add("<script>%s</script>" % SCRIPT)
    add("</body></html>")
    return "\n".join(out) + "\n"

def state_json(doc):
    """The one serialization of folded state, shared by --state and the copy the
    board embeds.

    `<` is written as its \\u003c escape rather than raw. JSON parses the two
    identically, so the DOCUMENT is unchanged for every consumer, while no
    ledger text can carry a `</script` sequence into the
    <script type="application/json"> element the board embeds this in and have
    the browser end the element early - which turned the rest of the fold into
    live markup. Escaping here rather than at the embed site keeps the two
    output modes byte-identical, which is the property that proves they cannot
    drift.
    """
    return json.dumps(doc, indent=2, sort_keys=True,
                      ensure_ascii=False).replace("<", "\\u003c")


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
    if mode in ("html", "history"):
        # ONE fold, shared in-process: the renderer consumes the return value
        # directly. It is handed no ledger path and opens no file, so the
        # drawing half cannot become a second reader of the stream.
        #
        # The live readings are collected separately and handed in as a second
        # document, for the same reason in the other direction: they are not
        # ledger facts and must never enter the fold, or `--state` - read by the
        # linter, the co-captain and every lifecycle query - would grow a
        # subprocess behind it. Only the board renders them, and this runs on
        # the supervision loop, so only the board pays to collect them.
        global BOARD_FILENAME, HISTORY_FILENAME
        fm_home, state_dir = argv[4], argv[5]
        BOARD_FILENAME, HISTORY_FILENAME = argv[6], argv[7]
        doc = fold(argv[2], argv[3])
        if mode == "html":
            sys.stdout.write(render_board(doc, collect_env(fm_home, state_dir,
                                                           argv[3])))
        else:
            sys.stdout.write(render_history(doc))
        return 0
    if mode == "signature":
        sys.stdout.write(signature(argv[2]) + "\n")
        return 0
    sys.stderr.write("unknown mode: %s\n" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
  PROGRAM=$staged
}

cleanup() { [ -n "$PROGRAM" ] && rm -f "$PROGRAM"; }
trap cleanup EXIT

require_python() {
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to fold the ledger; refusing to render a board that would look empty"
}

# Everything a mode needs before it can run, in one call, FROM THE TOP-LEVEL
# SHELL. Staging inside a substitution is the defect above.
prepare() {
  require_python
  stage_program || die "cannot stage the fold program"
}

# The single seam every consumer goes through.
emit_state() {  # <folded-at> [id]
  python3 "$PROGRAM" state "$(fm_bridge_ledger_path)" "$1" "${2:-}"
}

emit_lifecycle() {  # <folded-at> <id>
  python3 "$PROGRAM" lifecycle "$(fm_bridge_ledger_path)" "$1" "$2"
}

emit_page() {  # <mode: html|history> <folded-at>
  # One process, one fold, shared in-process with the renderer. FM_HOME and the
  # state dir travel with it because the live half of the board - lanes and the
  # admission gauges - is read from them, and the two page basenames because
  # each page links to the other.
  python3 "$PROGRAM" "$1" "$(fm_bridge_ledger_path)" "$2" "$FM_HOME" "$STATE_DIR" \
    "$(basename "$(fm_bridge_board_path)")" "$(basename "$(fm_bridge_history_path)")"
}

emit_html() {  # <folded-at>
  emit_page html "$1"
}

emit_history() {  # <folded-at>
  emit_page history "$1"
}

ledger_signature() {
  python3 "$PROGRAM" signature "$(fm_bridge_ledger_path)"
}

# WRITING THE BOARD IS NOT FREE. Lavish hosts this file and reloads the page on
# any write to it, which discards a ruling the captain is part-way through
# annotating - and it reloads on a BYTE-IDENTICAL rewrite too, because the
# reload keys on the write and not on a diff (measured, both:
# docs/verification/bridge-hosted-input.md). So the last thing before the rename
# is a comparison, and an unchanged board is left alone rather than replaced
# with a copy of itself. Returns 0 when the board is current, whether or not
# this call is what made it so.
#
# Every failure path says on stderr WHAT failed, because the caller records that
# sentence and it is the only thing a later reader has to go on: "the board did
# not render" and "the board's directory is a file" send someone to two very
# different places.
write_page() {  # <emitter> <path> <folded-at>
  local emitter=$1 target=$2 tmp
  mkdir -p "$(dirname "$target")" \
    || { printf 'cannot create the directory %s\n' "$(dirname "$target")" >&2; return 1; }
  tmp="$target.tmp.$$"
  "$emitter" "$3" > "$tmp" \
    || { rm -f "$tmp"; printf 'the fold or the render failed for %s\n' "$target" >&2; return 1; }
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$target" \
    || { rm -f "$tmp"; printf 'cannot replace %s with the rendered page\n' "$target" >&2; return 1; }
  return 0
}

# BOTH PAGES, FROM ONE FOLD EACH, AND ALWAYS TOGETHER. History is a second
# output of the same surface, not a separate artifact with its own schedule: a
# board whose history link resolves to a page from an older fold would be two
# readings of one record, which is the thing this design exists to make
# impossible. History is written FIRST, so the board's history link never goes
# live before the page it points at exists.
write_board() {  # <folded-at>
  write_page emit_history "$(fm_bridge_history_path)" "$1" || return 1
  write_page emit_html "$(fm_bridge_board_path)" "$1" || return 1
  return 0
}

# --- the tick's own failure record -----------------------------------------
#
# A board that renders fine and a board whose render has been failing for an
# hour LOOK IDENTICAL to the reader: the content clock reads an older time, and
# an older time is also what a quiet fleet looks like. Silence there is a stale
# surface wearing a freshness promise, so the tick records its own failures
# where the reason is still in hand, and alarms.
#
# THREE CONSECUTIVE, not one. A single failed render is transient - a full disk
# that drained, a directory mid-replacement - and the next tick retries by
# itself; alarming on it trains the reader to ignore the alarm. Three in a row
# is a broken board.
#
# THE ALARM CARRIES THE REASON. An alarm that only says a render failed sends
# the reader off to reproduce what the tick already knew.
#
# EVIDENCE OF HEALTH RESETS IT, THE PASSAGE OF TIME NEVER DOES: only a render
# that actually landed clears the count, and the reset is logged before the
# counter is dropped so the episode stays reconstructable afterwards.
#
# A SKIP IS NEUTRAL. Only a landed render resets the count and only a failed
# render increments it; a tick that had nothing to render observed nothing about
# the renderer's health and may neither clear an alarm a real failure earned nor
# manufacture one.
#
# No rate limit lives here on purpose. The supervision cycle runs this tick at
# most once per FM_BRIDGE_INTERVAL, so that gate already caps how often the
# alarm can fire; a second limiter would be a second owner of one noise budget,
# and the one that stayed quiet would be the one nobody remembered.
TICK_FAILURES="$STATE_DIR/.bridge-tick-failures"
TICK_LOG="$STATE_DIR/.bridge-tick.log"
TICK_LOG_MAX_BYTES=${FM_BRIDGE_TICK_LOG_MAX_BYTES:-131072}
ALARM_AFTER_FAILURES=3

# Bounded, best-effort, append-only. Never fatal: a log that cannot be written
# must not be the reason the board stops rendering.
tick_log() {  # <line>
  local sz
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '[%s] %s\n' "$(fm_bridge_now)" "$1" >> "$TICK_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TICK_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TICK_LOG_MAX_BYTES" ]; then
    tail -n 500 "$TICK_LOG" > "$TICK_LOG.tmp" 2>/dev/null \
      && mv -f "$TICK_LOG.tmp" "$TICK_LOG" 2>/dev/null
    rm -f "$TICK_LOG.tmp" 2>/dev/null || true
  fi
  return 0
}

# One line, so a reason survives being carried as a wake payload and a log entry.
one_line() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

consecutive_tick_failures() {
  local n
  n=$(cut -f1 "$TICK_FAILURES" 2>/dev/null | head -1)
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# EVERY failure says what failed, on stderr, at every count. Only the
# `bridge-alarm: ` PREFIX is gated behind the threshold, because the prefix is
# what wakes somebody and the reason is what a reader in front of the terminal
# needs either way - bin/fm-session-start.sh runs this tick and prints whatever
# it says, so withholding the reason below the threshold would leave the first
# two failures reported as "could not be brought up to date" and nothing else.
# The count travels with it because "how long has this been broken" is the
# second question every reader asks.
note_tick_failure() {  # <reason>
  local reason n
  reason=$(one_line "$1")
  [ -n "$reason" ] || reason='the render failed without saying why'
  n=$(( $(consecutive_tick_failures) + 1 ))
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\t%s\n' "$n" "$reason" > "$TICK_FAILURES" 2>/dev/null || true
  tick_log "render FAILED ($n in a row): $reason"
  if [ "$n" -ge "$ALARM_AFTER_FAILURES" ]; then
    printf 'bridge-alarm: the captain board has failed to render %s times in a row: %s\n' \
      "$n" "$reason" >&2
  else
    printf 'bridge: the board did not render (failure %s of the %s that raise the alarm): %s\n' \
      "$n" "$ALARM_AFTER_FAILURES" "$reason" >&2
  fi
  return 0
}

note_tick_success() {
  local n
  n=$(consecutive_tick_failures)
  [ "$n" -gt 0 ] || return 0
  tick_log "render RECOVERED after $n consecutive failures; the count is back to 0"
  rm -f "$TICK_FAILURES" 2>/dev/null || true
  return 0
}

# --- the supervision-cycle tick --------------------------------------------
#
# Zero model involvement, and no model is ever woken to update the Bridge.
#
# The tick rewrites the board WHEN THE LEDGER CONTENT CHANGED, and otherwise
# touches nothing at all. It used to restamp a "checked" clock into the board
# every interval so a frozen board and a dead supervision cycle would not look
# the same; that clock is gone, because the write it needed is what makes Lavish
# reload the hosted page and silently discard whatever ruling the captain was
# annotating. Refresh yields to composition: the captain typing a ruling is the
# whole point of the surface, and a clock is not worth interrupting it for.
#
# Liveness moved back to the instruments built for it - the watcher beacon at
# state/.last-watcher-beat and the guard that alarms on a lapsed chain - which
# answer it durably and cost the captain nothing. The ledger keeps every tick's
# material for audit; the board never was that record.
#
# Every way this can fail is funnelled through note_tick_failure with the reason
# it failed for, INCLUDING the ones that used to die() straight out of the
# process: the supervision cycle runs this with output discarded, so a message
# that only reached stderr reached nobody. The counter is what turns a transient
# failure into an alarm once it stops being transient.
do_tick() {
  local verbose=$1 now sig prev board err errf status
  if ! err=$(require_python 2>&1); then
    note_tick_failure "$err"
    return 1
  fi
  # Staged HERE, in do_tick's own shell, which the dispatch calls at top level -
  # so the memo and the EXIT trap see the same variable. See stage_program.
  if ! stage_program; then
    note_tick_failure "cannot stage the fold program"
    return 1
  fi
  now=$(fm_bridge_now)
  board=$(fm_bridge_board_path)
  # The signature IS this call's stdout, so its stderr goes to a file rather
  # than into the value - a diagnostic folded into the signature would read as
  # a ledger change and rewrite the board for nothing. mktemp, like every other
  # temporary this script stages: a predictable name in a shared /tmp is a path
  # somebody else can own first, and this one is opened for truncation.
  if ! errf=$(mktemp "${TMPDIR:-/tmp}/fm-bridge-tick.XXXXXX.err" 2>/dev/null); then
    note_tick_failure "cannot stage a temporary file to capture the fold's diagnostics"
    return 1
  fi
  sig=$(ledger_signature 2>"$errf") || status=$?
  if [ "${status:-0}" -ne 0 ]; then
    err=$(cat "$errf" 2>/dev/null || true)
    rm -f "$errf"
    note_tick_failure "$err"
    return 1
  fi
  rm -f "$errf"
  prev=$(cat "$STAMP" 2>/dev/null || true)

  # THE BASELINE IS THE LAST SUCCESSFUL RENDER, NEVER THE LAST TICK. $STAMP is
  # written only where the board actually landed, so neither a failed attempt
  # nor a skip advances it. A skip is only a skip when there is genuinely
  # nothing owed to the surface.
  #
  # Compare tick-to-tick instead and the failure is silent: two renders fail,
  # the ledger then goes quiet, and every later tick sees "unchanged since last
  # time" and skips forever - the count frozen at two, the board stale, the
  # alarm never earned. Against the last SUCCESSFUL render the unrendered delta
  # stays owed, so every tick keeps ATTEMPTING until it lands or the count
  # crosses the threshold.
  #
  # And the skip itself is NEUTRAL: it neither resets the count nor increments
  # it, because a tick with nothing to render observed nothing about whether the
  # renderer works.
  if [ "$sig" = "$prev" ] && [ -f "$board" ] && [ -f "$(fm_bridge_history_path)" ]; then
    [ "$verbose" -eq 1 ] && printf 'bridge: ledger unchanged since the last render; left %s alone\n' "$board"
    return 0
  fi

  if ! err=$(write_board "$now" 2>&1); then
    note_tick_failure "$err"
    return 1
  fi
  note_tick_success
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s' "$sig" > "$STAMP" 2>/dev/null || true
  [ "$verbose" -eq 1 ] && printf 'bridge: rendered %s\n' "$board"
  return 0
}

MODE='html'
VERBOSE=0
OUT=
ITEM_ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --state) MODE='state'; shift ;;
    --html) MODE='html'; shift ;;
    --history) MODE='history'; shift ;;
    --tick) MODE='tick'; shift ;;
    --write) MODE='write'; shift ;;
    --path) MODE='path'; shift ;;
    --history-path) MODE='history-path'; shift ;;
    --ledger-path) MODE='ledger-path'; shift ;;
    --id) [ $# -gt 1 ] || die "--id needs an item id"; ITEM_ID=$2; shift 2 ;;
    --lifecycle)
      [ $# -gt 1 ] || die "--lifecycle needs an item id"
      MODE='lifecycle'; ITEM_ID=$2; shift 2 ;;
    --out) [ $# -gt 1 ] || die "--out needs a path"; OUT=$2; shift 2 ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

NOW=$(fm_bridge_now)
case "$MODE" in
  path) fm_bridge_board_path; echo ;;
  history-path) fm_bridge_history_path; echo ;;
  ledger-path) fm_bridge_ledger_path; echo ;;
  state)
    prepare
    if [ -n "$OUT" ]; then
      emit_state "$NOW" "$ITEM_ID" > "$OUT"
    else
      emit_state "$NOW" "$ITEM_ID"
    fi
    ;;
  lifecycle)
    prepare
    if [ -n "$OUT" ]; then
      emit_lifecycle "$NOW" "$ITEM_ID" > "$OUT"
    else
      emit_lifecycle "$NOW" "$ITEM_ID"
    fi
    ;;
  html)
    prepare
    if [ -n "$OUT" ]; then emit_html "$NOW" > "$OUT"; else emit_html "$NOW"; fi
    ;;
  history)
    prepare
    if [ -n "$OUT" ]; then emit_history "$NOW" > "$OUT"; else emit_history "$NOW"; fi
    ;;
  write)
    prepare
    write_board "$NOW" || die "could not write the board"
    printf '%s\n' "$(fm_bridge_board_path)"
    printf '%s\n' "$(fm_bridge_history_path)"
    ;;
  tick) do_tick "$VERBOSE" ;;
esac
