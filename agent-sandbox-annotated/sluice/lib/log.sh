#!/usr/bin/env bash
# =============================================================================
# lib/log.sh - leveled, colourised, structured logging
# =============================================================================
#
#   log::info "backup written" archive=/srv/backups/x.tar.gz bytes=1048576
#
# prints a human-oriented line to stderr:
#
#   13:42:03.120 INFO  backup        backup written archive=/srv/... bytes=1048576
#
# and, when SLUICE_EVENTS_FILE is set (the engine sets it for every run),
# appends a machine-oriented JSON line to that file:
#
#   {"ts":"2026-11-05T06:42:03.120Z","level":"info","component":"backup",
#    "msg":"backup written","fields":{"archive":"/srv/...","bytes":1048576}}
#
# Every job of a run appends to the same events.jsonl concurrently. That is
# safe because each event is written with ONE write(2) on a file opened with
# O_APPEND (what >> does); the kernel performs the seek-to-end and the write
# atomically, so lines from parallel jobs never interleave mid-line.
#
# Logs go to stderr on purpose: stdout stays free for real output (data,
# reports), so `sluice graph > pipeline.dot` works while progress is logged.
# =============================================================================

core::import json

declare -gA __LOG_RANK=([trace]=5 [debug]=10 [info]=20 [warn]=30 [error]=40 [silent]=100)
declare -gi __LOG_MIN=20
declare -gA __LOG_STYLE=()
declare -g LOG_COMPONENT=${LOG_COMPONENT:-sluice}

# log::configure - (re)read SLUICE_LOG_LEVEL / NO_COLOR / SLUICE_COLOR.
# Called once at import time and again by the CLI after it parsed --log-level.
log::configure() {
  local level=${SLUICE_LOG_LEVEL:-info}
  level=${level,,}
  if [[ -z ${__LOG_RANK[$level]-} ]]; then
    printf 'sluice: ignoring invalid SLUICE_LOG_LEVEL=%q (use trace|debug|info|warn|error|silent)\n' "$level" >&2
    level=info
  fi
  __LOG_MIN=${__LOG_RANK[$level]}
  __LOG_STYLE=()
  if log::_color_wanted; then
    # $'...' is ANSI-C quoting: \e becomes the ESC byte that starts an ANSI
    # escape sequence. 90=bright black, 36=cyan, 32=green, 33=yellow,
    # 1;31=bold red, 2=dim, 94=bright blue, 0=reset.
    __LOG_STYLE=(
      [trace]=$'\e[90m' [debug]=$'\e[36m' [info]=$'\e[32m' [warn]=$'\e[33m'
      [error]=$'\e[1;31m' [dim]=$'\e[2m' [key]=$'\e[94m' [reset]=$'\e[0m'
    )
  fi
}

# Colour only when a human is watching: stderr is a terminal and the terminal
# can render escapes. NO_COLOR (https://no-color.org) always wins;
# SLUICE_COLOR=always|never overrides the auto-detection.
log::_color_wanted() {
  [[ -z ${NO_COLOR-} ]] || return 1
  case ${SLUICE_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -t 2 && ${TERM:-dumb} != dumb ]]
}

# log::emit LEVEL MESSAGE [KEY=VALUE...]
log::emit() {
  local level=$1 msg=${2-}
  shift 2 || shift $#
  # Cheapest possible early exit for suppressed levels: one array lookup.
  (( ${__LOG_RANK[$level]:-20} >= __LOG_MIN )) || return 0

  # $EPOCHREALTIME is "seconds.microseconds" (bash 5+), read without forking
  # `date`. The separator follows LC_NUMERIC - some locales print a comma -
  # so both halves are split with the bracket pattern [.,].
  local now=$EPOCHREALTIME stamp kv fields=""
  local sec=${now%[.,]*} frac=${now#*[.,]}
  local c=${__LOG_STYLE[$level]-} d=${__LOG_STYLE[dim]-} k=${__LOG_STYLE[key]-} r=${__LOG_STYLE[reset]-}

  # printf's %(fmt)T formats an epoch with strftime(3) - a builtin, no fork.
  printf -v stamp '%(%H:%M:%S)T.%s' "$sec" "${frac:0:3}"
  for kv in "$@"; do
    fields+=" $k${kv%%=*}$r=${kv#*=}"
  done
  printf '%s%s%s %s%-5s%s %s%-13s%s %s%s\n' \
    "$d" "$stamp" "$r" "$c" "${level^^}" "$r" "$d" "$LOG_COMPONENT" "$r" "$msg" "$fields" >&2

  if [[ -n ${SLUICE_EVENTS_FILE-} ]]; then
    log::_event "$level" "$sec" "${frac:0:3}" "$msg" "$@"
  fi
  return 0
}

# Serialise one event as a JSON line. Field values are auto-typed (":a"), so
# bytes=1048576 becomes a JSON number while path=/x stays a string.
# `TZ=UTC printf ...` is a temporary assignment that applies to this single
# builtin: bash notices the TZ change and calls tzset(3) for it.
log::_event() {
  local level=$1 sec=$2 ms=$3 msg=$4 iso kv fields
  shift 4
  local -a spec=()
  for kv in "$@"; do
    spec+=("${kv%%=*}:a=${kv#*=}")
  done
  json::object "${spec[@]}" || return 0
  fields=$REPLY
  TZ=UTC printf -v iso '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "$sec" "$ms"
  json::object "ts=$iso" "level=$level" "component=$LOG_COMPONENT" "msg=$msg" "fields:raw=$fields" || return 0
  printf '%s\n' "$REPLY" >> "$SLUICE_EVENTS_FILE" || :
}

log::trace() { log::emit trace "$@"; }
log::debug() { log::emit debug "$@"; }
log::info() { log::emit info "$@"; }
log::warn() { log::emit warn "$@"; }
log::error() { log::emit error "$@"; }

log::configure
