#!/usr/bin/env bash
# =============================================================================
# lib/scheduler.sh - bounded-parallel DAG executor
# =============================================================================
#
# Job lifecycle (one state per job, kept in SCHED_STATE):
#
#   pending --deps done--> ready --slot free--> running --> ok | warn | skipped
#      |                     |                     |        | failed | timeout
#      +---------------------+--> cancelled        +--> interrupted (signal)
#        (upstream failed, fail-fast halt, or the run was interrupted)
#
# The main loop is event driven and never polls:
#
#   resolve   promote pending jobs whose dependencies are all terminal to
#             "ready" - or "cancelled" when the trigger rule forbids running
#   fill      launch ready jobs (in topological order) while slots are free
#   wait      `wait -n -p pid <our pids>` sleeps until ANY job exits and tells
#             us which one (bash 5.1+); no `sleep 0.1` loops, no CPU burned
#   reap      read the finished job's status file, then resolve/fill again
#
# Trigger rules (`when` in the pipeline file):
#   success   (default) run only if every dependency ended ok/warn/skipped,
#             or failed with allow_failure = true
#   always    run once every dependency is terminal, whatever its outcome -
#             how the report and notify jobs still run after a failure
#
# Each job runs in a background subshell (the "runner") that owns retries,
# the timeout and the log files, and finally writes ONE status line with an
# atomic rename. The parent therefore only exchanges files and signals with
# its children - no shared memory, no races.
#
# Status file format (TAB-separated, a single line):
#   state  exit_code  attempts  start_ms  end_ms  note
# =============================================================================

core::import log time retry lock render

declare -gA SCHED_STATE=() SCHED_PID2JOB=()
declare -ga SCHED_JOBS=()
declare -gi SCHED_MAX=1 SCHED_FAIL_FAST=0 SCHED_RUNNING=0 SCHED_HALTED=0 SCHED_INTERRUPTED=0
declare -g SCHED_DIR="" SCHED_TIMEOUT_BIN="" SCHED_SIGNAL=""

# sched::run RUN_DIR MAX_PARALLEL FAIL_FAST JOB... (jobs in topological order)
sched::run() {
  SCHED_DIR=$1
  SCHED_MAX=$2
  SCHED_FAIL_FAST=$3
  shift 3
  SCHED_JOBS=("$@")
  SCHED_STATE=() SCHED_PID2JOB=()
  SCHED_RUNNING=0 SCHED_HALTED=0 SCHED_INTERRUPTED=0 SCHED_SIGNAL=""
  local LOG_COMPONENT=sched job pid
  local -i rc

  sched::_detect_timeout
  for job in "${SCHED_JOBS[@]}"; do
    SCHED_STATE[$job]=pending
  done

  # Replace core's "clean up and die" handlers: an interrupted run must stop
  # its children, let them record their state and still print a summary.
  trap 'sched::_on_signal INT' INT
  trap 'sched::_on_signal TERM' TERM

  sched::_resolve
  sched::_fill
  while (( SCHED_RUNNING > 0 )); do
    # `-p pid` receives the PID of the job that finished; bash UNSETS the
    # variable first, hence ${pid-} below (we run under `set -u`). Listing
    # our PIDs explicitly makes unrelated background processes invisible.
    # A trapped signal interrupts `wait` (status > 128) without reaping
    # anything: the handler has run, so we simply loop and wait again.
    if wait -n -p pid "${!SCHED_PID2JOB[@]}"; then
      rc=0
    else
      rc=$?
    fi
    if [[ -z ${pid-} ]]; then
      if (( rc == 127 )); then
        log::error "scheduler lost track of $SCHED_RUNNING running job(s)"
        break
      fi
      continue
    fi
    sched::_reap "$pid"
    sched::_resolve
    sched::_fill
  done

  core::install_traps
}

sched::_detect_timeout() {
  local job c
  SCHED_TIMEOUT_BIN=""
  for c in timeout gtimeout; do
    if core::have "$c"; then
      SCHED_TIMEOUT_BIN=$c
      return 0
    fi
  done
  for job in "${SCHED_JOBS[@]}"; do
    if (( JOB_TIMEOUT_MS[$job] > 0 )); then
      log::warn "timeout(1) not found: per-job timeouts will NOT be enforced (install GNU coreutils)"
      return 0
    fi
  done
}

