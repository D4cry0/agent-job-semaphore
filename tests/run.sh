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
export AJS_BEAT=1 AJS_STALE=3 AJS_POLL=1 AJS_SLOTS=1
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
  R=$(mktemp -d "$TMP/r.XXXXXX"); D=$R/lock; Q=$D/queue; LOG=$D/events.log; S1=$D/slot.1; S2=$D/slot.2
  mkdir -p "$R/repo" "$R/out"
  export AJS_DIR=$D AJS_LOADAVG_FILE=$R/loadavg AJS_MEMINFO_FILE=$R/meminfo AJS_PSI_FILE=$R/pressure
  load_set 0.50; mem_set 16777216 8388608 8388608; psi_set 0.00
}
note_name() { echo "$1" >> "$TMP/names"; }
sw() {  # sw [options] -- <cmd...>: one run with a huge load budget, raw output in $R/out
  local a; for a; do note_name "$a"; done
  "${AJS_OVERRIDE:-$AJS}" -C "$R/repo" --load-max 1000 --out "$R/out" --timeout 30 "$@"
}
swt() {  # swt <s> [options] -- <cmd...>: the queue never times out; an outer timeout of <s> s cuts it (rc 124)
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
shim() {  # shim <dir> <cmd...>: wrappers that log each call to <dir>/count and run the real command
  local d=$1 c; shift; mkdir -p "$d"
  for c in "$@"; do printf '#!/bin/bash\necho %s >> %q\nexec %q "$@"\n' "$c" "$d/count" "$(command -v "$c")" > "$d/$c"; chmod +x "$d/$c"; done
}
fake_head() {  # slot 1 held by a live owner that is not a test process, and <n> live tickets ahead of the next one
  mkdir -p "$Q" "$S1"; echo "f pid=1 since=x ticket=1000-1-f" > "$S1/owner"; touch -d '+1 min' "$S1/owner"
  local i; for ((i = 1; i <= $1; i++)); do touch -d '+1 min' "$Q/1000$(printf %03d "$i")-1-f$i"; done
}
SUMMARY='^ajs repo rc=0 [0-9:]{8}->[0-9:]{8} load1 [0-9.]+->[0-9.]+ Tests: 3 passed, 3 total \(output: .*\)$'
# Slot scenarios' command: "+ <name> <ns>" on entry and "- <name> <ns>" on exit, in $R/ev.
EV='echo "+ $1 $(date +%s%N)" >> "$0"; sleep "$2"; echo "- $1 $(date +%s%N)" >> "$0"'
started() { grep -q "^+ $1 " "$R/ev" 2>/dev/null; }
ev_at() { awk -v k="$1" -v n="$2" '$1 == k && $2 == n {print $3}' "$R/ev"; }
overlap() { [ "$(ev_at + "$2")" -lt "$(ev_at - "$1")" ] && [ "$(ev_at + "$1")" -lt "$(ev_at - "$2")" ]; }
first_end() { local x y; x=$(ev_at - "$1"); y=$(ev_at - "$2"); echo $((x < y ? x : y)); }
max_conc() { sort -k3,3n "$R/ev" | awk '{c += ($1 == "+") ? 1 : -1; if (c > m) m = c} END {print m + 0}'; }
acq_shim() {  # a mkdir that logs "<name> <slot>" each time a run takes a slot: the order of entry
  local d=$R/acq-bin real; real=$(command -v mkdir); mkdir -p "$d"
  cat > "$d/mkdir" <<EOF
#!/bin/bash
for a; do last=\$a; done
$real "\$@"; rc=\$?
if [ \$rc = 0 ]; then case \$last in "$D"/slot.*) echo "\$(tr '\\0' '\\n' < /proc/\$PPID/cmdline | sed -n '/^-n\$/{n;p;q}') \${last##*/}" >> "$R/acq" ;; esac; fi
exit \$rc
EOF
  chmod +x "$d/mkdir"; export PATH="$d:$PATH"
}
acq_order() { cut -d' ' -f1 "$R/acq" 2>/dev/null | tr '\n' ' '; }
mem_set() {  # mem_set <MemAvailable kB> <SwapTotal kB> <SwapFree kB>
  printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$@" > "$R/meminfo.new"; mv -f "$R/meminfo.new" "$R/meminfo"
}
psi_set() { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$1" > "$R/pressure.new"; mv -f "$R/pressure.new" "$R/pressure"; }
load_set() { printf '%s %s %s 1/100 1\n' "$1" "$1" "$1" > "$R/loadavg.new"; mv -f "$R/loadavg.new" "$R/loadavg"; }
not_root() { [ "$(id -u)" != 0 ]; }

t_summary_line() {
  fresh; out=$(sw -n a -- sh -c 'echo "Tests: 3 passed, 3 total"'); rc=$?
  check summary-line-and-clean-queue '[ $rc = 0 ] && [[ $out =~ $SUMMARY ]] && [ "$(wc -l <<<"$out")" = 1 ] && [ -z "$(ls -A "$Q")" ] && [ ! -e "$S1" ] && [ ! -e "$LOG" ]'
  sw -n a --append-to "$R/journal" -- sh -c 'exit 7' > "$R/b.out"; rc=$?
  check command-rc-and-append-to '[ $rc = 7 ] && grep -q " rc=7 .* no test summary " "$R/b.out" && grep -Eq "^[0-9-]{10} [0-9:]{8} a: ajs repo rc=7 " "$R/journal"'
  sw -n a -- sh -c 'echo "Tests: 1 failed, 3 total"; echo "   Tests:  2 passed, 3 total"; echo trailing' > "$R/c.out"
  check summary-is-the-last-matching-line-trimmed 'grep -Eq "load1 [0-9.]+->[0-9.]+ Tests:  2 passed, 3 total \(output: " "$R/c.out"'
  AJS_SUMMARY_REGEX='^=+ [0-9]+ passed' sw -n a -- sh -c 'echo "===== 5 passed in 0.12s ====="' > "$R/p.out"
  check summary-regex-is-configurable 'grep -q " ===== 5 passed in 0.12s ===== (output: " "$R/p.out"'
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
  rm -f "$Q"; : > "$S1"
  swt 10 -n a -- touch "$R/ran5" > /dev/null 2> "$R/e5"; rc=$?
  check slot-that-is-a-file-rc78 '[ $rc = 78 ] && [ ! -e "$R/ran5" ] && grep -q "slot.1 is not a directory" "$R/e5"'
  rm -f "$S1"
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

t_slot_turned_file_at_take_time() {  # the slot path becomes a file between the check and the mkdir
  fresh; mkdir -p "$R/mkdir-shim"
  printf '#!/bin/bash\nfor a in "$@"; do\n  if [ "$a" = %q ]; then : > %q; exit 1; fi\ndone\nexec %q "$@"\n' "$S1" "$S1" "$(command -v mkdir)" > "$R/mkdir-shim/mkdir"
  chmod +x "$R/mkdir-shim/mkdir"
  PATH="$R/mkdir-shim:$PATH" swt 8 -n a --timeout 3 -- touch "$R/ran" > /dev/null 2> "$R/e"; rc=$?
  check slot-turned-file-at-take-time-rc78-without-running '[ $rc = 78 ] && [ ! -e "$R/ran" ] && grep -q "slot.1 is not a directory" "$R/e"'
}

t_settings_out_of_range_are_refused() {  # every AJS_* value is checked before anything is written
  fresh; local spec i=0
  for spec in AJS_SLOTS=0 AJS_SLOTS=17 AJS_SLOTS=x AJS_BEAT=0 AJS_STALE=2 AJS_POLL=0 AJS_GATE_POLL=0 \
    AJS_NOTICE_AFTER=0 AJS_MEM_MIN_MIB=-1 AJS_MEM_ROOMY_MIB=x AJS_SWAP_RESERVE_MIB=1.5 AJS_PSI_MAX=1.5 \
    AJS_JEST_WORKERS=x AJS_LOAD_MAX=0 AJS_LOAD_MAX=abc; do
    i=$((i + 1)); timeout 20 env "$spec" "$AJS" -C "$R/repo" --out "$R/out" -- touch "$R/ran-$i" > /dev/null 2> "$R/s$i.err"; rc=$?
    check "setting-$spec-refused-rc78" "[ \$rc = 78 ] && [ ! -e '$R/ran-$i' ] && grep -qF '${spec%%=*}' '$R/s$i.err' && [ ! -e '$D' ]"
  done
  for spec in AJS_SLOTS=1 AJS_SLOTS=2 AJS_SLOTS=16 AJS_LOAD_MAX=2.5; do
    timeout 20 env "$spec" "$AJS" -C "$R/repo" --out "$R/out" -- true > /dev/null 2>&1; rc=$?
    check "setting-$spec-accepted" '[ $rc = 0 ]'
  done
}

t_usage_errors() {
  fresh; local i=0 args
  for args in '--timeout x' '--load-max 0' '--dir /nonexistent-ajs-dir' '--bogus' '-n'; do
    i=$((i + 1))
    # shellcheck disable=SC2086
    timeout 20 "$AJS" $args -- touch "$R/ran-$i" > /dev/null 2> "$R/u$i.err"; rc=$?
    check "usage-error-${args%% *}-rc2" "[ \$rc = 2 ] && [ ! -e '$R/ran-$i' ] && [ ! -e '$D' ]"
  done
  "$AJS" -C "$R/repo" > /dev/null 2>&1; rc=$?
  check usage-without-command-rc2 '[ $rc = 2 ] && [ ! -e "$D" ]'
  "$AJS" --help > "$R/help"; rc=$?
  check help-names-every-exit-code '[ $rc = 0 ] && grep -q "^  73 " "$R/help" && grep -q "^  75 " "$R/help" && grep -q "^  78 " "$R/help" && grep -q "^  130/143 " "$R/help"'
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
  fresh; bg x x -- sleep 3; until_ 5 '[ -d "$S1" ]'; tk=$(ls "$Q")
  t0=$(date +%s%N); sw -n x -- touch "$R/second-ran" > /dev/null 2> "$R/dup.err"; rc=$?; ms=$((($(date +%s%N) - t0) / 1000000))
  check one-ticket-per-name-second-exits-73-at-once '[ $rc = 73 ] && [ $ms -lt 2000 ] && [ ! -e "$R/second-ran" ] && [ "$(ls "$Q")" = "$tk" ] && grep -qF "$tk" "$R/dup.err"'
  check one-ticket-per-name-leaves-the-first-alone '[ "$(rc_of x)" = 0 ] && [ -z "$(ls -A "$Q")" ]'
}

t_duplicate_name_race() {  # five processes with one name start together after a barrier
  fresh; bg z z -- sleep 2; until_ 5 '[ -d "$S1" ]'
  for i in 1 2 3 4 5; do
    { until [ -e "$R/go" ]; do sleep 0.01; done; sw -n y -- sh -c 'echo y >> "$0"' "$R/runs" > /dev/null 2>&1; echo $? > "$R/y$i.rc"; } &
    kids+=($!)
  done
  sleep 0.3; touch "$R/go"
  for i in 1 2 3 4 5; do rc_of "y$i" 15 > /dev/null; done
  rcs=$(cat "$R"/y?.rc | sort | tr '\n' ' ')
  check one-ticket-per-name-race-lets-one-through '[ "$rcs" = "0 73 73 73 73 " ] && [ "$(wc -l < "$R/runs")" = 1 ]'
}

t_fifo() {
  fresh; bg z z -- sleep 2; until_ 5 '[ -d "$S1" ]'
  for n in a b c; do bg "$n" "$n" -- sh -c 'echo "$1" >> "$0"' "$R/order" "$n"; queued "$n"; done
  for n in a b c; do rc_of "$n" 20 > /dev/null; done
  check fifo-order-kept '[ "$(rcs a b c)" = 000 ] && [ "$(tr "\n" " " < "$R/order")" = "a b c " ] && [ ! -e "$LOG" ]'
}

t_sigkill_owner() {  # real SIGKILL to the slot owner: its ticket and its slot are reaped
  fresh; bg k k -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/k.child"; until_ 5 '[ -s "$R/k.child" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  kp=$(pid_of k); kill -9 "$kp"; kill -9 "$(cat "$R/k.child")"
  check sigkill-owner-reaps-ticket-and-slot '[ "$(rc_of w 20)" = 0 ] && grep -qx w "$R/order" && grep -Eq "reaps dead ticket [0-9]+-$kp-k " "$LOG" && grep -q "reaps orphaned slot 1 (k pid=$kp " "$LOG" && [ -z "$(ls -A "$Q")" ] && [ ! -e "$S1" ]'
}

t_signals_free_the_slot() {  # TERM and INT stop the command, free the slot and leave the queue
  fresh; bg k k -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/k.child"; until_ 5 '[ -s "$R/k.child" ] && [ -s "$S1/owner" ]'
  kp=$(pid_of k); kill -TERM "$kp"
  check term-exits-143-stops-command-and-frees-slot '[ "$(rc_of k 10)" = 143 ] && ! kill -0 "$(cat "$R/k.child")" 2>/dev/null && [ ! -e "$S1" ] && [ -z "$(ls -A "$Q")" ]'
  # A background job starts with SIGINT ignored; perl resets it as a foreground terminal would.
  { perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' "$AJS" -C "$R/repo" --load-max 1000 --out "$R/out" -n i -- \
      sh -c 'echo $$ > "$0"; exec sleep 60' "$R/i.child" > /dev/null 2>&1; echo $? > "$R/i.rc"; } &
  kids+=($!); until_ 5 '[ -s "$R/i.child" ] && [ -s "$S1/owner" ]'
  kill -INT "$(pid_of i)"
  check int-exits-130-stops-command-and-frees-slot '[ "$(rc_of i 10)" = 130 ] && ! kill -0 "$(cat "$R/i.child")" 2>/dev/null && [ ! -e "$S1" ] && [ -z "$(ls -A "$Q")" ]'
  bg h h -- sleep 4; until_ 5 '[ -d "$S1" ]'; bg w w -- touch "$R/w-ran"; queued w
  kill -TERM "$(pid_of w)"
  check term-while-queued-exits-143-and-leaves-the-queue '[ "$(rc_of w 10)" = 143 ] && [ ! -e "$R/w-ran" ] && ! ls "$Q" | grep -q -- "-w$" && [ "$(rc_of h 10)" = 0 ]'
}

t_dead_ticket_at_head() {  # a dead ticket at the head of the queue is reaped; a live slot is never touched
  fresh; fake_head 0; touch -d '+1 min' "$Q/1000-1-f"
  bg k k -- true; until_ 5 '[ "$(tickets)" = 2 ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 3 ]'
  kill -9 "$(pid_of k)"
  until_ 15 '! ls "$Q" | grep -q -- "-k$"'; sleep 2
  check live-slot-is-not-touched '[ "$(cat "$S1/owner")" = "f pid=1 since=x ticket=1000-1-f" ] && ! grep -q "orphaned" "$LOG"'
  rm -rf "$S1" "$Q/1000-1-f"
  check dead-ticket-at-head-is-reaped '[ "$(rc_of w 10)" = 0 ] && grep -qx w "$R/order" && grep -Eq "reaps dead ticket [0-9]+-[0-9]+-k " "$LOG" && [ -z "$(ls -A "$Q")" ]'
}

t_slot_without_owner() {  # died between mkdir and writing the owner: the dir is reaped by its own mtime
  fresh; mkdir -p "$S1"; touch -d '-1 min' "$S1"
  bg w w -- true
  check stale-slot-without-owner-is-reaped '[ "$(rc_of w 10)" = 0 ] && grep -q "reaps orphaned slot 1 (no owner)" "$LOG" && [ ! -e "$S1" ]'
}

t_slow_live_owner() {  # an owner three times longer than AJS_STALE, and a waiter that polls slower than that
  fresh; bg l l -- sh -c 'sleep 9; echo l-end >> "$0"' "$R/order"; until_ 5 '[ -d "$S1" ]'
  AJS_POLL=7 bg s s -- sh -c 'echo s >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"
  for n in l s w; do rc_of "$n" 30 > /dev/null; done
  check slow-live-owner-is-not-reaped '[ "$(rcs l s w)" = 000 ] && [ "$(tr "\n" " " < "$R/order")" = "l-end s w " ] && [ ! -e "$LOG" ]'
}

t_ticket_removed_from_live_waiter() {  # it returns to its place: the one behind does not overtake it
  fresh; bg z z -- sleep 3; until_ 5 '[ -d "$S1" ]'
  bg w1 w1 --timeout 15 -- sh -c 'echo w1 >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  bg w2 w2 -- sh -c 'echo w2 >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 3 ]'
  tw1=$(ls "$Q" | grep -- '-w1$'); rm -f "$Q"/*-w1
  check removed-ticket-of-live-waiter-returns-to-its-place '[ "$(rc_of w1 20)" = 0 ] && [ "$(rc_of w2 20)" = 0 ] && [ "$(tr "\n" " " < "$R/order")" = "w1 w2 " ] && grep -q "w1 lost its ticket while alive; back in its place as $tw1" "$LOG"'
}

t_ticket_removed_from_live_owner() {  # the slot's heartbeat is its owner file: without a ticket the owner stays
  fresh; bg h h -- sh -c 'sleep 6; echo h-end >> "$0"' "$R/order"; until_ 5 '[ -d "$S1" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 2 ]'
  rm -f "$Q"/*-h
  for n in h w; do rc_of "$n" 20 > /dev/null; done
  check removed-ticket-of-live-owner-keeps-the-slot '[ "$(rcs h w)" = 00 ] && [ "$(tr "\n" " " < "$R/order")" = "h-end w " ] && ! grep -qs slot "$LOG"'
}

t_slot_moved_while_live() {  # between reading a stale owner and the mv, another process took a fresh slot
  fresh; mkdir -p "$S1"; echo "k pid=5 since=x ticket=1-5-k" > "$S1/owner"; touch -d '-1 min' "$S1/owner"
  mkdir -p "$R/swap"; cat > "$R/swap/mv" <<EOF
#!/bin/bash
for a; do last=\$a; done
if [[ \$last == "$D/.reaped-slot.1-"* ]] && [ ! -e "$R/swap.done" ]; then
  : > "$R/swap.done"; rm -rf "$S1"; mkdir "$S1"; echo "other pid=9 since=x ticket=1-9-other" > "$S1/owner"; touch -d '+1 min' "$S1/owner"
fi
exec $(command -v mv) "\$@"
EOF
  chmod +x "$R/swap/mv"
  PATH=$R/swap:$PATH swt 5 -n w -- true > /dev/null 2>&1; rc=$?
  check slot-moved-while-live-is-given-back '[ -e "$R/swap.done" ] && [ $rc = 124 ] && grep -q "^other " "$S1/owner" && grep -q "gives back live slot 1 (other pid=9 " "$LOG" && ! grep -q "reaps orphaned" "$LOG"'
}

cost_run() {  # cost_run <n> [env...]: external calls of a waiter up to its 4th reaping pass, with <n> tickets ahead
  local n=$1; shift; fresh; fake_head "$n"; shim "$R/shim" date stat ls sort head basename cat touch sleep mv rm grep sed cut awk mkdir id nproc realpath tail
  printf '#!/bin/bash\n[ "$1 $2" = "-c %%Y %%n" ] && echo stat-batch >> %q || echo stat >> %q\nexec %q "$@"\n' \
    "$R/shim/count" "$R/shim/count" "$(command -v stat)" > "$R/shim/stat"
  env "$@" PATH="$R/shim:$PATH" timeout 30 "$AJS" -C "$R/repo" --load-max 1000 --out "$R/out" -n w -- true > /dev/null 2>&1 & local p=$!
  until_ 25 "[ \$(grep -c '^stat-batch\$' '$R/shim/count') -ge 4 ]"; kill "$p" 2>/dev/null; wait "$p"
  awk '$0 == "stat-batch" && ++k == 4 {print NR; f=1; exit} END {if (!f) print 0}' "$R/shim/count"
}

t_poll_cost() {  # what a waiter launches per pass does not grow with the queue; counted per pass, not per clock
  local n; local -A c
  for n in 5 25; do c[$n]=$(cost_run "$n" AJS_SLOTS=1); done
  echo "# cost: external calls up to the 4th pass with 5 tickets ${c[5]}, with 25 ${c[25]}"
  check poll-costs-the-same-with-5-or-25-tickets '[ ${c[5]} -gt 0 ] && [ $((${c[25]} - ${c[5]})) -lt 20 ]'
  for n in 5 25; do c[$n]=$(cost_run "$n" AJS_SLOTS=2); done
  echo "# cost with two slots: with 5 tickets ${c[5]}, with 25 ${c[25]}"
  check poll-with-two-slots-costs-the-same-with-5-or-25-tickets '[ ${c[5]} -gt 0 ] && [ $((${c[25]} - ${c[5]})) -lt 20 ]'
}

t_slow_newcomer() {  # its first stat takes longer than AJS_STALE: the heartbeat already runs
  fresh; bg h h -- sleep 8; until_ 5 '[ -d "$S1" ]'
  bg w w -- true; until_ 5 '[ "$(tickets)" = 2 ]'
  mkdir -p "$R/slow"; printf '#!/bin/bash\n[ -e %q ] || { : > %q; sleep 5; }\nexec %q "$@"\n' "$R/slow.done" "$R/slow.done" "$(command -v stat)" > "$R/slow/stat"; chmod +x "$R/slow/stat"
  PATH=$R/slow:$PATH bg n n -- true
  local x; for x in h w n; do rc_of "$x" 25 > /dev/null; done
  check slow-newcomer-keeps-its-ticket '[ -e "$R/slow.done" ] && [ "$(rcs h w n)" = 000 ] && ! grep -Eqs -- "-n |n lost" "$LOG"'
}

t_name_with_dead_ticket() {  # a dead ticket with my name does not send me away: it is reaped first
  fresh; mkdir -p "$Q"; touch -d '-1 min' "$Q/1-99-x"
  sw -n x -- true > /dev/null 2>&1; rc=$?
  check dead-ticket-with-my-name-does-not-count '[ $rc = 0 ] && grep -q "reaps dead ticket 1-99-x " "$LOG"'
}

t_cut_wait_keeps_ownerless_slot() {  # leaving the queue without a slot never removes one, even without owner
  fresh; mkdir -p "$S1"; touch -d '+1 min' "$S1"
  swt 3 -n w -- true > /dev/null 2>&1; rc=$?
  check fresh-slot-without-owner-is-not-reaped '! grep -qs "reaps orphaned" "$LOG"'
  check cut-wait-does-not-remove-an-ownerless-slot '[ $rc = 124 ] && [ -d "$S1" ] && ! grep -qs "lost slot" "$LOG"'
}

t_odd_owner_lines() {  # a stale owner with an empty ticket field, or none, is reaped like any orphan
  fresh; mkdir -p "$S1"; echo "k pid=5 since=x ticket=" > "$S1/owner"; touch -d '-1 min' "$S1/owner"
  swt 8 -n w -- true > /dev/null 2>&1; rc=$?
  check owner-with-empty-ticket-field-is-reaped '[ $rc = 0 ] && grep -q "reaps orphaned slot 1 (k pid=5 since=x ticket=)" "$LOG"'
  fresh; mkdir -p "$S1"; echo "hand-made lock" > "$S1/owner"; touch -d '-1 min' "$S1/owner"
  swt 8 -n w -- true > /dev/null 2>&1; rc=$?
  check owner-without-ticket-field-is-reaped '[ $rc = 0 ] && grep -q "reaps orphaned slot 1 (hand-made lock)" "$LOG"'
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

t_first_given_up_for_dead() {  # its ticket is removed between reading a stale owner and the mv: it does not move it
  fresh; mkdir -p "$S1"; echo "k pid=5 since=x ticket=1-5-k" > "$S1/owner"; touch -d '-1 min' "$S1/owner"
  mkdir -p "$R/st"; cat > "$R/st/stat" <<EOF
#!/bin/bash
for a; do :; done
[ "\$a" = "$S1/owner" ] && [ ! -e "$R/st.done" ] && { : > "$R/st.done"; rm -f "$Q"/*-w; }
exec $(command -v stat) "\$@"
EOF
  chmod +x "$R/st/stat"
  PATH=$R/st:$PATH sw -n w -- true > /dev/null 2>&1; rc=$?
  check first-given-up-for-dead-does-not-reap-the-slot '[ -e "$R/st.done" ] && [ $rc = 0 ] && [ "$(grep -o -m1 -e "lost its ticket" -e "reaps orphaned" "$LOG")" = "lost its ticket" ]'
}

t_queue_has_no_limit() {  # a ticket with a heartbeat waits its turn beyond --timeout and keeps its place
  fresh; bg h h -- sleep 6; until_ 5 '[ -d "$S1" ]'
  bg w w --timeout 2 -- sh -c 'echo w >> "$0"' "$R/order"; queued w
  bg b b -- sh -c 'echo b >> "$0"' "$R/order"; queued b
  check queue-has-no-limit '[ "$(rc_of w 30)$(rc_of b 30)$(rc_of h 30)" = 000 ] && [ "$(tr "\n" " " < "$R/order")" = "w b " ]'
}

t_gate_counts_from_arrival() {  # --timeout measures the gate from when the slot reaches it, not from the queue
  # Gate polls at G, G+6 and G+12; load drops at G+8: an 8 s limit from G holds, one from the queue (>= 6 s earlier) would not.
  fresh; bg h h -- sh -c 'touch "$0"; sleep 6' "$R/h.go"; until_ 10 '[ -e "$R/h.go" ]'
  load_set 9.00; bg w w --load-max 4 --timeout 8 -- true; until_ 20 '[ -e "$S1/gate" ]'; sleep 8; load_set 0.50
  check gate-timeout-counts-from-arrival '[ "$(rc_of w 20)" = 0 ]'
  rc_of h > /dev/null
}

t_notice_names_the_ticket() {  # after AJS_NOTICE_AFTER, the exact rm that frees a dead owner's slot
  fresh; bg h h -- sleep 8; until_ 5 '[ -d "$S1" ]'; th=$(ls "$Q")
  AJS_NOTICE_AFTER=2 swt 5 -n w -- true > /dev/null 2> "$R/w.err"; rc=$?
  check notice-names-the-owner-ticket '[ $rc = 124 ] && grep -qF "rm -rf '\''$S1'\'' '\''$Q/$th'\''" "$R/w.err"'
  rc_of h > /dev/null
}

t_foreign_slot_at_release() {  # if the slot is no longer mine when done, I do not remove it
  fresh; bg h h -- sleep 2; until_ 5 '[ -s "$S1/owner" ]'
  rm -rf "$S1"; mkdir "$S1"; echo "other pid=9 since=x ticket=1-9-other" > "$S1/owner"
  check foreign-slot-survives-release '[ "$(rc_of h 10)" = 0 ] && grep -q "^other " "$S1/owner"'
  check lost-slot-warns-of-overlap 'grep -q "lost slot 1 while running" "$R/h.err" && grep -q "h lost slot 1 while running" "$LOG"'
}

fake_runners() {  # <dir>/{jest,vitest,npx,pnpm,vitest-part.sh}: print their args; the wrapper sets its own workers
  local d=$1 c; mkdir -p "$d"
  for c in jest vitest; do printf '#!/bin/bash\necho "args: $*"\necho "Tests: 1 passed, 1 total"\n' > "$d/$c"; done
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

t_two_slots_by_default() {  # without AJS_SLOTS: two at once; the third starts when one leaves
  fresh; unset AJS_SLOTS
  for n in a b c; do bg "$n" "$n" -- sh -c "$EV" "$R/ev" "$n" 3; queued "$n"; done
  for n in a b c; do rc_of "$n" 30 > /dev/null; done
  check two-slots-run-together-by-default '[ "$(rcs a b c)" = 000 ] && overlap a b'
  check third-waits-for-a-free-slot '[ "$(max_conc)" = 2 ] && [ "$(ev_at + c)" -ge "$(first_end a b)" ] && [ ! -e "$S1" ] && [ ! -e "$S2" ] && [ -z "$(ls -A "$Q")" ] && [ ! -e "$LOG" ]'
}

t_two_slots_fifo_with_a_slow_poller() {  # the freed slot goes to the oldest ticket even if it polls every 7 s
  fresh; export AJS_SLOTS=2; acq_shim
  bg z1 z1 -- sleep 6; until_ 5 '[ -d "$S1" ]'
  bg z2 z2 -- sleep 2; until_ 5 '[ -d "$S2" ]'
  AJS_POLL=7 bg a a -- sh -c "$EV" "$R/ev" a 1; queued a
  bg b b -- sh -c "$EV" "$R/ev" b 1; queued b
  for n in z1 z2 a b; do rc_of "$n" 30 > /dev/null; done
  check two-slots-fifo-free-slot-goes-to-the-oldest '[ "$(rcs z1 z2 a b)" = 0000 ] && [ "$(acq_order)" = "z1 z2 a b " ]'
}

t_dead_slot_two_is_reaped() {  # SIGKILL to the owner of slot 2: its ticket and slot are reaped and the next enters
  fresh; export AJS_SLOTS=2
  bg z z -- sh -c "$EV" "$R/ev" z 12; until_ 5 'started z'
  bg k k -- sh -c 'echo $$ > "$0"; exec sleep 60' "$R/k.child"; until_ 5 '[ -s "$R/k.child" ] && [ -d "$S2" ]'
  bg w w -- sh -c "$EV" "$R/ev" w 0; until_ 5 '[ "$(tickets)" = 3 ]'
  kp=$(pid_of k); kill -9 "$kp"; kill -9 "$(cat "$R/k.child")"
  rc_of w 20 > /dev/null; rc_of z 20 > /dev/null
  check dead-slot-is-reaped-and-the-next-enters '[ "$(rcs w z)" = 00 ] && [ "$(ev_at + w)" -lt "$(ev_at - z)" ] && grep -Eq "reaps dead ticket [0-9]+-$kp-k " "$LOG" && grep -q "reaps orphaned slot 2 (k pid=$kp " "$LOG" && [ ! -e "$S2" ]'
}

t_slot_with_live_ticket_is_kept() {  # a stale owner file whose ticket still beats belongs to a live process
  fresh; export AJS_SLOTS=2; mkdir -p "$Q" "$S1" "$S2"
  echo "f1 pid=1 since=x ticket=1000-1-f1" > "$S1/owner"; touch -d '+1 min' "$S1/owner" "$Q/1000-1-f1"
  echo "f2 pid=2 since=x ticket=1001-2-f2" > "$S2/owner"; touch -d '-1 min' "$S2/owner"; touch -d '+1 min' "$Q/1001-2-f2"
  AJS_NOTICE_AFTER=2 swt 5 -n w -- true > /dev/null 2> "$R/w.err"; rc=$?
  check slot-with-live-ticket-is-not-reaped '[ $rc = 124 ] && [ "$(cat "$S2/owner")" = "f2 pid=2 since=x ticket=1001-2-f2" ] && ! grep -qs "reaps orphaned" "$LOG"'
  check notice-names-each-slot-and-its-ticket 'grep -qF "waiting for a slot held by slot.1: f1 pid=1 since=x ticket=1000-1-f1; slot.2: f2 pid=2 since=x ticket=1001-2-f2 for " "$R/w.err" && grep -qF "rm -rf '\''$S1'\'' '\''$Q/1000-1-f1'\'' '\''$S2'\'' '\''$Q/1001-2-f2'\''  (queue: " "$R/w.err"'
}

t_slot_two_ticket_removed_stays() {  # slot 2's heartbeat is its owner file: without a ticket its live owner stays
  fresh; export AJS_SLOTS=2
  bg z z -- sleep 10; until_ 5 '[ -d "$S1" ]'
  bg h h -- sh -c 'sleep 6; echo h-end >> "$0"' "$R/order"; until_ 5 '[ -d "$S2" ]'
  bg w w -- sh -c 'echo w >> "$0"' "$R/order"; until_ 5 '[ "$(tickets)" = 3 ]'
  rm -f "$Q"/*-h
  for n in h w z; do rc_of "$n" 25 > /dev/null; done
  check slot-two-without-ticket-keeps-its-owner '[ "$(rcs h w z)" = 000 ] && [ "$(tr "\n" " " < "$R/order")" = "h-end w " ] && ! grep -qs slot "$LOG"'
}

t_fewer_slots_session_sees_every_slot() {  # a session with AJS_SLOTS=1 still counts a holder of slot 2 as served
  fresh; mkdir -p "$Q" "$S2"
  echo "f pid=1 since=x ticket=1000-1-f" > "$S2/owner"; touch -d '+1 min' "$S2/owner" "$Q/1000-1-f"
  AJS_SLOTS=1 swt 8 -n w -- true > /dev/null 2>&1; rc=$?
  check fewer-slots-session-sees-every-slot '[ $rc = 0 ] && [ -d "$S2" ] && [ ! -e "$S1" ]'
}

t_memory_gate_per_slot() {  # alone it never waits for memory; the second waits for RAM, for swap when RAM is low, and for PSI
  fresh; export AJS_SLOTS=2; mem_set 1048576 0 0; psi_set 50.00
  sw -n solo -- sh -c "$EV" "$R/ev" solo 0 > /dev/null 2>&1; rc=$?
  check memory-gate-never-stops-the-first '[ $rc = 0 ] && started solo'
  psi_set 0.00; bg z z -- sh -c "$EV" "$R/ev" z 26; until_ 5 'started z'
  bg w w -- sh -c "$EV" "$R/ev" w 0; until_ 5 '[ -e "$S2/gate" ]'
  sleep 3; started w && low=no || low=yes
  mem_set 6291456 8388608 1048576; sleep 7; started w && swap=no || swap=yes
  mem_set 16777216 8388608 8388608; psi_set 25.00; sleep 7; started w && psi=no || psi=yes
  mem_set 16777216 8388608 1048576; psi_set 9.99; rc_of w 20 > /dev/null; rc_of z 35 > /dev/null
  check memory-gate-stops-the-second '[ "$low" = yes ]'
  check swap-gate-stops-the-second '[ "$swap" = yes ]'
  check psi-gate-stops-the-second '[ "$psi" = yes ]'
  check memory-gate-opens-when-there-is-room '[ "$(rcs w z)" = 00 ] && [ "$(ev_at + w)" -lt "$(ev_at - z)" ] && [ ! -e "$S2" ]'
  check used-swap-with-roomy-ram-does-not-stop '[ "$(rcs w z)" = 00 ] && [ "$(ev_at + w)" -lt "$(ev_at - z)" ]'
}

t_memory_timeout_names_the_measure() {
  fresh; export AJS_SLOTS=2; mem_set 1048576 0 0
  bg z z -- sleep 9; until_ 5 '[ -d "$S1" ]'
  sw -n x --timeout 2 -- true > /dev/null 2> "$R/x.err"; rc=$?
  check memory-timeout-rc75-with-the-measure '[ $rc = 75 ] && grep -qF "agent-job-semaphore: no memory for another slot (MemAvailable 1024 MiB, minimum 4096; SwapFree 0 MiB, reserve 0 below 8192; PSI some avg10 0.00, maximum 10) after" "$R/x.err" && [ ! -e "$S2" ]'
  rc_of z 15 > /dev/null
}

t_memory_thresholds_are_configurable() {
  fresh; export AJS_SLOTS=2; mem_set 1048576 0 0
  bg z z -- sleep 15; until_ 5 '[ -d "$S1" ]'
  AJS_MEM_MIN_MIB=512 sw -n x --timeout 2 -- true > /dev/null 2>&1; rc=$?
  check memory-minimum-is-configurable '[ $rc = 0 ]'
  mem_set 16777216 8388608 8388608; psi_set 5.00
  AJS_PSI_MAX=3 sw -n y --timeout 2 -- true > /dev/null 2> "$R/y.err"; rc=$?
  check psi-maximum-is-configurable '[ $rc = 75 ] && grep -qF "PSI some avg10 5.00, maximum 3" "$R/y.err"'
  rc_of z 25 > /dev/null
}

t_two_at_their_gates_do_not_deadlock() {  # a slot waiting at its gate counts only for later arrivals
  fresh; export AJS_SLOTS=2; mem_set 1048576 0 0; load_set 50.00
  bg a a --load-max 4 --timeout 25 -- sh -c "$EV" "$R/ev" a 2; until_ 5 '[ -e "$S1/gate" ]'
  bg b b --load-max 4 --timeout 25 -- sh -c "$EV" "$R/ev" b 0; until_ 5 '[ -e "$S2/gate" ]'
  load_set 1.00
  rc_of a 30 > /dev/null; rc_of b 30 > /dev/null
  check two-at-their-gates-do-not-deadlock '[ "$(rcs a b)" = 00 ]'
  check second-waits-for-memory-while-the-first-runs '[ "$(ev_at + b)" -ge "$(ev_at - a)" ]'
}

t_foreign_load_counts_only_running_slots() {  # outside load between one and two budgets, nothing running: nobody starts
  fresh; export AJS_SLOTS=2; acq_shim; load_set 5.00
  # The first polls its gate every 15 s and the second every 6: without the line at the gate, the second would pass first.
  AJS_GATE_POLL=15 bg a a --load-max 4 -- sh -c "$EV" "$R/ev" a 3; until_ 5 '[ -e "$S1/gate" ]'
  bg b b --load-max 4 -- sh -c "$EV" "$R/ev" b 0; until_ 5 '[ -e "$S2/gate" ]'
  sleep 3; started a || started b && nobody=no || nobody=yes
  low=$(date +%s%N); load_set 1.00
  rc_of a 40 > /dev/null; rc_of b 40 > /dev/null
  check foreign-load-with-two-slots-and-none-running-nobody-starts '[ "$nobody" = yes ]'
  check foreign-load-drops-and-they-start-in-queue-order '[ "$(rcs a b)" = 00 ] && [ "$(acq_order)" = "a b " ] && [ "$(ev_at + a)" -gt "$low" ] && [ "$(ev_at + a)" -lt "$(ev_at + b)" ]'
}

t_dead_at_its_gate() {  # silent while at its gate: it neither loads the machine nor holds back later ones
  fresh; export AJS_SLOTS=2; mkdir -p "$Q" "$S1"; : > "$S1/gate"
  echo "m pid=1 since=x ticket=1000-1-m" > "$S1/owner"; touch -d '-1 min' "$S1/owner" "$S1/gate" "$S1"; load_set 5.00
  bg w w --load-max 4 --timeout 15 -- sh -c "$EV" "$R/ev" w 0; until_ 5 '[ -e "$S2/gate" ]'
  sleep 3; started w && load=no || load=yes
  load_set 1.00; rc_of w 25 > /dev/null
  check dead-at-its-gate-does-not-count-for-load '[ "$load" = yes ]'
  check dead-at-its-gate-does-not-hold-back-the-next '[ "$(rcs w)" = 0 ] && started w'
}

t_slot_marks_its_gate_before_its_owner() {  # whoever reads a freshly taken slot's owner already sees its gate
  fresh; export AJS_SLOTS=2; load_set 5.00
  sed -E 's/(> "\$slot\/owner")$/\1; sleep 4/' "$AJS" > "$R/owner-slow" && chmod +x "$R/owner-slow" &&
    grep -q '> "$slot/owner"; sleep 4$' "$R/owner-slow" || { ko gate-before-owner-instrument 'no slow-owner copy'; return; }
  AJS_OVERRIDE=$R/owner-slow bg a a --load-max 4 --timeout 20 -- sh -c "$EV" "$R/ev" a 0; until_ 5 '[ -s "$S1/owner" ]'
  bg b b --load-max 4 --timeout 20 -- sh -c "$EV" "$R/ev" b 0; until_ 5 '[ -e "$S2/gate" ]'
  sleep 2; started b && early=yes || early=no
  load_set 1.00; rc_of a 30 > /dev/null; rc_of b 30 > /dev/null
  check slot-at-its-gate-does-not-look-running-after-its-owner '[ "$early" = no ] && [ "$(rcs a b)" = 00 ]'
}

t_load_per_slot() {  # alone, load1 < budget; with another slot running, < budget per busy slot
  fresh; export AJS_SLOTS=2; load_set 6.00
  sw -n x --load-max 4 --timeout 2 -- true > /dev/null 2> "$R/x.err"; rc=$?
  check load-with-one-slot-uses-one-budget '[ $rc = 75 ] && grep -qF "agent-job-semaphore: load1 6.00 >= 4 after" "$R/x.err"'
  load_set 1.00; bg z z --load-max 4 -- sh -c "$EV" "$R/ev" z 22; until_ 5 'started z'
  load_set 6.00; sw -n w --load-max 4 -- sh -c "$EV" "$R/ev" w 0 > /dev/null 2>&1; rc=$?
  check load-per-slot-lets-the-second-in '[ $rc = 0 ] && started w && ! grep -q "^- z " "$R/ev"'
  load_set 9.00; sw -n y --load-max 4 --timeout 2 -- true > /dev/null 2> "$R/y.err"; rc=$?
  check load-per-slot-stops-above-two-budgets '[ $rc = 75 ] && grep -qF "agent-job-semaphore: load1 9.00 >= 8 (4 per slot, 2 slots) after" "$R/y.err"'
  load_set 1.00; sw -n v --load-max 0.5 --timeout 2 -- true > /dev/null 2> "$R/v.err"; rc=$?
  check fractional-load-budget '[ $rc = 75 ] && grep -qF "load1 1.00 >= 1 (0.50 per slot, 2 slots) after" "$R/v.err"'
  rc_of z 30 > /dev/null
}

t_unreadable_loadavg_holds_the_gate() {  # a load that cannot be read never counts as low
  fresh; export AJS_LOADAVG_FILE=$R/missing
  sw -n x --timeout 1 -- touch "$R/ran" > /dev/null 2> "$R/x.err"; rc=$?
  check unreadable-loadavg-holds-the-gate '[ $rc = 75 ] && [ ! -e "$R/ran" ] && grep -qF "load1 ? >= 1000 after" "$R/x.err"'
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
