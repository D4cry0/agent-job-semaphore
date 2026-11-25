# agent-job-semaphore

A machine-wide semaphore for heavy jobs started by AI coding agents. One bash script, no daemon.

## The problem

Run three or four agent sessions (Claude Code, Codex, Aider, your own scripts) on one workstation and
sooner or later they all decide to run the test suite at the same moment. Each `jest`, `cargo test`
or `docker compose up` assumes it has the whole machine: load climbs past the core count, memory
spills into swap, every suite slows to a crawl, timeouts fire, and the agents misread the failures
as bugs in their own code.

A fixed number of slots does not fit that. A lint run needs 200 MiB and one core; a browser suite
needs 6 GiB and four. Two slots either leave the machine idle or let two big jobs kill it.

## The model

`agent-job-semaphore` runs every heavy command as a **window** with a **weight**: how much memory and
CPU it is expected to use. A window enters, whole, **as soon as it fits** beside the windows already
running. There are no slots, no turns and no queue order: the first job that fits goes in, and a small
job does not wait behind a big one that cannot start yet. The agent gets back **one summary line**
instead of thousands of lines of test output.

- **Weights are measured.** Each window records its peak memory and CPU when it ends. A job's *class*
  (`--class pg`, `--class browser`...) weighs the largest peak of its last 20 runs in the last 7 days
  (never less than 1 GiB). Jobs with no class and `jest` weigh the 90th percentile of their own last 100
  runs, so one freak run does not make every later run look huge. With no measure yet a window weighs a
  reserve of 3 GiB and one core (three for jest). A weight never asks for more cores than the machine
  has, and a window running alone is asked for one core, so a small machine never starves a job.
  `--mem` and `--cpu` declare a weight by hand.
- **A window fits** when what the running windows can still grow (their weight minus what they use
  now) plus the new weight stays within `MemAvailable` (with a floor and the machine's memory
  pressure and swap as extra brakes), and when `load1` (or the CPU the running windows weigh,
  whichever is larger) plus the new weight stays within the machine's cores.
- **Nobody starves.** A job that has waited 15 minutes keeps its place: it is counted as running for
  everyone else, who enter only if they fit beside it too.
- **A runaway dies alone.** Each window runs in its own user, pid and mount namespace with a task limit;
  a watcher kills that window, and no other, when it passes its memory or 90 % of its tasks.
- **A hung command is cut.** `--max-runtime` (4 hours by default) sends TERM to the whole command tree
  and, 10 seconds later, KILL.
- **Dead jobs are retired.** A ticket without a heartbeat for 90 seconds is removed by whoever waits.

### An example

Three sessions on a 16 GiB, 8-core machine. Nothing has run yet, so every class weighs the 3 GiB reserve.

```sh
# session api: the first window enters at once (nothing else runs)
agent-job-semaphore --name api --class jest -- npm test
# session web, a moment later: 3 GiB more fits beside the first, so it enters too
agent-job-semaphore --name web --class jest -- npm test
# session ops asks for a heavy job: 11 GiB does not fit beside two running suites, so it waits...
agent-job-semaphore --name ops --mem 11 -- docker compose up --build
# ...while a small one that fits goes ahead of it
agent-job-semaphore --name lint --mem 0.5 -- npm run lint
```

After a few runs the log knows what `jest` really costs (say 1.4 GiB and 2 cores) and stops
reserving 3 GiB for it. Ask what would fit right now without queueing anything:

```sh
$ agent-job-semaphore --fits jest
fits class=jest estimate=1503238554 cpu=2 source=log running=1 waiting=0 would_open=3
```

The command's output goes to a file and the agent reads one line:

```text
ajs my-repo rc=0 14:02:11->14:05:40 load1 2.10->3.85 Tests: 412 passed, 412 total (output: /home/me/.local/state/agent-job-semaphore/api/ajs-my-repo-20260101T140211-48213.log)
```

