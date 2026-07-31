#!/usr/bin/env bash
# fm-bridge.sh - write to the Bridge ledger, and lint what is in it.
#
# The Bridge ledger is where captain-relevant facts are BORN. An append here is
# a side effect of a turn that is already happening and REPLACES the equivalent
# prose in the terminal stream; it is never separate bookkeeping and never a
# turn of its own. If a turn is ever spent "maintaining the board", the design
# has drifted: facts are written where they happen, and the view builds itself.
#
# Writing (one line each, at the moment of the event):
#   fm-bridge.sh note     --project P --title T [--body B] [--pointer URL]
#   fm-bridge.sh ask      --project P --title T --answer A --answer B [--to WHO]
#   fm-bridge.sh critical --project P --title T [--answer A ...] [--to WHO]
#   fm-bridge.sh route    --id ID --to captain|cocaptain|firstmate
#   fm-bridge.sh handling --id ID [--title T] [--note N]
#   fm-bridge.sh resolve  --id ID --pointer URL [--note N]
#   fm-bridge.sh task     --id ID --project P --phase PH [--state S] [--pointer URL]
#   fm-bridge.sh term     --project P --term WORD --means TEXT
#   fm-bridge.sh append   <name=value> ...        (raw, still normalized)
#
# Reading goes through the ONE fold, never through a second parser:
#   fm-bridge.sh state [--id ID]        -> bin/fm-bridge-render.sh --state
#   fm-bridge.sh lifecycle ID           -> bin/fm-bridge-render.sh --lifecycle
#   fm-bridge.sh lint [--strict]        record hygiene, over folded state
#   fm-bridge.sh path [ledger|board]
#
# --to is the ROUTING decision: which reader's queue the item lands on.
# `--to cocaptain` addresses machine and repo-infrastructure work to the
# dotfiles session through the ledger, so it never spends captain attention.
# Default is the captain for an ask or a critical.
#
# Common options: --id, --severity (critical|high|normal|low), --owner, --check,
# --state, --quiet. Omit --id and one is derived from kind+project+title, so
# re-appending the same fact updates that item instead of duplicating it.
#
# Every write is one bounded append to an append-only JSONL file. See
# docs/bridge.md for the published schema and bin/fm-bridge-lib.sh for the
# writer contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-bridge-lib.sh
. "$SCRIPT_DIR/fm-bridge-lib.sh"

RENDER="$SCRIPT_DIR/fm-bridge-render.sh"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-bridge: %s\n' "$1" >&2; exit 2; }

[ $# -gt 0 ] || { usage; exit 2; }
COMMAND=$1
shift

QUIET=0
ROUTE_TO=
declare -a FIELDS=()
TERM_WORD=
TERM_MEANS=

add_field() { FIELDS+=("$1=$2"); }

parse_common() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --id)       [ $# -gt 1 ] || die "--id needs a value"; add_field id "$2"; shift 2 ;;
      --project)  [ $# -gt 1 ] || die "--project needs a value"; add_field project "$2"; shift 2 ;;
      --title)    [ $# -gt 1 ] || die "--title needs a value"; add_field title "$2"; shift 2 ;;
      --body)     [ $# -gt 1 ] || die "--body needs a value"; add_field body "$2"; shift 2 ;;
      --note)     [ $# -gt 1 ] || die "--note needs a value"; add_field note "$2"; shift 2 ;;
      --pointer)  [ $# -gt 1 ] || die "--pointer needs a value"; add_field pointer "$2"; shift 2 ;;
      --severity) [ $# -gt 1 ] || die "--severity needs a value"; add_field severity "$2"; shift 2 ;;
      --owner)    [ $# -gt 1 ] || die "--owner needs a value"; add_field owner "$2"; shift 2 ;;
      --state)    [ $# -gt 1 ] || die "--state needs a value"; add_field state "$2"; shift 2 ;;
      --phase)    [ $# -gt 1 ] || die "--phase needs a value"; add_field phase "$2"; shift 2 ;;
      --check)    [ $# -gt 1 ] || die "--check needs a value"; add_field check "$2"; shift 2 ;;
      --answer)   [ $# -gt 1 ] || die "--answer needs a value"; add_field answer "$2"; shift 2 ;;
      --to)
        # Routing sets BOTH the queue and the owner. Moving an item to another
        # reader while leaving the old owner behind would put it on one reader's
        # queue while still naming another as responsible - the ambiguity this
        # field exists to remove.
        [ $# -gt 1 ] || die "--to needs a reader ($FM_BRIDGE_READERS)"
        ROUTE_TO=$(fm_bridge_state_for_reader "$2") \
          || die "--to must name one of: $FM_BRIDGE_READERS"
        add_field state "$ROUTE_TO"
        add_field owner "$2"
        shift 2 ;;
      --ts)       [ $# -gt 1 ] || die "--ts needs a value"; add_field ts "$2"; shift 2 ;;
      --term)     [ $# -gt 1 ] || die "--term needs a value"; TERM_WORD=$2; shift 2 ;;
      --means)    [ $# -gt 1 ] || die "--means needs a value"; TERM_MEANS=$2; shift 2 ;;
      --quiet|-q) QUIET=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done
}

has_field() {  # <name>
  local want=$1 entry
  for entry in ${FIELDS[@]+"${FIELDS[@]}"}; do
    case "$entry" in "$want"=*) return 0 ;; esac
  done
  return 1
}

