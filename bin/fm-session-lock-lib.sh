#!/usr/bin/env bash
# Shared session-lock identity.
#
# ONE owner of the "does this home's session lock belong to the session asking?"
# decision. bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.
#
# THE IDENTITY BASIS IS A SESSION ID, NOT A PROCESS ID, and that is structural
# rather than a preference. A Claude Code primary is two layers: the interactive
# CLI is one process, and the harness that runs hooks and tool calls can be a
# different process on unrelated ancestry behind a detached pty host. The
# ancestry chain between them is broken BY CONSTRUCTION, so a lock recording
# either process cannot be recognized from the other however carefully the
# processes are inspected. Measured in this fleet: the lock held pid 3638271,
# the captain's own live CLI, while the same session's harness ran as pid 849887
# under a bg-pty-host - one session, two layers, no zombie and nothing to kill.
# The session id is the identifier both layers carry, so it is the one that can
# answer the question. docs/verification/session-identity.md holds the probe.
#
# THE REFUSAL BIAS IS UNCHANGED AND MUST STAY UNCHANGED. A session that does not
# own the lock is still refused; only the BASIS for deciding ownership moved. An
# unresolvable session id, an absent lock, and a malformed lock are all refusals,
# never permission. The process helpers below survive because they still answer
# their own narrower questions - is this pid a live harness, which pid should the
# lock record - and because a lock that records no session id at all (written
# before this contract, or by a harness whose session id was not observable) is
# still judged by the ancestry test rather than being handed a free pass.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  # Parameter expansion rather than a basename fork, and not for tidiness: this
  # predicate is a universal refusal inside bin/fm-safe-kill.sh, evaluated after
  # the decision to stop a process but before the signal is delivered. Every
  # subprocess spawned on that path is time the target keeps running, and the
  # window is observable - tests/fm-pr-check-security.test.sh catches a legacy
  # check executing inside it. ${comm##*/} is exactly basename for the paths ps
  # reports here, so the matching semantics above are unchanged.
  base=${comm##*/}
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True when pid $1 is a verified harness AND that harness is Claude Code.
#
# This exists to decide the PROVENANCE of CLAUDE_CODE_SESSION_ID, never
# ownership. Claude Code injects that variable into every child it spawns, and
# firstmate launches other harnesses from inside a Claude tool call, so a Kimi or
# Codex primary can inherit the launching CLAUDE session's id and record it as
# its own. That record would be wrong, and a wrong-but-currently-unread record is
# how a defect waits for a consumer. Gate the variable on the acquiring harness
# actually being Claude, and an unresolvable answer simply records no session,
# which lands on the unchanged legacy basis rather than on a guess.
# PROVENANCE-STRICT classification, this consumer only (round 3, review-1).
#
# The shared matcher's *claude* SUBSTRING is deliberately loose so the ancestry
# walk can span version-named Claude binaries; provenance cannot ride that
# looseness, because a foreign harness script living under a claude-named
# directory (node /opt/claude-tools/codex.js) would satisfy the substring and
# record the launching session's id as its own. Provenance therefore requires
# an EXACT claude basename or an EXACT claude path component on the pid itself.
# This is a pure predicate over the ps-reported strings so its behavior is
# testable without a live process, and it is called ONLY from
# fm_harness_pid_is_claude - the ancestry walk and every other consumer of the
# shared matcher are untouched, which is what keeps this strictly narrower.
fm_harness_claude_provenance_strict() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  base=${comm##*/}
  case "$base" in
    claude|claude[-.0-9]*) return 0 ;;
  esac
  if name=$(fm_harness_path_name "$comm"); then
    [ "$name" = claude ] && return 0
  fi
  argv0=${args%% *}
  base=${argv0##*/}
  case "$base" in
    claude|claude[-.0-9]*) return 0 ;;
  esac
  if name=$(fm_harness_path_name "$argv0"); then
    [ "$name" = claude ] && return 0
  fi
  # Bare-interpreter admit, component-exact (attestation r2): the shared
  # matcher's rule 3 models a node/python-hosted Claude as a real, supported
  # shape, so provenance must be able to admit the one TRUSTED package
  # identity - the exact path components /@anthropic-ai/claude-code/ in the
  # interpreter's script argument. This encodes where the trusted code LIVES
  # (npm-registry-fixed), not a guess about how the process names itself;
  # substring shapes (/opt/claude-tools/, @anthropic-ai/claude-code-fake/)
  # still refuse on component exactness.
  case "$comm" in
    *node*|*python*)
      case "$args" in
        *"/@anthropic-ai/claude-code/"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

