#!/usr/bin/env bash

core::import ini dag

declare -g PIPE_FILE="" PIPE_DIR="" PIPE_NAME="" PIPE_DESC=""
declare -gi PIPE_MAX_PARALLEL=4 PIPE_FAIL_FAST=0
declare -ga PIPE_JOBS=() PIPE_ORDER=() PIPE_ENV_KEYS=()
declare -gA PIPE_ENV=() PIPE_LEVEL=()
declare -gA JOB_RUN=() JOB_NEEDS=() JOB_DESC=() JOB_TIMEOUT_MS=() JOB_RETRIES=() \
  JOB_RETRY_DELAY_MS=() JOB_WHEN=() JOB_ALLOW_FAILURE=()

declare -gr __PIPE_NAME_RE='^[a-z0-9][a-z0-9_-]*$'

pipeline::load() {
  local file=$1 key section field job dir=.
  local -A cfg=()
  local -a keys=() sections=()
  local -i errors=0

  [[ $file != */* ]] || dir=${file%/*}
  if [[ ! -r $file ]] || ! PIPE_DIR=$(cd -P -- "$dir" 2>/dev/null && pwd); then
    log::error "pipeline file not readable: $file"
    return "$EX_DATAERR"
  fi
  PIPE_FILE=$PIPE_DIR/${file##*/}
  ini::parse "$PIPE_FILE" cfg keys sections || return "$EX_DATAERR"

  for section in "${sections[@]}"; do
    case $section in
      pipeline | env) ;;
      job) pipeline::_err "a [job] section needs a name, e.g. [job backup]" ;;
      job.*)
        job=${section#job.}
        if [[ $job =~ $__PIPE_NAME_RE ]]; then
          PIPE_JOBS+=("$job")
        else
          pipeline::_err "invalid job name '$job' (use a-z, 0-9, '-' and '_')"
        fi
        ;;
      *) pipeline::_err "unknown section [${section/./ }]" ;;
    esac
  done

  for key in "${keys[@]}"; do
    section=${key%.*}
    field=${key##*.}
    case $section in
      pipeline) pipeline::_set_pipeline "$field" "${cfg[$key]}" ;;
      env)
        PIPE_ENV_KEYS+=("$field")
        PIPE_ENV[$field]=${cfg[$key]}
        ;;
      job.*) pipeline::_set_job "${section#job.}" "$field" "${cfg[$key]}" ;;
    esac
  done

  [[ -n $PIPE_NAME ]] || pipeline::_err "[pipeline] must define 'name'"
  (( ${#PIPE_JOBS[@]} )) || pipeline::_err "no [job NAME] sections defined"

  for job in "${PIPE_JOBS[@]}"; do
    [[ -n ${JOB_RUN[$job]-} ]] || pipeline::_err "job '$job' must define 'run'"
    JOB_NEEDS[$job]=${JOB_NEEDS[$job]-}
    JOB_DESC[$job]=${JOB_DESC[$job]-}
    JOB_WHEN[$job]=${JOB_WHEN[$job]:-success}
    JOB_TIMEOUT_MS[$job]=${JOB_TIMEOUT_MS[$job]:-0}
    JOB_RETRIES[$job]=${JOB_RETRIES[$job]:-0}
    JOB_RETRY_DELAY_MS[$job]=${JOB_RETRY_DELAY_MS[$job]:-1000}
    JOB_ALLOW_FAILURE[$job]=${JOB_ALLOW_FAILURE[$job]:-0}
  done
  (( errors == 0 )) || return "$EX_DATAERR"

  dag::validate PIPE_JOBS JOB_NEEDS || return "$EX_DATAERR"
  if ! dag::waves PIPE_JOBS JOB_NEEDS PIPE_ORDER PIPE_LEVEL; then
    log::error "$PIPE_FILE: dependency cycle: $REPLY"
    return "$EX_DATAERR"
  fi
}

pipeline::_err() {
  log::error "$PIPE_FILE: $1"
  (( ++errors ))
}

pipeline::_set_pipeline() {
  local field=$1 value=$2
  case $field in
    name)
      if [[ $value =~ $__PIPE_NAME_RE ]]; then
        PIPE_NAME=$value
      else
        pipeline::_err "invalid pipeline name '$value' (use a-z, 0-9, '-' and '_')"
      fi
      ;;
    description) PIPE_DESC=$value ;;
    max_parallel)
      if [[ $value =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 64 )); then
        PIPE_MAX_PARALLEL=$(( 10#$value ))
      else
        pipeline::_err "max_parallel must be an integer from 1 to 64 (got '$value')"
      fi
      ;;
    fail_fast)
      if core::parse_bool "$value"; then
        PIPE_FAIL_FAST=$REPLY
      else
        pipeline::_err "fail_fast must be a boolean (got '$value')"
      fi
      ;;
    *) pipeline::_err "unknown key '$field' in [pipeline]" ;;
  esac
}

