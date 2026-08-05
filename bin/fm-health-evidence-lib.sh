#!/usr/bin/env bash
# fm-health-evidence-lib.sh - the ONE owner of "has this lane demonstrably done
# work since the last time we looked?", used to reset wedge-alarm state.
#
# WHY THIS IS SEPARATE FROM BUSY STATE. bin/fm-busy-lib.sh owns the semantic
# turn-lifecycle contract and deliberately excludes child processes and CPU as
# state signals - that boundary stands and this file does not cross it. Busy
# state answers "is a turn in progress?". This answers a different question:
# "did anything move?". A lane can be outside a model turn and still be
# genuinely computing, which is exactly the case that breaks a pane read.
#
# THE DEFECT THIS CLOSES. A wedge escalation ratchets 1 -> 2 -> 3 -> 4 and
# nothing counts it back down. At the demand-deep-inspection threshold every
# wake insists the lane must not be waved through on a cheap read - correct in
# isolation, but it has no counterpart, so PROVEN HEALTH never clears it.
# A test-heavy lane is static for minutes at a time in the ordinary course of
# working (run a bounded sweep, read results, run the next), so it reaches the
# threshold just by doing its job and is then permanently under deep inspection.
# Measured on the live fleet: four deep inspections of one healthy lane inside
# twenty minutes, all four confirming health, a fifth already queued.
# An instrument that can only ratchet toward alarm is not measuring the system;
# it is measuring elapsed time since it started worrying.
#
# THE SIGNALS, and why these three. Each one sees through a blind spot of the
# others, and all three were already being produced at zero extra cost:
#
#   rendered   the captured pane tail changed - the model is producing output.
#              Blind while a foreground command runs and the TUI is static.
#   cpu        the pane's process tree consumed CPU time. Sees straight through
#              a static pane into `timeout 900 bash bin/fm-test-run.sh`, which
#              is precisely the case a pane read cannot distinguish from a wedge.
#   children   live descendants under the pane's foreground command. Catches a
#              tree that is waiting on I/O rather than burning CPU, where the
#              cpu signal alone would read as frozen.
#
# ANY ONE of them advancing is a healthy worker. FROZEN ON ALL THREE across two
# readings is what a real wedge looks like.
#
# NEVER TIME. Elapsed time is not a signal here and must not become one. A
# time-based amnesty - "it has been quiet a while, clear the alarm" - would
# pardon exactly the slow wedge this machinery exists to catch, and it would do
# it silently. That is the load-bearing constraint in this file: every reset
# below is caused by an observed CHANGE between two samples, never by the age of
# anything.
#
# UNKNOWN IS NOT HEALTH. When a sample cannot be taken - no resolvable pane
# process, an unreadable /proc - the comparison returns "unknown" and the caller
# leaves the alarm state exactly as it was. Absence of evidence never resets an
# alarm, and it never accelerates one either.

# fm_health_sample <backend> <target> <rendered-hash>
# One comparable sample line: "rendered=<hash> cpu=<ticks> children=<n>".
# A component that cannot be read is recorded as "?" so a later comparison can
# tell "did not move" apart from "could not be seen".
# The tree is resolved ONCE and handed to both consumers. This runs in the
# watcher's poll loop for every stale window, and each consumer used to walk the
# process table for itself, so one sample cost two full walks of the same tree.
fm_health_sample() {
  local backend=$1 target=$2 rendered=$3 pid pids cpu='?' children='?'
  if pid=$(fm_health_target_pid "$backend" "$target"); then
    pids=$(fm_health_tree_pids "$pid")
    cpu=$(fm_health_tree_cpu "$pids")
    children=$(fm_health_tree_size "$pids")
  fi
  printf 'rendered=%s cpu=%s children=%s\n' "${rendered:-?}" "$cpu" "$children"
}

# The pane's foreground process. Only the two verified supervisor backends can
# answer this; everywhere else the honest answer is that we cannot see it.
fm_health_target_pid() {  # <backend> <target>
  local backend=$1 target=$2 pid session pane
  case "$backend" in
    tmux)
      pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      ;;
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      command -v fm_backend_herdr_cli >/dev/null 2>&1 || return 1
      pid=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null \
        | sed -n 's/.*"\{0,1\}pid"\{0,1\}[[:space:]]*[:=][[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' \
        | head -1) || return 1
      ;;
    *)
      return 1
      ;;
  esac
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Total CPU ticks consumed by <pid> and every descendant. Reads /proc directly;
# a host without it reports "?" rather than a fabricated zero, because a zero
# would read as "frozen" and could raise a false alarm.
fm_health_tree_cpu() {  # <pid-list>
  local pids=$1 proc_root total=0 pid stat_line counted=0
  local -a fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc_root" ] || { printf '?\n'; return 0; }
  for pid in $pids; do
    counted=1
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || continue
    read -r -a fields <<< "${stat_line##*)}"
    [ "${#fields[@]}" -ge 13 ] || continue
    case "${fields[11]}${fields[12]}" in
      ''|*[!0-9]*) continue ;;
    esac
    total=$(( total + fields[11] + fields[12] ))
  done
  # No readable process in the tree is UNKNOWN, not zero. A fabricated 0 compares
  # as "did not move" on a channel the reset depends on, which is the same defect
  # as the fabricated child count and fails in the same silent direction.
  [ "$counted" -eq 1 ] || { printf '?\n'; return 0; }
  printf '%s\n' "$total"
}

