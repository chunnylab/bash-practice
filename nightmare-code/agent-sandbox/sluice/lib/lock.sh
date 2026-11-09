#!/usr/bin/env bash

core::import time

declare -gA __LOCK_FD=() __LOCK_DIR=()

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

lock::_alive() {
  kill -0 "$1" 2>/dev/null || [[ -d /proc/$1 ]]
}

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

lock::forget_inherited() {
  local path fd
  for path in "${!__LOCK_FD[@]}"; do
    fd=${__LOCK_FD[$path]}
    exec {fd}>&-
  done
  __LOCK_FD=()
  __LOCK_DIR=()
}
