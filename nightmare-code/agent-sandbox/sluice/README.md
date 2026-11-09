# sluice

**A dependency-free, DAG-driven ops pipeline engine in pure Bash, plus a complete nightly maintenance pipeline for a Linux web host.**

> [!IMPORTANT]
> This project lives in an **AI agent sandbox**. An AI coding agent wrote it; it is **not** the work of the repository owner and does not represent their skills, style or opinions. See the sandbox README one directory up.

```text
$ bin/sluice demo
  nightly-ops  20261105T145824Z-acae  warn

     JOB            STATE           TIME TRY  TIMELINE
  ✔  preflight      ok              38ms   1  ███
  ✔  host-facts     ok              40ms   1     ███
  ▲  log-insights   warn            89ms   1     ███████                     5 finding(s): 1 high, 2 medium, 1 low, 1 info
  ▲  ssh-audit      warn            41ms   1      ████                       6 finding(s): 1 high, 2 medium, 3 low
  ▲  fs-audit       warn            54ms   1      █████                      5 finding(s): 2 high, 3 medium
  ▲  cert-expiry    warn            59ms   1         █████                   2 finding(s): 1 high, 1 medium
  ✔  backup         ok              75ms   1          ██████
  ✔  backup-verify  ok              38ms   1                ███
  ✔  report         ok              85ms   1                   ███████
  ✔  publish        ok              55ms   1                          █████
  ↷  notify         skipped         23ms   1                           ██    no SLUICE_WEBHOOK_URL configured; payload saved to artifacts/notify/payload.json
  ────────────────────────────────────────────────────────────────────────────
  11 job(s): 6 ok · 4 warn · 1 skipped
  wall 389ms · job time 597ms · parallelism x1.5
```

## Two editions, one code base

The code exists twice, **line for line identical**. Only the comments differ:

| Edition | Path from the repository root | Use it to |
|---|---|---|
| Comment-free | [`agent-sandbox/sluice/`](../../agent-sandbox/sluice/) | read the code as it is, without commentary |
| Annotated | [`agent-sandbox-annotated/sluice/`](../../agent-sandbox-annotated/sluice/) | learn: every file explains what it does, why, and which Bash features it uses |

The annotated edition is the source of truth. The comment-free edition is generated from it by `agent-sandbox-annotated/tools/sync-editions.sh`, and both editions pass the same test suite.

## Quick start

```bash
cd agent-sandbox/sluice            # or agent-sandbox-annotated/sluice
bin/sluice demo                    # build a fake server under var/demo and run the nightly pipeline on it
bin/sluice show                    # summary of the latest run
bin/sluice show latest ssh-audit   # logs of one job
bash tests/run.sh                  # the test suite (TAP output)
```

The demo does not need root, a network connection or a real web server. Everything it inspects is generated inside `var/demo`, with deliberate problems planted for each stage to find.

**Requirements:** bash 5.1 or newer, GNU coreutils and findutils, `tar`, `gzip`, `awk`. Optional: `openssl` (certificate checks), `curl` (notifications), `flock` (locking; there is a fallback) and `timeout` (per-job timeouts).

## The nightly pipeline

[`pipelines/nightly-ops.ini`](pipelines/nightly-ops.ini) defines 11 jobs in 5 waves:

```text
                   +-> host-facts -----------------+
                   +-> log-insights ---------------+
  preflight -------+-> ssh-audit ------------------+--> report --+-> publish
                   +-> fs-audit -------------------+             +-> notify
                   +-> cert-expiry ----------------+
                   +-> backup --> backup-verify ---+
```

