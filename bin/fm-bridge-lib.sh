#!/usr/bin/env bash
# fm-bridge-lib.sh - the WRITER half of the Bridge: canonical paths, record
# normalization, and the append primitive.
#
# The Bridge is the captain's primary surface for fleet state. It has exactly
# two moving parts and this file owns one of them:
#
#   ledger  (this file)              append-only JSONL, one event per line
#   fold    (bin/fm-bridge-render.sh) the ONE authoritative reader
#
# Nothing else may parse the ledger. Every consumer - the HTML board, the
# co-captain's independent audit, and firstmate's own record linter - reads
# folded current state through `fm-bridge-render.sh --state`. See docs/bridge.md
# for the published record schema, the state-mode schema, and the canonical
# paths, which are a stability contract with an external consumer.
#
# WHY APPEND-ONLY, AND WHY LINES ARE BOUNDED
# An append at the moment of an event must be one write with no read, no
# rewrite, and no lock: ledger writes are side effects of turns that are already
# happening, never separate bookkeeping. A single write(2) to an O_APPEND file
# is atomic up to PIPE_BUF (4096 bytes on every platform firstmate supports), so
# concurrent lanes cannot interleave a record as long as records stay under that
# bound. FM_BRIDGE_MAX_RECORD_BYTES enforces it by truncating body, then title,
# and marking the record truncated:true rather than emitting a line that could
# be torn by a concurrent writer.
#
# WRITERS NORMALIZE; THE READER TOLERATES EVERYTHING EVER WRITTEN, FOREVER.
# That split is the captain's standing ruling. This file is the normalizing
# writer: it lowercases and slugifies ids, fills defaults, and rejects unknown
# enum values at write time. The fold on the other side never rejects anything -
# see the tolerance contract in bin/fm-bridge-render.sh.
#
# Sourced by bin/fm-bridge.sh (the CLI) and by tests. Overridable inputs:
#   FM_HOME, FM_DATA_OVERRIDE   resolve the ledger location
#   FM_BRIDGE_LEDGER            absolute override of the ledger path
#   FM_BRIDGE_NOW               fixed RFC3339 UTC clock, for deterministic tests
#   FM_BRIDGE_MAX_RECORD_BYTES  record size bound (default 3800)

# Guard against double-sourcing: bin/fm-bridge.sh and a test helper may both
# source this in one process.
if [ -n "${FM_BRIDGE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_BRIDGE_LIB_SOURCED=1

FM_BRIDGE_SCHEMA_VERSION=1
FM_BRIDGE_MAX_RECORD_BYTES=${FM_BRIDGE_MAX_RECORD_BYTES:-3800}

# The four captain-facing zones, plus two substrate kinds.
#   critical - pinned criticals: security, data loss, fleet blocked, outward-facing anomaly
#   decision - a ruling the captain may owe, grouped by project on the board
#   event    - a notable event; the zone is capped and overflows to the record
#   task     - a fleet-strip row
#   term     - a project-scoped definition; renders as glossary, not as an item
#   steering - a steering message's lifecycle (sent/delivered/consumed), written
#              by a SECOND PRODUCER. Substrate, never a board item. Adding it
#              required no migration and no new fold, which is the property to
#              preserve: a new event kind must stay an ordinary addition here.
FM_BRIDGE_KINDS='critical decision event task term steering'

# The disposition triple. This field is load-bearing: it exists so the captain
# never mistakes an fm-handled item for an open ask.
#   needs-captain - waiting on them; ONLY these are asks
#   fm-handling   - firstmate has it; visible so it is not forgotten, not an ask
#   resolved      - done, and carries a pointer to where the outcome lives
FM_BRIDGE_STATES='needs-captain fm-handling resolved'

FM_BRIDGE_SEVERITIES='critical high normal low'

# --- paths ------------------------------------------------------------------

# Resolve the home's data directory the same way every other firstmate script
# does, so a secondmate home writes its own ledger and never the parent's.
fm_bridge_data_dir() {
  local root home
  root="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  home="${FM_HOME:-$root}"
  printf '%s' "${FM_DATA_OVERRIDE:-$home/data}"
}

fm_bridge_dir() {
  printf '%s' "${FM_BRIDGE_DIR:-$(fm_bridge_data_dir)/bridge}"
}

# The canonical ledger path. Published in docs/bridge.md; the co-captain reads it.
fm_bridge_ledger_path() {
  if [ -n "${FM_BRIDGE_LEDGER:-}" ]; then
    printf '%s' "$FM_BRIDGE_LEDGER"
    return 0
  fi
  printf '%s' "$(fm_bridge_dir)/ledger.jsonl"
}

# The canonical rendered board path.
fm_bridge_board_path() {
  if [ -n "${FM_BRIDGE_BOARD:-}" ]; then
    printf '%s' "$FM_BRIDGE_BOARD"
    return 0
  fi
  printf '%s' "$(fm_bridge_dir)/bridge.html"
}

fm_bridge_now() {
  if [ -n "${FM_BRIDGE_NOW:-}" ]; then
    printf '%s' "$FM_BRIDGE_NOW"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- normalization ----------------------------------------------------------

# Slugify to the id charset [a-z0-9._-]. Empty input yields empty output; the
# caller decides whether that is an error or a cue to derive an id.
fm_bridge_slug() {  # <text> [max-len]
  local s=$1 max=${2:-64}
  s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')
  # Collapse runs and trim leading/trailing separators.
  while case "$s" in *--*) true ;; *) false ;; esac; do s=${s//--/-}; done
  s=${s#-}; s=${s%-}
  printf '%s' "${s:0:$max}"
}

# Derive a deterministic id from project + title, so re-appending the same fact
# in a later turn updates that item instead of creating a duplicate. Idempotence
# by construction is what keeps a retried or replayed turn from littering the
# board.
fm_bridge_derive_id() {  # <kind> <project> <title>
  local kind=$1 project=$2 title=$3 stem digest
  stem=$(fm_bridge_slug "$title" 40)
  digest=$(printf '%s\n%s\n%s' "$kind" "$project" "$title" \
    | { cksum 2>/dev/null || printf '0 0'; } | awk '{print $1}')
  if [ -n "$stem" ]; then
    printf '%s-%s' "$stem" "$digest"
  else
    printf '%s-%s' "$(fm_bridge_slug "$kind" 16)" "$digest"
  fi
}

# JSON string literal for arbitrary shell text. Control characters that JSON
# forbids raw are escaped or dropped, so a record can never be emitted as
# invalid JSON no matter what a title or note contains.
fm_bridge_json_str() {  # <text>
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  printf '"%s"' "$s"
}

fm_bridge_in_set() {  # <value> <space-separated-set>
  local v=$1 set=$2 x
  for x in $set; do
    [ "$x" = "$v" ] && return 0
  done
  return 1
}

# Default disposition per kind. A decision or a critical starts as an ask; a
# task starts with firstmate; a notable event is a fact with nothing owed.
fm_bridge_default_state() {  # <kind>
  case "$1" in
    decision|critical) printf 'needs-captain' ;;
    task)              printf 'fm-handling' ;;
    *)                 printf 'resolved' ;;
  esac
}

