# agent-job-semaphore

A machine-wide semaphore for heavy jobs started by AI coding agents. One bash script, no daemon.

## The problem

Run three or four agent sessions (Claude Code, Codex, Aider, your own scripts) on one workstation and
sooner or later they all decide to run the test suite at the same moment. Each `jest`, `cargo test`
or `docker compose up` assumes it has the whole machine: load climbs past the core count, memory
spills into swap, every suite slows to a crawl, timeouts fire, and the agents misread the failures
as bugs in their own code.

`agent-job-semaphore` gives heavy commands a few shared **slots** (two by default). A session that
wants to run something heavy takes a ticket in a single **FIFO queue**, waits for a free slot, then
waits at a **gate** until the machine has room: a low enough load average and, when another job is
already running, enough free memory. The command runs, its raw output goes to a file, and the
agent gets back **one summary line** instead of thousands of lines of test output.

## Usage

```sh
agent-job-semaphore --name session-a -- npm test
```

```text
ajs my-repo rc=0 14:02:11->14:05:40 load1 2.10->3.85 Tests: 412 passed, 412 total (output: /home/me/.local/state/agent-job-semaphore/session-a/ajs-my-repo-20260101T140211-48213.log)
```

The exit code is the command's own, so `&&` chains and agent tool calls keep working.

## How it works

```text
 session A ──┐                        ┌─────────── slots (AJS_SLOTS=2) ────────────┐
 session B ──┼─► queue/ (FIFO by ──►  │ slot.1  [gate: load, memory] ─► running A  │
 session C ──┘    arrival time)       │ slot.2  [gate: load, memory] ─► running B  │
                  C waits here        └────────────────────────────────────────────┘
                                         C takes the first slot that frees up
```

1. **Ticket.** The process writes `queue/<epoch-ns>-<pid>-<name>`. Tickets sort by arrival time.
   Only one live ticket per name: a second `--name session-a` exits at once with code 73, so an
   agent cannot queue the same job twice.
2. **Slot.** A ticket may take a free slot once every ticket ahead of it already holds one, so
   nobody overtakes. A slot is a directory created with `mkdir`, which is atomic.
3. **Gate.** Holding a slot, the process waits until `load1 < load-max × (slots already running + 1)`,
   until any earlier ticket still at its own gate has passed, and, if another slot is busy, until
   `MemAvailable` is at least 4 GiB, memory pressure (PSI `some avg10`) is below 10, and, when
   `MemAvailable` is under 8 GiB, free swap stays above a small reserve. Swap that is merely in use
   while RAM is plentiful does not count as pressure. The first job never waits for memory.
4. **Run.** The command runs in the foreground with the caller's environment; its output goes to
   a log file. `jest` and `vitest` get `--maxWorkers=2` unless they already set workers, because
   one worker per core is what overloads a shared machine.
5. **Liveness.** Each process touches its ticket every 10 s, and the owner file of its slot. Sandboxed
   sessions often live in separate PID namespaces where `kill -0` cannot see each other, so a file
   modification time is the signal that crosses them. A ticket silent for 90 s is removed by the
   waiters; a slot whose owner is silent and whose ticket has left the queue is removed by the first
   in line. A live process whose ticket was removed (say, frozen under swap) puts it back in its
   original place. Every removal is logged to `<AJS_DIR>/events.log`.
6. **Signals.** SIGINT or SIGTERM, while queued or running, stops the command (it gets SIGTERM), frees
   the slot and leaves the queue, with exit code 130 or 143.

## Install

```sh
git clone https://github.com/D4cry0/agent-job-semaphore.git
install -m 755 agent-job-semaphore/agent-job-semaphore ~/.local/bin/
```

Requirements: Linux (`/proc`), bash 4.2 or later (tested with 5.3) and GNU coreutils. Nothing else:
no awk, sed, grep, flock or Python.

## Example: two Claude Code sessions

Give each session its own name and tell the agent to wrap heavy commands. In each repository's
`CLAUDE.md` (or your global one):

```markdown
Run test suites, builds and anything else heavy through the shared semaphore, never directly:
    agent-job-semaphore --name "$AJS_NAME" -- <command>
Read the one summary line it prints; open the log file it names only when a test fails.
```

Then start the sessions with distinct names:

```sh
# terminal 1
AJS_NAME=api claude
# terminal 2
AJS_NAME=web claude
```

When both agents run their suites at once, the first one starts; the second waits for a slot and then
for the gate, and both get a single line back. A third session would queue behind them in arrival
order. If an agent runs Claude Code's sandbox, make sure the lock directory (by default under
`$XDG_RUNTIME_DIR`) is writable and shared by every session; a private `/tmp` per sandbox cannot
host a shared queue.

## Options

