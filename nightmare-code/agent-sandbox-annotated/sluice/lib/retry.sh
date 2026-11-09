#!/usr/bin/env bash
# =============================================================================
# lib/retry.sh - retries with capped exponential backoff and full jitter
# =============================================================================
#
#   retry::run -a 5 -b 500 -m 8000 -x "10 20" -- curl -fsS "$url"
#
#   -a N     total attempts (default 3)
#   -b MS    base delay in milliseconds (default 500)
#   -m MS    maximum delay in milliseconds (default 30000)
#   -x LIST  exit codes that are final and must NOT be retried
#
# Delay before attempt k+1 is a random value in [0, min(max, base * 2^(k-1))]
# - "full jitter" from the AWS Architecture Blog post "Exponential Backoff
# And Jitter". Randomising the WHOLE interval spreads retries of many clients
# evenly instead of letting them stampede in lock-step after an outage.
#
# Hooks for callers and tests:
#   RETRY_ATTEMPT / RETRY_MAX  are visible to the command while it runs (they
#       are locals of retry::run, and bash scoping is dynamic);
#   RETRY_ABORT   set it to anything non-empty (e.g. from a signal trap) to
#       stop retrying after the current attempt;
#   RETRY_SLEEP   name of the sleeper function (default retry::_sleep), so
#       tests can record delays instead of actually sleeping.
#
# Caveat worth knowing: the command runs as the condition of an `if`, a
# context in which bash IGNORES errexit - also inside every function it
# calls. Shell functions run through retry::run must check their own errors.
# =============================================================================

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
    # " 10 20 " == *" 10 "* - padding with spaces avoids matching 1 in 10.
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

# retry::_sleep MILLISECONDS - an interruptible sleep.
# While bash waits for a FOREGROUND child it postpones trap handlers until
# the child exits, so `sleep 30` would delay a SIGTERM handler by up to 30s.
# The `wait` builtin, however, returns as soon as a trapped signal arrives.
# Running sleep in the background and waiting for it keeps us responsive;
# if the wait was interrupted, the orphaned sleep is cleaned up.
retry::_sleep() {
  local -i ms=$1 pid
  local secs
  printf -v secs '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
  sleep "$secs" &
  pid=$!
  wait "$pid" || kill "$pid" 2>/dev/null || :
}