| Stage | What it does |
|---|---|
| `preflight` | Checks required and optional tools, writable directories and free disk space; it fails fast before any real work starts |
| `host-facts` | Inventories OS, kernel, CPUs, load, memory, disks and IP addresses straight from `/proc`, with threshold findings |
| `log-insights` | Single-pass awk analytics of nginx/Apache logs, including `.gz` rotations: status classes, 5xx rate, p50/p90/p95/p99 latency, top paths and clients, scraper detection |
| `ssh-audit` | sshd hardening audit (13 CIS-inspired rules). It follows `Include` drop-ins, first-value-wins semantics and `Match` scoping, and reports `file:line` for every finding |
| `fs-audit` | Finds world-writable files and directories, unexpected setuid/setgid files, exposed private keys and `.env` files, and unowned files |
| `cert-expiry` | Days until expiry for PEM files (every certificate in a bundle) and live `host:port` endpoints |
| `backup` | Checksummed `tar.gz` with an embedded manifest, atomic publication, a lock, and grandfather-father-son retention (daily, weekly, monthly) |
| `backup-verify` | Proves the restore: sidecar checksum, `gzip -t`, extraction, and every file compared against the manifest |
| `report` | Writes `report.md`, `report.json` and a self-contained `index.html`; it runs even after failures (`when = always`) |
| `publish` | Zero-downtime release of the report: `releases/<run-id>` plus an atomic `current` symlink swap, health checks, automatic rollback and pruning |
| `notify` | Slack-compatible webhook (Discord, Mattermost) with retries and a redacted URL in logs; without a webhook it writes the payload to an outbox |

## The engine

- **DAG scheduling with bounded parallelism.** `wait -n -p` reacts the moment any job exits, with no polling. A strict INI parser and graph validation run before anything executes, and cycles are reported as a path (`a -> b -> a`).
- **Trigger rules:** `when = success | always`, `allow_failure`, `fail_fast` (with a `--keep-going` override), and `--target JOB`, which runs only a subgraph.
- **Per-job retries** with capped exponential backoff and *full jitter*, plus **per-job timeouts** through `timeout(1)`, which kills the whole process group.
- **Graceful interruption:** on Ctrl-C or SIGTERM, running jobs are terminated and recorded as `interrupted`, pending jobs are cancelled, and you still get a summary. The exit status is 130/143.
- **Locking:** a second concurrent run exits with 75 instead of corrupting state. It uses `flock`, with an atomic `mkdir` fallback that recovers stale locks.
- **Observability:** colourised logs on stderr, a structured `events.jsonl` per run, the Gantt timeline above, Graphviz export (`sluice graph | dot -Tsvg`), and run history (`sluice runs`, `sluice show`).
- **Safe configuration:** `.env` files and `${VAR}` templates are parsed as data, never executed with `source` or `eval`. Secrets are redacted in the run's environment snapshot.

## Commands

```text
sluice run      [PIPELINE] [options]   execute a pipeline (default: pipelines/nightly-ops.ini)
sluice demo     [options]              seed the demo workspace and run nightly-ops on it
sluice plan     [PIPELINE]             execution plan, wave by wave
sluice graph    [PIPELINE] [--run ID]  Graphviz DOT, optionally coloured by a run's results
sluice validate [PIPELINE]             check the definition and the scripts it references
sluice runs     [--limit N]            run history, newest first
sluice show     [RUN] [JOB]            summary of a run, or one job's logs (RUN may be a unique prefix)
```

Run options: `-j/--jobs N`, `-t/--target JOB`, `-n/--dry-run`, `-k/--keep-going`, `--fail-fast`, `--strict`, `-w/--wait-lock SEC`, `-e/--env-file FILE`, `-l/--log-level LEVEL`, `-q/--quiet`, `--no-color` and `--reseed` (demo only). Short options can be bundled, for example `-nqj2`.

| Exit status | Meaning |
|---|---|
| 0 | ok, or finished with warnings (`--strict` turns warnings into 1) |
| 1 | at least one job failed, timed out or was cancelled |
| 64 / 65 / 78 | usage error / invalid pipeline / configuration error |
| 75 | another run of the same pipeline holds the lock |
| 130 / 143 | interrupted by SIGINT / SIGTERM |

## Configuration

Precedence, highest first: **the environment**, then **`.env`** (or `--env-file`), then **the pipeline's `[env]` section**. An empty value in `.env` means "use the default".

```bash
cp .env.example .env     # every available setting, documented
```

To point the stages at a real host, set the input paths in `.env`, for example `SLUICE_ACCESS_LOGS=/var/log/nginx/access.log*` or `SLUICE_SSHD_CONFIG=/etc/ssh/sshd_config`. Set `SLUICE_WEBHOOK_URL` to enable chat notifications. `sluice demo` always uses its own workspace and ignores those input paths, so it can never touch the real system.

