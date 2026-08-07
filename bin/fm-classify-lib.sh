#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# Long re-surface cadence for a CAPTAIN-GATED wait, whose holding condition is a
# human ruling. Elapsed time cannot clear such a wait, so re-asking "does this
# wait still hold?" on the bounded cadence above only re-asks a question whose
# answer is already known, once an hour, for as long as the ruling is outstanding.
# Kept FINITE for the same reason the bounded cadence is - a forgotten hold must
# not rot invisibly - but it is a BACKSTOP, not the clearing mechanism: the
# arriving ruling drives the recheck through wait_recheck_request below.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_CAPTAIN_RESURFACE_SECS_DEFAULT=21600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# Kept separate from status_is_paused because the two declare DIFFERENT waits:
# a pause is bounded and expected to clear on its own, while a captain-held
# transfer cannot clear until a human rules. wait_class below is the one owner
# of what that difference costs.
status_is_captain_held() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  status_is_paused "$1" || status_is_captain_held "$1"
}

# --- declared-wait cadence class --------------------------------------------
#
# The ONE owner of the captain-gated / bounded split. Both consumers of the
# declared-wait recheck (fm-watch.sh's handle_paused_stale, fm-supervise-daemon.sh's
# pause re-surface) classify through here, so the cadence policy cannot drift
# between the always-on watcher and the away-mode daemon.
#
# TWO SIGNALS, OR'd, because they carry different facts and each covers a case
# the other cannot see:
#   - the STATUS VERB is the worker's own live declaration. Free, always current,
#     but only as good as whatever that worker last wrote.
#   - the BACKLOG HOLD KIND is firstmate's durable record that a human decision
#     gates this work. It survives status-line churn and covers the measured case
#     of a lane correctly declaring a plain `paused:` while firstmate holds the
#     item for the captain, plus the lane blocked by a captain hold that some
#     other lane's decision created.
# Neither alone is sufficient, so neither alone is used.
#
# The class is DERIVED from current state, never recorded on the lane when it
# parks. That is what makes a released hold self-healing: once the backlog stops
# recording a captain gate, the lane falls back to the bounded cadence on its own,
# with no invalidation step to forget. The backlog half of that derivation is
# throttled to one read per recheck window (see below), so the fallback is
# delayed by at most that window and never lost.
#
# UNREADABLE EVIDENCE IS NOT EVIDENCE OF A GATE. An absent, incompatible, or
# unparseable backlog answers `bounded`, never `captain`: the failure of a signal
# must never be what quiets a lane, and bounded is the noisier of the two.

# The backlog reader used by the classifier. Overridable so tests can drive the
# split without a real tasks-axi install.
FM_TASKS_AXI_BIN="${FM_TASKS_AXI_BIN:-tasks-axi}"

_wait_task_show() {  # <backlog-file> <task-id>
  command -v "$FM_TASKS_AXI_BIN" >/dev/null 2>&1 || return 1
  "$FM_TASKS_AXI_BIN" show "$2" --full --file "$1" 2>/dev/null
}

_wait_show_field() {  # <show-output> <field> -> value, unquoted, empty when absent
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}

# 0 when the backlog durably records that a human decision gates <task-id>: the
# item is itself held for the captain, or it is blocked by an item that is.
# Depth is deliberately ONE, not a graph walk - a lane blocked by a captain hold
# is the exact shape fm-decision-hold.sh creates (routed work blocked by
# <origin>-decision-<key>), so one level covers the designed relationship without
# turning a supervision poll into a backlog traversal.
backlog_wait_is_captain_gated() {  # <backlog-file> <task-id>
  local backlog=$1 task=$2 show blocked dep
  [ -n "$backlog" ] && [ -f "$backlog" ] || return 1
  show=$(_wait_task_show "$backlog" "$task") || return 1
  [ -n "$show" ] || return 1
  [ "$(_wait_show_field "$show" hold_kind)" = captain ] && return 0
  blocked=$(_wait_show_field "$show" blocked_by | tr -d '[:space:]')
  case "$blocked" in ''|none|-) return 1 ;; esac
  for dep in $(printf '%s' "$blocked" | tr ',' ' '); do
    show=$(_wait_task_show "$backlog" "$dep") || continue
    [ -n "$show" ] || continue
    [ "$(_wait_show_field "$show" hold_kind)" = captain ] && return 0
  done
  return 1
}

# The same answer, re-read at most once per <ttl> seconds. The recheck path runs
# on EVERY poll for as long as a lane stays parked, so an unthrottled lookup
# would spend a process per poll per lane for hours to re-answer a question that
# changes at most once. Callers pass the bounded recheck cadence as the ttl, which
# buys exactly one backlog read per lane per bounded window.
#
# The freshness that matters is not what this trades away. An arriving ruling
# never consults this answer at all - it is a durable request read on every poll
# - so a stale answer can only delay the fall back to the ordinary cadence for a
# hold released OUTSIDE the ruling path, and only until the next window.
# The record carries its own timestamp rather than leaning on file mtime, so
# neither consumer needs a portable stat helper for it.
_wait_class_cache_path() {  # <state-dir> <task-id>
  printf '%s/.wait-class-%s' "$1" "$(printf '%s' "$2" | tr '/:' '__')"
}

wait_class_cache_clear() {  # <state-dir> <task-id>
  rm -f "$(_wait_class_cache_path "$1" "$2")"
}

