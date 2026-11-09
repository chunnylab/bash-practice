#!/usr/bin/env bash

core::import time

declare -gA RENDER_ICON=() __RENDER_COLOR=()
declare -g RENDER_BAR='#' RENDER_RULE='-'

render::init() {
  if render::_utf8; then
    RENDER_ICON=([pending]='·' [ready]='·' [running]='▶' [ok]='✔' [warn]='▲' [skipped]='↷'
      [failed]='✖' [timeout]='✖' [cancelled]='⊘' [interrupted]='✖')
    RENDER_BAR='█' RENDER_RULE='─'
  else
    RENDER_ICON=([pending]='.' [ready]='.' [running]='>' [ok]='+' [warn]='!' [skipped]='~'
      [failed]='x' [timeout]='x' [cancelled]='-' [interrupted]='x')
    RENDER_BAR='#' RENDER_RULE='-'
  fi
  __RENDER_COLOR=()
  if render::_color_stdout; then
    __RENDER_COLOR=([ok]=$'\e[32m' [warn]=$'\e[33m' [skipped]=$'\e[36m' [failed]=$'\e[1;31m'
      [timeout]=$'\e[1;31m' [cancelled]=$'\e[90m' [interrupted]=$'\e[35m' [pending]=$'\e[90m'
      [dim]=$'\e[2m' [bold]=$'\e[1m' [reset]=$'\e[0m')
  fi
}

render::_utf8() {
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  [[ ${loc^^} == *UTF-8* || ${loc^^} == *UTF8* ]]
}

render::_color_stdout() {
  [[ -z ${NO_COLOR-} ]] || return 1
  case ${SLUICE_COLOR:-auto} in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -t 1 && ${TERM:-dumb} != dumb ]]
}

render::_columns() {
  local -i cols=${COLUMNS:-0}
  if (( cols <= 0 )) && [[ -t 1 ]]; then
    cols=$(tput cols 2>/dev/null) || cols=0
  fi
  (( cols > 0 )) || cols=100
  REPLY=$cols
}

