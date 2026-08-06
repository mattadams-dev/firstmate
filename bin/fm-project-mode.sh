#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init),
# bin/fm-fork-freshness.sh (enumerate registered projects and skip the local-only
# ones, which have no forge identity to read), and bin/fm-spawn.sh's advisory
# registry-deviation notice.
#
# This file is the ONLY parser of the registry line format. A caller that needs
# the whole registry rather than one project asks for --list rather than reading
# data/projects.md itself, because a second reader of the format is a second
# thing to keep in step with it.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# --list prints one "<name> <mode> <yolo>" line per registered project, in
# registry order, with the same validation, fallback and --raw mapping applied
# per line. There is no name to fall back FOR when the registry is missing
# entirely, so that prints nothing and warns rather than inventing a project.
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh [--raw] --list
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>|--list}
LIST=0
if [ "$NAME" = "--list" ]; then
  LIST=1
  NAME=""
fi

# parse_registry <name>: emit "<name> <mode> <yolo>" for the named project, or
# for every registered project when <name> is empty. The one form is the other
# with a filter and an early exit, so both readings share exactly one
# interpretation of the line format.
parse_registry() {
  awk -v n="$1" '
    $1=="-" && $2!="" && (n=="" || $2==n) {
      mode="no-mistakes"; yolo="off";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      }
      print $2, mode, yolo;
      if (n != "") exit
    }
  ' "$REG"
}

# resolve <name> <mode> <yolo>: validate what was registered and apply the
# conditional-policy mapping, warning on anything unrecognised. Shared by both
# forms so a typo'd mode is never louder in one than in the other.
resolve() {
  local name=$1 mode=$2 yolo=$3
  case "$mode" in
    no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *) echo "warn: unknown mode \"$mode\" for $name; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
  esac
  case "$yolo" in on|off) ;; *) yolo=off ;; esac
  # A conditional policy is not a task mode. Mechanical callers get its most
  # rigorous leg; --raw callers get the annotation itself (see the header).
  if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
    mode=no-mistakes
  fi
  printf '%s %s\n' "$mode" "$yolo"
}

if [ "$LIST" -eq 1 ]; then
  if [ ! -f "$REG" ]; then
    echo "warn: no registry at $REG; no projects to list" >&2
    exit 0
  fi
  while read -r lname lmode lyolo; do
    [ -n "$lname" ] || continue
    printf '%s %s\n' "$lname" "$(resolve "$lname" "$lmode" "$lyolo")"
  done <<EOF
$(parse_registry "")
EOF
  exit 0
fi

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

parsed=$(parse_registry "$NAME")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

read -r pname pmode pyolo <<EOF
$parsed
EOF
resolve "$pname" "$pmode" "$pyolo"