The exit code is the command's own, so `&&` chains and agent tool calls keep working.

## How it works

1. **Ticket.** The process writes `queue/<epoch-ns>-<pid>-<name>` with its estimate. Only one live
   ticket per name: a second `--name api` exits at once with code 73, so an agent cannot queue the same
   job twice.
2. **Entry.** Every few seconds the process asks whether it fits. Measuring and taking a window happen
   under `<AJS_DIR>/admit`, a lock that lasts milliseconds; a window is a directory
   (`<AJS_DIR>/win.<k>`) created with `mkdir`, which is atomic, holding its owner, weight and what it
   uses now.
3. **Run.** The command runs in the foreground with the caller's environment; its output goes to a
   log file. `jest` and `vitest` get `--maxWorkers=2` unless they already set workers, because one
   worker per core is what overloads a shared machine.
4. **Watch.** Every two seconds a watcher reads the command's process tree: it records the peak
   (memory and CPU), keeps what the window uses now for the others to read, and kills the window if it
   passes the memory or task limit.
5. **Liveness.** Each process touches its ticket every 10 s, and the owner file of its window. Sandboxed
   sessions often live in separate PID namespaces where `kill -0` cannot see each other, so a file
   modification time is the signal that crosses them. A ticket silent for 90 s is removed by the
   waiters; a window whose owner is silent and whose ticket has left the queue is removed too. A live
   process whose ticket was removed (say, frozen under swap) puts it back. If the machine itself
   stalled (every beat looks late at once), nothing is removed until another 90 s have shown who beats.
   Every removal is logged to `<AJS_DIR>/events.log`.
6. **End.** The window is removed, its peak is appended to `events.log` and the line is printed.
   SIGINT or SIGTERM, while waiting or running, stops the command (it gets SIGTERM), frees the window and
   leaves the queue, with exit code 130 or 143.

## Install

```sh
git clone https://github.com/D4cry0/agent-job-semaphore.git
install -m 755 agent-job-semaphore/agent-job-semaphore ~/.local/bin/
```

Requirements: Linux (`/proc`), bash 5.0 or later (tested with 5.3), GNU coreutils, `awk`, `grep` and
`sed`. For containment, `unshare` and `prlimit` from util-linux with unprivileged user namespaces;
without them the command runs as before and the summary line says `uncontained`.

## Upgrading from 0.1.0

0.2.0 replaces the slots and the FIFO queue with the windows above, and it breaks 0.1.0 in these ways:

- **Upgrade every session together.** 0.2.0 counts only its own `win.<k>` directories and does not see the
  `slot.<k>` ones of 0.1.0, so a mixed fleet runs jobs side by side with no mutual exclusion. Let the
  0.1.0 runs finish, replace the script (atomically, see the declared limits), and then delete any
  leftover `slot.*` directory under the lock directory.
- **`AJS_SLOTS` and `AJS_GATE_POLL` are gone, and ignored without a word.** Nothing fails if they stay in
  your environment or your agents' instructions; they just do nothing. How many jobs run at once now
  follows memory and CPU: tune it with `--mem`, `--cpu` and `--class`, and with `--load-max`.
- **`--timeout` defaults to `0`** (wait as long as the ticket beats). 0.1.0 gave up after 1800 seconds
  at the gate; pass `-t 1800` where a script relied on rc 75 for that.
- **`--load-max` is a budget for the whole machine** (default: the online cores), no longer a load
  per slot (default: a third of them).
- **New exit code 124**, from `--max-runtime` (default 4 hours); rc 75 now means `--timeout` ran out
  before the window fitted.
- **Requirements grew:** bash 5.0 or later (0.1.0 ran on 4.2), plus `awk`, `grep` and `sed`. For
  containment, `unshare` and `prlimit`; without them the summary line says `uncontained`.
