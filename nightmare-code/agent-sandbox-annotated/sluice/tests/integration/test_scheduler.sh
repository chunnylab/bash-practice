#!/usr/bin/env bash
# tests/integration/test_scheduler.sh - the engine end to end, through the
# real CLI, with small synthetic pipelines written into $TEST_TMP.
#
# Techniques worth noticing in this file:
#   * Pipelines are written with QUOTED heredocs (<<'INI'): bash leaves
#     ${TEST_TMP} alone, so it reaches sluice literally and sluice's own
#     interpolation (core::interpolate) expands it. The tests therefore
#     exercise that code path too.
#   * Stage scripts are tiny one-liners in $TEST_TMP/bin. A script ending in
#     .sh is executed by the engine's own $BASH, so no chmod is needed.
#   * `run = false` / `run = true` / `run = sleep 20` use plain commands as
#     jobs: the quickest way to produce a failure, a success or a slow job.
#   * Assertions read the engine's status files (t::status) instead of
#     parsing console output, so they test the contract, not the formatting.

# _job_script NAME BODY - an executable stage script in $TEST_TMP/bin.
_job_script() {
  mkdir -p -- "$TEST_TMP/bin"
  printf '%s\n' "$2" > "$TEST_TMP/bin/$1.sh"
}

# _run ARGS... - `sluice run ARGS`, exit status in T_RC, output in T_OUT.
# `|| T_RC=$?` keeps a failing run from tripping errexit in the test itself.
_run() {
  T_RC=0
  T_OUT=$(t::sluice run "$@" 2>&1) || T_RC=$?
}

# Parallelism is proven with the start/end timestamps the runners record,
# not with wall-clock measurements of the whole run: "b started before a
# ended" holds on a fast laptop and on a slow CI box alike. With -j 1 the
# same jobs must be strictly sequential.
test_jobs_run_in_parallel_up_to_max_parallel() {
  _job_script nap 'sleep 0.5'
  t::write p.ini <<'INI'
[pipeline]
name = par
max_parallel = 3
[job a]
run = ${TEST_TMP}/bin/nap.sh
[job b]
run = ${TEST_TMP}/bin/nap.sh
[job c]
run = ${TEST_TMP}/bin/nap.sh
INI
  local run
  local -i a1 b0 b1 c0
  _run p.ini
  assert::eq 0 "$T_RC" "parallel run"
  t::latest_run
  run=$REPLY
  t::status "$run" a
  a1=$S_END
  t::status "$run" b
  b0=$S_START
  t::status "$run" c
  c0=$S_START
  (( b0 < a1 && c0 < a1 )) || { printf 'jobs did not overlap\n' >&2; return 1; }

  _run p.ini -j 1
  assert::eq 0 "$T_RC" "serial run"
  t::latest_run
  run=$REPLY
  t::status "$run" a
  a1=$S_END
  t::status "$run" b
  b0=$S_START
  b1=$S_END
  t::status "$run" c
  c0=$S_START
  (( b0 >= a1 && c0 >= b1 )) || { printf -- '-j 1 still overlapped jobs\n' >&2; return 1; }
}

# The jobs are DEFINED in reverse order (c, b, a); the topological sort must
# still run them a -> b -> c. Every run of the script appends the job name
# (SLUICE_JOB is exported by the runner) to one file.
test_dependencies_define_execution_order() {
  _job_script record 'printf "%s\n" "$SLUICE_JOB" >> "$TEST_TMP/order.txt"'
  t::write p.ini <<'INI'
[pipeline]
name = order
max_parallel = 4
[job c]
needs = b
run = ${TEST_TMP}/bin/record.sh
[job b]
needs = a
run = ${TEST_TMP}/bin/record.sh
[job a]
run = ${TEST_TMP}/bin/record.sh
INI
  _run p.ini
  assert::eq 0 "$T_RC"
  assert::eq $'a\nb\nc' "$(< order.txt)"
}

# Each attempt is a NEW process, so the flaky script keeps its attempt
# counter in a file. It fails twice and succeeds on the third attempt;
# retries = 2 allows exactly that many extra attempts. The runner writes
# "==> attempt N of M" separators into the job's logs.
test_failed_attempts_are_retried_until_success() {
  _job_script flaky 'n=$(( $(cat "$TEST_TMP/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TEST_TMP/count"; echo "attempt $n" >&2; (( n >= 3 ))'
  t::write p.ini <<'INI'
[pipeline]
name = retry
[job flaky]
run = ${TEST_TMP}/bin/flaky.sh
retries = 2
retry_delay = 10ms
INI
  _run p.ini
  assert::eq 0 "$T_RC"
  t::latest_run
  t::status "$REPLY" flaky
  assert::eq ok "$S_STATE"
  assert::eq 3 "$S_ATTEMPTS"
  assert::contains "$(< "$REPLY/jobs/flaky/stderr.log")" "==> attempt 3 of 3"
}