# -----------------------------------------------------------------------------
# sched::_resolve - decide the fate of pending jobs whose dependencies are
# all terminal. Jobs are visited in topological order, so a cancellation
# cascades down the graph within this single pass.
#
# Jobs already "ready" (queued, waiting for a free slot) are re-examined as
# well: after a fail-fast halt or an interrupt they must not start either.
# -----------------------------------------------------------------------------
sched::_resolve() {
  local job dep blocker
  local -a deps=()
  local -i settled
  for job in "${SCHED_JOBS[@]}"; do
    case ${SCHED_STATE[$job]} in
      pending) ;;
      ready)
        if (( SCHED_INTERRUPTED )); then
          sched::_cancel "$job" "run interrupted"
        elif (( SCHED_HALTED )) && [[ ${JOB_WHEN[$job]} != always ]]; then
          sched::_cancel "$job" "fail-fast: pipeline halted after a failure"
        fi
        continue
        ;;
      *) continue ;;
    esac
    read -r -a deps <<< "${JOB_NEEDS[$job]-}"
    settled=1 blocker=""
    for dep in "${deps[@]}"; do
      case ${SCHED_STATE[$dep]-ok} in
        pending | ready | running)
          settled=0
          break
          ;;
        ok | warn | skipped) ;;
        failed | timeout)
          if (( ! JOB_ALLOW_FAILURE[$dep] )); then
            blocker=${blocker:-$dep}
          fi
          ;;
        *) blocker=${blocker:-$dep} ;;
      esac
    done
    (( settled )) || continue

    if (( SCHED_INTERRUPTED )); then
      sched::_cancel "$job" "run interrupted"
    elif [[ ${JOB_WHEN[$job]} == always ]]; then
      SCHED_STATE[$job]=ready
    elif (( SCHED_HALTED )); then
      sched::_cancel "$job" "fail-fast: pipeline halted after a failure"
    elif [[ -n $blocker ]]; then
      sched::_cancel "$job" "upstream job '$blocker' ${SCHED_STATE[$blocker]}"
    else
      SCHED_STATE[$job]=ready
    fi
  done
}

# sched::_fill - start ready jobs while there are free slots.
sched::_fill() {
  local job
  (( SCHED_INTERRUPTED == 0 )) || return 0
  for job in "${SCHED_JOBS[@]}"; do
    (( SCHED_RUNNING < SCHED_MAX )) || break
    [[ ${SCHED_STATE[$job]} == ready ]] || continue
    sched::_launch "$job"
  done
  return 0
}

sched::_launch() {
  local job=$1 dir=$SCHED_DIR/jobs/$1
  mkdir -p -- "$dir"
  SCHED_STATE[$job]=running
  # A function followed by & runs in a background SUBSHELL: a forked copy of
  # this shell with every variable and function, but its own PID ($BASHPID).
  sched::_runner "$job" "$dir" &
  SCHED_PID2JOB[$!]=$job
  SCHED_RUNNING=$(( SCHED_RUNNING + 1 ))
  log::info "${RENDER_ICON[running]} $job" pid="$!"
}

sched::_cancel() {
  local job=$1 note=$2
  SCHED_STATE[$job]=cancelled
  mkdir -p -- "$SCHED_DIR/jobs/$job"
  time::now_ms
  sched::_write_status "$SCHED_DIR/jobs/$job/status" cancelled 0 0 "$REPLY" "$REPLY" "$note"
  log::warn "${RENDER_ICON[cancelled]} $job" reason="$note"
}

