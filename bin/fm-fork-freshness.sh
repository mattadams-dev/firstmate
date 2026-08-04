#!/usr/bin/env bash
# Fork freshness sweep: read every maintained fork's compare-status against its
# upstream and turn "behind" into a tracked sync task instead of a warning.
#
# A fork that is behind blocks merges, makes its PRs misreport their own diff,
# and misdirects investigations, so the reading is taken by machine on two
# triggers rather than remembered: before any fork PR (bin/fm-pr-check.sh, which
# every merge provably passes through because bin/fm-pr-merge.sh refuses without
# the pr= it records) and on a weekly schedule (the locked session-start sweep in
# bin/fm-bootstrap.sh, gated here by --if-due). docs/fork-freshness.md owns the
# contract, the cadence, and the local configuration.
#
# Usage:
#   fm-fork-freshness.sh sweep [--if-due] [--owner <login>] [--dispatch] [--verbose]
#   fm-fork-freshness.sh check <owner/repo> [--dispatch]
#
# `sweep` covers every maintained fork: every fork owned by the sweep owner
# (read through the authenticated repo list, which includes private repos - the
# public users/<login>/repos endpoint sees a subset and would silently truncate),
# unioned with the origin of every clone under this home's projects/ and every
# entry in config/maintained-forks, minus config/fork-sweep-ignore. Ignored and
# unreachable candidates are reported, never dropped.
#
# `check <owner/repo>` takes one reading. It is silent when the repository is
# determinately not a fork, and loud when that could not be determined.
#
# Output is one line per swept fork plus one coverage line:
#   FORK_FRESHNESS: <owner/repo> status=<in-sync|behind|ahead|diverged> behind=<n> ahead=<n> upstream=<owner/repo> compare=<fork-branch>...<upstream-branch> action=<...>
#   FORK_FRESHNESS: <owner/repo> status=unknown reason=<text>
#   FORK_FRESHNESS_COVERAGE: owner=<login> repos=<n> forks=<n> swept=<n> behind=<n> unknown=<n> ignored=<n>
#   FORK_FRESHNESS_COVERAGE: status=unknown reason=<text>
# An unknown reading carries no behind= or ahead= field at all: a missing tool,
# an expired credential, a rate limit, an unreachable forge, and a renamed
# upstream are all "unknown", and none of them may render as in-sync. A reading
# that names both directions ("behind=20 ahead=6 status=diverged") is actionable
# where a single number is not, so both are always reported.
#
# Exit codes: 0 every reading taken and no fork behind; 3 at least one fork
# behind; 4 at least one unknown; 5 both. Callers that must not fail on a
# freshness result invoke this with `|| true` and relay the lines.
#
# behind > 0 materialises a durable sync task, idempotently, under the
# deterministic id fm-sync-<repo>: data/<id>/brief.md carrying the proven sync
# procedure, a backlog item, a check wake, and a Bridge item. Re-running never
# creates a second task for the same fork. --dispatch additionally launches the
# worker through bin/fm-spawn.sh when this home has a clone of that fork and
# FM_FORK_SYNC_HARNESS or config/fork-sync-harness names the harness to use;
# without it the task stays queued, because the sync pushes a merge commit
# straight to a default branch and that is not a dispatch this fleet makes
# without a person saying go. Either way the task exists and is tracked.
#
# This script never performs a sync: it neither fetches, merges, nor pushes any
# repository. It only reads compare-status and creates work.
#
# Local configuration, all optional and all under this home's config/:
#   fork-sweep-owner          login whose forks are swept (default: this home's own origin owner)
#   maintained-forks          extra "owner/repo" (or bare "repo") candidates, one per line
#   fork-sweep-ignore         "owner/repo" or bare "repo" candidates to skip, one per line
#   fork-sweep-interval-days  --if-due cadence in whole days (default 7)
#   fork-sync-harness         harness --dispatch launches the sync worker on
# Environment overrides: FM_FORK_SWEEP_INTERVAL_DAYS, FM_FORK_SWEEP_RETRY_MINUTES
# (floor between attempts after an incomplete sweep, default 60),
# FM_FORK_SYNC_HARNESS, FM_FORK_FRESHNESS_NOW (epoch, for tests).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

now_epoch() {
  printf '%s\n' "${FM_FORK_FRESHNESS_NOW:-$(date +%s)}"
}