- **`events.log` is kept, but starts the weights from the reserve:** 0.1.0 logged notices (a dead ticket
  removed, a window lost) but no peaks, so each class weighs 3 GiB until it has run once.

## Example: two Claude Code sessions

Give each session its own name and tell the agent to wrap heavy commands. In each repository's
`CLAUDE.md` (or your global one):

```markdown
Run test suites, builds and anything else heavy through the shared semaphore, never directly:
    agent-job-semaphore --name "$AJS_NAME" --class <tests|build|e2e> -- <command>
Read the one summary line it prints; open the log file it names only when a test fails.
```

Then start the sessions with distinct names:

```sh
# terminal 1
AJS_NAME=api claude
# terminal 2
AJS_NAME=web claude
```

If an agent runs Claude Code's sandbox, make sure the lock directory (by default under
`$XDG_RUNTIME_DIR`) is writable and shared by every session; a private `/tmp` per sandbox cannot
host a shared queue.

## Options

| Option | Default | Meaning |
|---|---|---|
| `-n, --name <name>` | `$AJS_NAME`, else `$USER` | Ticket name, `[A-Za-z0-9][A-Za-z0-9._-]*`; one live ticket per name |
| `-C, --dir <dir>` | current directory | Directory the command runs in; its basename labels the summary |
| `-t, --timeout <s>` | `0` | Longest wait to fit; `0` waits for as long as the ticket beats |
| `-l, --load-max <n>` | `$AJS_LOAD_MAX`, else the online cores (fewer if `nproc` says this process may use fewer) | CPU the machine may be asked for; decimals allowed |
| `--class <name>` | `jest` for a jest or vitest command, else `default` | Kind of job (`[a-z][a-z0-9-]*`, 16 characters at most); its weight is what its last runs measured |
| `--mem <GiB>` | the class's | Declare the memory weight, 0.1 to 64 |
| `--cpu <n>` | the class's | Declare the CPU weight, 1 to 64 cores; more than the machine's cores is refused (rc 2) |
| `--max-runtime <s>` | `14400` | Safety clock against a hung command, from its start; rc 124 |
| `-o, --out <dir>` | `$AJS_OUT`, else `${XDG_STATE_HOME:-~/.local/state}/agent-job-semaphore/<name>` | Where raw output files go |
| `-a, --append-to <file>` | none | Also append the summary line, with date and name, to a file |
| `--fits <class>` | | Print how many more windows of that class fit now, and the gate that stops the next one; queues nothing |
| `-h, --help` / `-V, --version` | | |

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `AJS_DIR` | `${XDG_RUNTIME_DIR:-/run/user/<uid>}/agent-job-semaphore` | Lock directory; every session must see the same one |
| `AJS_BEAT` | `10` | Seconds between heartbeats |
| `AJS_STALE` | `90` | Seconds of silence after which a ticket or window is dead; more than twice `AJS_BEAT` |
| `AJS_POLL` | `5` | Seconds between tries to enter; below `AJS_STALE - 2 × AJS_BEAT` |
| `AJS_HOLD_AFTER` | `900` | Seconds a waiter must have waited to keep its place |
| `AJS_NOTICE_AFTER` | `300` | Seconds of waiting before a notice names the gate and who runs |
| `AJS_RESERVE_GIB` | `3` | Weight of a class with no measure, and the most a window alone is asked (1 to 64) |
| `AJS_MEM_MIN_MIB` | `4096` | `MemAvailable` needed to open a window while another runs or holds a place |
| `AJS_MEM_ROOMY_MIB` | `8192` | Below this `MemAvailable`, free swap must also exceed the reserve |
| `AJS_SWAP_RESERVE_MIB` | `2048` | Swap reserve, capped at a quarter of `SwapTotal` |
| `AJS_PSI_MAX` | `10` | Maximum `some avg10` of `/proc/pressure/memory`; ignored where PSI is absent |
| `AJS_TASKS_MAX` | `2048` | Task limit of a contained window; it is killed at 90 % |
| `AJS_KILL_MEM_MIB` | `8192` | RSS at which a contained window is killed (1.5 × `--mem`, if larger) |
| `AJS_JEST_WORKERS` | `2` | `--maxWorkers` added to jest or vitest; `0` disables |
| `AJS_SUMMARY_REGEX` | `^[[:space:]]*Tests:?[[:space:]]` | Extended regex; the last match within the output's last 2000 lines is the summary |
| `AJS_NAME`, `AJS_LOAD_MAX`, `AJS_OUT` | | Defaults for `--name`, `--load-max` and `--out` |
| `AJS_LOADAVG_FILE`, `AJS_MEMINFO_FILE`, `AJS_PSI_FILE` | `/proc/...` | Read these instead, for tests or containers |