field_value() {  # <name> -> last value given for that field
  local want=$1 entry out=''
  for entry in ${FIELDS[@]+"${FIELDS[@]}"}; do
    case "$entry" in "$want"=*) out=${entry#*=} ;; esac
  done
  printf '%s' "$out"
}

emit() {
  fm_bridge_append ${FIELDS[@]+"${FIELDS[@]}"} || exit $?
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$FM_BRIDGE_LAST_ID"
}

case "$COMMAND" in
  note)
    parse_common "$@"
    has_field title || die "note needs --title"
    add_field kind event
    emit
    ;;
  ask)
    parse_common "$@"
    has_field title || die "ask needs --title"
    # Answer forms are mandatory on a surface whose job is collecting rulings.
    # An ask with no answer form makes the captain compose the reply from
    # scratch, which is the one regression that matters here.
    has_field answer || die "ask needs at least one --answer (answer forms are mandatory)"
    add_field kind decision
    emit
    ;;
  critical)
    parse_common "$@"
    has_field title || die "critical needs --title"
    add_field kind critical
    emit
    ;;
  handling)
    parse_common "$@"
    has_field id || die "handling needs --id"
    # Taking an item is a routing move like any other, so it moves the owner
    # too. Leaving the previous reader named while firstmate holds it is the
    # same ambiguity --to exists to remove.
    add_field state fm-handling
    has_field owner || add_field owner firstmate
    emit
    ;;
  resolve)
    parse_common "$@"
    has_field id || die "resolve needs --id"
    # A resolved item that does not say where the outcome lives sends the
    # captain hunting for it, which is the whole thing the pointer prevents.
    has_field pointer || die "resolve needs --pointer (where the outcome lives)"
    add_field state resolved
    emit
    ;;
  task)
    parse_common "$@"
    has_field id || die "task needs --id"
    add_field kind task
    has_field title || add_field title "$(field_value id)"
    emit
    ;;
  route)
    # Re-address an existing item to a different reader. A partial update, so it
    # changes only the queue the item sits on and touches nothing else.
    parse_common "$@"
    has_field id || die "route needs --id"
    has_field state || die "route needs --to (captain|cocaptain|firstmate)"
    emit
    ;;
  term)
    parse_common "$@"
    [ -n "$TERM_WORD" ] || die "term needs --term"
    [ -n "$TERM_MEANS" ] || die "term needs --means"
    add_field kind term
    add_field title "$TERM_WORD"
    add_field body "$TERM_MEANS"
    emit
    ;;
  append)
    for arg in "$@"; do
      case "$arg" in
        -h|--help) usage; exit 0 ;;
        --quiet|-q) QUIET=1 ;;
        *=*) FIELDS+=("$arg") ;;
        *) die "append expects name=value, got: $arg" ;;
      esac
    done
    emit
    ;;
  path)
    case "${1:-ledger}" in
      ledger) fm_bridge_ledger_path; echo ;;
      board) fm_bridge_board_path; echo ;;
      *) die "path takes ledger or board" ;;
    esac
    ;;
  state)
    exec "$RENDER" --state "$@"
    ;;
  lifecycle)
    [ $# -gt 0 ] || die "lifecycle needs an id"
    exec "$RENDER" --lifecycle "$@"
    ;;
  lint)
    # The third consumer of the one fold. It never opens the ledger itself:
    # a linter with its own parser would be exactly the second reading this
    # design exists to make impossible.
    STRICT=0
    case "${1:-}" in --strict) STRICT=1 ;; '') ;; *) die "lint takes --strict" ;; esac
    command -v python3 >/dev/null 2>&1 || die "python3 is required to lint"
    export FM_BRIDGE_LINT_STRICT="$STRICT"
    "$RENDER" --state | python3 -c '
import json, sys
doc = json.load(sys.stdin)
problems = []

if not doc["conserved"]:
    problems.append("CONSERVATION: %d non-blank lines but %d folded + %d unreadable"
                    % (doc["counts"]["lines_considered"], doc["counts"]["records"],
                       doc["counts"]["malformed"]))
for bad in doc["malformed"]:
    problems.append("line %d unreadable: %s" % (bad["line"], bad["reason"]))

for key, item in sorted(doc["items"].items()):
    label = item["ref"] or key
    recognized = item.get("recognized", {})
    for field in ("kind", "state", "severity"):
        if not recognized.get(field, True):
            problems.append("%s: unrecognized %s %r (kept verbatim, shown as odd)"
                            % (label, field, item[field]))
    if item["state"] == "resolved" and not item["pointer"] \
            and item["kind"] in ("decision", "critical"):
        problems.append("%s: resolved with no pointer to the outcome" % label)
    if item["kind"] in ("decision", "critical") and item["state"] == "needs-captain" \
            and not item["answers"]:
        problems.append("%s: is an ask with no answer form" % label)
    if item["kind"] in ("decision", "critical", "task") and not item["title"]:
        problems.append("%s: has no title" % label)
    if item["truncated"]:
        problems.append("%s: record was truncated at write time" % label)

for line in problems:
    print(line)
print("bridge lint: %d item(s), %d problem(s)" % (len(doc["items"]), len(problems)))
sys.exit(1 if (problems and __import__("os").environ.get("FM_BRIDGE_LINT_STRICT") == "1") else 0)
' && rc=0 || rc=$?
    [ "$STRICT" -eq 1 ] && exit "${rc:-0}"
    exit 0
    ;;
  -h|--help) usage ;;
  *) die "unknown command: $COMMAND (try --help)" ;;
esac