| Option | Default | Meaning |
|---|---|---|
| `-n, --name <name>` | `$AJS_NAME`, else `$USER` | Ticket name, `[A-Za-z0-9][A-Za-z0-9._-]*`; one live ticket per name |
| `-C, --dir <dir>` | current directory | Directory the command runs in; its basename labels the summary |
| `-t, --timeout <s>` | `1800` | Longest wait at the gate, counted from when the slot reaches it. The queue never times out |
| `-l, --load-max <n>` | `$AJS_LOAD_MAX`, else `nproc / 3` (at least 1) | load1 budget per slot; decimals allowed |
| `-o, --out <dir>` | `$AJS_OUT`, else `${XDG_STATE_HOME:-~/.local/state}/agent-job-semaphore/<name>` | Where raw output files go |
| `-a, --append-to <file>` | none | Also append the summary line, with date and name, to a file |
| `-h, --help` / `-V, --version` | | |

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `AJS_DIR` | `${XDG_RUNTIME_DIR:-/run/user/<uid>}/agent-job-semaphore` | Lock directory; every session must see the same one |
| `AJS_SLOTS` | `2` | Number of slots, 1 to 16; use the same value in every session |
| `AJS_BEAT` | `10` | Seconds between heartbeats |
| `AJS_STALE` | `90` | Seconds of silence after which a ticket or slot is dead; more than twice `AJS_BEAT` |
| `AJS_POLL` | `5` | Seconds between tries for a slot |
| `AJS_GATE_POLL` | `6 × AJS_POLL` | Seconds between gate checks |
| `AJS_NOTICE_AFTER` | `300` | Seconds of waiting before a notice names the holders and the command that frees a dead one |
| `AJS_MEM_MIN_MIB` | `4096` | `MemAvailable` needed to open a second slot |
| `AJS_MEM_ROOMY_MIB` | `8192` | Below this `MemAvailable`, free swap must also exceed the reserve |
| `AJS_SWAP_RESERVE_MIB` | `2048` | Swap reserve, capped at a quarter of `SwapTotal` |
| `AJS_PSI_MAX` | `10` | Maximum `some avg10` of `/proc/pressure/memory`; ignored where PSI is absent |
| `AJS_JEST_WORKERS` | `2` | `--maxWorkers` added to jest or vitest; `0` disables |
| `AJS_SUMMARY_REGEX` | `^[[:space:]]*Tests:?[[:space:]]` | Extended regex; the last match within the output's last 2000 lines is the summary |
| `AJS_LOADAVG_FILE`, `AJS_MEMINFO_FILE`, `AJS_PSI_FILE` | `/proc/...` | Read these instead, for tests or containers |

For pytest, for example: `AJS_SUMMARY_REGEX='^=+ .*(passed|failed)'`.

## Exit codes

| Code | Meaning |
|---|---|
| command's | The command ran; this is its exit code |
| 2 | Usage: no command, unknown option, bad value, or an invalid name |
| 73 | A live ticket with the same name is already queued; nothing was queued or run |
| 75 | The gate did not open within `--timeout` (load or memory stayed high) |
| 78 | Configuration: the lock directory is not usable, or an `AJS_*` value is out of range |
| 130 / 143 | SIGINT / SIGTERM arrived; the command was stopped and the slot freed |

## Declared limits

- **Cooperative, not a security boundary.** Only commands run through the script are limited. A
  session that sets another `AJS_DIR` has its own queue.
- **One user, one machine.** The lock directory is per user. Network filesystems are not supported:
  liveness compares file modification times against the local clock.
- **Dead or alive is a matter of time.** A process stalled for longer than `AJS_STALE` (stopped with
  SIGSTOP, starved by swap) looks dead. If its ticket was removed it goes back to its place; if its
  slot was taken over meanwhile, two jobs may overlap, and the process says so on stderr and in the
  events log when it finishes.
- **Load and memory are machine-wide.** `load1` is a one-minute average, so it reacts late. PSI is
  read from `/proc/pressure/memory`, the whole machine's, because a cgroup's own pressure is often
  invisible from inside a sandbox.
- **SIGINT reaches only foreground runs.** Bash starts background jobs (`cmd &`) with SIGINT ignored,
  and that cannot be undone; stop those with SIGTERM.
- **Replace the script atomically.** Bash reads a running script from disk as it goes: install a new
  version with `mv` or `install`, never by writing over the file in place.
- **The test summary is a heuristic.** Only the last 2000 lines of output are scanned.

## Tests

```sh
tests/run.sh            # the bench: real processes, each scenario on its own lock directory
tests/mutants.sh        # mutation harness: each mutant must fail its named test
MUT_SHARD=1/4 tests/mutants.sh   # one quarter of the mutants
```

The bench needs, beyond the script's own requirements, `awk`, `sed`, `grep`, `perl` and, for one
scenario, `unshare` from util-linux. It overrides `HOME` and the XDG directories and checks that it
never writes to the caller's real defaults.

## License

Apache-2.0. See [LICENSE](LICENSE).