For pytest, for example: `AJS_SUMMARY_REGEX='^=+ .*(passed|failed)'`.

## Exit codes

| Code | Meaning |
|---|---|
| command's | The command ran; this is its exit code (137 if its window was killed for memory or tasks) |
| 2 | Usage: no command, unknown option, bad value, or an invalid name |
| 73 | A live ticket with the same name is already queued; nothing was queued or run |
| 75 | `--timeout` ran out before the window fitted; the message names the gate |
| 78 | Configuration: the lock directory is not usable, or an `AJS_*` value is out of range |
| 124 | The command outlived `--max-runtime` |
| 130 / 143 | SIGINT / SIGTERM arrived; the command was stopped and the window freed |

## Declared limits

- **Cooperative, not a security boundary.** Only commands run through the script are limited. A
  session that sets another `AJS_DIR` has its own queue. Containment keeps a runaway job from taking
  the machine; it is not a sandbox.
- **One user, one machine.** The lock directory is per user. Network filesystems are not supported:
  liveness compares file modification times against the local clock.
- **Weights are estimates.** The first runs of a class weigh the reserve; memory a job takes after the
  decision still counts against the next one only through the watcher's two-second samples.
  A window alone is asked at most the reserve and one core, so a job bigger than the machine still runs.
- **Dead or alive is a matter of time.** A process stalled for longer than `AJS_STALE` (stopped with
  SIGSTOP, starved by swap) looks dead. If its ticket was removed it comes back; if its window was
  taken over meanwhile, two jobs may overlap, and the process says so on stderr and in the events
  log when it finishes.
- **Load and memory are machine-wide.** `load1` is a one-minute average, so it reacts late; that is
  why a running window weighs its declared or measured CPU until `load1` catches up. PSI is read from
  `/proc/pressure/memory`, the whole machine's, because a cgroup's own pressure is often invisible
  from inside a sandbox. Container memory is not attributed to the window that started the container.
- **SIGINT reaches only foreground runs.** Bash starts background jobs (`cmd &`) with SIGINT ignored,
  and that cannot be undone; stop those with SIGTERM.
- **Replace the script atomically.** Bash reads a running script from disk as it goes: install a new
  version with `mv` or `install`, never by writing over the file in place, and not while windows run.
- **The test summary is a heuristic.** Only the last 2000 lines of output are scanned.
- **`events.log` only grows**, by one line per finished run; truncate it when you like (the weights
  start again from the reserve).

## Tests

```sh
tests/run.sh            # the bench: real processes, each scenario on its own lock directory
tests/mutants.sh        # mutation harness: each mutant must fail its named test
MUT_SHARD=1/4 tests/mutants.sh   # one quarter of the mutants
```

The bench needs, beyond the script's own requirements, `perl` and, for the scenarios that exercise real
namespaces, `unshare` and `prlimit` from util-linux (they are skipped where they do not work; a
stand-in covers the watcher's decisions). It overrides `HOME` and the XDG directories and checks that it
never writes to the caller's real defaults.

## License

Apache-2.0. See [LICENSE](LICENSE).