# -----------------------------------------------------------------------------
# sched::_runner JOB DIR - body of the background subshell for one job.
#
# Communication with the helpers below relies on DYNAMIC SCOPING: the locals
# declared here (job_child, job_attempts, job_timed_out, job_terminated,
# RETRY_ABORT) are read and assigned by sched::_attempt and
# sched::_await_child, because those run (via retry::run) BELOW this frame.
#
# The job_ prefix is not cosmetic. A name lookup walks up the call stack and
# stops at the NEAREST frame declaring that name - and retry::run, which sits
# between us and sched::_attempt, has its own local called `attempts` (its
# attempt limit). A plain `attempts=$RETRY_ATTEMPT` in sched::_attempt would
# overwrite the retry limit instead of our counter and silently disable
# retries. Unique names make every dynamic-scope link unambiguous.
#
# Signals: async subshells of a non-interactive shell ignore SIGINT, so a
# terminal Ctrl-C reaches only the parent. The parent then sends SIGTERM to
# each runner; the trap below forwards it to the job's process and tells
# retry::run (via RETRY_ABORT) not to start another attempt.
# -----------------------------------------------------------------------------
sched::_runner() {
  local job=$1 dir=$2 job_child="" state note="" stage_note="" RETRY_ABORT=""
  local -i rc=0 job_attempts=0 job_timed_out=0 job_terminated=0 start end
  local -a argv=()
  trap 'job_terminated=1; RETRY_ABORT=1; if [[ -n $job_child ]]; then kill -TERM "$job_child" 2>/dev/null || :; fi' TERM

  lock::forget_inherited
  sched::_argv "$job" argv
  # NO_COLOR keeps ANSI escapes out of log files for every tool that honours
  # the convention, not just our own logger.
  export SLUICE_JOB=$job SLUICE_JOB_DIR=$dir NO_COLOR=1
  : > "$dir/stdout.log"
  : > "$dir/stderr.log"
  rm -f -- "$dir/note"

  time::now_ms
  start=$REPLY
  if retry::run -a $(( JOB_RETRIES[$job] + 1 )) -b "${JOB_RETRY_DELAY_MS[$job]}" -m 60000 \
    -x "$EX_WARN $EX_SKIP 130" -- sched::_attempt "$job" "$dir" "${argv[@]}"; then
    rc=0
  else
    rc=$?
  fi
  time::now_ms
  end=$REPLY

  if [[ -r $dir/note ]]; then
    IFS= read -r stage_note < "$dir/note" || :
  fi
  if (( job_terminated )); then
    state=interrupted note="terminated by signal"
  elif (( rc == 0 )); then
    state=ok note=$stage_note
  elif (( rc == EX_WARN )); then
    state=warn note=$stage_note
  elif (( rc == EX_SKIP )); then
    state=skipped note=$stage_note
  elif (( job_timed_out )); then
    time::fmt_duration "${JOB_TIMEOUT_MS[$job]}"
    state=timeout note="exceeded the ${REPLY} timeout"
  else
    state=failed note="exit status $rc${stage_note:+: $stage_note}"
  fi
  sched::_write_status "$dir/status" "$state" "$rc" "$job_attempts" "$start" "$end" "$note"
}