# A job that can never succeed: retries = 1 means 2 attempts in total, then
# the job is failed and so is the run (exit 1).
test_retries_are_bounded() {
  t::write p.ini <<'INI'
[pipeline]
name = bounded
[job never]
run = false
retries = 1
retry_delay = 10ms
INI
  _run p.ini
  assert::eq 1 "$T_RC"
  t::latest_run
  t::status "$REPLY" never
  assert::eq failed "$S_STATE"
  assert::eq 2 "$S_ATTEMPTS"
}

# `sleep 20` with a 1 s timeout: the run must end long before 20 s (proof
# that timeout(1) killed the job) and the job must be recorded as "timeout",
# a state distinct from an ordinary failure.
test_timeouts_stop_the_job_and_fail_the_run() {
  test::require_cmd timeout
  t::write p.ini <<'INI'
[pipeline]
name = slow
[job slow]
run = sleep 20
timeout = 1s
INI
  local -i began
  time::now_ms
  began=$REPLY
  _run p.ini
  time::now_ms
  assert::eq 1 "$T_RC"
  (( REPLY - began < 10000 )) || { printf 'timeout was not enforced\n' >&2; return 1; }
  t::latest_run
  t::status "$REPLY" slow
  assert::eq timeout "$S_STATE"
  assert::contains "$S_NOTE" "exceeded the 1.00s timeout"
}

# Trigger rules in one graph:
#   boom fails -> child (needs boom) is cancelled -> grandchild (needs child)
#   is cancelled too, with a note naming the job that blocked it;
#   finally (when = always) still runs; independent is unaffected.
test_failures_cascade_but_always_jobs_still_run() {
  t::write p.ini <<'INI'
[pipeline]
name = cascade
max_parallel = 2
[job boom]
run = false
[job child]
needs = boom
run = true
[job grandchild]
needs = child
run = true
[job finally]
needs = child
when = always
run = true
[job independent]
run = true
INI
  local run
  _run p.ini
  assert::eq 1 "$T_RC"
  t::latest_run
  run=$REPLY
  t::status "$run" boom
  assert::eq failed "$S_STATE"
  t::status "$run" child
  assert::eq cancelled "$S_STATE"
  assert::eq "upstream job 'boom' failed" "$S_NOTE"
  t::status "$run" grandchild
  assert::eq "upstream job 'child' cancelled" "$S_NOTE"
  t::status "$run" finally
  assert::eq ok "$S_STATE"
  t::status "$run" independent
  assert::eq ok "$S_STATE"
  t::meta "$run" status
  assert::eq failed "$REPLY"
}

# allow_failure: the failure is reported (run status "warn") but neither
# blocks the dependent job nor changes the exit status - unless --strict
# asks for warnings to count as failures.
test_allowed_failures_warn_without_blocking() {
  t::write p.ini <<'INI'
[pipeline]
name = tolerant
[job flaky]
run = false
allow_failure = yes
[job next]
needs = flaky
run = true
INI
  _run p.ini
  assert::eq 0 "$T_RC" "allowed failure keeps exit 0"
  t::latest_run
  t::status "$REPLY" next
  assert::eq ok "$S_STATE"
  t::meta "$REPLY" status
  assert::eq warn "$REPLY"
  _run p.ini --strict
  assert::eq 1 "$T_RC" "--strict turns warnings into failure"
}

# max_parallel = 1 makes "later" wait in the READY queue while "bad" runs.
# When "bad" fails, fail_fast must cancel that queued job (the bug this test
# guards against: queued jobs used to start anyway), while the
# `when = always` cleanup job still runs. --keep-going overrides fail_fast.
test_fail_fast_cancels_queued_jobs() {
  t::write p.ini <<'INI'
[pipeline]
name = fastfail
max_parallel = 1
fail_fast = true
[job bad]
run = false
[job later]
run = true
[job cleanup]
needs = later
when = always
run = true
INI
  local run
  _run p.ini
  assert::eq 1 "$T_RC"
  t::latest_run
  run=$REPLY
  t::status "$run" later
  assert::eq cancelled "$S_STATE"
  assert::contains "$S_NOTE" "fail-fast"
  t::status "$run" cleanup
  assert::eq ok "$S_STATE"
  _run p.ini --keep-going
  t::latest_run
  t::status "$REPLY" later
  assert::eq ok "$S_STATE" "--keep-going overrides fail_fast"
}

# The stage exit-code contract: 10 = warn, 20 = skipped. Both count as
# "done" for dependents, so "after" runs, and the run exits 0.
test_stage_exit_codes_map_to_warn_and_skipped() {
  _job_script w 'exit 10'
  _job_script s 'exit 20'
  t::write p.ini <<'INI'
[pipeline]
name = codes
[job w]
run = ${TEST_TMP}/bin/w.sh
[job s]
run = ${TEST_TMP}/bin/s.sh
[job after]
needs = w, s
run = true
INI
  local run
  _run p.ini
  assert::eq 0 "$T_RC"
  t::latest_run
  run=$REPLY
  t::status "$run" w
  assert::eq warn "$S_STATE"
  t::status "$run" s
  assert::eq skipped "$S_STATE"
  t::status "$run" after
  assert::eq ok "$S_STATE"
}

