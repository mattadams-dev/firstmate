#!/usr/bin/env bash
# Runs one suite and reports the worker supervisors it leaves alive, by pid-set
# difference. A pid counts only when its full argv is a bash interpreter running
# a fm-remote-job-worker.sh script, so greps and linters that merely mention the
# path are never counted.
set -u
suite=$1; label=$2
snapshot() {
  local p args
  for p in $(pgrep -f 'fm-remote-job-worker\.sh' 2>/dev/null); do
    args=$(ps -o args= -p "$p" 2>/dev/null || true)
    case "$args" in
      *bash\ */fm-remote-job-worker.sh|*bash\ */fm-remote-job-worker.sh\ *) printf '%s\n' "$p" ;;
    esac
  done
}
before=$(snapshot | sort | tr '\n' ' ')
out=$(bash "$suite" 2>&1); rc=$?
sleep 2
after=$(snapshot | sort | tr '\n' ' ')
leaked=; n=0
for p in $after; do
  case " $before " in *" $p "*) ;; *) leaked="${leaked:+$leaked }$p"; n=$((n+1)) ;; esac
done
printf '%s\n' "$out" > "$EVDIR/${label// /_}.log"
passed=no
printf '%s\n' "$out" | grep -qE '^ALL TESTS PASSED$' && passed=yes
firstbad=$(printf '%s\n' "$out" | grep -m1 -E '^not ok|^rm: cannot remove|Directory not empty' || echo '-')
printf '%-40s exit=%-3s ALL_TESTS_PASSED=%-3s leaked_supervisors=%-2s first_problem=%s\n' \
  "$label" "$rc" "$passed" "$n" "$firstbad"
for p in $leaked; do
  args=$(ps -o args= -p "$p" 2>/dev/null || true)
  root=$(printf '%s' "$args" | sed 's#.*\(/tmp/[^/]*\)/.*#\1#')
  printf '    leaked pid %-8s %s\n' "$p" "$args"
  printf '    its temp root %-42s exists=%s\n' "$root" "$([ -d "$root" ] && echo yes || echo NO-already-deleted-by-the-suite)"
  kill -KILL "$p" 2>/dev/null || true
done