render::summary() {
  local dir=$1 job state att start end note dur bar pad trail k
  local -a jobs=()
  local -A st=() at=() ts=() te=() nt=() count=() meta=()
  local -i t0=0 t1=0 span namew=4 width off len sum=0
  local c r d b

  mapfile -t jobs < "$dir/jobs.order"
  for job in "${jobs[@]}"; do
    state=pending att=0 start=0 end=0 note=""
    if [[ -r $dir/jobs/$job/status ]]; then
      IFS=$'\t' read -r state _ att start end note < "$dir/jobs/$job/status" || :
    fi
    st[$job]=$state at[$job]=$att ts[$job]=$start te[$job]=$end nt[$job]=$note
    count[$state]=$(( ${count[$state]:-0} + 1 ))
    (( ${#job} <= namew )) || namew=${#job}
    if (( start > 0 && end > start )); then
      if (( t0 == 0 || start < t0 )); then t0=$start; fi
      if (( end > t1 )); then t1=$end; fi
      sum=$(( sum + end - start ))
    fi
  done
  span=$(( t1 - t0 ))
  (( span > 0 )) || span=1

  render::_columns
  width=$(( REPLY - namew - 58 ))
  (( width >= 10 )) || width=10
  (( width <= 50 )) || width=50

  if [[ -r $dir/run.meta ]]; then
    while IFS='=' read -r k note; do meta[$k]=$note; done < "$dir/run.meta"
  fi
  d=${__RENDER_COLOR[dim]-} b=${__RENDER_COLOR[bold]-} r=${__RENDER_COLOR[reset]-}
  c=${__RENDER_COLOR[${meta[status]:-pending}]-}
  printf '\n  %s%s%s  %s%s%s  %s%s%s\n\n' "$b" "${meta[pipeline]:-${SLUICE_PIPELINE_NAME:-run}}" "$r" \
    "$d" "${dir##*/}" "$r" "$c" "${meta[status]:-in progress}" "$r"
  printf '  %s  %-*s  %-11s %8s %3s  %s\n' " " "$namew" JOB STATE TIME TRY TIMELINE

  for job in "${jobs[@]}"; do
    state=${st[$job]} start=${ts[$job]} end=${te[$job]}
    c=${__RENDER_COLOR[$state]-}
    dur="-" bar=""
    if (( start > 0 && end >= start )); then
      time::fmt_duration $(( end - start ))
      dur=$REPLY
    fi
    if (( start > 0 && end > start )); then
      off=$(( (start - t0) * width / span ))
      len=$(( ((end - start) * width + span - 1) / span ))
      (( off < width )) || off=$(( width - 1 ))
      (( len >= 1 )) || len=1
      (( off + len <= width )) || len=$(( width - off ))
      printf -v pad '%*s' "$off" ''
      printf -v bar '%*s' "$len" ''
      bar=${bar// /"$RENDER_BAR"}
    else
      off=0 len=0 pad=""
    fi
    printf -v trail '%*s' $(( width - off - len )) ''
    printf '  %s%s%s  %-*s  %s%-11s%s %8s %3s  %s%s%s%s%s  %s%s%s\n' \
      "$c" "${RENDER_ICON[$state]:-?}" "$r" "$namew" "$job" "$c" "$state" "$r" "$dur" "${at[$job]}" \
      "$pad" "$c" "$bar" "$r" "$trail" "$d" "${nt[$job]}" "$r"
  done

  printf -v pad '%*s' $(( namew + width + 34 )) ''
  printf '  %s%s%s\n' "$d" "${pad// /"$RENDER_RULE"}" "$r"
  local counts=""
  for k in ok warn skipped failed timeout cancelled interrupted; do
    (( ${count[$k]:-0} == 0 )) || counts+="${counts:+ · }${count[$k]} $k"
  done
  time::fmt_duration "$span"
  local wall=$REPLY
  time::fmt_duration "$sum"
  printf '  %d job(s): %s\n  wall %s · job time %s · parallelism x%d.%d\n\n' \
    "${#jobs[@]}" "${counts:-none}" "$wall" "$REPLY" $(( sum / span )) $(( sum * 10 / span % 10 ))
}

render::plan() {
  local job line needs tmo b=${__RENDER_COLOR[bold]-} r=${__RENDER_COLOR[reset]-} d=${__RENDER_COLOR[dim]-}
  local -i max=0 w
  for job in "${PIPE_ORDER[@]}"; do
    (( PIPE_LEVEL[$job] <= max )) || max=${PIPE_LEVEL[$job]}
  done
  printf '%s%s%s  %s\n' "$b" "$PIPE_NAME" "$r" "$PIPE_DESC"
  printf '%s%d job(s) in %d wave(s) · max_parallel=%d · fail_fast=%d%s\n\n' \
    "$d" "${#PIPE_ORDER[@]}" "$max" "$PIPE_MAX_PARALLEL" "$PIPE_FAIL_FAST" "$r"
  for (( w = 1; w <= max; w++ )); do
    line=""
    for job in "${PIPE_ORDER[@]}"; do
      if (( PIPE_LEVEL[$job] == w )); then
        line+="  $job"
      fi
    done
    printf '  wave %d |%s\n' "$w" "$line"
  done
  printf '\n  %-16s %-8s %-8s %-8s %-6s %s\n' JOB TIMEOUT RETRIES WHEN ALLOW NEEDS
  for job in "${PIPE_ORDER[@]}"; do
    tmo=-
    if (( JOB_TIMEOUT_MS[$job] > 0 )); then
      time::fmt_duration "${JOB_TIMEOUT_MS[$job]}"
      tmo=$REPLY
    fi
    needs=${JOB_NEEDS[$job]:--}
    printf '  %-16s %-8s %-8s %-8s %-6s %s\n' "$job" "$tmo" "${JOB_RETRIES[$job]}" \
      "${JOB_WHEN[$job]}" "${JOB_ALLOW_FAILURE[$job]}" "${needs// /, }"
  done
}

render::dot() {
  local dir=${1-} job dep state attrs label desc
  local -a deps=()
  local -A fill=([ok]='#dcfce7' [warn]='#fef3c7' [skipped]='#e0f2fe' [failed]='#fee2e2'
    [timeout]='#fee2e2' [cancelled]='#f1f5f9' [interrupted]='#fae8ff' [pending]='#ffffff')
  label=$PIPE_NAME
  [[ -z $dir ]] || label+=" - ${dir##*/}"
  printf 'digraph "%s" {\n' "$PIPE_NAME"
  printf '  graph [rankdir=LR, fontname="Helvetica", label="%s", labelloc=t];\n' "$label"
  printf '  node  [shape=box, style="rounded,filled", fontname="Helvetica", fillcolor="#eef2ff", color="#6366f1"];\n'
  printf '  edge  [color="#94a3b8", arrowsize=0.7];\n'
  for job in "${PIPE_ORDER[@]}"; do
    attrs=""
    if [[ ${JOB_WHEN[$job]} == always ]]; then
      attrs+=", peripheries=2"
    fi
    if [[ -n $dir ]]; then
      state=pending
      if [[ -r $dir/jobs/$job/status ]]; then
        IFS=$'\t' read -r state _ < "$dir/jobs/$job/status" || :
      fi
      attrs+=", fillcolor=\"${fill[$state]:-#ffffff}\", xlabel=\"$state\""
    fi
    desc=${JOB_DESC[$job]//\"/\\\"}
    printf '  "%s" [tooltip="%s"%s];\n' "$job" "$desc" "$attrs"
  done
  for job in "${PIPE_ORDER[@]}"; do
    read -r -a deps <<< "${JOB_NEEDS[$job]}"
    for dep in "${deps[@]}"; do
      printf '  "%s" -> "%s";\n' "$dep" "$job"
    done
  done
  printf '}\n'
}

render::init
