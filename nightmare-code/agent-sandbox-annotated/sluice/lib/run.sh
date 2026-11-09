#!/usr/bin/env bash
# =============================================================================
# lib/run.sh - the lifecycle of one pipeline run and the run history
# =============================================================================
#
# Every run gets an immutable, self-describing directory:
#
#   var/runs/20261105T064203Z-7f3a/
#     pipeline.ini     exact copy of the definition that ran (provenance)
#     env.snapshot     resolved configuration, secrets redacted
#     jobs.order       job names in execution order
#     events.jsonl     structured log of the engine and every stage
#     jobs/<job>/      stdout.log, stderr.log, status, note
#     artifacts/<job>/ what each stage produced (metrics.tsv, reports, ...)
#     run.meta         final status and counters (key=value)
#   var/runs/LATEST    id of the most recent run
#
# Run ids start with a UTC timestamp, so plain lexical sorting (what globs
# do) is chronological sorting, and a random suffix keeps two runs started
# in the same second apart.
# =============================================================================

core::import log time

declare -g RUN_ID="" RUN_DIR="" RUN_STATUS=""

# run::begin JOB... - create the run directory and export the run context
# that every job inherits.
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

# Record every SLUICE_* variable plus the pipeline's [env] keys.
# "${!SLUICE_@}" expands to the NAMES of all variables starting with
# SLUICE_ - a builtin, so no `env | grep` pipeline is needed. %q quoting
# makes the snapshot unambiguous (and safe to read back with a parser).
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

# run::end STRICT -> REPLY = process exit code; RUN_STATUS = ok|warn|failed|
# interrupted. Allowed failures (allow_failure = true) downgrade to "warn".
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
  # printf re-applies its format to the remaining arguments until they run
  # out, so one call renders all the key=value pairs.
  printf -v meta '%s=%s\n' run_id "$RUN_ID" pipeline "$PIPE_NAME" status "$RUN_STATUS" \
    exit_code "$code" started_ms "$SLUICE_RUN_STARTED_MS" ended_ms "$ended" \
    jobs "${#SCHED_JOBS[@]}" ok "$n_ok" warn "$n_warn" skipped "$n_skip" \
    failed $(( n_fail + n_allowed )) cancelled "$n_cancel" interrupted "$n_int" host "${HOSTNAME:-unknown}"
  core::atomic_write "$RUN_DIR/run.meta" "$meta"
  core::atomic_write "$SLUICE_VAR_DIR/runs/LATEST" "$RUN_ID"$'\n'
  REPLY=$code
}

# run::resolve [REF] -> REPLY = run directory. REF may be "latest", a full
# run id, or any unique prefix of one (like abbreviated git hashes).
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

# run::list [LIMIT] - newest first.
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