# One-line, tab-free, bounded: a reason is interpolated into a status line, and a
# multi-line CLI error would otherwise forge extra readings.
clean_reason() {
  printf '%s' "$1" |
    LC_ALL=C tr '\t\r\n' '   ' |
    LC_ALL=C tr -cd '[:print:]' |
    cut -c1-200
}

config_value() {
  local name=$1 value
  [ -f "$CONFIG/$name" ] || return 1
  value=$(tr -d '[:space:]' < "$CONFIG/$name" 2>/dev/null || true)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# config_list <name>: non-empty, non-comment lines of a config file, whitespace
# stripped. Absent file is an empty list, not an error.
config_list() {
  local name=$1 line value
  [ -f "$CONFIG/$name" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    value=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$value" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$value"
  done < "$CONFIG/$name"
}

# repo_slug_from_url <git-url>: "owner/repo" for a forge URL, nothing otherwise.
# Handles ssh://git@<host-alias>/owner/repo.git, git@<host>:owner/repo.git and
# https://<host>/owner/repo(.git). A file:// or path remote has no forge
# identity and yields nothing.
repo_slug_from_url() {
  local url=$1 path
  case "$url" in
    file://*|/*|.*) return 0 ;;
    ssh://*|https://*|http://*)
      path=${url#*://}
      path=${path#*@}
      path=${path#*/}
      ;;
    *:*)
      path=${url#*:}
      ;;
    *) return 0 ;;
  esac
  path=${path%.git}
  path=${path#/}
  case "$path" in
    */*/*|'') return 0 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 0 ;;
  esac
}

origin_slug() {
  local dir=$1 url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  repo_slug_from_url "$url"
}

# --- forge reads ------------------------------------------------------------
#
# Every read here has exactly two determinate outcomes and one indeterminate
# one. The indeterminate one returns non-zero and prints its reason on the same
# stdout the value would have used, so the caller that captures the value also
# captures the reason. A reason parked in a shell variable would be lost: every
# one of these is called through a command substitution, and a subshell's
# assignment never reaches the caller - which is how an unknown reading loses
# the one thing that makes it actionable.

gh_available() {
  command -v gh >/dev/null 2>&1
}

# repo_facts <owner/repo> -> "<isFork>\t<parent-full-name>\t<default-branch>\t<isArchived>"
repo_facts() {
  local slug=$1 out
  out=$(gh api "repos/$slug" \
    --jq '[(.fork|tostring), (.parent.full_name // ""), (.default_branch // ""), (.archived|tostring)] | @tsv' 2>&1) || {
    clean_reason "$out"
    return 1
  }
  case "$out" in
    true*|false*) printf '%s\n' "$out" ;;
    *)
      clean_reason "unreadable repository payload: $out"
      return 1
      ;;
  esac
}

# compare_status <upstream-slug> <upstream-branch> <fork-owner> <fork-branch>
#   -> "<status>\t<ahead_by>\t<behind_by>", where ahead/behind are the fork's.
compare_status() {
  local up=$1 up_branch=$2 fork_owner=$3 fork_branch=$4 out status ahead behind
  out=$(gh api "repos/$up/compare/${up%%/*}:$up_branch...$fork_owner:$fork_branch" \
    --jq '[.status, (.ahead_by|tostring), (.behind_by|tostring)] | @tsv' 2>&1) || {
    clean_reason "$out"
    return 1
  }
  IFS=$'\t' read -r status ahead behind <<< "$out"
  case "$status" in
    identical|ahead|behind|diverged) ;;
    *)
      clean_reason "unreadable compare payload: $out"
      return 1
      ;;
  esac
  case "$ahead$behind" in
    ''|*[!0-9]*)
      clean_reason "non-numeric compare counts: $out"
      return 1
      ;;
  esac
  printf '%s\t%s\t%s\n' "$status" "$ahead" "$behind"
}

# enumerate_owned <owner> -> one TSV row per owned repository. Uses the
# authenticated repository list so private repositories are included; a partial
# list would be a silent truncation of the sweep's whole reason to exist.
enumerate_owned() {
  local owner=$1 out
  out=$(gh repo list "$owner" --limit 200 \
    --json nameWithOwner,isFork,isArchived,parent,defaultBranchRef \
    --jq '.[] | [.nameWithOwner, (.isFork|tostring), (.isArchived|tostring), (.parent | if . == null then "" else .owner.login + "/" + .name end), (.defaultBranchRef.name // "")] | @tsv' 2>&1) || {
    clean_reason "$out"
    return 1
  }
  printf '%s\n' "$out"
}

# --- sync task materialisation ----------------------------------------------

sync_task_id() {
  printf 'fm-sync-%s\n' "$(printf '%s' "${1##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')"
}

# clone_dir_for <owner/repo>: this home's clone of that fork, if it has one.
clone_dir_for() {
  local slug=$1 name dir
  name=${slug##*/}
  dir="$PROJECTS/$name"
  [ -d "$dir/.git" ] || return 1
  [ "$(origin_slug "$dir")" = "$slug" ] || return 1
  printf '%s\n' "$dir"
}

write_sync_brief() {
  local path=$1 slug=$2 up=$3 fork_branch=$4 up_branch=$5 behind=$6 ahead=$7 status=$8 taken=$9
  local clone push_hint=""
  if clone=$(clone_dir_for "$slug"); then
    push_hint=$(git -C "$clone" remote get-url origin 2>/dev/null || true)
  fi
  mkdir -p "$(dirname "$path")"
  {
    cat <<BRIEF
# Sync $slug from $up

Bring the fork's \`$fork_branch\` back level with \`$up\` \`$up_branch\`.

## The reading that opened this task

Taken $taken: **behind $behind, ahead $ahead - $status**.

Re-take it before you act and again when you finish - a reading can be right
when taken and wrong when used:

\`\`\`
gh api repos/$up/compare/${up%%/*}:$up_branch...${slug%%/*}:$fork_branch --jq '{status, ahead_by, behind_by}'
\`\`\`

## The procedure - proven, and the alternatives are known-broken

1. **Push a true merge commit directly to \`$fork_branch\`. Never through a PR.**
   A squashed sync fossilises the divergence permanently: the merged-away commits
   never become ancestors, so every later compare still reports the fork behind.
   This is why the sync is the one change that does not go through a pull request.
2. **\`gh repo sync\` does not work here.** It fails on commits that touch workflow
   files, and upstream carries workflow commits.
3. **Push over the SSH alias remote form**, not an https remote.
BRIEF
    if [ -n "$push_hint" ]; then
      printf '   %s clone already has it: %s\n' "This home's" "$push_hint"
    fi
    cat <<BRIEF
4. **The old fast-forward procedure is retired, not conditioned.** Do not
   reintroduce it, and do not force, reset, or rewrite either side.

## Steps

\`\`\`
git fetch upstream
git checkout $fork_branch
git merge upstream/$up_branch     # a real merge commit; never --squash, never --ff-only
# resolve conflicts, then verify the tree builds and its tests pass
git push origin $fork_branch      # the SSH-alias remote
\`\`\`

Take the conflicts seriously: an upstream sync can silently land on top of work
another lane is restructuring. Before merging, intersect the upstream-changed
file list with what is currently in flight, and report the overlap.

## Isolation

Work in a disposable clone or worktree, never in the primary checkout, and
never in a lane whose work is not yet landed.

## If it will not resolve cleanly

Stop and report rather than forcing anything. Discarding either side's commits
needs the captain's explicit word.
BRIEF
    cat <<BRIEF

## Definition of done

The compare-status command above reads **behind 0** for \`$slug\` against
\`$up\`, taken fresh after the push, with that output quoted in your report.
BRIEF
  } > "$path"
}

backlog_add() {
  local id=$1 title=$2 note=$3
  command -v tasks-axi >/dev/null 2>&1 || return 1
  ( cd "$FM_HOME" && tasks-axi add "$title" --id "$id" --body "$note" ) >/dev/null 2>&1
}

bridge_note() {
  local slug=$1 title=$2 body=$3
  [ -x "$SCRIPT_DIR/fm-bridge.sh" ] || return 0
  "$SCRIPT_DIR/fm-bridge.sh" ask --project "${slug##*/}" --title "$title" \
    --body "$body" --answer "sync now" --answer "hold" --quiet >/dev/null 2>&1 || true
}

queue_wake() {
  local payload=$1
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_append check fork-freshness "$payload" >/dev/null 2>&1 || true
}

dispatch_harness() {
  printf '%s\n' "${FM_FORK_SYNC_HARNESS:-$(config_value fork-sync-harness || true)}"
}

# ensure_sync_task <slug> <upstream> <fork-branch> <upstream-branch> <behind> <ahead> <status>
# Echoes the action taken. Idempotent by construction: the task id is derived
# from the fork, so a second sweep finds the first sweep's task.
ensure_sync_task() {
  local slug=$1 up=$2 fork_branch=$3 up_branch=$4 behind=$5 ahead=$6 status=$7
  local id brief taken harness clone
  id=$(sync_task_id "$slug")
  brief="$DATA/$id/brief.md"

  if [ -f "$STATE/$id.meta" ]; then
    printf 'task %s already under way\n' "$id"
    return 0
  fi
  if [ -f "$brief" ]; then
    printf 'task %s already queued\n' "$id"
    return 0
  fi

  taken=$(date -u -d "@$(now_epoch)" '+%Y-%m-%d %H:%M UTC' 2>/dev/null ||
    date -u '+%Y-%m-%d %H:%M UTC')
  if ! write_sync_brief "$brief" "$slug" "$up" "$fork_branch" "$up_branch" \
    "$behind" "$ahead" "$status" "$taken"; then
    printf 'task %s NOT created: instructions could not be written\n' "$id"
    return 1
  fi

  backlog_add "$id" "Sync $slug from $up" \
    "Reading $taken: behind $behind, ahead $ahead - $status. Instructions: data/$id/brief.md. Sync pushes a true merge commit directly to $fork_branch, never through a PR." ||
    printf 'BACKLOG_MANUAL: add %s to the backlog by hand\n' "$id" >&2
  queue_wake "fork-freshness: $slug is behind $up by $behind (ahead $ahead) - sync task $id"
  bridge_note "$slug" "$slug is behind $up by $behind commits" \
    "Reading $taken: behind $behind, ahead $ahead - $status. Sync task $id is queued with the procedure; it pushes a merge commit straight to $fork_branch, so it waits for a go."

  harness=$(dispatch_harness)
  if [ "$DISPATCH" != 1 ]; then
    printf 'task %s queued\n' "$id"
    return 0
  fi
  if ! clone=$(clone_dir_for "$slug"); then
    printf 'task %s queued (no local copy of %s in this home)\n' "$id" "${slug##*/}"
    return 0
  fi
  if [ -z "$harness" ]; then
    printf 'task %s queued (no fork-sync-harness configured)\n' "$id"
    return 0
  fi
  if "$SCRIPT_DIR/fm-spawn.sh" "$id" "$clone" --harness "$harness" >/dev/null 2>&1; then
    printf 'task %s dispatched\n' "$id"
  else
    printf 'task %s queued (worker could not be launched)\n' "$id"
  fi
}

# --- one fork ---------------------------------------------------------------

BEHIND_COUNT=0
UNKNOWN_COUNT=0
SWEPT_COUNT=0

emit_unknown() {
  printf 'FORK_FRESHNESS: %s status=unknown reason=%s\n' "$1" "$(clean_reason "$2")"
  UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
}

# read_fork <slug> <parent-slug> <fork-default-branch>
# Any blank parent or branch is resolved from the forge; a resolution failure is
# unknown, never a skip.
read_fork() {
  local slug=$1 up=$2 fork_branch=$3
  local facts up_branch cmp status ahead behind action

  if [ -z "$up" ] || [ -z "$fork_branch" ]; then
    if ! facts=$(repo_facts "$slug"); then
      emit_unknown "$slug" "repository could not be read: $facts"
      return 0
    fi
    [ -n "$up" ] || up=$(printf '%s' "$facts" | cut -f2)
    [ -n "$fork_branch" ] || fork_branch=$(printf '%s' "$facts" | cut -f3)
  fi
  if [ -z "$up" ]; then
    emit_unknown "$slug" "fork has no readable upstream"
    return 0
  fi
  if [ -z "$fork_branch" ]; then
    emit_unknown "$slug" "fork has no readable default branch"
    return 0
  fi

  if ! facts=$(repo_facts "$up"); then
    emit_unknown "$slug" "upstream $up could not be read: $facts"
    return 0
  fi
  up_branch=$(printf '%s' "$facts" | cut -f3)
  if [ -z "$up_branch" ]; then
    emit_unknown "$slug" "upstream $up has no readable default branch"
    return 0
  fi

  if ! cmp=$(compare_status "$up" "$up_branch" "${slug%%/*}" "$fork_branch"); then
    emit_unknown "$slug" "compare against $up failed: $cmp"
    return 0
  fi
  IFS=$'\t' read -r status ahead behind <<< "$cmp"
  [ "$status" != identical ] || status=in-sync

  SWEPT_COUNT=$((SWEPT_COUNT + 1))
  action=none
  if [ "$behind" -gt 0 ]; then
    BEHIND_COUNT=$((BEHIND_COUNT + 1))
    action=$(ensure_sync_task "$slug" "$up" "$fork_branch" "$up_branch" \
      "$behind" "$ahead" "$status") || action="task NOT created"
  fi
  printf 'FORK_FRESHNESS: %s status=%s behind=%s ahead=%s upstream=%s compare=%s...%s action=%s\n' \
    "$slug" "$status" "$behind" "$ahead" "$up" "$fork_branch" "$up_branch" "$action"
}

# --- candidate discovery ----------------------------------------------------

sweep_owner() {
  local configured slug
  if configured=$(config_value fork-sweep-owner); then
    printf '%s\n' "$configured"
    return 0
  fi
  slug=$(origin_slug "$FM_ROOT")
  [ -n "$slug" ] || return 1
  printf '%s\n' "${slug%%/*}"
}

qualify() {
  local entry=$1 owner=$2
  case "$entry" in
    */*) printf '%s\n' "$entry" ;;
    *) printf '%s/%s\n' "$owner" "$entry" ;;
  esac
}

is_ignored() {
  local slug=$1 entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$slug" ] && return 0
    [ "$entry" = "${slug##*/}" ] && return 0
  done <<< "$IGNORE_LIST"
  return 1
}

# --- commands ---------------------------------------------------------------

DISPATCH=0
VERBOSE=0
IF_DUE=0
OWNER_ARG=""
IGNORE_LIST=""

due_check() {
  local interval retry now last attempt
  interval=${FM_FORK_SWEEP_INTERVAL_DAYS:-$(config_value fork-sweep-interval-days || echo 7)}
  case "$interval" in ''|*[!0-9]*) interval=7 ;; esac
  retry=${FM_FORK_SWEEP_RETRY_MINUTES:-60}
  case "$retry" in ''|*[!0-9]*) retry=60 ;; esac
  now=$(now_epoch)
  last=$(cat "$STATE/.fork-freshness-last" 2>/dev/null || echo 0)
  attempt=$(cat "$STATE/.fork-freshness-attempt" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac
  [ $((now - last)) -ge $((interval * 86400)) ] || return 1
  [ $((now - attempt)) -ge $((retry * 60)) ] || return 1
  return 0
}

cmd_sweep() {
  local owner rows row slug is_fork archived parent branch ignored=0 forks=0 repos=0

  if ! gh_available; then
    printf 'FORK_FRESHNESS_COVERAGE: status=unknown reason=%s\n' \
      'no gh on PATH, so no fork could be read'
    return 4
  fi
  if [ -n "$OWNER_ARG" ]; then
    owner=$OWNER_ARG
  elif ! owner=$(sweep_owner); then
    printf 'FORK_FRESHNESS_COVERAGE: status=unknown reason=%s\n' \
      'no sweep owner: this home has no forge origin and config/fork-sweep-owner is unset'
    return 4
  fi

  IGNORE_LIST=$(config_list fork-sweep-ignore)

  if ! rows=$(enumerate_owned "$owner"); then
    printf 'FORK_FRESHNESS_COVERAGE: status=unknown reason=%s\n' \
      "$(clean_reason "repositories of $owner could not be listed: $rows")"
    return 4
  fi

  # Candidates the enumeration cannot see: a clone whose origin belongs to
  # another account, and any maintained fork with no clone and no owned copy.
  local extra_rows="" extra
  {
    if [ -d "$PROJECTS" ]; then
      for dir in "$PROJECTS"/*/; do
        [ -d "$dir/.git" ] || continue
        origin_slug "${dir%/}"
      done
    fi
    config_list maintained-forks | while IFS= read -r extra; do
      [ -n "$extra" ] || continue
      qualify "$extra" "$owner"
    done
  } | sort -u > "$STATE/.fork-freshness-extra.$$" 2>/dev/null || true
  extra_rows=$(cat "$STATE/.fork-freshness-extra.$$" 2>/dev/null || true)
  rm -f "$STATE/.fork-freshness-extra.$$"

  # Every reading prints from THIS shell. Buffering the lines through a command
  # substitution would run read_fork in a subshell, and its swept/behind/unknown
  # increments would be discarded - a coverage line reading "swept=0 behind=0"
  # over two forks that are behind, and an exit code to match. A false count is
  # the same failure as a false reading.
  local seen="" facts
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    repos=$((repos + 1))
    slug=$(printf '%s' "$row" | cut -f1)
    is_fork=$(printf '%s' "$row" | cut -f2)
    archived=$(printf '%s' "$row" | cut -f3)
    parent=$(printf '%s' "$row" | cut -f4)
    branch=$(printf '%s' "$row" | cut -f5)
    seen="$seen$slug"$'\n'
    [ "$is_fork" = true ] || continue
    forks=$((forks + 1))
    if is_ignored "$slug"; then
      ignored=$((ignored + 1))
      printf 'FORK_FRESHNESS: %s status=ignored reason=listed in config/fork-sweep-ignore\n' "$slug"
      continue
    fi
    if [ "$archived" = true ]; then
      ignored=$((ignored + 1))
      printf 'FORK_FRESHNESS: %s status=ignored reason=archived fork\n' "$slug"
      continue
    fi
    read_fork "$slug" "$parent" "$branch"
  done <<< "$rows"

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    case "$seen" in *"$slug"$'\n'*) continue ;; esac
    seen="$seen$slug"$'\n'
    repos=$((repos + 1))
    if is_ignored "$slug"; then
      ignored=$((ignored + 1))
      printf 'FORK_FRESHNESS: %s status=ignored reason=listed in config/fork-sweep-ignore\n' "$slug"
      continue
    fi
    if ! facts=$(repo_facts "$slug"); then
      emit_unknown "$slug" "repository could not be read: $facts"
      continue
    fi
    [ "$(printf '%s' "$facts" | cut -f1)" = true ] || continue
    forks=$((forks + 1))
    read_fork "$slug" "$(printf '%s' "$facts" | cut -f2)" "$(printf '%s' "$facts" | cut -f3)"
  done <<< "$extra_rows"

  printf 'FORK_FRESHNESS_COVERAGE: owner=%s repos=%s forks=%s swept=%s behind=%s unknown=%s ignored=%s\n' \
    "$owner" "$repos" "$forks" "$SWEPT_COUNT" "$BEHIND_COUNT" "$UNKNOWN_COUNT" "$ignored"

  local code=0
  [ "$BEHIND_COUNT" -eq 0 ] || code=3
  if [ "$UNKNOWN_COUNT" -gt 0 ]; then
    [ "$code" -eq 3 ] && code=5 || code=4
  fi
  return "$code"
}

cmd_check() {
  local slug=$1 facts
  if ! gh_available; then
    emit_unknown "$slug" "no gh on PATH, so freshness could not be read"
    return 4
  fi
  if ! facts=$(repo_facts "$slug"); then
    emit_unknown "$slug" "repository could not be read: $facts"
    return 4
  fi
  # A determinate "not a fork" is silence: this runs on every PR, and a repo
  # with no upstream has no freshness to report.
  [ "$(printf '%s' "$facts" | cut -f1)" = true ] || return 0
  read_fork "$slug" "$(printf '%s' "$facts" | cut -f2)" "$(printf '%s' "$facts" | cut -f3)"
  local code=0
  [ "$BEHIND_COUNT" -eq 0 ] || code=3
  if [ "$UNKNOWN_COUNT" -gt 0 ]; then
    [ "$code" -eq 3 ] && code=5 || code=4
  fi
  return "$code"
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help) usage; exit 0 ;;
  sweep|check) shift ;;
  '') usage >&2; exit 2 ;;
  *) printf 'fm-fork-freshness: unknown command: %s\n' "$COMMAND" >&2; exit 2 ;;
esac

TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --if-due) IF_DUE=1 ;;
    --dispatch) DISPATCH=1 ;;
    --verbose) VERBOSE=1 ;;
    --owner) shift; OWNER_ARG=${1:-} ;;
    --owner=*) OWNER_ARG=${1#--owner=} ;;
    -*) printf 'fm-fork-freshness: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) TARGET=$1 ;;
  esac
  shift
done
: "$VERBOSE"

mkdir -p "$STATE"

if [ "$COMMAND" = check ]; then
  case "$TARGET" in
    */*) ;;
    *) printf 'fm-fork-freshness: check needs <owner/repo>\n' >&2; exit 2 ;;
  esac
  cmd_check "$TARGET"
  exit $?
fi

if [ "$IF_DUE" = 1 ] && ! due_check; then
  exit 0
fi

now_epoch > "$STATE/.fork-freshness-attempt"
set +e
cmd_sweep
CODE=$?
set -e
# The completion stamp means "coverage was fully determined", so an outage does
# not buy a week of silence: an incomplete sweep stays due, behind the retry
# floor. A sweep that found a fork behind is still complete - the task it
# created is the thing that carries that forward.
case "$CODE" in
  0|3) now_epoch > "$STATE/.fork-freshness-last" ;;
esac
exit "$CODE"
