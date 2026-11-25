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
m script no-ticket-reaping dead-ticket-is-reaped-and-live-window-is-not-touched t_dead_ticket_of_a_waiter 's/\[ "\$t" != "\$ticket" \] && \[ \$\(\(now - m\)\) -gt "\$stale" \] \|\| continue/continue/'
m script stat-per-ticket poll-costs-the-same-with-5-or-25-tickets t_poll_cost 's/\[ \$\(\(now - m\)\) -gt "\$stale" \]/[ \$((now - \$(stat -c %Y -- "\$t"))) -gt "\$stale" ]/'
m script no-heartbeat slow-live-owner-is-not-reaped t_slow_live_owner 's/touch -c "\$ticket"; //'
m script late-heartbeat slow-newcomer-keeps-its-ticket t_slow_newcomer 's/^(enqueue\(\) \{ .*); beat_on; \}$/$1; sleep 7; beat_on; }/'
m script owner-without-heartbeat removed-ticket-of-live-owner-keeps-the-window t_ticket_removed_from_live_owner 's/ && touch -c "\$s\/owner"//'
m script no-window-reaping sigkill-owner-reaps-ticket-and-window t_sigkill_owner 's/! reap_window "\$s"/! false/'
m script no-give-back window-moved-while-live-is-given-back t_window_moved_while_live 's/^  if fresh_window "\$moved"; then .*$//'
m script ignores-own-ticket first-given-up-for-dead-does-not-reap-the-window t_first_given_up_for_dead 's/^  \[ -e "\$ticket" \] \|\| return 1   # reaped.*$//'
m script ownerless-never-reaped stale-window-without-owner-is-reaped t_window_without_owner 's/\[ -z "\$o" \] \|\| \[ "\$\{o##\* ticket=\}" != "\$o" \]/[ "\${o##* ticket=}" != "\$o" ]/'
m script empty-ticket-field-kept owner-with-empty-ticket-field-is-reaped t_odd_owner_lines 's/ \|\| \[ -z "\$\{o##\* ticket=\}" \]//'
m script ticket-less-owner-reaped owner-without-ticket-field-is-never-touched t_odd_owner_lines 's/ \|\| \[ "\$\{o##\* ticket=\}" != "\$o" \] \|\| return 1/ || :/'
m script reaps-window-with-live-ticket window-with-live-ticket-is-not-reaped t_window_with_live_ticket_is_kept 's/\[ ! -e "\$queue\/\$\{o##\* ticket=\}" \] \|\| return 1/: || return 1/'
m script keeps-window-whose-ticket-left sigkill-owner-reaps-ticket-and-window t_sigkill_owner 's/\[ ! -e "\$queue\/\$\{o##\* ticket=\}" \] \|\| return 1/return 1/'
m script ownerless-by-owner-only fresh-window-without-owner-is-not-reaped t_fresh_window_without_owner_is_left_alone 's/\[ -e "\$f" \] \|\| f=\$1; //'
m script release-without-held timed-out-waiter-does-not-remove-an-ownerless-window t_fresh_window_without_owner_is_left_alone 's/^  if \[ "\$held" -eq 1 \]; then$/  if true; then/'
m script no-requeue removed-ticket-of-live-waiter-comes-back t_ticket_removed_from_live_waiter 's/^  \[ -e "\$ticket" \] \|\| \{ beat_off;/  true || { beat_off;/'
m script removes-foreign foreign-window-survives-release t_foreign_window_at_release 's/^mine\(\) \{ .*\}$/mine() { true; }/'
m script no-overlap-warning lost-window-warns-of-overlap-and-logs-no-peak t_foreign_window_at_release 's/note "lost \$\(win_label/: "lost \$(win_label/'
m script peak-of-a-lost-window lost-window-warns-of-overlap-and-logs-no-peak t_foreign_window_at_release 's/ && mine; then$/; then/'
m script runs-without-window window-turned-file-at-take-time-rc78-without-running t_window_turned_file_at_take_time 's/^    if mkdir "\$s" 2>\/dev\/null; then$/    if true; then/'
m script admit-takes-no-census window-turned-file-at-take-time-rc78-without-running t_window_turned_file_at_take_time 's/(admit\(\) \{\n  local s k=1\n  running_dirs\n)  for s in "\$\{slots\[@\]\}"; do \[ -d "\$s" \] \|\| refuse [^\n]*\n/$1/' slurp
m script dir-type-unchecked lock-dir-that-is-a-file-rc78 t_unusable_lock_dir_is_refused 's/^  \[ ! -e "\$dir" \] \|\| \[ -d "\$dir" \] \|\| refuse .*$//'
m script queue-type-unchecked queue-that-is-a-file-rc78 t_unusable_lock_dir_is_refused 's/^  \[ ! -e "\$queue" \] \|\| \[ -d "\$queue" \] \|\| refuse .*$//'
m script dir-without-probe read-only-lock-dir-rc78 t_unusable_lock_dir_is_refused 's/^  mkdir "\$probe" 2>\/dev\/null && rmdir "\$probe" 2>\/dev\/null \|\| refuse "cannot write in it"$/  true/'
m script queue-without-probe read-only-queue-rc78 t_unusable_lock_dir_is_refused 's/^  mkdir "\$probe" 2>\/dev\/null && rmdir "\$probe" 2>\/dev\/null \|\| refuse "cannot write in the queue"$/  true/'
m script settings-without-ceiling setting-AJS_RESERVE_GIB=65-refused-rc78 t_settings_out_of_range_are_refused 's/ && \{ \[ -z "\$\{4:-\}" \] \|\| \[ "\$\(\(10#\$v\)\)" -le "\$4" \]; \}//'
m script settings-without-floor setting-AJS_BEAT=0-refused-rc78 t_settings_out_of_range_are_refused 's/is_uint "\$v" && \[ "\$\(\(10#\$v\)\)" -ge "\$3" \] &&/is_uint "\$v" \&\&/'
m script stale-not-above-beat stale-must-exceed-twice-beat t_settings_out_of_range_are_refused 's/^\[ "\$stale" -gt \$\(\(beat \* 2\)\) \] \|\| die 78 .*$/true/'
m script poll-unbounded setting-AJS_POLL=4-refused-rc78 t_settings_out_of_range_are_refused 's/^\[ "\$poll" -lt .*$/true/'
m script load-budget-zero-accepted setting-AJS_LOAD_MAX=0-refused-rc78 t_settings_out_of_range_are_refused 's/^loadmax_c=\$\(centi "\$loadmax"\) && \[ "\$loadmax_c" -gt 0 \] \|\| \{$/loadmax_c=\$(centi "\$loadmax") || {/'
m script fraction-dropped fractional-budget t_cpu_budget 's/local f=\$\{BASH_REMATCH\[3\]\}00/local f=00/'
m script name-unchecked bad-name-1-refused-rc2 t_bad_names_are_refused 's/^  \[\[ \$name =~ .* \]\] \|\| die 2 .*$/  :/'
m script mem-unchecked usage-error-6---mem-rc2 t_usage_errors 's/ && \[ "\$t" -ge 1 \] && \[ "\$t" -le 640 \]//'
m script class-unchecked usage-error-11---class-rc2 t_usage_errors 's/^\[ -z "\$wclass" \] \|\| \[\[ \$wclass =~ .* \]\] \|\| die 2 .*$/:/'
m script max-runtime-unchecked usage-error-13---max-runtime-rc2 t_usage_errors 's/^\[\[ \$max_runtime =~ .* \]\] \|\| die 2 .*$/:/'
m script fits-takes-a-command fits-with-a-command-rc2 t_usage_errors 's/^  \[ \$# -eq 0 \] && \[ -z "\$wclass" \] \|\| \{ usage >&2; exit 2; \}$/  :/'
m script out-default-in-tmp default-output-under-xdg-state-home t_default_output_dir 's/^      out=\$\{XDG_STATE_HOME:-\$HOME\/\.local\/state\}\/agent-job-semaphore\/\$name$/      out=\$\{TMPDIR:-\/tmp\}/'
m script explicit-out-ignored explicit-out-is-used t_default_output_dir 's/-o\|--out\) out=\$2 ;;/-o|--out) ;;/'
m script ajs-out-ignored ajs-out-is-used t_default_output_dir 's/out=\$\{AJS_OUT:-\}$/out=/'
m script no-home-warning without-home-warns-and-uses-tmpdir t_default_output_dir 's/neither XDG_STATE_HOME nor HOME is set/neither is set/'
m script lock-name-changed default-lock-dir-under-xdg-runtime-dir t_default_lock_dir 's/\/agent-job-semaphore\}$/\/ajs}/'
m script lock-dir-mode-open default-lock-dir-under-xdg-runtime-dir t_default_lock_dir 's/mkdir -p -m 700 "\$dir"/mkdir -p "\$dir"/'
m script ajs-dir-ignored ajs-dir-wins-over-xdg-runtime-dir t_default_lock_dir 's/^dir=\$\{AJS_DIR:-/dir=\$\{AJS_DIR_IGNORED:-/'
m script lc-all-leaks command-gets-caller-path-variable-and-lc-all t_command_keeps_caller_environment 's/^  if \[ "\$caller_lc_set" = 1 \]; then .*$/  :/'
m script ignores-dir command-runs-in-dir t_command_keeps_caller_environment 's/^  cd -- "\$workdir" \|\| exit 126$/  :/'
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
m script weight-without-floor weight-has-a-floor-of-one-gib t_class_weighs_its_peaks 's/\[ "\$m" -ge "\$peak_floor_b" \] \|\| m=\$peak_floor_b/:/'
m script peaks-forever peaks-older-than-7-days-or-in-the-future-do-not-count t_class_weighs_its_peaks 's/peak_max_age_d=7$/peak_max_age_d=30/'
m script future-peaks-count peaks-older-than-7-days-or-in-the-future-do-not-count t_class_weighs_its_peaks 's/ && d <= n//'
m script last-50-not-20 class-weighs-the-largest-of-its-last-20 t_class_weighs_its_peaks 's/^peak_last=20;/peak_last=50;/'
m script smallest-not-largest class-weighs-the-largest-of-its-last-20 t_class_weighs_its_peaks 's/(" peak class=\$1 " \| tail -n "\$peak_last" \| grep -oE .* \| sort -n \| )tail -n 1$/$1head -n 1/'
m script default-takes-the-largest default-class-weighs-the-p90-not-the-largest t_class_weighs_its_peaks 's/sc_pct=90$/sc_pct=100/'
m script cpu-rounds-down measured-peak-and-cpu-weigh-the-class t_class_weighs_its_peaks 's/v=\$\(\( \(v \+ 99\) \/ 100 \)\);/v=\$((v \/ 100));/'
m script declared-memory-ignored declared-estimate-wins t_class_weighs_its_peaks 's/^  \[ -z "\$dmem_b" \] \|\| \{ est_b=\$dmem_b; est_src=declared; \}$/  :/'
m script declared-cpu-ignored declared-estimate-wins t_class_weighs_its_peaks 's/^  \[ -z "\$dcpu" \] \|\| est_cpu=\$dcpu$/  :/'
m script reserve-fixed reserve-is-configurable t_class_weighs_its_peaks 's/^reserve_b=\$\(\(reserve_gib \* 1073741824\)\)$/reserve_b=\$((3 * 1073741824))/'
m script jest-one-core jest-class-has-3-cores-by-default t_class_weighs_its_peaks 's/jest\) est_cpu=3 ;;/jest) est_cpu=1 ;;/'
m script peak-not-written run-writes-its-peak-line t_peak_is_registered 's/ >> "\$wlog" 2>\/dev\/null$/ >\/dev\/null 2>\&1/'
m script query-writes fits-counts-an-empty-machine t_fits_counts_what_would_open 's/^if \[ -z "\$query" \]; then   # the query writes nothing.*$/if true; then/'
m script fits-rc-always-0 fits-says-zero-and-why-with-rc1 t_fits_counts_what_would_open 's/^  \[ "\$k" -ge 1 \]$/  true/'
m script fits-forgets-the-place-held fits-counts-the-place-held-by-the-oldest-waiter t_fits_counts_what_would_open 's/res_b=\$\(\(b0 \+ k \* est_b\)\)/res_b=\$((k * est_b))/'
m script cpu-gate-off busy-machine-stops-even-the-first t_cpu_budget 's/^  if ! cpu_ok; then why=\$cpu_why; return 1; fi$/  :/'
m script running-cpu-ignored running-window-cpu-counts-while-load1-is-low t_cpu_budget 's/ \|\| u=\$\(\(run_cpu \* 100\)\)//'
m script own-cpu-ignored busy-machine-stops-even-the-first t_cpu_budget 's/\(res_cpu \+ ask_cpu\)/res_cpu/'
m script unreadable-load-passes unreadable-loadavg-holds-the-gate t_unreadable_loadavg_holds_the_gate 's/(\[\[ \$l =~ \^\[0-9\]\+\\\.\[0-9\]\[0-9\]\$ \]\] \|\| return )1/${1}0/'
m script memory-gate-even-alone memory-gate-never-stops-the-first t_memory_gate 's/^  \[ "\$run_n" -eq 0 \] && \[ "\$res_b" -eq 0 \] && return 0$//'
m script no-memory-gate memory-gate-stops-the-second t_memory_gate 's/^  \[ "\$run_n" -eq 0 \] && \[ "\$res_b" -eq 0 \] && return 0$/  return 0/'
m script no-memory-minimum memory-minimum-stops-even-a-small-window t_memory_minimum 's/\[ "\$avail" -ge "\$mem_min_kib" \] && //'
m script no-growth-check estimate-of-running-window-counts-until-it-ends t_memory_counts_what_running_windows_can_still_grow 's/ && \[ "\$avail" -ge "\$need" \]//'
m script no-psi-gate psi-gate-stops-the-second t_memory_gate 's/ && \{ \[ -z "\$psi" \] \|\| \[ "\$\{psi%\.\*\}" -lt "\$psi_max" \]; \}$//'
m script no-swap-reserve swap-gate-stops-the-second t_memory_gate 's/\{ \[ "\$stotal" -eq 0 \] \|\| \[ "\$avail" -ge "\$mem_roomy_kib" \] \|\| \[ "\$sfree" -gt "\$reserve" \]; \}/true/'
m script swap-always used-swap-with-roomy-ram-does-not-stop t_memory_gate 's/ \|\| \[ "\$avail" -ge "\$mem_roomy_kib" \]//'
m script memory-minimum-fixed memory-minimum-is-configurable t_memory_thresholds_are_configurable 's/mem_min_kib=\$\(\(v \* 1024\)\)/mem_min_kib=4194304/'
m script psi-maximum-fixed psi-maximum-is-configurable t_memory_thresholds_are_configurable 's/^psi_max=\$\(env_uint AJS_PSI_MAX 10 0\) \|\| exit 78$/psi_max=10/'
m script rem-ignores-use waiter-enters-after-the-estimate-is-free t_memory_counts_what_running_windows_can_still_grow 's/\[ "\$cur" -ge "\$b" \] \|\| rem_b=\$\(\(rem_b \+ b - cur\)\)/rem_b=0/'
m script everyone-holds-its-place small-enters-before-the-big-one-that-arrived-first t_nobody_waits_for_a_turn 's/^    \[ "\$since" -gt "\$hold_after" \] \|\| return 0$//'
m script holds-for-itself waiter-that-held-long-does-not-count-itself-twice t_hold_after_is_configurable 's/^    \[ "\$t" = "\$ticket" \] && return 0$//'
m script hold-after-fixed hold-after-env-makes-a-younger-ticket-hold-its-place t_hold_after_is_configurable 's/^hold_after=\$\(env_uint AJS_HOLD_AFTER 900 1\) \|\| exit 78$/hold_after=900/'
m script first-free-window-ignored two-windows-run-together-when-they-fit t_windows_enter_while_they_fit 's/while \[ -e "\$dir\/win\.\$k" \]; do k=\$\(\(k \+ 1\)\); done/:/'
m script timeout-ignored timeout-rc75-names-the-memory-gate t_timeout_names_the_gate 's/if \[ "\$timeout" -gt 0 \] && \[ "\$waited" -ge "\$timeout" \]; then/if false; then/'
m script zero-timeout-expires waiter-without-timeout-outlasts-twice-the-expiry t_without_timeout_it_waits_while_its_ticket_beats 's/\[ "\$timeout" -gt 0 \] && //'
m script notice-without-holders notice-says-why-and-who-holds t_notice_names_the_gate_and_the_holders 's/"\$waited" "\$why" "\$\(holder\)"/"\$waited" "\$why" none/'
m script notice-after-fixed notice-says-why-and-who-holds t_notice_names_the_gate_and_the_holders 's/^notice_after=\$\(env_uint AJS_NOTICE_AFTER 300 1\) \|\| exit 78$/notice_after=300/'
m script stall-removes-anyway stall-is-said-and-nothing-is-removed-at-once t_machine_stall_removes_nothing 's/^    stall_said && continue$/    :/'
m script stall-never-detected stall-is-said-and-nothing-is-removed-at-once t_machine_stall_removes_nothing 's/-gt \$\(\(stale - 2 \* beat\)\) \]/-gt \$((stale * 9)) ]/'
m script stall-never-ends dead-ticket-goes-after-the-grace t_machine_stall_removes_nothing 's/\[ "\$now" -lt "\$paron_until" \]/[ "\$now" -lt \$((paron_until + 99999)) ]/'
m script term-not-forwarded term-exits-143-stops-command-and-frees-window t_signals_free_the_window 's/else kill -s TERM "\$child" 2>\/dev\/null; fi/else :; fi/'
m script abort-without-release term-exits-143-stops-command-and-frees-window t_signals_free_the_window 's/clock_off; watch_off; release; trap - EXIT;/clock_off; watch_off; trap - EXIT;/'
m script int-untrapped int-exits-130-stops-command-and-frees-window t_signals_free_the_window "s/^trap 'abort INT' INT\$/:/"
m script int-as-term int-exits-130-stops-command-and-frees-window t_signals_free_the_window 's/\[ "\$1" = INT \] && exit 130 \|\| exit 143/exit 143/'
m script max-runtime-never max-runtime-ends-the-command-with-rc124 t_max_runtime_ends_a_hung_command 's/^    nap "\$max_runtime"$/    nap 99999/'
m script clock-ignores-its-owner max-runtime-clock-leaves-with-its-owner t_max_runtime_clock_dies_with_its_owner 's/^        kill -0 \$\$ 2>\/dev\/null \|\| exit 0$/        :/'
m script clock-sleeps-whole max-runtime-clock-leaves-with-its-owner t_max_runtime_clock_dies_with_its_owner 's/^clock_step=2$/clock_step=99999/'
m script clock-signals-without-owner max-runtime-clock-of-a-dead-owner-signals-nothing t_max_runtime_clock_dies_with_its_owner 's/^        kill -0 \$\$ 2>\/dev\/null \|\| exit 0$/        :/'
m script cpu-cap-refusal-off declared-cpu-above-the-cores-is-refused t_cpu_never_exceeds_the_cores 's/^\[ -z "\$dcpu" \] \|\| \[ "\$dcpu" -le "\$cores" \] \|\| die 2 .*$/:/'
m script estimate-uncapped a-peak-above-the-cores-weighs-the-cores t_cpu_never_exceeds_the_cores 's/^  \[ "\$est_cpu" -le "\$cores" \] \|\| est_cpu=\$cores .*$/  :/'
m script cores-without-floor a-fractional-budget-still-weighs-one-core t_cpu_never_exceeds_the_cores 's/; \[ "\$cores" -ge 1 \] \|\| cores=1$//'
m script nproc-ignored default-budget-is-fewer-when-the-process-may-use-fewer-cores t_cpu_never_exceeds_the_cores 's/^  \[\[ \$np =~ .*$/  :/'
m script alone-asks-its-whole-cpu alone-it-enters-whatever-its-class-asks t_cpu_never_exceeds_the_cores 's/^  \[ "\$run_n" -gt 0 \] \|\| \[ "\$res_b" -gt 0 \] \|\| ask_cpu=1$/  :/'
m script impossible-waiter-holds-a-place a-waiter-asking-more-cores-than-there-are-holds-no-place t_cpu_never_exceeds_the_cores 's/^    \[ "\$te_cpu" -le "\$cores" \] \|\| continue .*$/    :/'
m script jest-takes-the-largest-memory jest-weighs-the-p90-of-memory-and-cpu t_jest_weighs_the_p90 's/if p90_class "\$wclass"; then m=/if [ "\$wclass" = default ]; then m=/'
m script jest-takes-the-largest-cpu jest-weighs-the-p90-of-memory-and-cpu t_jest_weighs_the_p90 's/^  if p90_class "\$1"; then$/  if [ "\$1" = default ]; then/'
m script every-class-takes-the-p90 another-class-keeps-the-largest-of-20 t_jest_weighs_the_p90 's/p90_class\(\) \{ case \$1 in default\|jest\)/p90_class() { case \$1 in *)/'
m script percentile-counts-every-class the-peaks-of-another-class-do-not-count-in-its-percentile t_jest_weighs_the_p90 's/g=\$\(dated_lines "\$wlog" " peak class=\$1 " \|/g=\$(dated_lines "\$wlog" " peak class=" |/'
m script no-grace-wait max-runtime-kills-what-ignores-term-after-the-grace t_max_runtime_ends_a_hung_command 's/^kill_grace=10$/kill_grace=1/'
m script expiry-keeps-the-rc max-runtime-ends-the-command-with-rc124 t_max_runtime_ends_a_hung_command 's/; rc=124; \}/; :; }/'
m script contained-memory-not-killed stand-in-memory-past-the-limit-kills-the-window t_containment_with_a_stand_in 's/\[ "\$\{kib:-0\}" -ge "\$win_mem_kill_kib" \]/[ "\${kib:-0}" -ge 999999999999 ]/'
m script contained-tasks-not-killed stand-in-tasks-at-90-percent-kill-the-window t_containment_with_a_stand_in 's/\[ "\$\{n:-0\}" -ge "\$trip" \]/[ "\${n:-0}" -ge 999999999 ]/'
m script uncontained-not-said without-namespaces-the-line-says-uncontained t_uncontained_says_so 's/^\[ "\$contained" = 1 \] \|\| held_by="uncontained"$/:/'
m bench canary-seeded-lock real-default-dirs-untouched t_duplicate_name 's/export AJS_DIR=\$D AJS_LOADAVG_FILE/export AJS_DIR=\$REAL_RUNTIME AJS_LOADAVG_FILE/'
m bench canary-seeded-output real-default-dirs-untouched t_duplicate_name 's/--load-max 1000 --out "\$R\/out" --timeout 30 "\$@"/--load-max 1000 --out "\$REAL_STATE\/\$2" --timeout 30 "\$@"/'

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