# Background processes of a non-interactive shell ignore SIGINT, so the
# interrupt path is exercised with SIGTERM, which shares the same handler.
# sluice is started directly as a background SIMPLE command, so $! is the
# PID of the sluice process itself (not of a wrapper subshell). The test
# polls until the job has started, signals, then checks the bookkeeping:
# the running job "interrupted", the pending one "cancelled", exit 143.
test_sigterm_interrupts_running_jobs_and_cancels_the_rest() {
  t::write p.ini <<'INI'
[pipeline]
name = interrupt
[job long]
run = sleep 30
[job after]
needs = long
run = true
INI
  local run
  local -i pid rc=0 began
  time::now_ms
  began=$REPLY
  "$BASH" "$SLUICE_HOME/bin/sluice" run p.ini > out.txt 2>&1 &
  pid=$!
  t::wait_for 15 t::job_started long
  sleep 0.5
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  time::now_ms
  assert::eq 143 "$rc" "exit status after SIGTERM"
  (( REPLY - began < 15000 )) || { printf 'interrupt took too long\n' >&2; return 1; }
  t::latest_run
  run=$REPLY
  t::status "$run" long
  assert::eq interrupted "$S_STATE"
  t::status "$run" after
  assert::eq cancelled "$S_STATE"
  t::meta "$run" status
  assert::eq interrupted "$REPLY"
}

# While one run holds the pipeline lock, a second run must refuse to start
# with EX_TEMPFAIL (75) and an actionable message.
test_concurrent_runs_of_one_pipeline_are_rejected() {
  t::write p.ini <<'INI'
[pipeline]
name = lockme
[job long]
run = sleep 30
INI
  local -i first
  "$BASH" "$SLUICE_HOME/bin/sluice" run p.ini > first.txt 2>&1 &
  first=$!
  t::wait_for 15 t::job_started long
  assert::rc 75 t::sluice run p.ini
  assert::contains "$T_OUT" "another 'lockme' run is in progress"
  kill -TERM "$first"
  wait "$first" || :
}

# Three broken definitions, each rejected by `validate` with EX_DATAERR (65)
# and a precise message: a cycle (reported as a path), a typo in a key plus
# a bad value (both reported in one pass), and a missing script.
test_invalid_pipelines_are_rejected_before_running() {
  t::write cycle.ini <<'INI'
[pipeline]
name = cycle
[job a]
needs = b
run = true
[job b]
needs = a
run = true
INI
  assert::rc 65 t::sluice validate cycle.ini
  assert::contains "$T_OUT" "dependency cycle: a -> b -> a"

  t::write typo.ini <<'INI'
[pipeline]
name = typo
max_parallel = many
[job a]
neeeds = b
run = true
[job b]
run = stages/does-not-exist.sh
INI
  assert::rc 65 t::sluice validate typo.ini
  assert::contains "$T_OUT" "job 'a': unknown key 'neeeds'"
  assert::contains "$T_OUT" "max_parallel must be an integer from 1 to 64"

  t::write missing.ini <<'INI'
[pipeline]
name = missing
[job b]
run = stages/does-not-exist.sh
INI
  assert::rc 65 t::sluice validate missing.ini
  assert::contains "$T_OUT" "script not found"
}

# --target d runs d plus its transitive dependencies (a, b) and nothing else;
# jobs.order of the run records exactly that selection.
test_target_runs_only_the_needed_subgraph() {
  t::write p.ini <<'INI'
[pipeline]
name = subset
[job a]
run = true
[job b]
needs = a
run = true
[job c]
needs = a
run = true
[job d]
needs = b
run = true
INI
  _run p.ini --target d
  assert::eq 0 "$T_RC"
  t::latest_run
  assert::eq $'a\nb\nd' "$(< "$REPLY/jobs.order")"
  assert::rc 64 t::sluice run p.ini --target nope
}

# Configuration precedence, observed from inside a job:
#   run 1: GREETING comes from the --env-file (beats the [env] default),
#          SHADE is an [env] default built from another [env] default,
#          and -n exports SLUICE_DRY_RUN=1;
#   run 2: COLOR=red in the environment beats the [env] default "blue".
# `COLOR=red _run ...` is a temporary assignment for one function call; bash
# exports such assignments to the processes the function starts.
test_configuration_precedence_and_dry_run_reach_jobs() {
  _job_script env 'printf "%s|%s|%s\n" "$SLUICE_DRY_RUN" "${GREETING:-}" "$SHADE" > "$TEST_TMP/env.txt"'
  t::write p.ini <<'INI'
[pipeline]
name = envs
[env]
COLOR = blue
SHADE = dark ${COLOR}
GREETING = from-pipeline
[job show]
run = ${TEST_TMP}/bin/env.sh
INI
  printf 'GREETING="hello from .env"\n' > custom.env
  _run p.ini -n -e custom.env
  assert::eq 0 "$T_RC"
  assert::eq '1|hello from .env|dark blue' "$(< env.txt)"
  COLOR=red _run p.ini
  assert::eq '0|from-pipeline|dark red' "$(< env.txt)"
}
