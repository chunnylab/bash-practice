#!/usr/bin/env bash

core::import json

declare -gA __LOG_RANK=([trace]=5 [debug]=10 [info]=20 [warn]=30 [error]=40 [silent]=100)
declare -gi __LOG_MIN=20
declare -gA __LOG_STYLE=()
declare -g LOG_COMPONENT=${LOG_COMPONENT:-sluice}

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
    __LOG_STYLE=(
      [trace]=$'\e[90m' [debug]=$'\e[36m' [info]=$'\e[32m' [warn]=$'\e[33m'
      [error]=$'\e[1;31m' [dim]=$'\e[2m' [key]=$'\e[94m' [reset]=$'\e[0m'
    )
  fi
}

log::_color_wanted() {
  [[ -z ${NO_COLOR-} ]] || return 1
  case ${SLUICE_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -t 2 && ${TERM:-dumb} != dumb ]]
}

log::emit() {
  local level=$1 msg=${2-}
  shift 2 || shift $#
  (( ${__LOG_RANK[$level]:-20} >= __LOG_MIN )) || return 0

  local now=$EPOCHREALTIME stamp kv fields=""
  local sec=${now%[.,]*} frac=${now#*[.,]}
  local c=${__LOG_STYLE[$level]-} d=${__LOG_STYLE[dim]-} k=${__LOG_STYLE[key]-} r=${__LOG_STYLE[reset]-}

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
