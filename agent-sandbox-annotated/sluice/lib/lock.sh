#!/usr/bin/env bash
# =============================================================================
# lib/lock.sh - inter-process mutual exclusion
# =============================================================================
#
#   lock::acquire /var/lock/nightly.lock 30 || exit "$EX_TEMPFAIL"
#   ...critical section...
#   lock::release /var/lock/nightly.lock    # optional: also done at exit
#
# Two backends, chosen by SLUICE_LOCK_BACKEND=auto|flock|mkdir:
#
# flock (preferred, util-linux): an advisory lock on an open file descriptor.
#   The kernel drops it automatically when the holder dies - even on SIGKILL
#   - so stale locks cannot exist. `exec {fd}>>file` asks bash to open the
#   file on the lowest free descriptor >= 10 and store its NUMBER in $fd
#   (no hard-coded fd 9 that could collide with someone else's). Append mode
#   (>>) matters: opening with > would truncate the holder's PID record
#   before we even know whether we get the lock.
#
# mkdir (fallback; Git Bash and macOS have no flock): mkdir(2) is atomic -
#   exactly one process can create a directory. A crash leaves the directory
#   behind, so the owner's PID and host are recorded inside and a lock whose
#   owner is gone is reclaimed. Reclaiming RENAMES the stale directory away
#   first: two waiters may both decide the lock is stale, but only one rename
#   can succeed, so they cannot both "win". Use this backend on NFS too,
#   where flock semantics are unreliable.
# =============================================================================

core::import time

declare -gA __LOCK_FD=() __LOCK_DIR=()

# lock::acquire PATH [WAIT_SECONDS=0] - 0 on success, EX_TEMPFAIL when busy.
lock::acquire() {
  local path=$1 backend=${SLUICE_LOCK_BACKEND:-auto}
  local -i wait_s=${2:-0}
  if [[ $backend == auto ]]; then
    if core::have flock; then
      backend='flock'
    else
      backend='mkdir'
    fi
  fi
  case $backend in
    flock) lock::_flock "$path" "$wait_s" || return ;;
    mkdir) lock::_mkdir "$path" "$wait_s" || return ;;
    *) core::die "unknown SLUICE_LOCK_BACKEND '$backend' (use auto|flock|mkdir)" "$EX_CONFIG" ;;
  esac
  core::on_exit lock::release "$path"
}

lock::_flock() {
  local path=$1 fd
  local -i wait_s=$2
  exec {fd}>>"$path" || return "$EX_CANTCREAT"
  local -a mode=(-n)
  if (( wait_s > 0 )); then
    mode=(-w "$wait_s")
  fi
  if ! flock "${mode[@]}" "$fd"; then
    exec {fd}>&-
    return "$EX_TEMPFAIL"
  fi
  printf '%d %s %d\n' "$BASHPID" "${HOSTNAME:-unknown}" "$EPOCHSECONDS" > "$path"
  __LOCK_FD[$path]=$fd
}

lock::_mkdir() {
  local path=$1 dir=$1.d pid host
  local -i wait_s=$2 deadline
  time::now_ms
  deadline=$(( REPLY + wait_s * 1000 ))
  while :; do
    if mkdir -- "$dir" 2>/dev/null; then
      printf '%d %s %d\n' "$BASHPID" "${HOSTNAME:-unknown}" "$EPOCHSECONDS" > "$dir/owner"
      __LOCK_DIR[$path]=$dir
      return 0
    fi
    # 2>/dev/null comes BEFORE the < redirection on purpose: redirections are
    # applied left to right, so stderr is already silenced when opening an
    # owner file that the winning process has not written yet fails.
    if IFS=' ' read -r pid host _ 2>/dev/null < "$dir/owner"; then
      if [[ $host == "${HOSTNAME:-unknown}" ]] && ! lock::_alive "$pid"; then
        log::warn "reclaiming stale lock" lock="$path" dead_pid="$pid"
        if mv -- "$dir" "$dir.stale.$BASHPID" 2>/dev/null; then
          rm -rf -- "$dir.stale.$BASHPID"
        fi
        continue
      fi
    fi
    time::now_ms
    if (( REPLY >= deadline )); then
      return "$EX_TEMPFAIL"
    fi
    sleep 0.1
  done
}

# kill -0 sends no signal; it only checks that the PID exists and that we may
# signal it. It also fails with EPERM for live processes of OTHER users, so
# /proc/<pid> (Linux, Cygwin/MSYS) is consulted before declaring death.
lock::_alive() {
  kill -0 "$1" 2>/dev/null || [[ -d /proc/$1 ]]
}

# lock::release PATH - idempotent; unknown paths are ignored.
lock::release() {
  local path=$1 fd
  if [[ -n ${__LOCK_FD[$path]-} ]]; then
    fd=${__LOCK_FD[$path]}
    exec {fd}>&-
    unset '__LOCK_FD[$path]'
  fi
  if [[ -n ${__LOCK_DIR[$path]-} ]]; then
    rm -rf -- "${__LOCK_DIR[$path]}"
    unset '__LOCK_DIR[$path]'
  fi
}

# lock::forget_inherited - called at the start of every job runner.
# A forked child inherits the parent's descriptors; a long-running stage
# holding the run lock's fd would keep the lock alive after the engine
# exited. Closing it here prevents that, and forgetting the mkdir lock
# prevents the child from deleting a lock it does not own.
lock::forget_inherited() {
  local path fd
  for path in "${!__LOCK_FD[@]}"; do
    fd=${__LOCK_FD[$path]}
    exec {fd}>&-
  done
  __LOCK_FD=()
  __LOCK_DIR=()
}