_backlog_captain_gate_throttled() {  # <state-dir> <task-id> <backlog-file> <ttl>
  local state=$1 task=$2 backlog=$3 ttl=$4 cache record stamp answer now
  cache=$(_wait_class_cache_path "$state" "$task")
  now=$(date +%s)
  record=$(cat "$cache" 2>/dev/null || true)
  stamp=${record%%$'\t'*}
  answer=${record#*$'\t'}
  case "$stamp" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$(( now - stamp ))" -lt "$ttl" ]; then
        [ "$answer" = captain ]
        return
      fi
      ;;
  esac
  if backlog_wait_is_captain_gated "$backlog" "$task"; then answer=captain; else answer=bounded; fi
  printf '%s\t%s' "$now" "$answer" > "$cache" 2>/dev/null || true
  [ "$answer" = captain ]
}

# Classify a declared wait: `captain` (only a human ruling can end it),
# `bounded` (expected to clear on its own), or `none` (not a declared wait).
# The backlog is consulted ONLY when the verb alone does not already answer
# captain, and then only through the throttle above.
wait_class() {  # <status-line> <backlog-file> <task-id> <state-dir> <ttl>
  local line=$1 backlog=${2:-} task=${3:-} state=${4:-} ttl=${5:-0}
  if status_is_captain_held "$line"; then printf 'captain'; return 0; fi
  if ! status_is_paused "$line"; then printf 'none'; return 0; fi
  if [ -n "$task" ] && [ -n "$state" ] && [ -d "$state" ] \
    && _backlog_captain_gate_throttled "$state" "$task" "$backlog" "$ttl"; then
    printf 'captain'
  else
    printf 'bounded'
  fi
}

# --- ruling-driven recheck request ------------------------------------------
#
# The event that can actually clear a captain-gated wait is the ruling, not the
# clock, so the ruling records a durable recheck request against every lane it
# gates and that lane comes due at the very next supervision poll regardless of
# how much of its long cadence remains. Written by bin/fm-decision-hold.sh when a
# captain decision is routed to the work it was blocking; consumed by the
# watcher and the away-mode daemon, each of which clears the request only for a
# lane it actually surfaced, so a deferred check-in can never swallow a ruling.
#
# This is what makes the long captain-gated cadence safe: without it, widening
# the cadence would just mean a lane that CAN move sits longer before anyone
# notices.
#
# THE REQUEST HAS A BOUNDED LIFETIME, for the same reason it exists at all: it
# claims that an EVENT just happened. Every consumer only reaches it through a
# lane that is currently declaring a wait, so a request written against work no
# crew is running - a ruling routed to queued backlog work, say - is read by
# nobody. Kept forever, that marker is still there whenever some later crew takes
# the same id and legitimately parks, and it then reports "ruling landed" for a
# ruling that landed on nothing: an event claimed that did not happen, costing
# exactly the unbatched supervision turn this cadence split exists to remove.
#
# A LIFETIME CANNOT SEPARATE THE TWO WORLDS IT SPANS, and this is the direction
# it errs in:
#   (a) a request whose lane will never park - genuinely stale, and dropping it
#       is exactly right;
#   (b) a request whose lane has not been dispatched YET - the ruling is real and
#       the recheck is still owed.
# From here both are the same thing: an unread marker and a clock. So the
# lifetime honors (b) for as long as (a) can still be tolerated, and then drops
# both. ERRING TOWARD DROPPING IS THE SAFE DIRECTION, and that is the whole
# justification for expiring at all: the wait class above is DERIVED from live
# state on every poll and never recorded on the lane, so a lane that loses its
# request simply falls back to the ordinary cadence, under a captain-gated
# backstop that is itself a finite ceiling. A dropped request costs LATENCY; a
# kept one eventually fabricates an event.
#
# Callers pass the captain-gated recheck window as the lifetime, because that is
# the window the request exists to short-circuit: once that much time has passed,
# it can no longer buy a lane anything its own backstop has not already given it.
_wait_recheck_marker() {  # <state-dir> <task-id>
  printf '%s/.wait-recheck-%s' "$1" "$(printf '%s' "$2" | tr '/:' '__')"
}

# Stamped rather than empty, because the stamp is the lifetime, and written
# through a rename so a poll landing mid-write reads the old record or the new
# one but never an empty file - an empty stamp reads as expired below, and a
# ruling must not be dropped by the instant it was recorded.
wait_recheck_request() {  # <state-dir> <task-id>
  local marker
  [ -d "$1" ] || return 1
  marker=$(_wait_recheck_marker "$1" "$2")
  date +%s > "$marker.new" || return 1
  mv -f "$marker.new" "$marker"
}

# 0 when a recheck request is pending AND still inside <lifetime> seconds of the
# ruling that recorded it. An expired request is REAPED as it is read, so a
# marker no consumer ever reached cannot outlive its meaning.
#
# The two unreadable cases below answer the same "do not fire" and are still not
# the same world, so they must not be collapsed into one. An unreadable LIFETIME
# is the CALLER being wrong - a knob written as 6h rather than 21600 - and says
# nothing about the request, so the request is left for a correctly configured
# read to judge rather than destroyed by a misconfiguration. An unreadable STAMP
# is the RECORD being wrong: a request that cannot say when its ruling landed can
# never be judged by any caller, so it is reaped where it lies.
wait_recheck_pending() {  # <state-dir> <task-id> <lifetime-secs>
  local marker lifetime=${3:-} stamp
  marker=$(_wait_recheck_marker "$1" "$2")
  [ -e "$marker" ] || return 1
  stamp=$(cat "$marker" 2>/dev/null || true)
  case "$lifetime" in ''|*[!0-9]*) return 1 ;; esac
  case "$stamp" in ''|*[!0-9]*) rm -f "$marker"; return 1 ;; esac
  [ "$(( $(date +%s) - stamp ))" -lt "$lifetime" ] && return 0
  rm -f "$marker"
  return 1
}

wait_recheck_clear() {  # <state-dir> <task-id>
  rm -f "$(_wait_recheck_marker "$1" "$2")"
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
