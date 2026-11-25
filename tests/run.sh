#!/usr/bin/env bash
# shellcheck disable=SC2016  # check() conditions are evaluated later: they go in single quotes
# Test bench for agent-job-semaphore with real processes. Every scenario runs in a subshell with its own lock
# directory, XDG dirs and fake /proc/loadavg, /proc/meminfo and PSI files; fast timings come from AJS_*.
#   tests/run.sh [path/to/agent-job-semaphore]   prints "ok <test>", "FAIL <test> - <condition>", "skip <test>"
#                                                and ends with "Tests: N passed, M failed"
#   ONLY=<regex> runs only the scenarios whose function name matches.
# SPDX-License-Identifier: Apache-2.0
set -u
here=$(cd "$(dirname "$0")" && pwd)
AJS=${1:-$here/../agent-job-semaphore}
AJS=$(cd "$(dirname "$AJS")" && pwd)/$(basename "$AJS")
[ -x "$AJS" ] || { echo "INVALID: $AJS is not executable"; exit 2; }

# The caller's real default dirs, measured before the bench overrides them: no scenario may write there.
REAL_RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-job-semaphore
REAL_STATE=${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/agent-job-semaphore
TMP=$(mktemp -d "${BENCH_TMP:-${TMPDIR:-/tmp}}/ajs-bench.XXXXXX") || exit 1
BENCH_START_NS=$(date +%s%N)
sampler_pid=0
cleanup() {
  [ "$sampler_pid" -gt 0 ] && { kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null; }
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT
while IFS='=' read -r v _; do case $v in AJS_*) unset "$v" ;; esac; done < <(env)
export HOME=$TMP/home XDG_RUNTIME_DIR=$TMP/xdg-runtime XDG_STATE_HOME=$TMP/xdg-state
export AJS_BEAT=1 AJS_STALE=5 AJS_POLL=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"
: > "$TMP/results"; : > "$TMP/names"
( while :; do
    ls -A "$REAL_RUNTIME/queue" "$REAL_RUNTIME" 2>/dev/null
    find "$REAL_STATE" -newermt "@${BENCH_START_NS%?????????}" -type f -printf 'state:%P\n' 2>/dev/null
    sleep 0.2
  done ) > "$TMP/real.samples" & sampler_pid=$!

ok() { echo "ok $1" >> "$TMP/results"; echo "ok $1"; }
ko() { echo "FAIL $1" >> "$TMP/results"; echo "FAIL $1 - $2"; }
skip() { echo "skip $1 - $2"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }   # check <name> <bash condition>

fresh() {  # a new lock dir and default inputs: load 0.50, 16 GiB available, 8 GiB swap free, PSI 0
  R=$(mktemp -d "$TMP/r.XXXXXX"); D=$R/lock; Q=$D/queue; LOG=$D/events.log; W1=$D/win.1; W2=$D/win.2
  mkdir -p "$R/repo" "$R/out"
  export AJS_DIR=$D AJS_LOADAVG_FILE=$R/loadavg AJS_MEMINFO_FILE=$R/meminfo AJS_PSI_FILE=$R/pressure
  load_set 0.50; mem_set 16777216 8388608 8388608; psi_set 0.00
}
note_name() { echo "$1" >> "$TMP/names"; }
sw() {  # sw [options] -- <cmd...>: one run with a huge CPU budget, raw output in $R/out
  local a; for a; do note_name "$a"; done
  "${AJS_OVERRIDE:-$AJS}" -C "$R/repo" --load-max 1000 --out "$R/out" --timeout 30 "$@"
}
swt() {  # swt <s> [options] -- <cmd...>: no --timeout; an outer timeout of <s> s cuts it (rc 124)
  local s=$1 a; shift; for a; do note_name "$a"; done
  timeout "$s" "${AJS_OVERRIDE:-$AJS}" -C "$R/repo" --load-max 1000 --out "$R/out" "$@"
}
kids=()
bg() {  # bg <tag> <name> [options] -- <cmd...>: a run in the background; its rc lands in $R/<tag>.rc
  local tag=$1 name=$2; shift 2
  { sw -n "$name" "$@" > "$R/$tag.out" 2> "$R/$tag.err"; echo $? > "$R/$tag.rc"; } &
  kids+=($!)
}
kill_kids() { local p; for p in "${kids[@]}"; do pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done; }
until_() { local n=$(($1 * 10)); while [ $n -gt 0 ]; do eval "$2" && return 0; sleep 0.1; n=$((n - 1)); done; return 1; }
rc_of() { until_ "${2:-30}" "[ -s '$R/$1.rc' ]"; cat "$R/$1.rc" 2>/dev/null || echo none; }
rcs() { local n; for n; do cat "$R/$n.rc" 2>/dev/null || echo x; done | tr -d '\n'; }
tickets() { ls "$Q" 2>/dev/null | wc -l; }
queued() { until_ 5 "ls '$Q' 2>/dev/null | grep -q -- '-$1\$'"; }
pid_of() { ls "$Q" | sed -n "s/^[0-9]*-\([0-9]*\)-$1\$/\1/p"; }   # the script's pid is in its ticket name
raw_of() { sed -n 's/.*(output: \(.*\))$/\1/p' "$1"; }
wins() { ls -d "$D"/win.* 2>/dev/null | wc -l; }
noev() { [ -z "$(grep -v ' peak class=' "$LOG" 2>/dev/null)" ]; }   # no event in the log but the peaks of finished runs
shim() {  # shim <dir> <cmd...>: wrappers that log each call to <dir>/count and run the real command
  local d=$1 c; shift; mkdir -p "$d"
  for c in "$@"; do printf '#!/bin/bash\necho %s >> %q\nexec %q "$@"\n' "$c" "$d/count" "$(command -v "$c")" > "$d/$c"; chmod +x "$d/$c"; done
}
fake_win() {  # fake_win <k> <bytes>: window <k> held by a live owner that is not a test process, with its live ticket
  local k=$1; mkdir -p "$Q" "$D/win.$k"
  echo "f$k pid=1 since=x ticket=1000-$k-f$k" > "$D/win.$k/owner"; echo "class=fake bytes=$2 source=log cpu=1" > "$D/win.$k/weight"
  : > "$Q/1000-$k-f$k"; touch -d '+10 min' "$D/win.$k/owner" "$Q/1000-$k-f$k"
}
fake_ticket() {  # fake_ticket <seconds old> <name> <bytes> [cpu]: a live ticket that arrived that long ago
  mkdir -p "$Q"; local f; f="$(($(date +%s) - $1))000000000-1-$2"
  printf 'class=fake bytes=%s cpu=%s' "$3" "${4:-1}" > "$Q/$f"; touch -d '+10 min' "$Q/$f"
}
peakline() {  # peakline <class> <bytes> [cpu hundredths] [date]: a finished run's peak in the log
  mkdir -p "$D"; printf '%s agent-job-semaphore: x peak class=%s bytes=%s rc=0 s=5 cpu=%s\n' "${4:-$(date '+%F %T')}" "$1" "$2" "${3:-100}" >> "$LOG"
}
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }
SUMMARY='^ajs repo rc=0 [0-9:]{8}->[0-9:]{8} load1 [0-9.]+->[0-9.]+ Tests: 3 passed, 3 total( uncontained)? \(output: .*\)$'
# Window scenarios' command: "+ <name> <ns>" on entry and "- <name> <ns>" on exit, in $R/ev.
EV='echo "+ $1 $(date +%s%N)" >> "$0"; sleep "$2"; echo "- $1 $(date +%s%N)" >> "$0"'
started() { grep -q "^+ $1 " "$R/ev" 2>/dev/null; }
ended() { grep -q "^- $1 " "$R/ev" 2>/dev/null; }
ev_at() { awk -v k="$1" -v n="$2" '$1 == k && $2 == n {print $3}' "$R/ev"; }
overlap() { [ "$(ev_at + "$2")" -lt "$(ev_at - "$1")" ] && [ "$(ev_at + "$1")" -lt "$(ev_at - "$2")" ]; }
first_end() { local x y; x=$(ev_at - "$1"); y=$(ev_at - "$2"); echo $((x < y ? x : y)); }
max_conc() { sort -k3,3n "$R/ev" | awk '{c += ($1 == "+") ? 1 : -1; if (c > m) m = c} END {print m + 0}'; }
mem_set() {  # mem_set <MemAvailable kB> <SwapTotal kB> <SwapFree kB>
  printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$@" > "$R/meminfo.new"; mv -f "$R/meminfo.new" "$R/meminfo"
}
psi_set() { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$1" > "$R/pressure.new"; mv -f "$R/pressure.new" "$R/pressure"; }
load_set() { printf '%s %s %s 1/100 1\n' "$1" "$1" "$1" > "$R/loadavg.new"; mv -f "$R/loadavg.new" "$R/loadavg"; }
not_root() { [ "$(id -u)" != 0 ]; }
GIB=1073741824

t_summary_line() {
  fresh; out=$(sw -n a -- sh -c 'echo "Tests: 3 passed, 3 total"'); rc=$?
  check summary-line-and-clean-queue '[ $rc = 0 ] && [[ $out =~ $SUMMARY ]] && [ "$(wc -l <<<"$out")" = 1 ] && [ -z "$(ls -A "$Q")" ] && [ "$(wins)" = 0 ] && noev'
  sw -n a --append-to "$R/journal" -- sh -c 'exit 7' > "$R/b.out"; rc=$?
  check command-rc-and-append-to '[ $rc = 7 ] && grep -q " rc=7 .* no test summary" "$R/b.out" && grep -Eq "^[0-9-]{10} [0-9:]{8} a: ajs repo rc=7 " "$R/journal"'
  sw -n a -- sh -c 'echo "Tests: 1 failed, 3 total"; echo "   Tests:  2 passed, 3 total"; echo trailing' > "$R/c.out"
  check summary-is-the-last-matching-line-trimmed 'grep -Eq "load1 [0-9.]+->[0-9.]+ Tests:  2 passed, 3 total( uncontained)? \(output: " "$R/c.out"'
  AJS_SUMMARY_REGEX='^=+ [0-9]+ passed' sw -n a -- sh -c 'echo "===== 5 passed in 0.12s ====="' > "$R/p.out"
  check summary-regex-is-configurable 'grep -q " ===== 5 passed in 0.12s =====\( uncontained\)\? (output: " "$R/p.out"'
}

t_default_output_dir() {  # under XDG_STATE_HOME, else HOME/.local/state; --out and AJS_OUT win; no home: TMPDIR
  fresh
  out=$(XDG_STATE_HOME=$R/state "$AJS" -C "$R/repo" -n lane-x --load-max 1000 -- sh -c 'echo "Tests: 1 passed, 1 total"' 2> "$R/d.err"); rc=$?
  raw=$(find "$R/state/agent-job-semaphore/lane-x" -maxdepth 1 -type f -name 'ajs-repo-*.log' 2>/dev/null)
  check default-output-under-xdg-state-home '[ $rc = 0 ] && [ -n "$raw" ] && grep -q "^Tests: 1 passed" "$raw" && [[ $out == *"(output: $raw)" ]]'
  env -u XDG_STATE_HOME HOME="$R/home" "$AJS" -C "$R/repo" -n lane-h --load-max 1000 -- true > /dev/null 2>&1; rc=$?
  check default-output-under-home-local-state '[ $rc = 0 ] && [ -n "$(find "$R/home/.local/state/agent-job-semaphore/lane-h" -name "ajs-repo-*.log" 2>/dev/null)" ]'
  XDG_STATE_HOME=$R/state2 "$AJS" -C "$R/repo" -n lane-y --load-max 1000 --out "$R/other" -- true > /dev/null 2>&1; rc=$?
  check explicit-out-is-used '[ $rc = 0 ] && [ -n "$(find "$R/other" -name "ajs-repo-*.log")" ] && [ ! -e "$R/state2" ]'
  XDG_STATE_HOME=$R/state3 AJS_OUT=$R/envout "$AJS" -C "$R/repo" -n lane-e --load-max 1000 -- true > /dev/null 2>&1; rc=$?
  check ajs-out-is-used '[ $rc = 0 ] && [ -n "$(find "$R/envout" -name "ajs-repo-*.log")" ] && [ ! -e "$R/state3" ]'
  mkdir -p "$R/tmp"
  env -u XDG_STATE_HOME -u HOME TMPDIR="$R/tmp" "$AJS" -C "$R/repo" -n lane-z --load-max 1000 -- true > /dev/null 2> "$R/z.err"; rc=$?
  check without-home-warns-and-uses-tmpdir '[ $rc = 0 ] && grep -q "neither XDG_STATE_HOME nor HOME" "$R/z.err" && [ -n "$(find "$R/tmp" -name "ajs-repo-*.log")" ]'
}

t_bad_names_are_refused() {  # a name becomes a file name: anything outside the pattern is refused before writing
  fresh; local n i=0
  for n in ../escape a/b -lead '' 'sp ace'; do
    i=$((i + 1)); sw -n "$n" -- touch "$R/ran-$i" > /dev/null 2> "$R/n$i.err"; rc=$?
    check "bad-name-$i-refused-rc2" "[ \$rc = 2 ] && [ ! -e '$R/ran-$i' ] && grep -qF 'is not [A-Za-z0-9]' '$R/n$i.err' && [ ! -e '$D' ]"
  done
}

t_default_lock_dir() {  # XDG_RUNTIME_DIR, else /run/user/<uid> (measured in a private mount namespace)
  fresh; unset AJS_DIR
  XDG_RUNTIME_DIR=$R/xdg sw -n a -- true > /dev/null 2>&1; rc=$?
  check default-lock-dir-under-xdg-runtime-dir '[ $rc = 0 ] && [ -d "$R/xdg/agent-job-semaphore/queue" ] && [ "$(stat -c %a "$R/xdg/agent-job-semaphore")" = 700 ]'
  AJS_DIR=$R/explicit XDG_RUNTIME_DIR=$R/xdg2 sw -n a -- true > /dev/null 2>&1; rc=$?
  check ajs-dir-wins-over-xdg-runtime-dir '[ $rc = 0 ] && [ -d "$R/explicit/queue" ] && [ ! -e "$R/xdg2" ]'
  if unshare -Urm true 2> /dev/null; then
    unshare -Urm bash -c 'mount -t tmpfs tmpfs /run/user && mkdir /run/user/0 &&
      env -u XDG_RUNTIME_DIR -u AJS_DIR "$0" -C "$1" -n a --load-max 1000 --out "$2" -- true > /dev/null 2>&1 &&
      [ -d /run/user/0/agent-job-semaphore/queue ] && [ -z "$(ls -A /run/user/0/agent-job-semaphore/queue)" ]' "$AJS" "$R/repo" "$R/out"
    rc=$?
    check default-lock-dir-under-run-user-uid '[ $rc = 0 ]'
  else
    skip default-lock-dir-under-run-user-uid 'unshare -Urm is not available here'
  fi
}

t_unusable_lock_dir_is_refused() {  # rc 78 and the command never runs
  fresh; : > "$R/afile"
  AJS_DIR=$R/afile swt 10 -n a -- touch "$R/ran1" > /dev/null 2> "$R/e1"; rc=$?
  check lock-dir-that-is-a-file-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran1" ] && grep -q "is not a directory" "$R/e1"'
  mkdir -p "$D"; : > "$Q"
  swt 10 -n a -- touch "$R/ran3" > /dev/null 2> "$R/e3"; rc=$?
  check queue-that-is-a-file-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran3" ] && grep -q "queue is not a directory" "$R/e3"'
  rm -f "$Q"; : > "$W1"
  swt 10 -n a -- touch "$R/ran5" > /dev/null 2> "$R/e5"; rc=$?
  check window-that-is-a-file-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran5" ] && grep -q "win.1 is not a directory" "$R/e5"'
  rm -f "$W1"
  if not_root; then
    mkdir -p "$R/ro"; chmod 500 "$R/ro"
    AJS_DIR=$R/ro swt 10 -n a -- touch "$R/ran2" > /dev/null 2> "$R/e2"; rc=$?
    check read-only-lock-dir-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran2" ] && grep -q "cannot write in it" "$R/e2" && [ -z "$(ls -A "$R/ro")" ]'
    chmod 700 "$R/ro"; chmod 500 "$Q"
    swt 10 -n a -- touch "$R/ran4" > /dev/null 2> "$R/e4"; rc=$?
    check read-only-queue-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran4" ] && grep -q "cannot write in the queue" "$R/e4" && [ -z "$(ls -A "$Q")" ]'
    chmod 700 "$Q"
  else
    skip read-only-lock-dir-rc78 'root ignores permissions'; skip read-only-queue-rc78 'root ignores permissions'
  fi
}

t_window_turned_file_at_take_time() {  # the window path becomes a file between the check and the mkdir
  fresh; mkdir -p "$R/mkdir-shim"
  printf '#!/bin/bash\nfor a in "$@"; do\n  if [ "$a" = %q ]; then : > %q; exit 1; fi\ndone\nexec %q "$@"\n' "$W1" "$W1" "$(command -v mkdir)" > "$R/mkdir-shim/mkdir"
  chmod +x "$R/mkdir-shim/mkdir"
  PATH="$R/mkdir-shim:$PATH" swt 8 -n a --timeout 3 -- touch "$R/ran" > /dev/null 2> "$R/e"; rc=$?
  check window-turned-file-at-take-time-rc78-without-running '[ $rc = 78 ] && [ ! -e "$R/ran" ] && grep -q "win.1 is not a directory" "$R/e"'
}

t_settings_out_of_range_are_refused() {  # every AJS_* value is checked before anything is written
  fresh; local spec i=0
  for spec in AJS_BEAT=0 AJS_STALE=2 AJS_POLL=0 AJS_POLL=4 AJS_NOTICE_AFTER=0 AJS_HOLD_AFTER=0 AJS_RESERVE_GIB=0 AJS_RESERVE_GIB=65 \
    AJS_MEM_MIN_MIB=-1 AJS_MEM_ROOMY_MIB=x AJS_SWAP_RESERVE_MIB=1.5 AJS_PSI_MAX=1.5 AJS_TASKS_MAX=5 AJS_KILL_MEM_MIB=1 \
    AJS_JEST_WORKERS=x AJS_LOAD_MAX=0 AJS_LOAD_MAX=abc; do
    i=$((i + 1)); timeout 20 env "$spec" "$AJS" -C "$R/repo" --out "$R/out" -- touch "$R/ran-$i" > /dev/null 2> "$R/s$i.err"; rc=$?
    check "setting-$spec-refused-rc78" "[ \$rc = 78 ] && [ ! -e '$R/ran-$i' ] && grep -qF '${spec%%=*}' '$R/s$i.err' && [ ! -e '$D' ]"
  done
  timeout 20 env AJS_BEAT=5 AJS_STALE=9 "$AJS" -C "$R/repo" --out "$R/out" -- touch "$R/ran-stale" > /dev/null 2> "$R/stale.err"; rc=$?
  check stale-must-exceed-twice-beat '[ $rc = 78 ] && [ ! -e "$R/ran-stale" ] && grep -qF "must be more than twice AJS_BEAT" "$R/stale.err"'
  for spec in AJS_RESERVE_GIB=1 AJS_RESERVE_GIB=64 AJS_LOAD_MAX=2.5 AJS_TASKS_MAX=100 AJS_JEST_WORKERS=0; do
    timeout 20 env "$spec" "$AJS" -C "$R/repo" --out "$R/out" -- true > /dev/null 2>&1; rc=$?
    check "setting-$spec-accepted" '[ $rc = 0 ]'
  done
}

t_usage_errors() {
  fresh; local i=0 args
  for args in '--timeout x' '--load-max 0' '--dir /nonexistent-ajs-dir' '--bogus' '-n' '--mem 0' '--mem 65' '--mem 1.55' '--cpu 0' '--cpu 65' \
    '--class UPPER' '--class 1abc' '--max-runtime 0' '--max-runtime 1000000'; do
    i=$((i + 1))
    # shellcheck disable=SC2086
    timeout 20 "$AJS" $args -- touch "$R/ran-$i" > /dev/null 2> "$R/u$i.err"; rc=$?
    check "usage-error-$i-${args%% *}-rc2" "[ \$rc = 2 ] && [ ! -e '$R/ran-$i' ] && [ ! -e '$D' ]"
  done
  "$AJS" -C "$R/repo" > /dev/null 2>&1; rc=$?
  check usage-without-command-rc2 '[ $rc = 2 ] && [ ! -e "$D" ]'
  "$AJS" --fits default -- true > /dev/null 2>&1; rc=$?
  check fits-with-a-command-rc2 '[ $rc = 2 ] && [ ! -e "$D" ]'
  "$AJS" --fits > /dev/null 2>&1; rc=$?
  check fits-without-a-class-rc2 '[ $rc = 2 ]'
  "$AJS" --help > "$R/help"; rc=$?
  check help-names-every-exit-code '[ $rc = 0 ] && grep -q "^  73 " "$R/help" && grep -q "^  75 " "$R/help" && grep -q "^  78 " "$R/help" && grep -q "^  124 " "$R/help" && grep -q "^  130/143 " "$R/help"'
  check version-is-printed '[ "$("$AJS" --version)" = "agent-job-semaphore 0.2.0" ]'
}

t_command_keeps_caller_environment() {  # the bench's LC_ALL=C for sorting never reaches the command
  fresh; local caller_path="$R/path-shim:$PATH"
  PATH="$caller_path" AJS_BENCH_PROBE=caller-value LC_ALL=POSIX sw -n env -- /usr/bin/env > "$R/e.out" 2> /dev/null; rc=$?
  raw=$(raw_of "$R/e.out")
  check command-gets-caller-path-variable-and-lc-all '[ $rc = 0 ] && grep -Fxq "PATH=$caller_path" "$raw" && grep -Fxq "AJS_BENCH_PROBE=caller-value" "$raw" && grep -Fxq "LC_ALL=POSIX" "$raw"'
  env -u LC_ALL "$AJS" -C "$R/repo" -n env2 --load-max 1000 --out "$R/out" -- /usr/bin/env > "$R/f.out" 2> /dev/null; rc=$?
  raw=$(raw_of "$R/f.out")
  check command-without-lc-all-gets-none '[ $rc = 0 ] && [ -n "$raw" ] && ! grep -q "^LC_ALL=" "$raw"'
  sw -n cwd -- pwd > "$R/g.out"; raw=$(raw_of "$R/g.out")
  check command-runs-in-dir '[ "$(cat "$raw")" = "$R/repo" ]'
}

t_duplicate_name() {
  fresh; bg x x -- sleep 3; until_ 5 '[ -d "$W1" ]'; tk=$(ls "$Q")
  t0=$(date +%s%N); sw -n x -- touch "$R/second-ran" > /dev/null 2> "$R/dup.err"; rc=$?; ms=$((($(date +%s%N) - t0) / 1000000))
  check one-ticket-per-name-second-exits-73-at-once '[ $rc = 73 ] && [ $ms -lt 2000 ] && [ ! -e "$R/second-ran" ] && [ "$(ls "$Q")" = "$tk" ] && grep -qF "$tk" "$R/dup.err"'
  check one-ticket-per-name-leaves-the-first-alone '[ "$(rc_of x)" = 0 ] && [ -z "$(ls -A "$Q")" ]'
}

t_duplicate_name_race() {  # five processes with one name start together after a barrier
  fresh; bg z z -- sleep 2; until_ 5 '[ -d "$W1" ]'
  for i in 1 2 3 4 5; do
    { until [ -e "$R/go" ]; do sleep 0.01; done; sw -n y -- sh -c 'echo y >> "$0"' "$R/runs" > /dev/null 2>&1; echo $? > "$R/y$i.rc"; } &
    kids+=($!)
  done
  sleep 0.3; touch "$R/go"
  for i in 1 2 3 4 5; do rc_of "y$i" 15 > /dev/null; done
  rcs=$(cat "$R"/y?.rc | sort | tr '\n' ' ')
  check one-ticket-per-name-race-lets-one-through '[ "$rcs" = "0 73 73 73 73 " ] && [ "$(wc -l < "$R/runs")" = 1 ]'
}

# ---- the weight of a window: what the runs of its class measured --------------------------------------------------------

t_class_weighs_its_peaks() {  # --fits reads the log and touches nothing
  fresh; local o
  o=$("$AJS" --fits pgx --load-max 1000)
  check no-measure-weighs-the-reserve '[ "$(field "$o" estimate)" = $((3 * GIB)) ] && [ "$(field "$o" source)" = default ] && [ "$(field "$o" cpu)" = 1 ] && [ ! -e "$D" ]'
  o=$(AJS_RESERVE_GIB=5 "$AJS" --fits pgx --load-max 1000)
  check reserve-is-configurable '[ "$(field "$o" estimate)" = $((5 * GIB)) ]'
  peakline pgx $((4 * GIB)) 250
  o=$("$AJS" --fits pgx --load-max 1000)
  check measured-peak-and-cpu-weigh-the-class '[ "$(field "$o" estimate)" = $((4 * GIB)) ] && [ "$(field "$o" source)" = log ] && [ "$(field "$o" cpu)" = 3 ]'
  o=$("$AJS" --fits other --load-max 1000)
  check another-class-is-not-affected '[ "$(field "$o" source)" = default ]'
  fresh; peakline many $((9 * GIB)); local i; for i in $(seq 19); do peakline many $((2 * GIB)); done; peakline many $((6 * GIB))
  o=$("$AJS" --fits many --load-max 1000)
  check class-weighs-the-largest-of-its-last-20 '[ "$(field "$o" estimate)" = $((6 * GIB)) ]'
  fresh; peakline small 100000000
  o=$("$AJS" --fits small --load-max 1000)
  check weight-has-a-floor-of-one-gib '[ "$(field "$o" estimate)" = $GIB ] && [ "$(field "$o" source)" = log ]'
  fresh; peakline old $((9 * GIB)) 100 "$(date -d '-8 days' '+%F %T')"; peakline future $((9 * GIB)) 100 "$(date -d '+2 hours' '+%F %T')"
  o=$("$AJS" --fits old --load-max 1000); p=$("$AJS" --fits future --load-max 1000)
  check peaks-older-than-7-days-or-in-the-future-do-not-count '[ "$(field "$o" source)" = default ] && [ "$(field "$p" source)" = default ]'
  fresh; for i in $(seq 9); do peakline default $GIB; peakline big $GIB; done; peakline default $((10 * GIB)); peakline big $((10 * GIB))
  o=$("$AJS" --fits default --load-max 1000); p=$("$AJS" --fits big --load-max 1000)
  check default-class-weighs-the-p90-not-the-largest '[ "$(field "$o" estimate)" = $GIB ] && [ "$(field "$p" estimate)" = $((10 * GIB)) ]'
  o=$("$AJS" --fits pgx --mem 2.5 --cpu 4 --load-max 1000)
  check declared-estimate-wins '[ "$(field "$o" estimate)" = 2684354560 ] && [ "$(field "$o" source)" = declared ] && [ "$(field "$o" cpu)" = 4 ]'
  fresh; o=$("$AJS" --fits jest --load-max 1000)
  check jest-class-has-3-cores-by-default '[ "$(field "$o" cpu)" = 3 ]'
}

t_peak_is_registered() {  # a finished run leaves its peak, with its class, for the next one
  fresh; fake_runners "$R/bin"
  sw -n a --class pgx -- sleep 2 > /dev/null 2>&1
  sw -n j -- "$R/bin/jest" x > /dev/null 2>&1
  sw -n d -- sleep 2 > /dev/null 2>&1
  check run-writes-its-peak-line 'grep -Eq "agent-job-semaphore: a peak class=pgx bytes=[1-9][0-9]* rc=0 s=[0-9]+ cpu=[0-9]+$" "$LOG"'
  check jest-runner-is-class-jest 'grep -Eq " j peak class=jest bytes=[1-9][0-9]* " "$LOG"'
  check unclassed-command-is-class-default 'grep -Eq " d peak class=default bytes=[1-9][0-9]* " "$LOG"'
  o=$("$AJS" --fits pgx --load-max 1000)
  check next-run-reads-the-measure '[ "$(field "$o" source)" = log ] && [ "$(field "$o" estimate)" -ge $GIB ]'
}

t_fits_counts_what_would_open() {
  fresh; local o
  o=$("$AJS" --fits default --load-max 1000); rc=$?
  check fits-counts-an-empty-machine '[ $rc = 0 ] && [ "$(field "$o" would_open)" = 5 ] && [ "$(field "$o" running)" = 0 ] && [[ $o == *" reason=no memory for another window ("* ]] && [ ! -e "$D" ]'
  fake_win 1 $((3 * GIB))
  o=$("$AJS" --fits default --load-max 1000); rc=$?
  check fits-counts-beside-a-running-window '[ $rc = 0 ] && [ "$(field "$o" would_open)" = 4 ] && [ "$(field "$o" running)" = 1 ]'
  fake_ticket 2000 big $((6 * GIB)); fake_ticket 5 young $((6 * GIB))
  o=$("$AJS" --fits default --load-max 1000)
  check fits-counts-the-place-held-by-the-oldest-waiter '[ "$(field "$o" would_open)" = 2 ] && [ "$(field "$o" waiting)" = 2 ]'
  fresh; fake_win 1 $((3 * GIB)); mem_set 5242880 0 0
  o=$("$AJS" --fits default --load-max 1000); rc=$?
  check fits-says-zero-and-why-with-rc1 '[ $rc = 1 ] && [ "$(field "$o" would_open)" = 0 ] && [[ $o == *"reason=no memory for another window (MemAvailable 5120 MiB, minimum 4096 and"* ]]'
  fresh; load_set 5.00
  o=$("$AJS" --fits default --load-max 4); rc=$?
  check fits-names-the-cpu-gate '[ $rc = 1 ] && [[ $o == *"reason=no CPU for another window (load1 5.00;"* ]]'
}

# ---- entering: whole, when it fits, in no order ------------------------------------------------------------------------------

t_windows_enter_while_they_fit() {  # 7 GiB: two reserves of 3 fit, the third waits for one to end
  fresh; mem_set 7340032 0 0
  for n in a b c; do bg "$n" "$n" -- sh -c "$EV" "$R/ev" "$n" 3; queued "$n"; done
  for n in a b c; do rc_of "$n" 30 > /dev/null; done
  check two-windows-run-together-when-they-fit '[ "$(rcs a b c)" = 000 ] && overlap a b'
  check third-waits-until-one-ends '[ "$(max_conc)" = 2 ] && [ "$(ev_at + c)" -ge "$(first_end a b)" ] && [ "$(wins)" = 0 ] && [ -z "$(ls -A "$Q")" ] && noev'
}

t_nobody_waits_for_a_turn() {  # a small job enters ahead of a big one that arrived first and does not fit yet
  fresh; mem_set 7340032 0 0
  bg z z --mem 2 -- sh -c "$EV" "$R/ev" z 6; until_ 5 'started z'
  bg big big --mem 6 -- sh -c "$EV" "$R/ev" big 0; queued big
  bg small small --mem 1 -- sh -c "$EV" "$R/ev" small 1; queued small
  for n in z big small; do rc_of "$n" 30 > /dev/null; done
  check small-enters-before-the-big-one-that-arrived-first '[ "$(rcs z big small)" = 000 ] && [ "$(ev_at + small)" -lt "$(ev_at + big)" ] && [ "$(ev_at + small)" -lt "$(ev_at - z)" ]'
  check big-one-enters-when-it-fits '[ "$(ev_at + big)" -ge "$(ev_at - z)" ]'
}

t_waiter_over_hold_after_keeps_its_place() {  # an old live ticket is added to what runs; a young one is not
  fresh; mem_set 7340032 0 0
  bg z z --mem 2 -- sh -c "$EV" "$R/ev" z 12; until_ 5 'started z'
  fake_ticket 2000 big $((6 * GIB))
  bg s s --mem 1 -- sh -c "$EV" "$R/ev" s 0; queued s; sleep 3
  started s && held=no || held=yes
  rm -f "$Q"/*-big; fake_ticket 5 young $((6 * GIB))
  until_ 6 'started s'
  check old-waiter-holds-its-place-and-a-young-one-does-not '[ "$held" = yes ] && started s && ! ended z'
  rm -f "$Q"/*-young; for n in z s; do rc_of "$n" 30 > /dev/null; done
  check waiters-finish-after-the-place-is-released '[ "$(rcs z s)" = 00 ]'
}

t_hold_after_is_configurable() {
  fresh; mem_set 7340032 0 0
  bg z z --mem 2 -- sleep 6; until_ 5 '[ -d "$W1" ]'
  fake_ticket 5 big $((6 * GIB))
  AJS_HOLD_AFTER=2 bg s s --mem 1 -- sh -c "$EV" "$R/ev" s 0; sleep 4
  check hold-after-env-makes-a-younger-ticket-hold-its-place '! started s'
  rm -f "$Q"/*-big; rc_of s 20 > /dev/null; rc_of z 10 > /dev/null
  fresh; mem_set 7340032 0 0   # a waiter that has waited long does not hold a place against itself
  bg z z --mem 5 -- sh -c "$EV" "$R/ev" z 5; until_ 5 'started z'
  AJS_HOLD_AFTER=1 bg w w --mem 4 -- sh -c "$EV" "$R/ev" w 0; rc_of w 25 > /dev/null; rc_of z 10 > /dev/null
  check waiter-that-held-long-does-not-count-itself-twice '[ "$(rcs z w)" = 00 ] && [ "$(ev_at + w)" -ge "$(ev_at - z)" ]'
}

t_memory_gate() {  # alone it never waits for memory; the second waits for RAM, for swap when RAM is low, and for PSI
  fresh; mem_set 1048576 0 0; psi_set 50.00
  sw -n solo -- sh -c "$EV" "$R/ev" solo 0 > /dev/null 2>&1; rc=$?
  check memory-gate-never-stops-the-first '[ $rc = 0 ] && started solo'
  psi_set 0.00; bg z z -- sh -c "$EV" "$R/ev" z 26; until_ 5 'started z'
  bg w w -- sh -c "$EV" "$R/ev" w 0; queued w
  sleep 3; started w && low=no || low=yes
  mem_set 6291456 8388608 1048576; sleep 3; started w && swap=no || swap=yes
  mem_set 16777216 8388608 8388608; psi_set 25.00; sleep 3; started w && psi=no || psi=yes
  mem_set 16777216 8388608 1048576; psi_set 9.99; rc_of w 20 > /dev/null; rc_of z 35 > /dev/null
  check memory-gate-stops-the-second '[ "$low" = yes ]'
  check swap-gate-stops-the-second '[ "$swap" = yes ]'
  check psi-gate-stops-the-second '[ "$psi" = yes ]'
  check memory-gate-opens-when-there-is-room '[ "$(rcs w z)" = 00 ] && [ "$(ev_at + w)" -lt "$(ev_at - z)" ] && [ "$(wins)" = 0 ]'
  check used-swap-with-roomy-ram-does-not-stop '[ "$(rcs w z)" = 00 ] && [ "$(ev_at + w)" -lt "$(ev_at - z)" ]'
}

t_memory_counts_what_running_windows_can_still_grow() {  # 7 GiB: a window that declared 6 leaves no room for a 3
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sh -c "$EV" "$R/ev" z 5; until_ 5 'started z'
  bg w w -- sh -c "$EV" "$R/ev" w 0; queued w; sleep 2
  started w && early=no || early=yes
  bg v v --mem 0.5 -- sh -c "$EV" "$R/ev" v 0; sleep 3
  check estimate-of-running-window-counts-until-it-ends '[ "$early" = yes ] && started v'
  for n in z w v; do rc_of "$n" 30 > /dev/null; done
  check waiter-enters-after-the-estimate-is-free '[ "$(rcs z w v)" = 000 ] && [ "$(ev_at + w)" -ge "$(ev_at - z)" ]'
}

t_timeout_names_the_gate() {
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sleep 9; until_ 5 '[ -d "$W1" ]'
  sw -n x --timeout 2 -- touch "$R/ran" > /dev/null 2> "$R/x.err"; rc=$?
  check timeout-rc75-names-the-memory-gate '[ $rc = 75 ] && [ ! -e "$R/ran" ] && grep -Eq "^agent-job-semaphore: no memory for another window \(MemAvailable 7168 MiB, minimum 4096 and what the running windows can still grow plus this one 9[0-9]{3}; SwapFree 0 MiB, reserve 0 below 8192; PSI some avg10 0.00, maximum 10\) after [0-9]+s$" "$R/x.err" && [ "$(wins)" = 1 ]'
  check timeout-leaves-the-queue '! ls "$Q" | grep -q -- "-x$"'
  rc_of z 15 > /dev/null
}

t_without_timeout_it_waits_while_its_ticket_beats() {
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sleep 8; until_ 5 '[ -d "$W1" ]'
  swt 40 -n w -- sh -c 'echo w >> "$0"' "$R/order" > /dev/null 2>&1; rc=$?
  check waiter-without-timeout-outlasts-twice-the-expiry '[ $rc = 0 ] && grep -qx w "$R/order" && noev'
  rc_of z 15 > /dev/null
}

t_memory_thresholds_are_configurable() {
  fresh; mem_set 1048576 0 0
  bg z z --mem 0.1 -- sleep 15; until_ 5 '[ -d "$W1" ]'
  AJS_MEM_MIN_MIB=512 sw -n x --mem 0.1 --timeout 3 -- true > /dev/null 2>&1; rc=$?
  check memory-minimum-is-configurable '[ $rc = 0 ]'
  mem_set 16777216 8388608 8388608; psi_set 5.00
  AJS_PSI_MAX=3 sw -n y --timeout 2 -- true > /dev/null 2> "$R/y.err"; rc=$?
  check psi-maximum-is-configurable '[ $rc = 75 ] && grep -qF "PSI some avg10 5.00, maximum 3" "$R/y.err"'
  rc_of z 25 > /dev/null
}

t_memory_minimum() {  # below MemAvailable minimum even a small window waits, whatever its estimate
  fresh; mem_set 1048576 0 0
  bg z z --mem 0.1 -- sleep 6; until_ 5 '[ -d "$W1" ]'
  sw -n x --mem 0.1 --timeout 2 -- touch "$R/ran" > /dev/null 2> "$R/x.err"; rc=$?
  check memory-minimum-stops-even-a-small-window '[ $rc = 75 ] && [ ! -e "$R/ran" ] && grep -qF "MemAvailable 1024 MiB, minimum 4096 and" "$R/x.err"'
  rc_of z 15 > /dev/null
}

t_cpu_budget() {  # load1 or the CPU the running windows weigh (the larger), plus the one asked, up to --load-max
  fresh; load_set 3.50
  sw -n a --load-max 4 --timeout 2 -- touch "$R/ran" > /dev/null 2> "$R/a.err"; rc=$?
  check busy-machine-stops-even-the-first '[ $rc = 75 ] && [ ! -e "$R/ran" ] && grep -qF "no CPU for another window (load1 3.50; running windows weigh 0; the place held 0; this one 1; budget 4)" "$R/a.err"'
  load_set 3.00
  sw -n b --load-max 4 -- true > /dev/null 2>&1; rc=$?
  check budget-is-reached-exactly-and-passes '[ $rc = 0 ]'
  load_set 0.50
  bg z z --load-max 4 --cpu 3 -- sleep 7; until_ 5 '[ -d "$W1" ]'
  sw -n c --load-max 4 --cpu 2 --timeout 2 -- true > /dev/null 2> "$R/c.err"; rc=$?
  check running-window-cpu-counts-while-load1-is-low '[ $rc = 75 ] && grep -qF "load1 0.50; running windows weigh 3; the place held 0; this one 2; budget 4" "$R/c.err"'
  sw -n d --load-max 4 --cpu 1 --timeout 5 -- true > /dev/null 2>&1; rc=$?
  check one-core-more-fits-beside-it '[ $rc = 0 ]'
  rc_of z 15 > /dev/null
  load_set 1.00; sw -n v --load-max 0.5 --timeout 2 -- true > /dev/null 2> "$R/v.err"; rc=$?
  check fractional-budget '[ $rc = 75 ] && grep -qF "budget 0.50)" "$R/v.err"'
  check default-budget-is-the-cores '[ "$("$AJS" --fits default | sed -n "s/.*would_open=\([0-9]*\).*/\1/p")" -ge 1 ]'
}