pipeline::_set_job() {
  local job=$1 field=$2 value=$3 dep
  local -a deps=()
  case $field in
    run) JOB_RUN[$job]=$value ;;
    description) JOB_DESC[$job]=$value ;;
    needs)
      IFS=$', \t' read -r -a deps <<< "$value"
      for dep in "${deps[@]}"; do
        [[ $dep =~ $__PIPE_NAME_RE ]] || pipeline::_err "job '$job': invalid dependency name '$dep'"
      done
      JOB_NEEDS[$job]=${deps[*]}
      ;;
    timeout)
      if core::parse_duration_ms "$value"; then
        JOB_TIMEOUT_MS[$job]=$REPLY
      else
        pipeline::_err "job '$job': invalid timeout '$value' (examples: 90, 30s, 5m, 1h)"
      fi
      ;;
    retries)
      if [[ $value =~ ^[0-9]+$ ]] && (( 10#$value <= 10 )); then
        JOB_RETRIES[$job]=$(( 10#$value ))
      else
        pipeline::_err "job '$job': retries must be an integer from 0 to 10 (got '$value')"
      fi
      ;;
    retry_delay)
      if core::parse_duration_ms "$value"; then
        JOB_RETRY_DELAY_MS[$job]=$REPLY
      else
        pipeline::_err "job '$job': invalid retry_delay '$value' (examples: 500ms, 2s)"
      fi
      ;;
    when)
      case $value in
        success | always) JOB_WHEN[$job]=$value ;;
        *) pipeline::_err "job '$job': 'when' must be 'success' or 'always' (got '$value')" ;;
      esac
      ;;
    allow_failure)
      if core::parse_bool "$value"; then
        JOB_ALLOW_FAILURE[$job]=$REPLY
      else
        pipeline::_err "job '$job': allow_failure must be a boolean (got '$value')"
      fi
      ;;
    *) pipeline::_err "job '$job': unknown key '$field'" ;;
  esac
}

pipeline::apply_env() {
  local key
  local -i errors=0
  export SLUICE_PIPELINE_NAME=$PIPE_NAME SLUICE_PIPELINE_FILE=$PIPE_FILE SLUICE_PIPELINE_DIR=$PIPE_DIR
  for key in "${PIPE_ENV_KEYS[@]}"; do
    [[ -z ${!key:-} ]] || continue
    if core::interpolate "${PIPE_ENV[$key]}"; then
      export "$key=$REPLY"
    else
      log::error "$PIPE_FILE: [env] $key references undefined variable \${$REPLY}"
      (( ++errors ))
    fi
  done
  (( errors == 0 )) || return "$EX_CONFIG"
}

pipeline::resolve_commands() {
  local job
  local -i errors=0
  for job in "${PIPE_JOBS[@]}"; do
    if core::interpolate "${JOB_RUN[$job]}"; then
      JOB_RUN[$job]=$REPLY
    else
      log::error "$PIPE_FILE: job '$job': run references undefined variable \${$REPLY}"
      (( ++errors ))
    fi
  done
  (( errors == 0 )) || return "$EX_CONFIG"
}

pipeline::select() {
  local job
  local -A keep=()
  local -a order=()
  for job in "$@"; do
    if [[ -z ${JOB_RUN[$job]-} ]]; then
      log::error "unknown target job '$job' (known: ${PIPE_JOBS[*]})"
      return "$EX_USAGE"
    fi
  done
  dag::closure JOB_NEEDS keep "$@"
  for job in "${PIPE_ORDER[@]}"; do
    [[ -z ${keep[$job]-} ]] || order+=("$job")
  done
  PIPE_ORDER=("${order[@]}")
}