# sched::_argv JOB OUT_ARRAY - split the `run` line into an argv.
# Words are split on whitespace (no shell re-parsing: quotes, $(...) and ;
# have no special meaning). A *.sh program is executed by the SAME bash
# binary that runs the engine ($BASH), so the exec bit and the script's
# shebang do not matter - handy on filesystems without POSIX permissions.
# Relative script paths are resolved against SLUICE_HOME.
sched::_argv() {
  local -n __sa_out=$2
  read -r -a __sa_out <<< "${JOB_RUN[$1]}"
  if [[ ${__sa_out[0]} == *.sh ]]; then
    if [[ ${__sa_out[0]} != /* ]]; then
      __sa_out[0]=$SLUICE_HOME/${__sa_out[0]}
    fi
    __sa_out=("$BASH" "${__sa_out[@]}")
  fi
}

# One attempt: optional timeout wrapper, output appended to the log files.
# GNU timeout(1) puts itself and the job in a NEW process group and, on
# expiry, signals the whole group - grandchildren (tar, awk, ...) die too.
# Its exit status is 124 on timeout, or 137 if it had to escalate to SIGKILL
# after the -k grace period.
sched::_attempt() {
  local job=$1 dir=$2
  shift 2
  local -i r=0 tmo=${JOB_TIMEOUT_MS[$job]} began
  local secs
  local -a cmd=()
  job_attempts=$RETRY_ATTEMPT
  (( job_terminated == 0 )) || return 130
  export SLUICE_ATTEMPT=$RETRY_ATTEMPT
  if (( tmo > 0 )) && [[ -n $SCHED_TIMEOUT_BIN ]]; then
    printf -v secs '%d.%03d' $(( tmo / 1000 )) $(( tmo % 1000 ))
    cmd=("$SCHED_TIMEOUT_BIN" -k 5 "$secs")
  fi
  cmd+=("$@")
  if (( RETRY_MAX > 1 )); then
    printf '==> attempt %d of %d\n' "$RETRY_ATTEMPT" "$RETRY_MAX" >> "$dir/stdout.log"
    printf '==> attempt %d of %d\n' "$RETRY_ATTEMPT" "$RETRY_MAX" >> "$dir/stderr.log"
  fi
  time::now_ms
  began=$REPLY
  "${cmd[@]}" >> "$dir/stdout.log" 2>> "$dir/stderr.log" &
  job_child=$!
  sched::_await_child
  job_child=""
  (( job_terminated == 0 )) || return 130
  time::now_ms
  if (( r == 124 || (r == 137 && tmo > 0 && REPLY - began >= tmo) )); then
    job_timed_out=1
  else
    job_timed_out=0
  fi
  return "$r"
}

# Wait for $job_child, surviving interruptions: when our TERM trap fires,
# `wait` returns >128 although the child still lives (it is busy dying), so
# we wait again until it is really gone. Sets `r` in sched::_attempt.
sched::_await_child() {
  local -i s
  while :; do
    if wait "$job_child"; then
      s=0
    else
      s=$?
    fi
    if (( s > 128 )) && kill -0 "$job_child" 2>/dev/null; then
      continue
    fi
    break
  done
  r=$s
}

# A TAB is "IFS whitespace", so `read` would merge an empty field with its
# neighbours. That is why the only optional field (note) comes last and why
# tabs/newlines inside the note are flattened to spaces.
sched::_write_status() {
  local -r ws=$'\t\n\r'
  local note=${7//[$ws]/ }
  core::atomic_write "$1" "$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"$'\t'"$note"$'\n'
}

sched::_reap() {
  local pid=$1 job state rc attempts start end note took f
  job=${SCHED_PID2JOB[$pid]-}
  [[ -n $job ]] || return 0
  unset 'SCHED_PID2JOB[$pid]'
  SCHED_RUNNING=$(( SCHED_RUNNING - 1 ))
  f=$SCHED_DIR/jobs/$job/status

  if [[ ! -r $f ]] || ! IFS=$'\t' read -r state rc attempts start end note < "$f"; then
    time::now_ms
    start=$REPLY end=$REPLY rc=$EX_SOFTWARE attempts=0
    if (( SCHED_INTERRUPTED )); then
      state=interrupted note="killed before recording a status"
    else
      state=failed note="job runner died without recording a status"
    fi
    sched::_write_status "$f" "$state" "$rc" "$attempts" "$start" "$end" "$note"
  fi
  SCHED_STATE[$job]=$state
  time::fmt_duration $(( end - start ))
  took=$REPLY

  case $state in
    ok) log::info "${RENDER_ICON[ok]} $job" took="$took" attempts="$attempts" ;;
    warn | skipped) log::warn "${RENDER_ICON[$state]} $job" state="$state" took="$took" note="$note" ;;
    interrupted) log::warn "${RENDER_ICON[interrupted]} $job" took="$took" ;;
    *)
      log::error "${RENDER_ICON[$state]} $job" state="$state" took="$took" attempts="$attempts" note="$note"
      sched::_show_tail "$job"
      ;;
  esac

  if [[ $state == failed || $state == timeout ]] && (( ! JOB_ALLOW_FAILURE[$job] )); then
    if (( SCHED_FAIL_FAST && ! SCHED_HALTED )); then
      SCHED_HALTED=1
      log::warn "fail-fast: no new jobs will be started; 'when = always' jobs still run"
    fi
  fi
}

# Show the end of a failed job's output - the part that usually explains it.
sched::_show_tail() {
  local f=$SCHED_DIR/jobs/$1/stderr.log line
  [[ -s $f ]] || f=$SCHED_DIR/jobs/$1/stdout.log
  [[ -s $f ]] || return 0
  printf '      ---- last lines of %s ----\n' "${f#"$SCHED_DIR/"}" >&2
  while IFS= read -r line; do
    printf '      %s\n' "$line" >&2
  done < <(tail -n 12 -- "$f")
}

# Signal handler of the main process. First signal: stop scheduling and ask
# every runner to terminate (they record "interrupted" and exit). A second
# signal means "now": SIGKILL the runners, with no further bookkeeping.
sched::_on_signal() {
  local sig=$1 pid
  if (( SCHED_INTERRUPTED )); then
    log::error "second SIG$sig: killing all runners"
    for pid in "${!SCHED_PID2JOB[@]}"; do
      kill -KILL "$pid" 2>/dev/null || :
    done
    return 0
  fi
  SCHED_INTERRUPTED=1
  SCHED_SIGNAL=$sig
  log::warn "caught SIG$sig: terminating $SCHED_RUNNING running job(s), cancelling the rest"
  for pid in "${!SCHED_PID2JOB[@]}"; do
    kill -TERM "$pid" 2>/dev/null || :
  done
}
