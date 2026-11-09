#!/usr/bin/env bash

core::import log time

declare -g RUN_ID="" RUN_DIR="" RUN_STATUS=""

run::begin() {
  time::utc_stamp
  printf -v RUN_ID '%s-%04x' "$REPLY" $(( SRANDOM & 0xffff ))
  RUN_DIR=$SLUICE_VAR_DIR/runs/$RUN_ID
  mkdir -p -- "$RUN_DIR/jobs" "$RUN_DIR/artifacts" || core::die "cannot create $RUN_DIR" "$EX_CANTCREAT"
  cp -- "$PIPE_FILE" "$RUN_DIR/pipeline.ini"
  printf '%s\n' "$@" > "$RUN_DIR/jobs.order"
  time::now_ms
  export SLUICE_RUN_ID=$RUN_ID SLUICE_RUN_DIR=$RUN_DIR SLUICE_ARTIFACTS=$RUN_DIR/artifacts \
    SLUICE_EVENTS_FILE=$RUN_DIR/events.jsonl SLUICE_RUN_STARTED_MS=$REPLY
  run::_snapshot_env
}

run::_snapshot_env() {
  local name value line out=""
  local -A seen=()
  for name in "${!SLUICE_@}" "${PIPE_ENV_KEYS[@]}"; do
    [[ -z ${seen[$name]-} && -n ${!name+set} ]] || continue
    seen[$name]=1
    value=${!name}
    if [[ -n $value ]] && core::is_secret_name "$name"; then
      value='<redacted>'
    fi
    printf -v line '%s=%q\n' "$name" "$value"
    out+=$line
  done
  core::atomic_write "$RUN_DIR/env.snapshot" "$out"
}

run::end() {
  local -i strict=$1 n_ok=0 n_warn=0 n_skip=0 n_fail=0 n_allowed=0 n_cancel=0 n_int=0 code=0 ended
  local job meta
  RUN_STATUS=ok
  for job in "${SCHED_JOBS[@]}"; do
    case ${SCHED_STATE[$job]} in
      ok) (( ++n_ok )) ;;
      warn) (( ++n_warn )) ;;
      skipped) (( ++n_skip )) ;;
      failed | timeout)
        if (( JOB_ALLOW_FAILURE[$job] )); then
          (( ++n_allowed ))
        else
          (( ++n_fail ))
        fi
        ;;
      cancelled) (( ++n_cancel )) ;;
      interrupted) (( ++n_int )) ;;
    esac
  done

  if (( SCHED_INTERRUPTED )); then
    RUN_STATUS=interrupted
  elif (( n_fail + n_cancel > 0 )); then
    RUN_STATUS=failed
  elif (( n_warn + n_allowed > 0 )); then
    RUN_STATUS=warn
  fi
  case $RUN_STATUS in
    ok) code=0 ;;
    warn) code=$(( strict ? 1 : 0 )) ;;
    failed) code=1 ;;
    interrupted) if [[ $SCHED_SIGNAL == TERM ]]; then code=143; else code=130; fi ;;
  esac

  time::now_ms
  ended=$REPLY
  printf -v meta '%s=%s\n' run_id "$RUN_ID" pipeline "$PIPE_NAME" status "$RUN_STATUS" \
    exit_code "$code" started_ms "$SLUICE_RUN_STARTED_MS" ended_ms "$ended" \
    jobs "${#SCHED_JOBS[@]}" ok "$n_ok" warn "$n_warn" skipped "$n_skip" \
    failed $(( n_fail + n_allowed )) cancelled "$n_cancel" interrupted "$n_int" host "${HOSTNAME:-unknown}"
  core::atomic_write "$RUN_DIR/run.meta" "$meta"
  core::atomic_write "$SLUICE_VAR_DIR/runs/LATEST" "$RUN_ID"$'\n'
  REPLY=$code
}

run::resolve() {
  local ref=${1:-latest} id root=$SLUICE_VAR_DIR/runs
  local -a hits=()
  if [[ $ref == latest ]]; then
    if [[ ! -r $root/LATEST ]]; then
      log::error "no runs recorded under $root yet"
      return 1
    fi
    IFS= read -r id < "$root/LATEST"
  else
    id=$ref
  fi
  if [[ ! $id =~ ^[A-Za-z0-9_-]+$ ]]; then
    log::error "invalid run id '$ref'"
    return 1
  fi
  if [[ -d $root/$id ]]; then
    REPLY=$root/$id
    return 0
  fi
  hits=("$root/$id"*/)
  case ${#hits[@]} in
    1) REPLY=${hits[0]%/} ;;
    0) log::error "no run matches '$ref'"; return 1 ;;
    *) log::error "'$ref' is ambiguous (${#hits[@]} runs match)"; return 1 ;;
  esac
}

run::list() {
  local -i limit=${1:-20} shown=0 i
  local dir k v dur
  local -a dirs=("$SLUICE_VAR_DIR"/runs/*/)
  local -A meta=()
  if (( ${#dirs[@]} == 0 )); then
    printf 'no runs recorded under %s\n' "$SLUICE_VAR_DIR/runs"
    return 0
  fi
  printf '%-24s %-16s %-12s %9s %5s\n' RUN PIPELINE STATUS DURATION JOBS
  for (( i = ${#dirs[@]} - 1; i >= 0 && shown < limit; i-- )); do
    dir=${dirs[i]%/}
    meta=()
    if [[ -r $dir/run.meta ]]; then
      while IFS='=' read -r k v; do meta[$k]=$v; done < "$dir/run.meta"
    fi
    dur=-
    if [[ -n ${meta[ended_ms]-} ]]; then
      time::fmt_duration $(( meta[ended_ms] - meta[started_ms] ))
      dur=$REPLY
    fi
    printf '%-24s %-16s %-12s %9s %5s\n' "${dir##*/}" "${meta[pipeline]:-?}" \
      "${meta[status]:-incomplete}" "$dur" "${meta[jobs]:-?}"
    (( ++shown ))
  done
}
