#!/usr/bin/env bash

retry::run() {
  local -i attempts=3 base=500 max=30000 rc=0 cap delay exp
  local final="" opt OPTARG
  local -i OPTIND=1
  while getopts ':a:b:m:x:' opt; do
    case $opt in
      a) attempts=$OPTARG ;;
      b) base=$OPTARG ;;
      m) max=$OPTARG ;;
      x) final=" $OPTARG " ;;
      *)
        log::error "retry::run: invalid option -$OPTARG"
        return "$EX_USAGE"
        ;;
    esac
  done
  shift $(( OPTIND - 1 ))
  if [[ ${1-} == -- ]]; then
    shift
  fi
  if (( $# == 0 )); then
    log::error "retry::run: missing command"
    return "$EX_USAGE"
  fi
  (( attempts >= 1 )) || attempts=1

  local -i RETRY_ATTEMPT RETRY_MAX=$attempts
  for (( RETRY_ATTEMPT = 1; RETRY_ATTEMPT <= attempts; RETRY_ATTEMPT++ )); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if [[ $final == *" $rc "* ]]; then
      return "$rc"
    fi
    if (( RETRY_ATTEMPT == attempts )) || [[ -n ${RETRY_ABORT-} ]]; then
      break
    fi
    exp=$(( RETRY_ATTEMPT - 1 > 20 ? 20 : RETRY_ATTEMPT - 1 ))
    cap=$(( base * 2 ** exp ))
    if (( cap > max )); then
      cap=$max
    fi
    delay=$(( SRANDOM % (cap + 1) ))
    log::debug "attempt failed, backing off" attempt="$RETRY_ATTEMPT/$attempts" rc="$rc" delay_ms="$delay"
    "${RETRY_SLEEP:-retry::_sleep}" "$delay"
    if [[ -n ${RETRY_ABORT-} ]]; then
      break
    fi
  done
  return "$rc"
}

retry::_sleep() {
  local -i ms=$1 pid
  local secs
  printf -v secs '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
  sleep "$secs" &
  pid=$!
  wait "$pid" || kill "$pid" 2>/dev/null || :
}
