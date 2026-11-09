#!/usr/bin/env bash
# =============================================================================
# lib/stage.sh - the contract between the engine and a stage script
# =============================================================================
#
# A stage is an ordinary bash script that sources this file:
#
#   source "${BASH_SOURCE[0]%/*}/../lib/stage.sh"
#   stage::init my-stage
#   stage::metric requests 1234
#   stage::finding high WEB-001 "5xx rate 7.1% exceeds 2%"
#   stage::finish
#
# INPUTS (exported by the engine; all optional when run by hand)
#   SLUICE_JOB         job name            SLUICE_ARTIFACTS  shared output dir
#   SLUICE_JOB_DIR     engine's job dir    SLUICE_RUN_ID     current run id
#   SLUICE_DRY_RUN     1 = do not modify anything
#
# OUTPUTS (in $SLUICE_ARTIFACTS/<job>/)
#   metrics.tsv    key<TAB>value                     - numbers and facts
#   findings.tsv   severity<TAB>code<TAB>message     - things a human should see
#   summary.json   both of the above as JSON
#   + any stage-specific artifacts (reports, archives' manifests, ...)
#
# EXIT CODES understood by the scheduler
#   0 ok    10 warn (finished; findings at/above SLUICE_WARN_AT)
#   20 skipped (preconditions not met)    anything else: failed
#
# Findings never fail a stage by themselves: an audit that FINDS problems
# did its job. Operational failures (a corrupt backup) call stage::fail.
# =============================================================================

# A stage is a fresh bash process, so it boots the runtime itself. Inside
# this file ${BASH_SOURCE[0]} is the path of stage.sh, whose directory is lib/.
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

# Values are flattened to one line: TAB and newlines would break the format.
stage::metric() {
  local -r ws=$'\t\n\r'
  printf '%s\t%s\n' "$1" "${2//[$ws]/ }" >> "$STAGE_OUT/metrics.tsv"
}

# stage::finding SEVERITY CODE MESSAGE
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

# A one-line note shown next to the job in the run summary.
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

# summary.json = {"stage":..,"status":..,"metrics":{..},"findings":[..]}
# Metric values are auto-typed (:a) so counts become numbers in the JSON.
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

# stage::split_list OUT_ARRAY STRING - split a list from an env variable on
# commas and whitespace (newlines too, so multi-line values work).
stage::split_list() {
  local -n __sl_out=$1
  IFS=$', \t\n' read -r -d '' -a __sl_out <<< "${2-}" || :
}

# stage::expand_globs OUT_ARRAY PATTERN... - expand shell globs that came
# from configuration, e.g. SLUICE_ACCESS_LOGS="/var/log/nginx/access.log*".
#
# `$__eg_p` is deliberately UNQUOTED in the inner loop so that pathname
# expansion happens, while `local IFS=` (empty) switches word splitting OFF:
# a pattern like "/srv/My Logs/*.log" expands correctly instead of being
# torn apart at the space. nullglob (core.sh) drops patterns that match
# nothing; words without glob characters pass through untouched, so a
# missing literal path is kept and can be reported by the caller.
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

# stage::require_cmds CMD... - skip (not fail) when optional tooling is absent.
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

# stage::tsv_get FILE KEY -> REPLY: value of KEY in a key<TAB>value file.
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
