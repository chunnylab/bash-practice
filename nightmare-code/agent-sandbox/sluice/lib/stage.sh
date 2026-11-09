#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/core.sh"
core::import log json time

declare -gA __STAGE_RANK=([info]=0 [low]=1 [medium]=2 [high]=3 [critical]=4)
declare -g STAGE_NAME="" STAGE_OUT=""
declare -gi STAGE_DRY_RUN=0 __STAGE_WORST=-1 __STAGE_FINDINGS=0
declare -gA __STAGE_SEVERITY_COUNT=()

stage::init() {
  STAGE_NAME=${SLUICE_JOB:-$1}
  LOG_COMPONENT=$STAGE_NAME
  STAGE_OUT=${SLUICE_ARTIFACTS:-${SLUICE_VAR_DIR:-$SLUICE_HOME/var}/adhoc}/$STAGE_NAME
  mkdir -p -- "$STAGE_OUT"
  : > "$STAGE_OUT/metrics.tsv"
  : > "$STAGE_OUT/findings.tsv"
  STAGE_DRY_RUN=0
  if core::is_true "${SLUICE_DRY_RUN:-0}"; then
    STAGE_DRY_RUN=1
  fi
  log::debug "stage initialised" out="$STAGE_OUT" dry_run="$STAGE_DRY_RUN"
}

stage::metric() {
  local -r ws=$'\t\n\r'
  printf '%s\t%s\n' "$1" "${2//[$ws]/ }" >> "$STAGE_OUT/metrics.tsv"
}

stage::finding() {
  local -r ws=$'\t\n\r'
  local sev=${1,,} code=$2 msg=${3//[$ws]/ }
  if [[ -z ${__STAGE_RANK[$sev]-} ]]; then
    core::die "stage::finding: unknown severity '$1' (use info|low|medium|high|critical)" "$EX_SOFTWARE"
  fi
  printf '%s\t%s\t%s\n' "$sev" "$code" "$msg" >> "$STAGE_OUT/findings.tsv"
  (( ++__STAGE_FINDINGS ))
  __STAGE_SEVERITY_COUNT[$sev]=$(( ${__STAGE_SEVERITY_COUNT[$sev]:-0} + 1 ))
  if (( __STAGE_RANK[$sev] > __STAGE_WORST )); then
    __STAGE_WORST=${__STAGE_RANK[$sev]}
  fi
  case $sev in
    info | low) log::info "finding [$sev] $code: $msg" ;;
    *) log::warn "finding [$sev] $code: $msg" ;;
  esac
}

stage::note() {
  if [[ -n ${SLUICE_JOB_DIR-} && -d ${SLUICE_JOB_DIR} ]]; then
    printf '%s\n' "${1//$'\n'/ }" > "$SLUICE_JOB_DIR/note"
  fi
}

stage::skip() {
  log::warn "skipped: $1"
  stage::note "$1"
  stage::_write_summary skipped
  exit "$EX_SKIP"
}

stage::fail() {
  stage::finding critical "${2:-${STAGE_NAME^^}-FAILED}" "$1"
  stage::note "$1"
  stage::_write_summary failed
  log::error "$1"
  exit "$EX_FAIL"
}

stage::finish() {
  local threshold=${SLUICE_WARN_AT:-medium} status=ok sev note=""
  local -i rank=${__STAGE_RANK[${threshold,,}]:-2}
  if (( __STAGE_FINDINGS > 0 )); then
    for sev in critical high medium low info; do
      (( ${__STAGE_SEVERITY_COUNT[$sev]:-0} == 0 )) || note+="${note:+, }${__STAGE_SEVERITY_COUNT[$sev]} $sev"
    done
    stage::note "$__STAGE_FINDINGS finding(s): $note"
  fi
  if (( __STAGE_WORST >= rank )); then
    status=warn
  fi
  stage::_write_summary "$status"
  log::debug "stage finished" status="$status" findings="$__STAGE_FINDINGS"
  if [[ $status == warn ]]; then
    exit "$EX_WARN"
  fi
  exit "$EX_OK"
}

stage::_write_summary() {
  local status=$1 k v sev code msg
  local -a m=() f=()
  while IFS=$'\t' read -r k v; do
    m+=("$k:a=$v")
  done < "$STAGE_OUT/metrics.tsv"
  while IFS=$'\t' read -r sev code msg; do
    json::object "severity=$sev" "code=$code" "message=$msg"
    f+=("$REPLY")
  done < "$STAGE_OUT/findings.tsv"
  json::object "${m[@]}"
  local metrics=$REPLY
  json::array raw "${f[@]}"
  json::object "stage=$STAGE_NAME" "status=$status" "run_id=${SLUICE_RUN_ID:-adhoc}" \
    "metrics:raw=$metrics" "findings:raw=$REPLY"
  core::atomic_write "$STAGE_OUT/summary.json" "$REPLY"$'\n'
}

stage::split_list() {
  local -n __sl_out=$1
  IFS=$', \t\n' read -r -d '' -a __sl_out <<< "${2-}" || :
}

stage::expand_globs() {
  local -n __eg_out=$1
  shift
  local __eg_p __eg_f IFS=
  __eg_out=()
  for __eg_p in "$@"; do
    for __eg_f in $__eg_p; do
      __eg_out+=("$__eg_f")
    done
  done
}

stage::require_cmds() {
  local -a missing=()
  local c
  for c in "$@"; do
    core::have "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    stage::skip "required command(s) not installed: ${missing[*]}"
  fi
}

stage::tsv_get() {
  local k v
  REPLY=""
  [[ -r $1 ]] || return 1
  while IFS=$'\t' read -r k v; do
    if [[ $k == "$2" ]]; then
      REPLY=$v
      return 0
    fi
  done < "$1"
  return 1
}
