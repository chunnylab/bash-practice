#!/usr/bin/env bash

core::import log time retry lock render

declare -gA SCHED_STATE=() SCHED_PID2JOB=()
declare -ga SCHED_JOBS=()
declare -gi SCHED_MAX=1 SCHED_FAIL_FAST=0 SCHED_RUNNING=0 SCHED_HALTED=0 SCHED_INTERRUPTED=0
declare -g SCHED_DIR="" SCHED_TIMEOUT_BIN="" SCHED_SIGNAL=""

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

  trap 'sched::_on_signal INT' INT
  trap 'sched::_on_signal TERM' TERM

  sched::_resolve
  sched::_fill
  while (( SCHED_RUNNING > 0 )); do
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

sched::_runner() {
  local job=$1 dir=$2 job_child="" state note="" stage_note="" RETRY_ABORT=""
  local -i rc=0 job_attempts=0 job_timed_out=0 job_terminated=0 start end
  local -a argv=()
  trap 'job_terminated=1; RETRY_ABORT=1; if [[ -n $job_child ]]; then kill -TERM "$job_child" 2>/dev/null || :; fi' TERM

  lock::forget_inherited
  sched::_argv "$job" argv
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

sched::_show_tail() {
  local f=$SCHED_DIR/jobs/$1/stderr.log line
  [[ -s $f ]] || f=$SCHED_DIR/jobs/$1/stdout.log
  [[ -s $f ]] || return 0
  printf '      ---- last lines of %s ----\n' "${f#"$SCHED_DIR/"}" >&2
  while IFS= read -r line; do
    printf '      %s\n' "$line" >&2
  done < <(tail -n 12 -- "$f")
}

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