fm_harness_pid_is_claude() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
  fm_harness_claude_provenance_strict "$comm" "$args"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- session identity ---------------------------------------------------------

# True when $1 has the shape of a session id. Deliberately narrow: a session id
# is an opaque token, so anything carrying whitespace, a newline, or a shell
# metacharacter is rejected rather than normalized. That keeps a malformed or
# forged lock line from being read as a match, and it makes "unreadable" and
# "does not match" the same refusing answer.
fm_session_id_valid() {  # <id>
  case "$1" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print THIS session's id, or return 1 when it cannot be established.
#
# Precedence, and both sources name the same session on either side of the
# CLI/harness split:
#   1. FM_SESSION_ID   - set explicitly by a caller that already read the value
#                        from an authoritative payload (the Claude Stop hook
#                        passes its payload's .session_id this way), and by
#                        tests.
#   2. CLAUDE_CODE_SESSION_ID - injected by Claude Code into every tool-call and
#                        hook child. It is NOT present on the harness process's
#                        own environment, which is why this is read from the
#                        caller's environment rather than from /proc.
#
# Returning 1 is a refusal, not a fallback: a caller that cannot establish who it
# is must not be treated as the owner of anything.
fm_session_id_self() {
  local id=${FM_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}
  fm_session_id_valid "$id" || return 1
  printf '%s\n' "$id"
}

# --- the lock record ----------------------------------------------------------
#
# state/.lock is line-addressed and line 1 NEVER changes meaning:
#   line 1  the harness process id                  (required)
#   line 2  session=<session-id>                    (optional)
#
# Line 1 stays the pid because other readers depend on exactly that line and
# depend on it for REFUSALS: bin/fm-safe-kill.sh refuses to signal the pid on
# line 1, and bin/fm-sessionstart-nudge.sh, bin/fm-trace-context-lib.sh, and
# bin/fm-session-start.sh's Pi extension check all read line 1 alone. Moving or
# reformatting it would quietly turn those refusals into permission, which is the
# one direction this contract may never move.

# Print the harness pid recorded in state dir $1's lock, or return 1.
fm_session_lock_pid() {  # <state-dir>
  local pid
  { IFS= read -r pid < "$1/.lock"; } 2>/dev/null || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Print the session id recorded in state dir $1's lock, or return 1 when the lock
# records none. An absent session line is a real, distinguishable state - a lock
# written before this contract, or by a harness whose session id was not
# observable - and it is reported as such rather than as an empty match.
fm_session_lock_session() {  # <state-dir>
  local id
  id=$(sed -n '2s/^session=//p' "$1/.lock" 2>/dev/null) || return 1
  fm_session_id_valid "$id" || return 1
  printf '%s\n' "$id"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process. Membership is the honest test of that question, because
# the lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session.
#
# This is now the LEGACY basis, reached only for a lock that records no session
# id. It is kept rather than dropped because dropping it would refuse every
# session whose lock predates this contract, and a guard that refuses a
# legitimate session is disabled by the next person under time pressure.
fm_session_lock_ancestry_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(fm_session_lock_pid "$state") || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when the caller runs inside the session that owns state dir $1's lock.
#
# When the lock records a session id, that id alone decides: this session owns
# the lock exactly when the two ids match, whatever process is asking. That is
# what survives the CLI/harness split. When the lock records no session id, the
# legacy ancestry test above answers instead, unchanged.
#
# Every uncertainty refuses: a missing lock, a malformed lock, a lock whose
# session line cannot be read, a caller whose own session id cannot be
# established, and a lock naming a different session.
fm_session_lock_owned_by_self() {  # <state-dir>
  local state=$1 lock_session self_session
  fm_session_lock_pid "$state" >/dev/null || return 1
  if lock_session=$(fm_session_lock_session "$state"); then
    self_session=$(fm_session_id_self) || return 1
    [ "$self_session" = "$lock_session" ]
    return
  fi
  fm_session_lock_ancestry_owned_by_self "$state"
}