t_cpu_never_exceeds_the_cores() {  # no estimate asks for more cores than the machine has, and a window alone enters
  fresh; local o
  "$AJS" --fits pgx --cpu 5 --load-max 4 > /dev/null 2> "$R/c.err"; rc=$?
  check declared-cpu-above-the-cores-is-refused '[ $rc = 2 ] && grep -qF -- "--cpu 5 needs more CPU than the machine has (4)" "$R/c.err"'
  peakline pgx $((2 * GIB)) 900
  o=$("$AJS" --fits pgx --load-max 4)
  check a-peak-above-the-cores-weighs-the-cores '[ "$(field "$o" cpu)" = 4 ]'
  o=$("$AJS" --fits jest --load-max 2)
  check the-default-of-a-class-is-capped-too '[ "$(field "$o" cpu)" = 2 ]'
  o=$("$AJS" --fits pgx --load-max 0.5)
  check a-fractional-budget-still-weighs-one-core '[ "$(field "$o" cpu)" = 1 ]'
  mkdir -p "$R/bin"; printf '#!/bin/sh\necho 1\n' > "$R/bin/nproc"; chmod +x "$R/bin/nproc"
  o=$(PATH="$R/bin:$PATH" "$AJS" --fits jest)
  check default-budget-is-fewer-when-the-process-may-use-fewer-cores '[ "$(field "$o" cpu)" = 1 ]'
  load_set 0.50
  sw -n a --class jest --load-max 2 --timeout 3 -- touch "$R/ran" > /dev/null 2>&1; rc=$?
  check alone-it-enters-whatever-its-class-asks '[ $rc = 0 ] && [ -e "$R/ran" ]'
  fresh; mem_set 7340032 0 0
  bg z z --mem 2 --load-max 4 -- sh -c "$EV" "$R/ev" z 8; until_ 5 'started z'
  fake_ticket 2000 big $((6 * GIB)) 9
  bg s s --mem 1 --load-max 4 -- sh -c "$EV" "$R/ev" s 0; until_ 6 'started s'
  check a-waiter-asking-more-cores-than-there-are-holds-no-place 'started s && ! ended z'
  rm -f "$Q"/*-big; for n in z s; do rc_of "$n" 30 > /dev/null; done
}

t_jest_weighs_the_p90() {  # like "default": a percentile of its own last 100 runs, not the largest of 20
  fresh; local i o p
  for i in $(seq 9); do peakline jest $GIB 100; peakline pgx $GIB 100; done; peakline jest $((10 * GIB)) 500; peakline pgx $((10 * GIB)) 500
  o=$("$AJS" --fits jest --load-max 1000); p=$("$AJS" --fits pgx --load-max 1000)
  check jest-weighs-the-p90-of-memory-and-cpu '[ "$(field "$o" estimate)" = $GIB ] && [ "$(field "$o" cpu)" = 1 ] && [ "$(field "$o" source)" = log ]'
  check another-class-keeps-the-largest-of-20 '[ "$(field "$p" estimate)" = $((10 * GIB)) ] && [ "$(field "$p" cpu)" = 5 ]'
  fresh; for i in $(seq 20); do peakline default $GIB 100; done; peakline jest $((10 * GIB)) 500
  o=$("$AJS" --fits jest --load-max 1000)
  check the-peaks-of-another-class-do-not-count-in-its-percentile '[ "$(field "$o" estimate)" = $((10 * GIB)) ]'
}

t_unreadable_loadavg_holds_the_gate() {  # a load that cannot be read never counts as low
  fresh; export AJS_LOADAVG_FILE=$R/missing
  sw -n x --timeout 1 -- touch "$R/ran" > /dev/null 2> "$R/x.err"; rc=$?
  check unreadable-loadavg-holds-the-gate '[ $rc = 75 ] && [ ! -e "$R/ran" ] && grep -qF "load1 ?;" "$R/x.err"'
}

t_notice_names_the_gate_and_the_holders() {
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sleep 8; until_ 5 '[ -d "$W1" ]'
  AJS_NOTICE_AFTER=2 swt 20 -n w -- true > /dev/null 2> "$R/w.err"; rc=$?
  check notice-says-why-and-who-holds '[ $rc = 0 ] && grep -Eq "^agent-job-semaphore: waiting for [23]s: no memory for another window \(.*\) \(running: z pid=[0-9]+ since=[^ ]+ ticket=[0-9]+-[0-9]+-z\)$" "$R/w.err"'
  rc_of z 10 > /dev/null
}

# ---- liveness: dead tickets, orphaned windows, a stalled machine ----------------------------------------------------------

t_sigkill_owner() {  # real SIGKILL to the window's owner: its ticket and its window are reaped by a waiter
  fresh; mem_set 5242880 0 0
  bg k k -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/k.child"; until_ 5 '[ -s "$R/k.child" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  kp=$(pid_of k); kill -9 "$kp"; kill -9 "$(cat "$R/k.child")"
  check sigkill-owner-reaps-ticket-and-window '[ "$(rc_of w 20)" = 0 ] && grep -qx w "$R/order" && grep -Eq "reaps dead ticket [0-9]+-$kp-k " "$LOG" && grep -q "reaps orphaned window 1 (k pid=$kp " "$LOG" && [ -z "$(ls -A "$Q")" ] && [ "$(wins)" = 0 ]'
}

t_signals_free_the_window() {  # TERM and INT stop the command, free the window and leave the queue
  fresh; bg k k -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/k.child"; until_ 5 '[ -s "$R/k.child" ] && [ -s "$W1/owner" ]'
  kp=$(pid_of k); kill -TERM "$kp"
  check term-exits-143-stops-command-and-frees-window '[ "$(rc_of k 10)" = 143 ] && ! kill -0 "$(cat "$R/k.child")" 2>/dev/null && [ ! -e "$W1" ] && [ -z "$(ls -A "$Q")" ]'
  # A background job starts with SIGINT ignored; perl resets it as a foreground terminal would.
  { perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' "$AJS" -C "$R/repo" --load-max 1000 --out "$R/out" -n i -- \
      sh -c 'echo $$ > "$0"; exec sleep 60' "$R/i.child" > /dev/null 2>&1; echo $? > "$R/i.rc"; } &
  kids+=($!); until_ 5 '[ -s "$R/i.child" ] && [ -s "$W1/owner" ]'
  kill -INT "$(pid_of i)"
  check int-exits-130-stops-command-and-frees-window '[ "$(rc_of i 10)" = 130 ] && ! kill -0 "$(cat "$R/i.child")" 2>/dev/null && [ ! -e "$W1" ] && [ -z "$(ls -A "$Q")" ]'
  mem_set 7340032 0 0; bg h h --mem 6 -- sleep 4; until_ 5 '[ -d "$W1" ]'; bg w w -- touch "$R/w-ran"; queued w
  kill -TERM "$(pid_of w)"
  check term-while-waiting-exits-143-and-leaves-the-queue '[ "$(rc_of w 10)" = 143 ] && [ ! -e "$R/w-ran" ] && ! ls "$Q" | grep -q -- "-w$" && [ "$(rc_of h 10)" = 0 ]'
}

t_dead_ticket_of_a_waiter() {  # a dead ticket is reaped; a live window is never touched
  fresh; mem_set 5242880 0 0; fake_win 1 $((3 * GIB)); : > "$Q/1000-9-dead"; touch -d '-1 min' "$Q/1000-9-dead"
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 'grep -q "reaps dead ticket 1000-9-dead " "$LOG" 2>/dev/null'
  sleep 2
  check dead-ticket-is-reaped-and-live-window-is-not-touched '[ ! -e "$Q/1000-9-dead" ] && [ "$(cat "$W1/owner")" = "f1 pid=1 since=x ticket=1000-1-f1" ] && ! grep -q "orphaned" "$LOG" && ! started w'
  rm -rf "$W1" "$Q/1000-1-f1"
  check waiter-runs-when-the-window-is-gone '[ "$(rc_of w 10)" = 0 ] && grep -qx w "$R/order"'
}

t_window_without_owner() {  # died between mkdir and writing the owner: the dir is reaped by its own mtime
  fresh; mem_set 5242880 0 0; mkdir -p "$W1"; touch -d '-1 min' "$W1"
  bg w w -- true
  check stale-window-without-owner-is-reaped '[ "$(rc_of w 10)" = 0 ] && grep -q "reaps orphaned window 1 (no owner)" "$LOG" && [ ! -e "$W1" ]'
}

t_slow_live_owner() {  # an owner more than twice AJS_STALE long, and waiters behind it
  fresh; mem_set 5242880 0 0
  bg l l -- sh -c 'sleep 12; echo l-end >> "$0"' "$R/order"; until_ 5 '[ -d "$W1" ]'
  bg s s -- sh -c 'echo s >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"
  for n in l s w; do rc_of "$n" 40 > /dev/null; done
  check slow-live-owner-is-not-reaped '[ "$(rcs l s w)" = 000 ] && [ "$(head -n1 "$R/order")" = l-end ] && noev'
}

t_ticket_removed_from_live_waiter() {  # it comes back with its estimate
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sleep 5; until_ 5 '[ -d "$W1" ]'
  bg w1 w1 -- sh -c 'echo w1 >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  tw1=$(ls "$Q" | grep -- '-w1$'); rm -f "$Q"/*-w1
  check removed-ticket-of-live-waiter-comes-back '[ "$(rc_of w1 20)" = 0 ] && grep -qx w1 "$R/order" && grep -q "w1 lost its ticket while alive; back as $tw1" "$LOG"'
  rc_of z 10 > /dev/null
}

t_ticket_removed_from_live_owner() {  # the window's heartbeat is its owner file: without a ticket the owner stays
  fresh; mem_set 5242880 0 0
  bg h h -- sh -c 'sleep 8; echo h-end >> "$0"' "$R/order"; until_ 5 '[ -d "$W1" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  rm -f "$Q"/*-h
  for n in h w; do rc_of "$n" 20 > /dev/null; done
  check removed-ticket-of-live-owner-keeps-the-window '[ "$(rcs h w)" = 00 ] && [ "$(tr "\n" " " < "$R/order")" = "h-end w " ] && ! grep -qs window "$LOG"'
}

t_window_moved_while_live() {  # between reading a stale owner and the mv, another process took a fresh window
  fresh; mem_set 5242880 0 0; mkdir -p "$W1"; echo "k pid=5 since=x ticket=1-5-k" > "$W1/owner"; touch -d '-1 min' "$W1/owner"
  mkdir -p "$R/swap"; cat > "$R/swap/mv" <<EOF
#!/bin/bash
for a; do last=\$a; done
if [[ \$last == "$D/.reaped-win.1-"* ]] && [ ! -e "$R/swap.done" ]; then
  : > "$R/swap.done"; rm -rf "$W1"; mkdir "$W1"; echo "other pid=9 since=x ticket=1-9-other" > "$W1/owner"; touch -d '+1 min' "$W1/owner"
fi
exec $(command -v mv) "\$@"
EOF
  chmod +x "$R/swap/mv"
  PATH=$R/swap:$PATH swt 5 -n w -- true > /dev/null 2>&1; rc=$?
  check window-moved-while-live-is-given-back '[ -e "$R/swap.done" ] && [ $rc = 124 ] && grep -q "^other " "$W1/owner" && grep -q "gives back live window 1 (other pid=9 " "$LOG" && ! grep -q "reaps orphaned" "$LOG"'
}

t_poll_cost() {  # what a waiter launches per pass does not grow with the queue; counted per pass, not per clock
  local n; local -A c
  for n in 5 25; do c[$n]=$(cost_run "$n"); done
  echo "# cost: external calls up to the 4th pass with 5 tickets ${c[5]}, with 25 ${c[25]}"
  check poll-costs-the-same-with-5-or-25-tickets '[ ${c[5]} -gt 0 ] && [ $((${c[25]} - ${c[5]})) -lt 20 ]'
}
cost_run() {  # cost_run <n>: external calls of a waiter up to its 4th reaping pass, with a live window and <n> live tickets
  local n=$1 i; fresh; mem_set 5242880 0 0; fake_win 1 $((3 * GIB))
  for ((i = 1; i <= n; i++)); do : > "$Q/1000$(printf %03d "$i")-1-f$i"; touch -d '+1 min' "$Q/1000$(printf %03d "$i")-1-f$i"; done
  shim "$R/shim" date stat ls sort head basename cat touch sleep mv rm grep sed cut awk mkdir id realpath tail tr getconf
  printf '#!/bin/bash\n[ "$1 $2" = "-c %%Y %%n" ] && echo stat-batch >> %q || echo stat >> %q\nexec %q "$@"\n' \
    "$R/shim/count" "$R/shim/count" "$(command -v stat)" > "$R/shim/stat"
  PATH="$R/shim:$PATH" timeout 30 "$AJS" -C "$R/repo" --load-max 1000 --out "$R/out" -n w -- true > /dev/null 2>&1 & local p=$!
  until_ 25 "[ \$(grep -c '^stat-batch\$' '$R/shim/count') -ge 4 ]"; kill "$p" 2>/dev/null; wait "$p"
  awk '$0 == "stat-batch" && ++k == 4 {print NR; f=1; exit} END {if (!f) print 0}' "$R/shim/count"
}

t_slow_newcomer() {  # its first stat takes longer than AJS_STALE: the heartbeat already runs
  fresh; mem_set 5242880 0 0; bg h h -- sleep 11; until_ 5 '[ -d "$W1" ]'
  bg w w -- true; until_ 5 '[ "$(tickets)" = 2 ]'
  mkdir -p "$R/slow"; printf '#!/bin/bash\n[ -e %q ] || { : > %q; sleep 7; }\nexec %q "$@"\n' "$R/slow.done" "$R/slow.done" "$(command -v stat)" > "$R/slow/stat"; chmod +x "$R/slow/stat"
  PATH=$R/slow:$PATH bg n n -- true
  local x; for x in h w n; do rc_of "$x" 30 > /dev/null; done
  check slow-newcomer-keeps-its-ticket '[ -e "$R/slow.done" ] && [ "$(rcs h w n)" = 000 ] && ! grep -Eqs -- "-n |n lost" "$LOG"'
}

t_name_with_dead_ticket() {  # a dead ticket with my name does not send me away: it is reaped first
  fresh; mkdir -p "$Q"; touch -d '-1 min' "$Q/1-99-x"
  sw -n x -- true > /dev/null 2>&1; rc=$?
  check dead-ticket-with-my-name-does-not-count '[ $rc = 0 ] && grep -q "reaps dead ticket 1-99-x " "$LOG"'
}

t_fresh_window_without_owner_is_left_alone() {  # it is no one's to remove; the newcomer runs beside it
  fresh; mkdir -p "$W1"; touch -d '+1 min' "$W1"
  sw -n w -- true > /dev/null 2>&1; rc=$?
  check fresh-window-without-owner-is-not-reaped '[ $rc = 0 ] && [ -d "$W1" ] && ! grep -qs "reaps orphaned" "$LOG" && noev'
  mem_set 5242880 0 0
  sw -n x --timeout 2 -- touch "$R/ran" > /dev/null 2>&1; rc=$?
  check timed-out-waiter-does-not-remove-an-ownerless-window '[ $rc = 75 ] && [ ! -e "$R/ran" ] && [ -d "$W1" ] && ! grep -qs "lost window" "$LOG"'
}

t_window_with_live_ticket_is_kept() {  # a stale owner file whose ticket still beats belongs to a live process
  fresh; mem_set 5242880 0 0; fake_win 1 $((3 * GIB)); touch -d '-1 min' "$W1/owner"
  AJS_NOTICE_AFTER=2 swt 5 -n w -- true > /dev/null 2> "$R/w.err"; rc=$?
  check window-with-live-ticket-is-not-reaped '[ $rc = 124 ] && [ "$(cat "$W1/owner")" = "f1 pid=1 since=x ticket=1000-1-f1" ] && ! grep -qs "reaps" "$LOG"'
}

t_odd_owner_lines() {  # a stale owner with an empty ticket field is reaped; one with no ticket field is not touched
  fresh; mem_set 5242880 0 0; mkdir -p "$W1"; echo "k pid=5 since=x ticket=" > "$W1/owner"; touch -d '-1 min' "$W1/owner"
  swt 8 -n w -- true > /dev/null 2>&1; rc=$?
  check owner-with-empty-ticket-field-is-reaped '[ $rc = 0 ] && grep -q "reaps orphaned window 1 (k pid=5 since=x ticket=)" "$LOG"'
  fresh; mem_set 5242880 0 0; mkdir -p "$W1"; echo "hand-made lock" > "$W1/owner"; touch -d '-1 min' "$W1/owner"
  swt 4 -n w -- touch "$R/ran" > /dev/null 2>&1; rc=$?
  check owner-without-ticket-field-is-never-touched '[ $rc = 124 ] && [ ! -e "$R/ran" ] && [ "$(cat "$W1/owner")" = "hand-made lock" ] && ! grep -qs "reaps" "$LOG"'
}

t_tickets_sort_bytewise_under_any_locale() {  # en_US collation skips '-': ticket order must not depend on it
  fresh; local loc p tb_like fake
  loc=$(locale -a 2> /dev/null | grep -m1 -iE '^en_US\.utf-?8$') || { skip tickets-sort-bytewise-under-any-locale 'no en_US.UTF-8 locale'; return; }
  p=$(date +%s | cut -c1-3); tb_like="$(date +%s%N)-5-x"; fake="$p-9-x"
  LC_ALL=$loc bash -c '[[ $0 < $1 ]]' "$tb_like" "$fake" && LC_ALL=C bash -c '[[ $1 < $0 ]]' "$tb_like" "$fake" ||
    { skip tickets-sort-bytewise-under-any-locale "$loc does not reorder $fake"; return; }
  mkdir -p "$Q"; touch -d '+1 min' "$Q/$fake"
  LC_ALL=$loc sw -n x -- touch "$R/ran" > /dev/null 2> "$R/x.err"; rc=$?
  check tickets-sort-bytewise-under-any-locale '[ $rc = 73 ] && [ ! -e "$R/ran" ] && grep -qF "$fake" "$R/x.err"'
}

t_first_given_up_for_dead() {  # its ticket is removed while it reads a stale owner: it does not reap the window until it is back
  fresh; mem_set 5242880 0 0; mkdir -p "$W1"; echo "k pid=5 since=x ticket=1-5-k" > "$W1/owner"; touch -d '-1 min' "$W1/owner"
  mkdir -p "$R/st"; cat > "$R/st/stat" <<EOF
#!/bin/bash
for a; do :; done
[ "\$a" = "$W1/owner" ] && [ ! -e "$R/st.done" ] && { : > "$R/st.done"; rm -f "$Q"/*-w; }
exec $(command -v stat) "\$@"
EOF
  chmod +x "$R/st/stat"
  PATH=$R/st:$PATH sw -n w -- true > /dev/null 2>&1; rc=$?
  check first-given-up-for-dead-does-not-reap-the-window '[ -e "$R/st.done" ] && [ $rc = 0 ] && [ "$(grep -o -m1 -e "lost its ticket" -e "reaps orphaned" "$LOG")" = "lost its ticket" ]'
}

t_machine_stall_removes_nothing() {  # a process stopped for longer than AJS_STALE - 2 x AJS_BEAT sees every beat silent: it waits
  fresh; mem_set 7340032 0 0
  bg z z --mem 6 -- sleep 16; until_ 5 '[ -d "$W1" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; queued w; sleep 1
  wp=$(pid_of w); kill -STOP "$wp"; : > "$Q/1000-9-dead"; touch -d '-1 min' "$Q/1000-9-dead"; sleep 4; kill -CONT "$wp"
  until_ 8 'grep -q "machine stall" "$LOG" 2>/dev/null'; stalled=$?; [ -e "$Q/1000-9-dead" ] && kept=yes || kept=no
  check stall-is-said-and-nothing-is-removed-at-once '[ $stalled = 0 ] && [ "$kept" = yes ] && grep -Eq "w machine stall: this process was [0-9]+ s without running; not removing tickets or windows until 5 s later" "$LOG"'
  check dead-ticket-goes-after-the-grace '[ "$(until_ 15 "[ ! -e \"$Q/1000-9-dead\" ]"; echo $?)" = 0 ] && grep -q "reaps dead ticket 1000-9-dead " "$LOG"'
  for n in z w; do rc_of "$n" 30 > /dev/null; done
}

t_foreign_window_at_release() {  # if the window is no longer mine when done, I do not remove it, and I do not log a peak
  fresh; bg h h -- sleep 3; until_ 5 '[ -s "$W1/owner" ]'
  rm -rf "$W1"; mkdir "$W1"; echo "other pid=9 since=x ticket=1-9-other" > "$W1/owner"; echo 123456789 > "$W1/peak"
  check foreign-window-survives-release '[ "$(rc_of h 10)" = 0 ] && grep -q "^other " "$W1/owner"'
  check lost-window-warns-of-overlap-and-logs-no-peak 'grep -q "lost window 1 while running" "$R/h.err" && grep -q "h lost window 1 while running" "$LOG" && ! grep -q " h peak " "$LOG"'
}

# ---- the command: workers, logs, the safety clock ----------------------------------------------------------------------------------

fake_runners() {  # <dir>/{jest,vitest,npx,pnpm,vitest-part.sh}: print their args; the wrapper sets its own workers
  local d=$1 c; mkdir -p "$d"
  for c in jest vitest; do printf '#!/bin/bash\necho "args: $*"\necho "Tests: 1 passed, 1 total"\nsleep 1\n' > "$d/$c"; done
  printf '#!/bin/bash\nwhile [[ ${1:-} == -* ]]; do shift; done\nexec "$@"\n' > "$d/npx"
  printf '#!/bin/bash\n[ "$1" = exec ] && shift\nexec "$@"\n' > "$d/pnpm"
  printf '#!/bin/bash\nexec "%s/vitest" --maxWorkers=1 "$@"\n' "$d" > "$d/vitest-part.sh"
  chmod +x "$d"/*
}
workers_of() { grep -o -- '--maxWorkers=[0-9]*' "$(raw_of "$1")" | tr '\n' ' '; }

t_jest_workers() {  # only when jest or vitest is the program that runs, directly or after timeout/npx/pnpm exec
  fresh; fake_runners "$R/bin"
  sw -n a -- "$R/bin/jest" x > "$R/j.out"; check jest-direct-gets-two-workers '[ "$(workers_of "$R/j.out")" = "--maxWorkers=2 " ]'
  sw -n a -- timeout 20 "$R/bin/vitest" x > "$R/t.out"; check vitest-after-timeout-gets-two-workers '[ "$(workers_of "$R/t.out")" = "--maxWorkers=2 " ]'
  sw -n a -- "$R/bin/npx" --yes "$R/bin/jest" x > "$R/n.out"; check jest-after-npx-gets-two-workers '[ "$(workers_of "$R/n.out")" = "--maxWorkers=2 " ]'
  sw -n a -- "$R/bin/pnpm" exec "$R/bin/vitest" x > "$R/p.out"; check vitest-after-pnpm-exec-gets-two-workers '[ "$(workers_of "$R/p.out")" = "--maxWorkers=2 " ]'
  sw -n a -- "$R/bin/vitest-part.sh" x > "$R/w.out"; check wrapper-with-its-own-gets-no-other '[ "$(workers_of "$R/w.out")" = "--maxWorkers=1 " ] && grep -q " rc=0 " "$R/w.out"'
  sw -n a -- "$R/bin/jest" --max-workers=4 x > "$R/m.out"; check workers-set-by-the-caller-are-kept '[ -z "$(workers_of "$R/m.out")" ]'
  sw -n a -- sh -c 'echo "args: $*"' x jest vitest > "$R/o.out"; check naming-jest-in-an-argument-is-not-enough '[ -z "$(workers_of "$R/o.out")" ]'
  AJS_JEST_WORKERS=3 sw -n a -- "$R/bin/jest" x > "$R/k.out"; check jest-workers-is-configurable '[ "$(workers_of "$R/k.out")" = "--maxWorkers=3 " ]'
  AJS_JEST_WORKERS=0 sw -n a -- "$R/bin/jest" x > "$R/z.out"; check jest-workers-zero-disables '[ -z "$(workers_of "$R/z.out")" ]'
}

t_same_second_logs_do_not_clash() {  # a date frozen in one second: the pid in the log name keeps them apart
  fresh; mkdir -p "$R/bin"
  printf '#!/bin/bash\ncase "$*" in "+%%Y%%m%%dT%%H%%M%%S") echo 20261101T020000 ;; *) exec %q "$@" ;; esac\n' "$(command -v date)" > "$R/bin/date"; chmod +x "$R/bin/date"
  PATH="$R/bin:$PATH" sw -n a -- sh -c 'echo one; echo "Tests: 1 passed, 1 total"' > "$R/1.out"
  PATH="$R/bin:$PATH" sw -n a -- sh -c 'echo two; echo "Tests: 2 passed, 2 total"' > "$R/2.out"
  l1=$(raw_of "$R/1.out"); l2=$(raw_of "$R/2.out")
  check same-second-two-logs-with-distinct-names '[ -n "$l1" ] && [ "$l1" != "$l2" ] && [[ $l1 == *T020000-* ]] && [[ $l2 == *T020000-* ]]'
  check same-second-second-does-not-overwrite-first '[ "$(head -n1 "$l1")" = one ] && [ "$(head -n1 "$l2")" = two ] && [ "$(ls "$R/out" | wc -l)" = 2 ]'
}

t_max_runtime_ends_a_hung_command() {  # the safety clock: TERM to the tree, KILL after 10 s, rc 124
  fresh
  t0=$SECONDS; sw -n t --max-runtime 2 -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/t.pid" > "$R/t.out" 2> "$R/t.err"; rc=$?; el=$((SECONDS - t0))
  check max-runtime-ends-the-command-with-rc124 '[ $rc = 124 ] && [ $el -lt 9 ] && ! kill -0 "$(cat "$R/t.pid")" 2>/dev/null && grep -Eq "expired: --max-runtime 2 s; TERM to the command.s tree and KILL after 10 s \(the command left with 1[34][0-9]\) \(output: " "$R/t.out" && [ "$(wins)" = 0 ] && [ -z "$(ls -A "$Q")" ]'
  t0=$SECONDS; sw -n u --max-runtime 2 -- sh -c 'trap "" TERM; echo $$ > "$0"; i=0; while [ $i -lt 40 ]; do sleep 1; i=$((i + 1)); done' "$R/u.pid" > "$R/u.out" 2> /dev/null; rc=$?; el=$((SECONDS - t0))
  check max-runtime-kills-what-ignores-term-after-the-grace '[ $rc = 124 ] && [ $el -ge 11 ] && [ $el -lt 20 ] && ! kill -0 "$(cat "$R/u.pid")" 2>/dev/null'
  sw -n v --max-runtime 30 -- sh -c 'echo "Tests: 1 passed, 1 total"' > "$R/v.out"; rc=$?
  check max-runtime-does-not-touch-a-command-that-ends '[ $rc = 0 ] && ! grep -q expired "$R/v.out"'
}

helpers_of() {  # helpers_of <pid>: the descendants of <pid> that run the script itself (heartbeat, watcher, clock), one per line
  local want p; want=$(tr '\0' ' ' < "/proc/$1/cmdline")
  ps -e -o pid=,ppid= | awk -v r="$1" '{ k[$2] = k[$2] " " $1 } END { q[1] = r; h = 1; t = 1
    while (h <= t) { n = split(k[q[h++]], c, " "); for (i = 1; i <= n; i++) { q[++t] = c[i]; print c[i] } } }' |
    while read -r p; do [ "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" = "$want" ] && echo "$p"; done
}
t_max_runtime_clock_dies_with_its_owner() {  # owner SIGKILLed: its clock leaves without signalling anything
  fresh
  bg a a --max-runtime 40 -- sh -c 'exec sleep 12.1'; bg b b --max-runtime 12 -- sh -c 'exec sleep 59.2'
  until_ 8 '[ -s "$W1/owner" ] && [ -s "$W2/owner" ]'; sleep 1
  pa=$(pid_of a); pb=$(pid_of b); ha=$(helpers_of "$pa" | tr '\n' ' ')
  kill -9 "$pa" "$pb"; sleep 16
  gone=1; for p in $ha; do kill -0 "$p" 2>/dev/null && gone=0; done
  check max-runtime-clock-leaves-with-its-owner '[ -n "$ha" ] && [ $gone = 1 ]'
  check max-runtime-clock-of-a-dead-owner-signals-nothing 'pgrep -xf "sleep 59.2" > /dev/null'
  pkill -xf "sleep 59.2" 2>/dev/null; true
}

# ---- containment: a window that runs away dies alone -----------------------------------------------------------------------------

real_contain() { command -v prlimit > /dev/null && unshare --user --map-current-user --pid --fork --kill-child --mount-proc -- /bin/true 2> /dev/null; }
contain_shims() {  # stand-ins for unshare and prlimit: they run the command as a child, so the watcher reads its tree as it would in a namespace
  mkdir -p "$R/cshim"
  cat > "$R/cshim/unshare" <<'EOF'
#!/bin/bash
while [ "${1:-}" != -- ] && [ $# -gt 0 ]; do shift; done; shift
"$@"; exit $?
EOF
  cat > "$R/cshim/prlimit" <<'EOF'
#!/bin/bash
while [ "${1:-}" != -- ] && [ $# -gt 0 ]; do shift; done; shift
exec "$@"
EOF
  chmod +x "$R/cshim/unshare" "$R/cshim/prlimit"
}
contain_checks() {  # contain_checks <label> <orphans>: memory and task limits kill the window that passes them, not the others
  local label=$1 orphans=$2   # a stand-in leaves the command's orphans behind, and their pid is real; in a namespace they die with it
  AJS_KILL_MEM_MIB=64 sw -n m -- perl -e 'open F, ">", $ARGV[0]; print F $$; close F; $x = "a" x 150_000_000; sleep 12' "$R/m.pid" > "$R/m.out" 2> "$R/m.err"; rc=$?
  [ "$orphans" = yes ] && [ -s "$R/m.pid" ] && kill -9 "$(cat "$R/m.pid")" 2>/dev/null
  check "$label-memory-past-the-limit-kills-the-window" '[ $rc = 137 ] && grep -Eq " contained: RSS [0-9]+ MiB >= 64 MiB (\(output: |$)" "$R/m.out" && grep -q "contained: RSS" "$(raw_of "$R/m.out")" && [ "$(wins)" = 0 ]'
  AJS_TASKS_MAX=20 sw -n k -- sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do sleep 9 & done; wait' > "$R/k.out" 2> /dev/null; rc=$?
  check "$label-tasks-at-90-percent-kill-the-window" '[ $rc = 137 ] && grep -Eq " contained: tasks [0-9]+ >= 18 \(90 % of its cap 20\)" "$R/k.out"'
  bg z z --mem 0.2 -- sleep 5; until_ 5 '[ -d "$W1" ]'
  AJS_KILL_MEM_MIB=64 sw -n m2 -- perl -e 'open F, ">", $ARGV[0]; print F $$; close F; $x = "a" x 150_000_000; sleep 12' "$R/m2.pid" > /dev/null 2>&1
  [ "$orphans" = yes ] && [ -s "$R/m2.pid" ] && kill -9 "$(cat "$R/m2.pid")" 2>/dev/null
  check "$label-only-the-runaway-window-dies" '[ "$(rc_of z 15)" = 0 ]'
  sw -n ok --mem 0.2 -- sh -c 'echo "Tests: 1 passed, 1 total"; sleep 1' > "$R/ok.out"; rc=$?
  check "$label-a-sane-command-is-not-touched" '[ $rc = 0 ] && ! grep -q contained "$R/ok.out"'
}
t_containment_with_a_stand_in() {  # the watcher's decisions, whether or not this machine allows namespaces
  fresh; contain_shims
  PATH="$R/cshim:$PATH" contain_checks stand-in yes
}
t_containment_with_namespaces() {
  fresh
  real_contain || { skip containment-with-namespaces 'unshare of user and pid namespaces (and prlimit) does not work here'; return; }
  contain_checks namespace no
  sw -n ns -- sh -c 'echo "pid inside: $$"' > "$R/ns.out"
  check namespace-command-is-pid-1-ish '[ "$(sed -n "s/^pid inside: //p" "$(raw_of "$R/ns.out")")" -lt 10 ] && ! grep -q uncontained "$R/ns.out"'
}
t_uncontained_says_so() {
  fresh; mkdir -p "$R/nonamespace"; printf '#!/bin/sh\nexit 1\n' > "$R/nonamespace/unshare"; chmod +x "$R/nonamespace/unshare"
  PATH="$R/nonamespace:$PATH" sw -n u -- sh -c 'echo "Tests: 1 passed, 1 total"' > "$R/u.out"; rc=$?
  check without-namespaces-the-line-says-uncontained '[ $rc = 0 ] && grep -Eq "Tests: 1 passed, 1 total uncontained \(output: " "$R/u.out"'
}

for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  [[ $t =~ ${ONLY:-.} ]] || continue
  ( trap kill_kids EXIT; "$t" )
done

# The canary: no bench name ever showed up in the caller's real default dirs.
kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null; sampler_pid=0
sort -u "$TMP/names" | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' > "$TMP/names.u"
leaks=$(sort -u "$TMP/real.samples" | awk -v start="$BENCH_START_NS" 'NR == FNR { n[$0] = 1; next }
  /^state:/ { split(substr($0, 7), p, "/"); if (p[1] in n) print; next }
  match($0, /^[0-9]+-[0-9]+-/) { if (substr($0, 1, RLENGTH) + 0 >= start + 0 && substr($0, RLENGTH + 1) in n) print }' "$TMP/names.u" - | head -n 3)
samples=$(wc -l < "$TMP/real.samples")
check "real-default-dirs-untouched leaks=${leaks:-none}" '[ -z "$leaks" ]'
pass=$(grep -c '^ok ' "$TMP/results"); fail=$(grep -c '^FAIL ' "$TMP/results")
echo "# canary sampled $REAL_RUNTIME and $REAL_STATE (${samples} lines)"
echo "Tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
