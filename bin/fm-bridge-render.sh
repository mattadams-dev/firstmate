#!/usr/bin/env bash
# fm-bridge-render.sh - the READER half of the Bridge: the ONE authoritative
# fold over the ledger, exposed in two output shapes.
#
#   fm-bridge-render.sh --state            folded current state, as structured JSON
#   fm-bridge-render.sh --state --id ID    the same fold, narrowed to one item
#   fm-bridge-render.sh --lifecycle ID     typed answer to "what happened to ID?"
#   fm-bridge-render.sh --html             the HTML board, on stdout
#   fm-bridge-render.sh --write            render the board to its canonical path
#   fm-bridge-render.sh --tick             the supervision-cycle entry point
#   fm-bridge-render.sh --path             print the canonical board path
#   fm-bridge-render.sh --ledger-path      print the canonical ledger path
#
# --out PATH sends any output shape to a file instead of stdout, and --verbose
# (-v) makes --tick report whether it re-rendered the board or left it alone.
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

usage() { sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; }

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
  html      <ledger> <folded-at>           folds once, then render_html(doc)
  signature <ledger>                       content signature of the ledger, for the tick

render_html takes the fold's RETURN VALUE and no ledger path, so the drawing
half cannot re-read or re-parse the stream.
"""
import hashlib
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

    # Every open ask, across every project and kind, oldest first. Oldest first
    # is deliberate: the forgotten ones rise to the top instead of sinking under
    # whatever arrived most recently.
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
ol.asks.co li a:hover { background:rgba(187,154,247,.07); }

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
.card.needs-captain   { border-left-color:var(--tn-red); }
.card.needs-cocaptain { border-left-color:var(--tn-purple); }
.card.fm-handling   { border-left-color:var(--tn-blue); }
.card.resolved      { border-left-color:var(--tn-green); opacity:.72; }
.card.odd           { border-left-color:var(--tn-orange); }
.card.pinned { background:linear-gradient(90deg,rgba(247,118,142,.09),transparent 60%); }

.head { display:flex; gap:.55rem; align-items:baseline; flex-wrap:wrap; }
.ref {
  color:var(--tn-dim); font-weight:700; font-family:ui-monospace,monospace;
  font-size:.85rem; flex:none;
}
.title { font-weight:600; min-width:0; overflow-wrap:anywhere; }
.chip {
  font-size:.68rem; letter-spacing:.06em; text-transform:uppercase;
  border-radius:.25rem; padding:.1rem .4rem; border:1px solid currentColor;
  white-space:nowrap; flex:none;
}
.chip.needs-captain   { color:var(--tn-red); }
.chip.needs-cocaptain { color:var(--tn-purple); }
.chip.fm-handling   { color:var(--tn-blue); }
.chip.resolved      { color:var(--tn-green); }
.chip.odd           { color:var(--tn-orange); }
/* The outcome axis. Green for work that landed matches the resolved accent's
   meaning of a good ending; orange keeps its single meaning of something to
   look at, which covers both a discard and an ending nobody could determine. */
.chip.landed        { color:var(--tn-green); }
.chip.discarded     { color:var(--tn-orange); }
.chip.unknown       { color:var(--tn-orange); }
.chip.sev           { color:var(--tn-dim); }
.meta { color:var(--tn-dim); font-size:.76rem; margin-top:.3rem; }
.meta .sep { color:var(--tn-line); margin:0 .35rem; }
.body { margin-top:.4rem; color:var(--tn-dim); font-size:.88rem; overflow-wrap:anywhere; }
.pointer { margin-top:.4rem; font-size:.82rem; overflow-wrap:anywhere; }
.pointer .lbl { color:var(--tn-muted); margin-right:.35rem; }

/* The answer options are deliberately NOT controls. Lavish excludes
   `button,input,select,textarea,...` and everything inside them from its
   annotation capture, so an option rendered as a <button> would be the one
   element on an ask row the captain cannot annotate - on the surface whose
   whole input path is annotation. Measured, both directions:
   docs/verification/bridge-hosted-input.md. */
.answers { margin-top:.6rem; display:flex; gap:.4rem; flex-wrap:wrap; align-items:center; }
.answers .lbl { color:var(--tn-muted); font-size:.74rem; margin-right:.15rem; }
.answers .ans {
  font-size:.82rem; color:var(--tn-fg); background:var(--tn-deep);
  border:1px solid var(--tn-line); border-radius:.3rem; padding:.25rem .55rem;
}

.checkline { margin-top:.5rem; font-size:.76rem; color:var(--tn-muted); overflow-x:auto; }
.checkline code { color:var(--tn-cyan); }

table.strip { width:100%; border-collapse:collapse; font-size:.85rem; }
table.strip th {
  text-align:left; font-size:.7rem; text-transform:uppercase; letter-spacing:.09em;
  color:var(--tn-muted); font-weight:600; padding:.3rem .5rem; border-bottom:1px solid var(--tn-line);
}
table.strip td { padding:.42rem .5rem; border-bottom:1px solid rgba(59,66,97,.45); vertical-align:top; }
table.strip td.st { white-space:nowrap; width:1%; }
/* Why a row was discarded, on the row itself. The strip is scannable, so this
   stays small and secondary - but it is on the board, because the board is
   where the disposition is read. */
/* Secondary text under a row. It is DIM by default because a note is an
   ordinary field on every write command, and only the override accent below
   may claim the reader's alarm - one meaning per accent, and orange already
   means something is off. */
table.strip .why, ul.events .why {
  margin-top:.25rem; font-size:.76rem; line-height:1.45; color:var(--tn-dim);
  overflow-wrap:anywhere;
}
table.strip .why.override, ul.events .why.override { color:var(--tn-orange); }
.chip.was { color:var(--tn-muted); }
.stripwrap { overflow-x:auto; border:1px solid var(--tn-line); border-radius:.5rem; background:var(--tn-panel); }

ul.events { list-style:none; margin:0; padding:0; }
/* Same shape as the asks rows, and the same reason: a fixed timestamp cell
   beside free text with no wrap is how the collision the audit caught happens.
   Grid tracks make it unreachable here too. */
ul.events li {
  display:grid; grid-template-columns:max-content minmax(0,1fr);
  gap:.6rem; padding:.4rem 0; border-bottom:1px solid rgba(59,66,97,.4);
  font-size:.88rem; align-items:baseline;
}
ul.events li .when { color:var(--tn-muted); font-size:.74rem; font-family:ui-monospace,monospace; white-space:nowrap; }
ul.events li .what { min-width:0; overflow-wrap:anywhere; }
.overflow { margin-top:.55rem; font-size:.8rem; color:var(--tn-orange); }

.glossary { border:1px dashed var(--tn-line); border-radius:.5rem; padding:.7rem .9rem; background:var(--tn-bg); }
.glossary dl { margin:0; }
.glossary dt { font-weight:600; color:var(--tn-fg); font-size:.85rem; margin-top:.5rem; }
.glossary dt:first-child { margin-top:0; }
.glossary dd { margin:.15rem 0 0 0; font-size:.83rem; color:var(--tn-dim); }
.glossary .collide { color:var(--tn-orange); font-size:.72rem; text-transform:uppercase; letter-spacing:.07em; margin-left:.4rem; }
/* The project heading and the terms line under it need real separation: a
   hairline gap let their text boxes collide, which a browser layout audit
   flagged as overlapping text at 1024px. Explicit line-height and margins,
   not inline styles, so the spacing is stated once and stays checkable. */
h3.projhead {
  margin:1.6rem 0 .55rem; font-size:.95rem; font-weight:600; line-height:1.45;
  color:var(--tn-fg); overflow-wrap:anywhere;
}
h3.projhead .refs {
  color:var(--tn-muted); font-weight:400; font-size:.8rem; white-space:nowrap;
}
.local-terms { margin:0 0 .8rem; font-size:.79rem; line-height:1.5; color:var(--tn-dim); border-left:2px solid var(--tn-line); padding-left:.6rem; }

/* THE RAIL. The ask counter has to travel with the viewport so an open ask
   cannot be scrolled past - and it must never cover the board to do it.
   Chrome that travels with a vertically scrolling page ALWAYS ends up over the
   content when it sits across the top: every row passes behind it on the way
   past, and an anchor jump parks its target underneath it. A browser layout
   audit proved exactly that, twice, on rows in two different zones - the row
   was never the problem, the bar above it was.
   So the chrome moves out of the content column entirely. The page reserves a
   right-hand gutter, no content is ever laid out inside it, and everything
   viewport-fixed lives there. Scrolling is vertical, so a column the content
   never enters is the one place fixed chrome cannot come to cover it. */
:root { --rail:3.6rem; }
body { padding-right:var(--rail); }
#rail {
  position:fixed; top:0; right:0; bottom:0; width:var(--rail); z-index:6;
  display:flex; flex-direction:column; gap:.5rem; padding:.5rem .4rem;
  background:var(--tn-deep); border-left:1px solid var(--tn-line);
  overflow-y:auto; overflow-x:hidden;
}
#pin { flex:none; }
#pin a, #pin .clear {
  display:block; text-align:center; text-decoration:none; border-radius:.4rem;
  padding:.45rem .2rem; font-size:.62rem; text-transform:uppercase;
  letter-spacing:.05em; line-height:1.3; white-space:nowrap;
}
#pin a { background:#3d2430; color:var(--tn-red); }
#pin a:hover { outline:1px solid var(--tn-red); }
#pin .clear { background:var(--tn-panel); color:var(--tn-dim); }
#pin b { display:block; font-size:1.35rem; letter-spacing:0; }
#pin .since { display:block; color:var(--tn-muted); margin-top:.15rem; }

ol.asks { list-style:none; margin:0; padding:0; counter-reset:ask; }
ol.asks li { border-bottom:1px solid rgba(59,66,97,.4); }
/* Explicit grid tracks rather than flex with min-widths. A flex row whose
   items cannot shrink lets its text boxes collide once a cell's content
   outgrows its share, which a browser layout audit caught here as overlapping
   text. Every track is either intrinsic or minmax(0, ...), so no cell can be
   pushed over its neighbour at any width. */
ol.asks li a {
  display:grid;
  grid-template-columns:minmax(2.4rem,max-content) minmax(0,7rem) minmax(0,1fr) max-content;
  gap:.7rem; align-items:baseline; padding:.45rem .2rem;
  text-decoration:none; color:var(--tn-fg);
}
ol.asks li a:hover { background:rgba(122,162,247,.07); }
ol.asks .ref { min-width:0; }
ol.asks .proj {
  color:var(--tn-dim); font-size:.78rem;
  min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
ol.asks .what { min-width:0; overflow-wrap:anywhere; }
ol.asks .age { color:var(--tn-muted); font-size:.78rem; font-family:ui-monospace,monospace; white-space:nowrap; }
ol.asks li.aging .age { color:var(--tn-orange); }
.card.aging { box-shadow:inset 3px 0 0 var(--tn-orange); }
.chip.aging { color:var(--tn-orange); }
.allclear { color:var(--tn-green); font-size:.9rem; }
/* The input path, stated where the asks are. Blue: this is firstmate's side of
   the surface talking, not an ask and not a warning. */
.howto {
  margin:.2rem 0 .9rem; font-size:.82rem; line-height:1.5; color:var(--tn-dim);
  border-left:2px solid var(--tn-blue); padding-left:.6rem;
}

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
.promises { margin:0 0 1rem; padding-left:.6rem; border-left:2px solid var(--tn-blue);
            color:var(--tn-dim); font-size:.8rem; line-height:1.5; }
.promises div { margin:.25rem 0; }
.promises b { color:var(--tn-fg); }
footer code { color:var(--tn-cyan); }
footer .row { margin:.3rem 0; overflow-x:auto; white-space:nowrap; }
.banner {
  border:1px solid var(--tn-orange); color:var(--tn-orange); background:rgba(255,158,100,.08);
  border-radius:.5rem; padding:.7rem .9rem; margin:1rem 0 0; font-size:.85rem;
}
.banner code { color:var(--tn-orange); }
.empty { color:var(--tn-muted); font-size:.85rem; font-style:italic; }
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
    element stays annotatable and rulings still queue through the annotation
    layer. The answer-form buttons need nothing, because `button` is already on
    the native list.

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
        if item["pointer_gap"]:
            return ('<div class="pointer"><span class="lbl">outcome</span>'
                    '<span style="color:var(--tn-orange)">%s, with no pointer to '
                    'where it went - see record hygiene</span></div>'
                    % esc(item["pointer_gap"]))
        return ""
    target = item["pointer"]
    if target.startswith("http://") or target.startswith("https://"):
        shown = link(target)
    else:
        shown = '<code>%s</code>' % esc(target)
    return '<div class="pointer"><span class="lbl">outcome</span>%s</div>' % shown


def answer_forms(item):
    """The mandatory answer forms: the options the captain is choosing between.

    They are shown, not offered as controls. The board has no send of its own -
    the captain rules by annotating the row in Lavish and sending from the
    conversation panel - so an option that looked clickable would be promising
    an egress this page does not have.

    Every option therefore renders as a plain element, which is also what keeps
    it annotatable: Lavish's annotation layer skips native controls and
    everything inside them, so a <button> option would be the one part of an ask
    the captain could not annotate (docs/verification/bridge-hosted-input.md).
    """
    # The same conjunction the ask queues use, for the same reason: a form is
    # offered when someone owes a decision AND the work is still live. Nobody
    # can rule on work that ended, and nobody needs to rule on what is settled.
    if owed_by(item) == "resolved" or ended(item) or not item["answers"]:
        return ""
    label = item["ref"] or item["id"]
    options = []
    for answer in item["answers"]:
        # The ref rides on the option itself. An annotation carries the text of
        # what it was placed on, so an option that named only its own words
        # would arrive saying "retire it" with nothing saying which ask.
        options.append('<span class="ans">%s</span>'
                       % esc("%s: %s" % (label, answer)))
    return ('<div class="answers"><span class="lbl">answer</span>%s</div>'
            % "".join(options))


def check_line(item):
    if not item["check"]:
        return ""
    return '<div class="checkline">check <code>%s</code></div>' % esc(item["check"])


def card(item, pinned=False):
    classes = ["card", state_class(item)]
    if pinned:
        classes.append("pinned")
    if item.get("aging"):
        classes.append("aging")
    ref = '<span class="ref">%s</span>' % esc(item["ref"]) if item["ref"] else ""
    aged = ('<span class="chip aging">waiting %s</span>' % esc(item["age_label"])
            if item.get("aging") else "")
    parts = [
        '<div class="%s" id="item-%s">' % (" ".join(classes), esc(item["id"])),
        '<div class="head">%s<span class="title">%s</span>%s%s%s</div>'
        % (ref, esc(item["title"] or item["id"]), chip(item) + outcome_chip(item),
           sev_chip(item), aged),
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


def freshness_html(content_at):
    """WHEN THIS BOARD'S CONTENT IS FROM, and nothing more.

    It once also carried a `checked` clock that advanced on every supervision
    tick, so a frozen board and a dead cycle would not look the same. That clock
    cost a file write every tick, and a write is what makes Lavish reload the
    hosted page - silently destroying whatever ruling the captain was in the
    middle of annotating (docs/verification/bridge-hosted-input.md).

    Liveness is not this page's to prove. The watcher's beacon and the guard
    that reads it own it, they answer it durably, and they cost the captain's
    open annotation nothing. What is left here is the one time this page can
    state from its own content: when the ledger it was drawn from last changed.
    """
    return ('<div class="fresh">content as of '
            '<span class="clock">%s</span></div>' % esc(content_at))


def render_html(doc):
    items = doc["items"]
    zones = doc["zones"]
    caps = doc["caps"]
    counts = doc["counts"]
    summary = doc["summary"]
    outcomes = doc["outcomes"]
    out = []
    add = out.append

    add("<!doctype html>")
    add('<html lang="en"><head><meta charset="utf-8">')
    add('<meta name="viewport" content="width=device-width,initial-scale=1">')
    asks = doc.get("asks", [])
    # The tab title is the one part of this board that stays visible when the
    # captain has scrolled away, switched apps, or left it open for a day.
    add("<title>%s</title>"
        % ("Bridge - %d need you" % len(asks) if asks else "Bridge - clear"))
    add("<style>%s</style></head><body>" % CSS)

    # Fixed to the viewport and OUTSIDE the content column: an ask cannot be
    # scrolled past, and the counter that guarantees it never covers a row to
    # do so. Everything in here lives in the gutter the page reserves for it.
    add('<aside id="rail">')
    if asks:
        # The genuinely longest-waiting ask, not the first row of a
        # severity-sorted list. Calling the top row "oldest" would be a claim
        # the ordering does not support.
        longest = max(asks, key=lambda k: items[k]["age_seconds"] or 0)
        add('<div id="pin"><a href="#waiting" data-lavish-action '
            'title="%d waiting on you, longest %s">'
            "<b>%d</b>asks"
            '<span class="since">%s</span></a></div>'
            % (len(asks), esc(items[longest]["age_label"]), len(asks),
               esc(items[longest]["age_label"])))
    else:
        add('<div id="pin"><div class="clear" '
            'title="0 waiting on you, the queue is clear">'
            "<b>0</b>clear</div></div>")

    add("</aside>")

    add('<header class="top"><div class="wrap">')
    add('<h1>Bridge<span class="sub">fleet state, generated from the ledger</span></h1>')
    add(freshness_html(doc["folded_at"]))
    # THREE GROUPS, AND TWO OF THEM ADD UP. The ask count is the conjunction -
    # owed AND still live - and is labelled as its own number rather than being
    # blended into either axis. Below it each axis partitions the SAME items, so
    # both rows total `records folded`'s item count and a chip a reader can see
    # is always a chip they can find in a tally.
    total = counts["board_items"]
    add('<div class="tallies">')
    add('<div class="tally ask" title="asks: someone owes a decision AND the '
        'work is still live"><b>%d</b>waiting on you</div>' % len(asks))
    if doc["cocaptain_asks"]:
        add('<div class="tally co"><b>%d</b>with the co-captain</div>'
            % len(doc["cocaptain_asks"]))
    add("</div>")
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
    add('<p class="zone-note">Two things about every row, kept apart: who owes it, '
        "and how it ended. Neither answers the other.</p>")
    add('<div class="legend">'
        '<span class="l-red">needs you</span>'
        '<span class="l-purple">needs the co-captain</span>'
        '<span class="l-blue">firstmate has it</span>'
        '<span class="l-green">resolved, or landed</span>'
        '<span class="l-orange">discarded, ended unknown, aging, or otherwise off</span>'
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
    # Rows the fold could not resolve are NAMED, not quietly filled in. These
    # were written before the outcome axis existed, so their silence about how
    # the work ended says nothing at all - and a row nobody can resolve is worth
    # the captain seeing once rather than acquiring a confident-looking value.
    if doc["unobserved_outcomes"]:
        unresolved = doc["unobserved_outcomes"]
        add('<div class="banner"><b>%d %s written before the outcome axis '
            "existed.</b> Nothing in the record says how they ended, so the "
            "board says unknown rather than guessing: %s.%s</div>"
            % (len(unresolved),
               "row was" if len(unresolved) == 1 else "rows were",
               ", ".join(esc(items[key]["ref"] or key) for key in unresolved[:8]),
               "" if len(unresolved) <= 8 else " +%d more" % (len(unresolved) - 8)))
    if not doc["ledger"]["present"]:
        add('<div class="banner">No ledger at <code>%s</code> yet. '
            "The board is empty because nothing has been written, not because "
            "nothing happened.</div>" % esc(doc["ledger"]["path"]))

    # THE ASKS INDEX. Everything the captain owes, in one block, before anything
    # else on the page. It is an index and not a second set of cards on purpose:
    # each line jumps to the full card in its project section, so nothing has to
    # be triaged twice, and a reader arriving cold still sees the complete list
    # of what is waiting without scrolling or reconstructing it.
    add('<section id="waiting"><h2>Waiting on you</h2>')
    if asks:
        add('<p class="zone-note">Every open ask, oldest first. Nothing else on '
            "this page is an ask.</p>")
        # WHERE THE RULING GOES. The board had its own composer here once, with
        # copy and clear and no send - a visible input that could not reach
        # anybody. It is gone rather than disabled, because the defect was the
        # affordance itself. Saying where the input actually is costs one line
        # and turns an implied path into a stated one.
        add('<p class="howto">To rule: select the ask or the answer you want, '
            "annotate it, and send from the conversation panel. Queue it before "
            "you move on - a ruling still open in the annotation box is not "
            "saved anywhere.</p>")
        add('<ol class="asks">')
        for key in asks:
            item = items[key]
            add('<li%s><a href="#item-%s" data-lavish-action>'
                '<span class="ref">%s</span>'
                '<span class="proj">%s</span>'
                '<span class="what">%s</span>'
                '<span class="age">%s</span></a></li>'
                % (' class="aging"' if item.get("aging") else "",
                   esc(item["id"]),
                   esc(item["ref"] or "-"),
                   esc(item["project"]),
                   esc(item["title"] or item["id"]),
                   esc(item["age_label"])))
        add("</ol>")
        aging = [k for k in asks if items[k].get("aging")]
        if aging:
            add('<div class="overflow">%d of these have been open longer than %s. '
                "An ask that old is usually one that was already answered and "
                "never closed - worth checking before ruling again.</div>"
                % (len(aging), _age_label(doc.get("aging_seconds"))))
    else:
        add('<p class="allclear">Nothing is waiting on you. Everything below is '
            "either being handled or already resolved.</p>")
    add("</section>")

    # Routed elsewhere, and shown so the captain can see it is routed rather
    # than wonder. Deliberately BELOW their own asks, out of the tab title, and
    # out of the sticky counter: the point of the routing class is that these
    # never spend captain attention. The co-captain does not read this board at
    # all - they read the same items out of the ledger through --state - so this
    # section exists to reassure, not to deliver.
    cocaptain = doc.get("cocaptain_asks", [])
    if cocaptain:
        add('<section id="cocaptain"><h2>With the co-captain</h2>')
        add('<p class="zone-note">Machine and repo-infrastructure items, routed '
            "to the dotfiles session through the ledger. Not yours to answer - "
            "listed so you can see where they went.</p>")
        add('<ol class="asks co">')
        for key in cocaptain:
            item = items[key]
            add('<li%s><a href="#item-%s" data-lavish-action>'
                '<span class="ref">%s</span>'
                '<span class="proj">%s</span><span class="what">%s</span>'
                '<span class="age">%s</span></a></li>'
                % (' class="aging"' if item.get("aging") else "",
                   esc(item["id"]), esc(item["ref"] or "-"), esc(item["project"]),
                   esc(item["title"] or item["id"]), esc(item["age_label"])))
        add("</ol>")
        add('<div class="checkline">the co-captain reads these with '
            '<code>bin/fm-bridge-render.sh --state | jq -r \'.cocaptain_asks[]\'</code>'
            "</div>")
        add("</section>")

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
    # Closed criticals, kept apart by how they ended. A reader scanning for what
    # landed must never have to check whether a row under it was thrown away.
    for group, label in (("criticals_landed", "landed"),
                         ("criticals_discarded", "discarded"),
                         ("criticals_unknown", "ended, how unknown")):
        shown = zones[group][:caps["closed_decisions"]]
        if not shown:
            continue
        add('<p class="zone-note">%s</p>' % esc(label))
        for key in shown:
            add(card(items[key]))
        hidden = len(zones[group]) - len(shown)
        if hidden > 0:
            add('<div class="overflow">+%d more %s - the record has them: '
                '<code>%s</code></div>'
                % (hidden, esc(label), esc(doc["checks"]["raw stream"])))
    add("</section>")

    # Zone 2 - decisions, grouped by project, with per-project refs.
    add("<section><h2>Decisions</h2>")
    add('<p class="zone-note">Grouped by project. A ref like <b>O1</b> is unique '
        "to its project and never renumbers, so a bare number is safe to quote. "
        "Only the red ones are asks.</p>")
    if not zones["decisions"]:
        add('<p class="empty">No decisions on the board.</p>')
    for group in zones["decisions"]:
        add('<h3 class="projhead">%s <span class="refs">refs %s1, %s2, '
            "&hellip;</span></h3>"
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
        closed = [side for side in ("landed", "discarded", "unknown") if group[side]]
        if not group["open"] and not closed:
            add('<p class="empty">Nothing open.</p>')
        for key in group["open"]:
            add(card(items[key]))
        for side in ("landed", "discarded", "unknown"):
            shown = group[side][:caps["closed_decisions"]]
            for key in shown:
                add(card(items[key]))
            hidden = len(group[side]) - len(shown)
            if hidden > 0:
                add('<div class="overflow">+%d more %s in %s - the record has them: '
                    '<code>%s</code></div>'
                    % (hidden, esc(side), esc(group["project"]),
                       esc(doc["checks"]["raw stream"])))
    add("</section>")

    # Zone 3 - notable events, capped, overflowing to the record.
    add("<section><h2>Notable events</h2>")
    add('<p class="zone-note">Newest first, capped. Nothing here is an ask.</p>')
    shown_events = zones["events"][:caps["events"]]
    if shown_events:
        add('<ul class="events">')
        for key in shown_events:
            item = items[key]
            # An event whose outcome lives somewhere must SAY where. A notable
            # event the captain cannot follow through to is a dead end on the
            # one surface they read.
            target = item["pointer"]
            if target.startswith("http://") or target.startswith("https://"):
                trail = " " + link(target)
            elif target:
                trail = ' <code>%s</code>' % esc(target)
            else:
                trail = ""
            # An event that carries a note carries it onto the board. A forced
            # secondmate retirement lands here rather than on the fleet strip -
            # a persistent secondmate is not a work item - and it is the most
            # destructive override in the fleet, so the judgement that
            # authorized it has to be readable where the captain reads, not
            # only in the record behind the page.
            why = ('<div class="why%s">%s</div>'
                   % (" override" if item["outcome"] in ("discarded", "unknown")
                      else "", esc(item["note"]))
                   if item["note"] else "")
            add('<li><span class="when">%s</span>'
                '<span class="what">%s%s %s%s</span></li>'
                % (esc((item["ts"] or "")[:16].replace("T", " ")),
                   esc(item["title"] or item["id"]),
                   trail,
                   chip(item) if owed_by(item) != "resolved" else "",
                   why))
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
    # Live work first and uncapped, then the recent tail of each way work can
    # end, each capped and each saying how much it is not showing. The tails
    # never share a list: how a task ended is the one thing a reader of a closed
    # row is asking, so landed and discarded cannot sit under one heading.
    closed_shown = {}
    for group in ("fleet_landed", "fleet_discarded", "fleet_unknown"):
        closed_shown[group] = zones[group][:caps["fleet_closed"]]
    rows = (zones["fleet_open"] + closed_shown["fleet_landed"]
            + closed_shown["fleet_discarded"] + closed_shown["fleet_unknown"])
    if rows:
        add('<div class="stripwrap"><table class="strip">')
        add("<tr><th>task</th><th>project</th><th>phase</th>"
            "<th>who owes it</th><th>how it ended</th><th>where it is</th></tr>")
        for key in rows:
            item = items[key]
            target = item["pointer"]
            if target.startswith("http"):
                where = link(target)
            elif target:
                where = "<code>%s</code>" % esc(target)
            else:
                where = '<span style="color:var(--tn-muted)">-</span>'
            # The anchor is not decoration: a task waiting on the captain is
            # listed in the asks index above, and that index links here. A row
            # with no id would leave the captain clicking an ask that goes
            # nowhere. The answer form is here for the same reason - a row that
            # asks for a ruling and offers no way to give one is the one
            # regression that matters on this surface.
            forms = answer_forms(item)
            aged = ('<span class="chip aging">waiting %s</span>' % esc(item["age_label"])
                    if item.get("aging") else "")
            # A discarded row has to carry its own provenance. The cleanup that
            # wrote it skipped the landed-work test, so a reader needs all three
            # facts here - that the check was skipped, that the work was thrown
            # away, and the judgement someone gave for skipping it - rather than
            # only in the record behind the board.
            why = ('<div class="why override">%s</div>' % esc(item["note"])
                   if item["outcome"] in ("discarded", "unknown") and item["note"]
                   else "")
            ending = outcome_chip(item) or (
                '<span style="color:var(--tn-muted)">still going</span>')
            add('<tr id="item-%s"><td><b>%s</b>%s</td><td>%s</td><td>%s</td>'
                '<td class="st">%s%s</td><td class="st">%s</td><td>%s%s</td></tr>'
                % (esc(item["id"]), esc(item["title"] or item["id"]), why,
                   esc(item["project"]), esc(item["phase"] or "-"),
                   chip(item), aged, ending, where, forms))
        add("</table></div>")
    else:
        add('<p class="empty">No tasks on the board.</p>')
    for group, label in (("fleet_landed", "landed"),
                         ("fleet_discarded", "discarded"),
                         ("fleet_unknown", "ended, how unknown")):
        hidden = len(zones[group]) - len(closed_shown[group])
        if hidden > 0:
            add('<div class="overflow">+%d older %s tasks in the record. '
                "They are capped here, not dropped - <code>%s</code> has every "
                "one.</div>" % (hidden, esc(label), esc(doc["checks"]["raw stream"])))
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
    # WHAT THIS SURFACE PROMISES, AND WHAT IT DOES NOT. Every line here is a
    # measured verdict, not a design intention - the measurements and their
    # exact output are in docs/verification/bridge-hosted-input.md. A reader who
    # trusts the wrong half of this loses a ruling and does not find out, which
    # is why the half that does not hold is stated as plainly as the half that
    # does.
    add('<div class="promises">')
    add("<div><b>What this page does, and does not.</b></div>")
    add("<div>It shows fleet state, and it takes no input of its own. A ruling "
        "reaches firstmate by annotation: select the ask, or the answer you "
        "want, say what you decided, and send it from the conversation "
        "panel.</div>")
    add("<div>A ruling you have queued survives this page being redrawn, and "
        "still points at the ask you placed it on.</div>")
    add("<div>A ruling still sitting in the annotation box does not. This page "
        "is rewritten whenever the ledger changes, and an unqueued annotation "
        "goes with it, silently. Queue it, then keep reading.</div>")
    add("<div>Opened as a plain file with nothing behind it, this page has no "
        "input path at all. Tell firstmate directly.</div>")
    add("</div>")
    add("<div class=\"row\">This page is generated. Edits to it are overwritten "
        "the next time the ledger changes; facts belong in the ledger.</div>")
    add("</footer></div>")

    # The exact state document this board was drawn from rides along, so the
    # board can be audited without trusting the renderer.
    add('<script type="application/json" id="fm-bridge-state">')
    add(state_json(doc))
    add("</script>")
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
    if mode == "html":
        # ONE fold, shared in-process: render_html consumes the return value
        # directly. It is handed no path and opens no file, so the drawing half
        # cannot become a second reader of the stream.
        doc = fold(argv[2], argv[3])
        sys.stdout.write(render_html(doc))
        return 0
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

emit_html() {  # <folded-at>
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  # One process, one fold, shared in-process with the renderer.
  python3 "$prog" html "$(fm_bridge_ledger_path)" "$1"
}

ledger_signature() {
  local prog
  prog=$(program_path) || die "cannot stage the fold program"
  python3 "$prog" signature "$(fm_bridge_ledger_path)"
}

# WRITING THE BOARD IS NOT FREE. Lavish hosts this file and reloads the page on
# any write to it, which discards a ruling the captain is part-way through
# annotating - and it reloads on a BYTE-IDENTICAL rewrite too, because the
# reload keys on the write and not on a diff (measured, both:
# docs/verification/bridge-hosted-input.md). So the last thing before the rename
# is a comparison, and an unchanged board is left alone rather than replaced
# with a copy of itself. Returns 0 when the board is current, whether or not
# this call is what made it so.
write_board() {  # <folded-at>
  local board tmp
  board=$(fm_bridge_board_path)
  mkdir -p "$(dirname "$board")" || return 1
  tmp="$board.tmp.$$"
  emit_html "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$board" ] && cmp -s "$tmp" "$board"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$board" || { rm -f "$tmp"; return 1; }
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
do_tick() {
  local verbose=$1 now sig prev board
  require_python
  now=$(fm_bridge_now)
  board=$(fm_bridge_board_path)
  sig=$(ledger_signature)
  prev=$(cat "$STAMP" 2>/dev/null || true)

  if [ "$sig" = "$prev" ] && [ -f "$board" ]; then
    [ "$verbose" -eq 1 ] && printf 'bridge: ledger unchanged; left %s alone\n' "$board"
    return 0
  fi

  # The stamp is written only after the board actually landed, so a failed
  # render leaves the signature stale and the NEXT tick retries instead of
  # concluding nothing changed and skipping forever.
  write_board "$now" || return 1
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
    --tick) MODE='tick'; shift ;;
    --write) MODE='write'; shift ;;
    --path) MODE='path'; shift ;;
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
    if [ -n "$OUT" ]; then emit_html "$NOW" > "$OUT"; else emit_html "$NOW"; fi
    ;;
  write)
    require_python
    write_board "$NOW" || die "could not write the board"
    printf '%s\n' "$(fm_bridge_board_path)"
    ;;
  tick) do_tick "$VERBOSE" ;;
esac