### Writing your own pipeline

```ini
[pipeline]
name         = deploy-web
max_parallel = 2

[env]
APP_DIR = ${SLUICE_WORKSPACE}/app

[job build]
run         = ${SLUICE_PIPELINE_DIR}/scripts/build.sh --release
timeout     = 10m

[job smoke-test]
needs       = build
run         = curl -fsS http://localhost:8080/healthz
retries     = 3
retry_delay = 2s
```

A `run` line is a script (paths relative to the install directory, or absolute) or a command, followed by arguments split on whitespace. It is never re-parsed by a shell. A stage script that sources `lib/stage.sh` gets metrics, findings, notes, `summary.json` and the exit-code contract for free: `0` ok, `10` warn, `20` skipped, anything else failed. See any file in `stages/` for a template.

## Runs leave an audit trail

```text
var/runs/<run-id>/
  pipeline.ini      the exact definition that ran
  env.snapshot      resolved configuration, secrets redacted
  events.jsonl      structured log of the engine and every stage
  jobs/<job>/       stdout.log, stderr.log, status, note
  artifacts/<job>/  metrics.tsv, findings.tsv, summary.json, stage outputs
  run.meta          final status and counters
```

## Platform notes

| Platform | Status |
|---|---|
| Linux (tested on Ubuntu 26.04, bash 5.3) | Everything works; all 93 tests pass |
| Git Bash on Windows (bash 5.3) | Works; `publish` skips (no native symlinks), permission checks are limited by NTFS, and locking falls back to `mkdir`. 87 tests pass and 6 are skipped with a reason |
| macOS | Needs a modern bash (`brew install bash coreutils`); not tested |

## Quality

- **93 tests** in a self-written TAP runner. They cover unit tests per library, scheduler semantics (parallelism, retries, timeouts, cascades, fail-fast, signals, locking) and every stage against hand-computed fixtures, including a real local TLS server. Both editions pass the same suite.
- **ShellCheck clean.** [`.shellcheckrc`](.shellcheckrc) disables five checks and says why for each.
- **No dependencies** beyond the standard userland: JSON, INI, `.env`, date arithmetic and percentile maths are all implemented in Bash and POSIX awk.

## Reading guide

If you are here to learn, read the **annotated edition** in this order:

1. `lib/core.sh`: strict mode, the ERR-trap stack trace, a `defer`-style cleanup stack, and the module system
2. `lib/log.sh`, `lib/json.sh`: fork-free formatting, typed JSON encoding, and the bash 5.2 `patsub_replacement` trap
3. `lib/time.sh`: calendar arithmetic with no `date`, using Hinnant's algorithm
4. `lib/ini.sh`, `lib/dotenv.sh`, `lib/pipeline.sh`: parsing config as data, with namerefs and exhaustive validation
5. `lib/dag.sh`: Kahn's topological sort in waves and DFS cycle extraction
6. `lib/retry.sh`, `lib/lock.sh`: full-jitter backoff and `flock` versus atomic `mkdir`
7. `lib/scheduler.sh`: the heart of the engine (`wait -n -p`, signal forwarding, and a real dynamic-scoping bug that was caught and explained)
8. `lib/render.sh`, `lib/run.sh`: the Gantt chart and the run history
9. `lib/stage.sh`, then `stages/*.sh`: each stage is a small, self-contained sysadmin tool
10. `bin/sluice`, then `tests/`: a GNU-style option parser and a test framework written from scratch

## Layout

```text
bin/sluice                 CLI
lib/                       engine modules (core, log, json, time, ini, dotenv, dag, retry,
                           lock, pipeline, scheduler, render, run, stage, demo)
lib/awk/                   access-log analytics and the demo traffic generator (POSIX awk)
stages/                    the 11 stages of the nightly pipeline
pipelines/nightly-ops.ini  the pipeline definition
tests/                     run.sh (TAP runner), helpers.sh, unit/, integration/
.env.example               every configuration knob
.shellcheckrc              lint configuration
```