fm_bridge_default_owner() {  # <state>
  case "$1" in
    needs-captain) printf 'captain' ;;
    *)             printf 'firstmate' ;;
  esac
}

fm_bridge_default_severity() {  # <kind>
  case "$1" in
    critical) printf 'critical' ;;
    *)        printf 'normal' ;;
  esac
}

# --- append -----------------------------------------------------------------
#
# fm_bridge_append writes exactly one normalized record. Field values arrive as
# a flat NAME=VALUE argument list so a caller never has to build JSON.
#
#   fm_bridge_append id=o1 kind=decision project=orca state=needs-captain \
#                    title='...' answer='A: keep' answer='B: drop'
#
# Repeated answer= arguments build the answer-form array. Empty values are
# dropped rather than written as empty strings, so a partial update record
# carries only the fields it actually changes - the fold merges present fields
# over the item's prior state.
fm_bridge_append() {  # <name=value> ...
  local arg name value ledger json='' answers='' n_answers=0
  local id='' kind='' project='' state='' severity='' owner='' title='' body=''
  local pointer='' check='' note='' phase='' ts=''

  for arg in "$@"; do
    case "$arg" in
      *=*) name=${arg%%=*}; value=${arg#*=} ;;
      *) printf 'fm-bridge: append expects name=value, got: %s\n' "$arg" >&2; return 2 ;;
    esac
    case "$name" in
      id) id=$value ;;
      kind) kind=$value ;;
      project) project=$value ;;
      state) state=$value ;;
      severity) severity=$value ;;
      owner) owner=$value ;;
      title) title=$value ;;
      body) body=$value ;;
      pointer) pointer=$value ;;
      check) check=$value ;;
      note) note=$value ;;
      phase) phase=$value ;;
      ts) ts=$value ;;
      answer)
        [ -n "$value" ] || continue
        [ "$n_answers" -gt 0 ] && answers="$answers,"
        answers="$answers$(fm_bridge_json_str "$value")"
        n_answers=$((n_answers + 1))
        ;;
      *) printf 'fm-bridge: unknown field: %s\n' "$name" >&2; return 2 ;;
    esac
  done

  # Validate enums at WRITE time. The reader tolerates anything ever written, so
  # refusing a bad value here is the only place a typo can be caught while the
  # author is still present to fix it.
  if [ -n "$kind" ] && ! fm_bridge_in_set "$kind" "$FM_BRIDGE_KINDS"; then
    printf 'fm-bridge: kind must be one of: %s\n' "$FM_BRIDGE_KINDS" >&2; return 2
  fi
  if [ -n "$state" ] && ! fm_bridge_in_set "$state" "$FM_BRIDGE_STATES"; then
    printf 'fm-bridge: state must be one of: %s\n' "$FM_BRIDGE_STATES" >&2; return 2
  fi
  if [ -n "$severity" ] && ! fm_bridge_in_set "$severity" "$FM_BRIDGE_SEVERITIES"; then
    printf 'fm-bridge: severity must be one of: %s\n' "$FM_BRIDGE_SEVERITIES" >&2; return 2
  fi

  # WRITERS NORMALIZE. A record that OPENS an item (one that names its kind)
  # states its disposition explicitly rather than leaning on a reader default,
  # so the raw stream the co-captain audits already says what the item is. This
  # matters most for the ask kinds: a decision that reached the ledger without a
  # state would render as something firstmate is handling, and an ask that does
  # not look like an ask is the one failure this field exists to prevent.
  # Records with NO kind are partial updates (resolve, handling) and are left
  # minimal on purpose - defaulting them would overwrite fields the update never
  # meant to touch.
  if [ -n "$kind" ]; then
    [ -n "$state" ] || state=$(fm_bridge_default_state "$kind")
    [ -n "$severity" ] || severity=$(fm_bridge_default_severity "$kind")
    [ -n "$owner" ] || owner=$(fm_bridge_default_owner "$state")
  fi

  [ -n "$id" ] || {
    [ -n "$title" ] || { printf 'fm-bridge: append needs id= or title=\n' >&2; return 2; }
    id=$(fm_bridge_derive_id "${kind:-event}" "$project" "$title")
  }
  id=$(fm_bridge_slug "$id")
  [ -n "$id" ] || { printf 'fm-bridge: id slugified to empty\n' >&2; return 2; }
  [ -n "$project" ] && project=$(fm_bridge_slug "$project" 40)
  [ -n "$ts" ] || ts=$(fm_bridge_now)

  # Bound the record so one write(2) stays atomic under O_APPEND. Body first,
  # then title: losing detail is recoverable, losing the whole record is not.
  local truncated=0 overhead
  overhead=$(( ${#id} + ${#kind} + ${#project} + ${#state} + ${#severity} \
    + ${#owner} + ${#pointer} + ${#check} + ${#note} + ${#phase} + ${#answers} + 220 ))
  local budget=$(( FM_BRIDGE_MAX_RECORD_BYTES - overhead ))
  [ "$budget" -lt 120 ] && budget=120
  if [ $(( ${#title} + ${#body} )) -gt "$budget" ]; then
    truncated=1
    local title_budget=$(( budget / 3 ))
    [ "$title_budget" -lt 80 ] && title_budget=80
    if [ ${#title} -gt "$title_budget" ]; then
      title="${title:0:$((title_budget - 1))}…"
    fi
    local body_budget=$(( budget - ${#title} ))
    [ "$body_budget" -lt 0 ] && body_budget=0
    if [ ${#body} -gt "$body_budget" ]; then
      if [ "$body_budget" -gt 1 ]; then
        body="${body:0:$((body_budget - 1))}…"
      else
        body=''
      fi
    fi
  fi

  json="{\"v\":$FM_BRIDGE_SCHEMA_VERSION"
  json="$json,\"ts\":$(fm_bridge_json_str "$ts")"
  json="$json,\"id\":$(fm_bridge_json_str "$id")"
  [ -n "$kind" ]     && json="$json,\"kind\":$(fm_bridge_json_str "$kind")"
  [ -n "$project" ]  && json="$json,\"project\":$(fm_bridge_json_str "$project")"
  [ -n "$state" ]    && json="$json,\"state\":$(fm_bridge_json_str "$state")"
  [ -n "$severity" ] && json="$json,\"severity\":$(fm_bridge_json_str "$severity")"
  [ -n "$owner" ]    && json="$json,\"owner\":$(fm_bridge_json_str "$owner")"
  [ -n "$title" ]    && json="$json,\"title\":$(fm_bridge_json_str "$title")"
  [ -n "$body" ]     && json="$json,\"body\":$(fm_bridge_json_str "$body")"
  [ -n "$pointer" ]  && json="$json,\"pointer\":$(fm_bridge_json_str "$pointer")"
  [ -n "$check" ]    && json="$json,\"check\":$(fm_bridge_json_str "$check")"
  [ -n "$note" ]     && json="$json,\"note\":$(fm_bridge_json_str "$note")"
  [ -n "$phase" ]    && json="$json,\"phase\":$(fm_bridge_json_str "$phase")"
  [ "$n_answers" -gt 0 ] && json="$json,\"answers\":[$answers]"
  [ "$truncated" -eq 1 ] && json="$json,\"truncated\":true"
  json="$json}"

  ledger=$(fm_bridge_ledger_path)
  mkdir -p "$(dirname "$ledger")" || return 1
  # One O_APPEND write of one bounded line. No read, no rewrite, no lock.
  printf '%s\n' "$json" >> "$ledger" || return 1
  # shellcheck disable=SC2034 # Read by bin/fm-bridge.sh's emit, not this lib.
  FM_BRIDGE_LAST_ID=$id
  return 0
}
