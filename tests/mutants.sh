#!/usr/bin/env bash
# shellcheck disable=SC2016  # perl programs go in single quotes
# Mutation harness: each mutant removes one rule and must turn its NAMED test in tests/run.sh to FAIL.
#   tests/mutants.sh                 every mutant, after a control run of the scenarios they use
#   MUT_ONLY=<regex>                 only mutants whose name matches
#   MUT_SHARD=<k>/<n>                only the k-th of n slices (1-based), to keep each run short
# The bench runs against decoy XDG and HOME dirs, so its canary can be seeded without touching real ones.
# SPDX-License-Identifier: Apache-2.0
set -u
here=$(cd "$(dirname "$0")" && pwd); src=$here/../agent-job-semaphore; bench=$here/run.sh
W=$(mktemp -d "${BENCH_TMP:-${TMPDIR:-/tmp}}/ajs-mut.XXXXXX") || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/decoy-runtime" "$W/decoy-state" "$W/decoy-home"
decoy_env=(XDG_RUNTIME_DIR="$W/decoy-runtime" XDG_STATE_HOME="$W/decoy-state" HOME="$W/decoy-home")
killed=0; alive=0; idx=0; selected=(); scenarios=()

# Mutant table: kind (script|bench), name, test that must fail, scenario, one perl substitution, [slurp].
M=()
m() { M+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"$'\x1f'"$5"$'\x1f'"${6:-line}"); }
m script duplicate-name one-ticket-per-name-second-exits-73-at-once t_duplicate_name 's/^  exit 73$/  :/'
m script yields-to-anyone one-ticket-per-name-race-lets-one-through t_duplicate_name_race 's/ && \$b < \$tb \]\]/ ]]/'
m script no-initial-reap dead-ticket-with-my-name-does-not-count t_name_with_dead_ticket 's/^reap_tickets$/:/'
m script no-ticket-reaping dead-ticket-at-head-is-reaped t_dead_ticket_at_head 's/\[ "\$t" != "\$ticket" \] && \[ \$\(\(now - m\)\) -gt "\$stale" \] \|\| continue/continue/'
m script stat-per-ticket poll-costs-the-same-with-5-or-25-tickets t_poll_cost 's/\[ \$\(\(now - m\)\) -gt "\$stale" \]/[ \$((now - \$(stat -c %Y -- "\$t"))) -gt "\$stale" ]/'
m script no-heartbeat slow-live-owner-is-not-reaped t_slow_live_owner 's/touch -c "\$ticket"; //'
m script late-heartbeat slow-newcomer-keeps-its-ticket t_slow_newcomer 's/^(enqueue\(\) \{ .*); beat_on; \}$/$1; sleep 5; beat_on; }/'
m script owner-without-heartbeat removed-ticket-of-live-owner-keeps-the-slot t_ticket_removed_from_live_owner 's/ && touch -c "\$s\/owner"//'
m script no-slot-reaping sigkill-owner-reaps-ticket-and-slot t_sigkill_owner 's/reap_slot "\$s" && \{ reaped=1; break; \}/:/'
m script no-give-back slot-moved-while-live-is-given-back t_slot_moved_while_live 's/^  if fresh_slot "\$moved"; then .*$//'
m script ignores-own-ticket first-given-up-for-dead-does-not-reap-the-slot t_first_given_up_for_dead 's/^  \[ -e "\$ticket" \] \|\| return 1 .*$//'
m script ownerless-never-reaped stale-slot-without-owner-is-reaped t_slot_without_owner 's/\[ -z "\$o" \] \|\| \[ -z "\$t" \]/[ -n "\$o" ] || return 1; [ -z "\$t" ]/'
m script empty-ticket-field-kept owner-with-empty-ticket-field-is-reaped t_odd_owner_lines 's/\[ -z "\$o" \] \|\| \[ -z "\$t" \] \|\| /[ -z "\$o" ] || /'
m script reaps-slot-with-live-ticket slot-with-live-ticket-is-not-reaped t_slot_with_live_ticket_is_kept 's/\[ ! -e "\$queue\/\$t" \] \|\| return 1/: || return 1/'
m script keeps-slot-whose-ticket-left sigkill-owner-reaps-ticket-and-slot t_sigkill_owner 's/ \|\| \[ ! -e "\$queue\/\$t" \] \|\| return 1/ || return 1/'
m script ownerless-by-owner-only fresh-slot-without-owner-is-not-reaped t_cut_wait_keeps_ownerless_slot 's/\[ -e "\$f" \] \|\| f=\$1; //'
m script release-without-held cut-wait-does-not-remove-an-ownerless-slot t_cut_wait_keeps_ownerless_slot 's/^  if \[ "\$held" -eq 1 \]; then$/  if true; then/'
m script no-requeue removed-ticket-of-live-waiter-returns-to-its-place t_ticket_removed_from_live_waiter 's/^  \[ -e "\$ticket" \] \|\| \{ beat_off;/  true || { beat_off;/'
m script requeue-at-the-end removed-ticket-of-live-waiter-returns-to-its-place t_ticket_removed_from_live_waiter 's/\{ beat_off; : > "\$ticket" 2>\/dev\/null \|\| refuse "cannot write a ticket"; beat_on; note/{ beat_off; enqueue; note/'
m script removes-foreign foreign-slot-survives-release t_foreign_slot_at_release 's/^mine\(\) \{ .*\}$/mine() { true; }/'
m script no-overlap-warning lost-slot-warns-of-overlap t_foreign_slot_at_release 's/note "lost \$\(slot_label/: "lost \$(slot_label/'
m script runs-without-slot slot-turned-file-at-take-time-rc78-without-running t_slot_turned_file_at_take_time 's/^      if \[ ! -e "\$s" \] && mkdir "\$s" 2>\/dev\/null; then/      if true; then/'
m script slot-type-unchecked slot-that-is-a-file-rc78 t_unusable_lock_dir_is_refused 's/^      \[ ! -e "\$s" \] \|\| \[ -d "\$s" \] \|\| refuse .*$/      :/'
m script dir-type-unchecked lock-dir-that-is-a-file-rc78 t_unusable_lock_dir_is_refused 's/^\[ ! -e "\$dir" \] \|\| \[ -d "\$dir" \] \|\| refuse .*$/:/'
m script queue-type-unchecked queue-that-is-a-file-rc78 t_unusable_lock_dir_is_refused 's/^\[ ! -e "\$queue" \] \|\| \[ -d "\$queue" \] \|\| refuse .*$/:/'
m script dir-without-probe read-only-lock-dir-rc78 t_unusable_lock_dir_is_refused 's/^mkdir "\$probe" 2>\/dev\/null && rmdir "\$probe" 2>\/dev\/null \|\| refuse "cannot write in it"$/true/'
m script queue-without-probe read-only-queue-rc78 t_unusable_lock_dir_is_refused 's/^mkdir "\$probe" 2>\/dev\/null && rmdir "\$probe" 2>\/dev\/null \|\| refuse "cannot write in the queue"$/true/'
m script settings-without-ceiling setting-AJS_SLOTS=17-refused-rc78 t_settings_out_of_range_are_refused 's/ && \{ \[ -z "\$\{4:-\}" \] \|\| \[ "\$\(\(10#\$v\)\)" -le "\$4" \]; \}//'
m script settings-without-floor setting-AJS_BEAT=0-refused-rc78 t_settings_out_of_range_are_refused 's/is_uint "\$v" && \[ "\$\(\(10#\$v\)\)" -ge "\$3" \] &&/is_uint "\$v" \&\&/'
m script stale-not-above-beat setting-AJS_STALE=2-refused-rc78 t_settings_out_of_range_are_refused 's/^\[ "\$stale" -gt \$\(\(beat \* 2\)\) \] \|\| die 78 .*$/true/'
m script load-budget-zero-accepted setting-AJS_LOAD_MAX=0-refused-rc78 t_settings_out_of_range_are_refused 's/^loadmax_c=\$\(centi "\$loadmax"\) && \[ "\$loadmax_c" -gt 0 \] \|\| \{$/loadmax_c=\$(centi "\$loadmax") || {/'
m script fraction-dropped fractional-load-budget t_load_per_slot 's/local f=\$\{BASH_REMATCH\[3\]\}00/local f=00/'
m script name-unchecked bad-name-1-refused-rc2 t_bad_names_are_refused 's/^\[\[ \$name =~ .* \]\] \|\| die 2 .*$/:/'
m script out-default-in-tmp default-output-under-xdg-state-home t_default_output_dir 's/^    out=\$\{XDG_STATE_HOME:-\$HOME\/\.local\/state\}\/agent-job-semaphore\/\$name$/    out=\$\{TMPDIR:-\/tmp\}/'
m script explicit-out-ignored explicit-out-is-used t_default_output_dir 's/-o\|--out\) out=\$2 ;;/-o|--out) ;;/'
m script ajs-out-ignored ajs-out-is-used t_default_output_dir 's/out=\$\{AJS_OUT:-\}$/out=/'
m script no-home-warning without-home-warns-and-uses-tmpdir t_default_output_dir 's/neither XDG_STATE_HOME nor HOME is set/neither is set/'
m script lock-name-changed default-lock-dir-under-xdg-runtime-dir t_default_lock_dir 's/\/agent-job-semaphore\}$/\/ajs}/'
m script lock-dir-mode-open default-lock-dir-under-xdg-runtime-dir t_default_lock_dir 's/mkdir -p -m 700 "\$dir"/mkdir -p "\$dir"/'
m script ajs-dir-ignored ajs-dir-wins-over-xdg-runtime-dir t_default_lock_dir 's/^dir=\$\{AJS_DIR:-/dir=\$\{AJS_DIR_IGNORED:-/'
m script run-user-fallback-wrong default-lock-dir-under-run-user-uid t_default_lock_dir 's/:-\/run\/user\/\$uid\}/:-\/run\/user\/0\$uid}/'
m script lc-all-leaks command-gets-caller-path-variable-and-lc-all t_command_keeps_caller_environment 's/^  if \[ "\$caller_lc_set" = 1 \]; then .*$/  :/'
m script locale-collation tickets-sort-bytewise-under-any-locale t_tickets_sort_bytewise_under_any_locale 's/^LC_ALL=C$/:/'
m script ignores-dir command-runs-in-dir t_command_keeps_caller_environment 's/cd -- "\$workdir" && exec/exec/'
m script jest-by-wrapper-name wrapper-with-its-own-gets-no-other t_jest_workers 's/runner_is_jest_or_vitest "\$@"; then$/[[ "\$*" == *jest* || "\$*" == *vitest* ]]; then/'
m script jest-not-recognized jest-direct-gets-two-workers t_jest_workers 's/^(      jest\|jest\.js\|vitest\|vitest\.mjs\)) return 0 ;;$/$1 return 1 ;;/'
m script timeout-not-skipped vitest-after-timeout-gets-two-workers t_jest_workers 's/^      timeout\) i=\$\(\(i \+ 2\)\) ;;$/      timeout) return 1 ;;/'
m script npx-not-skipped jest-after-npx-gets-two-workers t_jest_workers 's/^      npx\|node\) i=/      npx|node) return 1; i=/'
m script pnpm-exec-not-skipped vitest-after-pnpm-exec-gets-two-workers t_jest_workers 's/^      pnpm\) \[ "\$\{a\[i \+ 1\]:-\}" = exec \] \|\| return 1; i=/      pnpm) return 1; i=/'
m script own-workers-doubled workers-set-by-the-caller-are-kept t_jest_workers 's/\*maxWorkers\*\|\*max-workers\*\) ;;/*maxWorkers*) ;;/'
m script workers-zero-ignored jest-workers-zero-disables t_jest_workers 's/\[ "\$jest_workers" -gt 0 \] && //'
m script workers-fixed jest-workers-is-configurable t_jest_workers 's/"--maxWorkers=\$jest_workers"/"--maxWorkers=2"/'
m script log-without-pid same-second-two-logs-with-distinct-names t_same_second_logs_do_not_clash 's/^log=(.*)-\$\$\.log$/log=$1.log/'
m script summary-untrimmed summary-is-the-last-matching-line-trimmed t_summary_line 's/^summary=\$\{summary#.*$/:/'
m script summary-first-match summary-is-the-last-matching-line-trimmed t_summary_line 's/\[\[ \$l =~ \$summary_re \]\] && summary=\$l/[[ \$l =~ \$summary_re ]] \&\& [ -z "\$summary" ] \&\& summary=\$l/'
m script summary-regex-fixed summary-regex-is-configurable t_summary_line 's/^summary_re=\$\{AJS_SUMMARY_REGEX:-/summary_re=\$\{AJS_SUMMARY_IGNORED:-/'
m script append-ignored command-rc-and-append-to t_summary_line 's/\[ -z "\$append" \] \|\| printf/true || printf/'
m script default-one-slot two-slots-run-together-by-default t_two_slots_by_default 's/env_uint AJS_SLOTS 2 1 16/env_uint AJS_SLOTS 1 1 16/'
m script slot-list-short two-slots-run-together-by-default t_two_slots_by_default 's/for \(\(k = 1; k <= nslots/for ((k = 2; k <= nslots/'
m script only-head-of-queue two-slots-run-together-by-default t_two_slots_by_default 's/^    \[\[ \$holders == \*" \$\{t##\*\/\} "\* \]\] \|\| return 1$/    return 1/'
m script overtakes-in-queue two-slots-fifo-free-slot-goes-to-the-oldest t_two_slots_fifo_with_a_slow_poller 's/^    \[\[ \$holders == \*" \$\{t##\*\/\} "\* \]\] \|\| return 1$/    :/'
m script holders-of-own-slots-only fewer-slots-session-sees-every-slot t_fewer_slots_session_sees_every_slot 's/^  for s in "\$dir"\/slot\.\*; do o=; \{ read -r o < "\$s\/owner"; \} 2>\/dev\/null; \[ "\$\{o##\* ticket=\}"/  for s in "\${slots[@]}"; do o=; { read -r o < "\$s\/owner"; } 2>\/dev\/null; [ "\${o##* ticket=}"/'
m script reaps-only-slot-1 dead-slot-is-reaped-and-the-next-enters t_dead_slot_two_is_reaped 's/reaped=0; for s in "\$\{slots\[@\]\}"; do reap_slot/reaped=0; for s in "\${slots[0]}"; do reap_slot/'
m script heartbeat-only-slot-1 slot-two-without-ticket-keeps-its-owner t_slot_two_ticket_removed_stays 's/for s in "\$\{slots\[@\]\}"; do owns/for s in "\${slots[0]}"; do owns/'
m script no-memory-gate memory-gate-stops-the-second t_memory_gate_per_slot 's/^  \[ "\$others" -eq 0 \] && return 0$/  return 0/'
m script memory-gate-even-alone memory-gate-never-stops-the-first t_memory_gate_per_slot 's/^  \[ "\$others" -eq 0 \] && return 0$//'
m script no-memory-minimum memory-gate-stops-the-second t_memory_gate_per_slot 's/\[ "\$avail" -ge "\$mem_min_kib" \] && //'
m script no-psi-gate psi-gate-stops-the-second t_memory_gate_per_slot 's/ &&\n    \{ \[ -z "\$psi" \] \|\| \[ "\$\{psi%\.\*\}" -lt "\$psi_max" \]; \}//' slurp
m script no-swap-reserve swap-gate-stops-the-second t_memory_gate_per_slot 's/\{ \[ "\$stotal" -eq 0 \] \|\| \[ "\$avail" -ge "\$mem_roomy_kib" \] \|\| \[ "\$sfree" -gt "\$reserve" \]; \}/true/'
m script swap-always used-swap-with-roomy-ram-does-not-stop t_memory_gate_per_slot 's/ \|\| \[ "\$avail" -ge "\$mem_roomy_kib" \]//'
m script memory-minimum-fixed memory-minimum-is-configurable t_memory_thresholds_are_configurable 's/mem_min_kib=\$\(\(v \* 1024\)\)/mem_min_kib=4194304/'
m script psi-maximum-fixed psi-maximum-is-configurable t_memory_thresholds_are_configurable 's/^psi_max=\$\(env_uint AJS_PSI_MAX 10 0\) \|\| exit 78$/psi_max=10/'
m script queue-with-limit queue-has-no-limit t_queue_has_no_limit 's/^  sleep "\$poll"; waited=\$\(\(SECONDS - start\)\)$/  [ "\$waited" -ge "\$timeout" ] \&\& exit 75; sleep "\$poll"; waited=\$((SECONDS - start))/'
m script notice-without-escape notice-names-the-owner-ticket t_notice_names_the_ticket 's/"\$\(escape\)"/"(the slot and its ticket)"/'
m script notice-after-fixed notice-names-the-owner-ticket t_notice_names_the_ticket 's/^notice_after=\$\(env_uint AJS_NOTICE_AFTER 300 1\) \|\| exit 78$/notice_after=300/'
m script gate-from-queue gate-timeout-counts-from-arrival t_gate_counts_from_arrival 's/waited=\$\(\(SECONDS - gstart\)\)/waited=\$((SECONDS - start))/'
m script gates-deadlock two-at-their-gates-do-not-deadlock t_two_at_their_gates_do_not_deadlock 's/\[\[ \$t < \$tb \]\] \|\| continue; //'
m script gate-backwards second-waits-for-memory-while-the-first-runs t_two_at_their_gates_do_not_deadlock 's/\[\[ \$t < \$tb \]\] \|\| continue;/[[ ! \$t < \$tb ]] || continue;/'
m script gate-not-cleared load-per-slot-lets-the-second-in t_load_per_slot 's/^rm -f "\$slot\/gate"$/:/'
m script load-unscaled load-per-slot-lets-the-second-in t_load_per_slot 's/\[ "\$a" -lt \$\(\(loadmax_c \* \(running \+ 1\)\)\) \]/[ "\$a" -lt "\$loadmax_c" ]/'
m script load-scaled-alone load-with-one-slot-uses-one-budget t_load_per_slot 's/\[ "\$a" -lt \$\(\(loadmax_c \* \(running \+ 1\)\)\) \]/[ "\$a" -lt \$((loadmax_c * 2)) ]/'
m script load-counts-waiters dead-at-its-gate-does-not-count-for-load t_dead_at_its_gate 's/\[ "\$a" -lt \$\(\(loadmax_c \* \(running \+ 1\)\)\) \]/[ "\$a" -lt \$((loadmax_c * (others + 1))) ]/'
m script unreadable-load-passes unreadable-loadavg-holds-the-gate t_unreadable_loadavg_holds_the_gate 's/a=\$\(centi "\$\(load1\)"\) \|\| return 1;/a=\$(centi "\$(load1)") || return 0;/'
m script overtakes-at-gate foreign-load-drops-and-they-start-in-queue-order t_foreign_load_counts_only_running_slots 's/^  elif \[ -n "\$ahead" \]; then$/  elif false; then/'
m script dead-holds-gate dead-at-its-gate-does-not-hold-back-the-next t_dead_at_its_gate 's/fresh_slot "\$s" && ahead=\$o;/ahead=\$o;/'
m script gate-after-owner slot-at-its-gate-does-not-look-running-after-its-owner t_slot_marks_its_gate_before_its_owner 's/(      : > "\$slot\/gate" 2>\/dev\/null)\n(      printf [^\n]*> "\$slot\/owner")\n/$2\n$1\n/' slurp
m script term-not-forwarded term-exits-143-stops-command-and-frees-slot t_signals_free_the_slot 's/\[ "\$child" -gt 0 \] && kill -s TERM "\$child" 2>\/dev\/null; //'
m script abort-without-release term-exits-143-stops-command-and-frees-slot t_signals_free_the_slot 's/wait "\$child" 2>\/dev\/null; release; trap - EXIT;/wait "\$child" 2>\/dev\/null; trap - EXIT;/'
m script int-untrapped int-exits-130-stops-command-and-frees-slot t_signals_free_the_slot "s/^trap 'abort INT' INT\$/:/"
m script int-as-term int-exits-130-stops-command-and-frees-slot t_signals_free_the_slot 's/\[ "\$1" = INT \] && exit 130 \|\| exit 143/exit 143/'
m bench canary-seeded-lock real-default-dirs-untouched t_fifo 's/export AJS_DIR=\$D AJS_LOADAVG_FILE/export AJS_DIR=\$REAL_RUNTIME AJS_LOADAVG_FILE/'
m bench canary-seeded-output real-default-dirs-untouched t_fifo 's/--load-max 1000 --out "\$R\/out" --timeout 30 "\$@"/--load-max 1000 --out "\$REAL_STATE\/\$2" --timeout 30 "\$@"/'

count_subst() {  # how many substitutions an expression really makes
  local flag=-ne; [ "$3" = slurp ] && flag=-0ne
  MUT_EDIT=$1 perl "$flag" 'our $n; $n += eval $ENV{MUT_EDIT}; die $@ if $@; END { print $n // 0 }' "$2"
}
for entry in "${M[@]}"; do
  IFS=$'\x1f' read -r kind name want scenario edit mode <<< "$entry"
  idx=$((idx + 1))
  [[ $name =~ ${MUT_ONLY:-.} ]] || continue
  if [ -n "${MUT_SHARD:-}" ]; then k=${MUT_SHARD%/*}; n=${MUT_SHARD#*/}; [ $(((idx - 1) % n + 1)) = "$k" ] || continue; fi
  selected+=("$entry"); [[ " ${scenarios[*]} " == *" $scenario "* ]] || scenarios+=("$scenario")
done
[ "${#selected[@]}" -gt 0 ] || { echo "INVALID: no mutant selected"; exit 2; }
only="^($(IFS='|'; echo "${scenarios[*]}"))\$"
out=$(env "${decoy_env[@]}" ONLY="$only" "$bench" "$src" 2>/dev/null)
echo "CONTROL (unmutated, ${#scenarios[@]} scenarios): $(tail -n 1 <<< "$out")"
grep -q '^Tests: [0-9]* passed, 0 failed$' <<< "$out" || { grep '^FAIL ' <<< "$out"; echo "INVALID: the control is not green"; exit 1; }

for entry in "${selected[@]}"; do
  IFS=$'\x1f' read -r kind name want scenario edit mode <<< "$entry"
  target=$src; [ "$kind" = bench ] && target=$bench
  n=$(count_subst "$edit" "$target" "$mode")
  mutant=$W/mutant; [ "$kind" = bench ] && mutant=$W/run-mutant.sh
  if [ "$mode" = slurp ]; then perl -0pe "$edit" "$target" > "$mutant"; else perl -pe "$edit" "$target" > "$mutant"; fi
  chmod +x "$mutant"
  if [ "$n" != 1 ] || cmp -s "$target" "$mutant"; then echo "INVALID $name: substitutions=$n, expected 1"; alive=$((alive + 1)); continue; fi
  bash -n "$mutant" || { echo "INVALID $name: the mutant is not valid bash"; alive=$((alive + 1)); continue; }
  echo "MUTANT $name"; diff -u --label original --label mutant "$target" "$mutant" | sed -n '3,$p' | grep '^[-+]'
  rm -rf "$W/decoy-runtime" "$W/decoy-state"; mkdir -p "$W/decoy-runtime" "$W/decoy-state"
  if [ "$kind" = bench ]; then out=$(env "${decoy_env[@]}" ONLY="^$scenario\$" "$mutant" "$src" 2>/dev/null)
  else out=$(env "${decoy_env[@]}" ONLY="^$scenario\$" "$bench" "$mutant" 2>/dev/null); fi
  if grep -q "^FAIL $want\( \|\$\)" <<< "$out"; then killed=$((killed + 1)); echo "KILLED $name -> $want"
  else alive=$((alive + 1)); echo "ALIVE  $name: $want did not fail; failures: $(grep '^FAIL ' <<< "$out" | cut -d' ' -f2 | tr '\n' ' ')"; fi
done
echo "Mutants: $killed killed by their named test, $alive alive or invalid"
[ "$alive" = 0 ]