fm_health_tree_size() {  # <pid-list>
  local n
  n=$(printf '%s\n' "$1" | grep -c .) || true
  case "$n" in
    ''|*[!0-9]*|0) printf '?\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# <pid> and its descendants, one line each. ONE ps call and ONE awk pass: the
# awk program builds the ppid->children map and walks it, so the cost does not
# grow with the size of the tree.
#
# It used to run `ps -o pid= --ppid <pid>` once per visited pid. That is a GNU
# option every other parent walk in bin/ already avoids, and on macOS - a
# supported platform - it is rejected outright, so the walk found no children and
# fm_health_tree_size reported a literal 1 for every process tree. A constant
# reported as an observation is worse than no observation: this file's own
# contract says an unreadable component must be recorded as '?' precisely so a
# comparison can tell "did not move" apart from "could not be seen", and a
# fabricated 1 never moves. That put a fabricated value on one of the three
# evidence channels the reset depends on. Per-pid forking in the watcher's poll
# loop was the lesser half of the problem.
#
# Failure prints nothing, so callers report '?' rather than a count.
fm_health_tree_pids() {  # <root-pid>
  local root=$1 table
  case "$root" in
    ''|*[!0-9]*) return 0 ;;
  esac
  table=$(ps -eo pid=,ppid= 2>/dev/null) || return 0
  [ -n "$table" ] || return 0
  # The root must actually be in the table. Emitting it unconditionally reported
  # a tree of exactly 1 for a pid that does not exist - the same fabricated
  # constant, one level down from the GNU-option defect above.
  printf '%s\n' "$table" | awk -v root="$root" -v limit=256 '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      kids[$2] = kids[$2] " " $1
      if ($1 == root) found = 1
    }
    END {
      if (!found) exit 1
      frontier = root
      seen = 0
      while (frontier != "" && seen < limit) {
        following = ""
        count = split(frontier, level, " ")
        for (i = 1; i <= count && seen < limit; i++) {
          print level[i]
          seen++
          following = following kids[level[i]]
        }
        frontier = following
      }
    }
  ' || return 0
}

# fm_health_compare <previous-sample> <current-sample>
#   0 - at least one component ADVANCED: proven health.
#   1 - every readable component held still: no evidence of health.
#   2 - nothing comparable could be read: unknown, which is neither.
# FM_HEALTH_ADVANCED names the components that moved, for the transition log.
FM_HEALTH_ADVANCED=
fm_health_compare() {
  local prev=$1 cur=$2 field old new comparable=0 advanced=
  FM_HEALTH_ADVANCED=
  [ -n "$prev" ] && [ -n "$cur" ] || return 2
  for field in rendered cpu children; do
    old=$(printf '%s\n' "$prev" | tr ' ' '\n' | sed -n "s/^$field=//p")
    new=$(printf '%s\n' "$cur" | tr ' ' '\n' | sed -n "s/^$field=//p")
    [ -n "$old" ] && [ -n "$new" ] || continue
    [ "$old" != '?' ] && [ "$new" != '?' ] || continue
    comparable=$((comparable + 1))
    case "$field" in
      rendered)
        # Any change is production; a hash has no ordering.
        [ "$old" = "$new" ] || advanced="$advanced rendered"
        ;;
      *)
        # Monotonic counters. A DECREASE is a restarted or replaced tree, not
        # work done, so it is deliberately not counted as health.
        case "$old$new" in
          *[!0-9]*) continue ;;
        esac
        [ "$new" -gt "$old" ] && advanced="$advanced $field"
        ;;
    esac
  done
  [ "$comparable" -gt 0 ] || return 2
  if [ -n "$advanced" ]; then
    # shellcheck disable=SC2034 # Read by callers for the transition log.
    FM_HEALTH_ADVANCED=${advanced# }
    return 0
  fi
  return 1
}
