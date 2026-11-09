#!/usr/bin/env bash

dag::validate() {
  local -n __dv_nodes=$1 __dv_needs=$2
  local __dv_n __dv_d
  local -a __dv_deps=()
  local -A __dv_known=()
  local -i __dv_bad=0
  for __dv_n in "${__dv_nodes[@]}"; do
    __dv_known[$__dv_n]=1
  done
  for __dv_n in "${__dv_nodes[@]}"; do
    read -r -a __dv_deps <<< "${__dv_needs[$__dv_n]-}"
    for __dv_d in "${__dv_deps[@]}"; do
      if [[ $__dv_d == "$__dv_n" ]]; then
        log::error "job '$__dv_n' cannot depend on itself"
        (( ++__dv_bad ))
      elif [[ -z ${__dv_known[$__dv_d]-} ]]; then
        log::error "job '$__dv_n' needs unknown job '$__dv_d'"
        (( ++__dv_bad ))
      fi
    done
  done
  (( __dv_bad == 0 ))
}

dag::waves() {
  local -n __dw_nodes=$1 __dw_needs=$2 __dw_order=$3 __dw_level=$4
  local -A __dw_done=()
  local -a __dw_wave=() __dw_deps=()
  local __dw_n __dw_d
  local -i __dw_lvl=0 __dw_ready
  __dw_order=()
  __dw_level=()
  while (( ${#__dw_order[@]} < ${#__dw_nodes[@]} )); do
    (( ++__dw_lvl ))
    __dw_wave=()
    for __dw_n in "${__dw_nodes[@]}"; do
      [[ -z ${__dw_done[$__dw_n]-} ]] || continue
      __dw_ready=1
      read -r -a __dw_deps <<< "${__dw_needs[$__dw_n]-}"
      for __dw_d in "${__dw_deps[@]}"; do
        if [[ -z ${__dw_done[$__dw_d]-} ]]; then
          __dw_ready=0
          break
        fi
      done
      if (( __dw_ready )); then
        __dw_wave+=("$__dw_n")
      fi
    done
    if (( ${#__dw_wave[@]} == 0 )); then
      dag::_find_cycle "$1" "$2" __dw_done
      return 1
    fi
    for __dw_n in "${__dw_wave[@]}"; do
      __dw_done[$__dw_n]=1
      __dw_level[$__dw_n]=$__dw_lvl
      __dw_order+=("$__dw_n")
    done
  done
}

dag::_find_cycle() {
  local -n __fc_nodes=$1 __fc_needs=$2 __fc_done=$3
  local -A __fc_color=()
  local -a __fc_path=()
  local __fc_start
  REPLY="(cycle detection failed)"
  for __fc_start in "${__fc_nodes[@]}"; do
    [[ -z ${__fc_done[$__fc_start]-} && -z ${__fc_color[$__fc_start]-} ]] || continue
    dag::_dfs "$__fc_start" || return 0
  done
}

dag::_dfs() {
  local n=$1 d
  local -a deps=()
  local -i i
  __fc_color[$n]=1
  __fc_path+=("$n")
  read -r -a deps <<< "${__fc_needs[$n]-}"
  for d in "${deps[@]}"; do
    [[ -z ${__fc_done[$d]-} ]] || continue
    if [[ ${__fc_color[$d]-} == 1 ]]; then
      for (( i = 0; i < ${#__fc_path[@]}; i++ )); do
        if [[ ${__fc_path[i]} == "$d" ]]; then
          break
        fi
      done
      core::join " -> " "${__fc_path[@]:i}" "$d"
      return 1
    fi
    if [[ -z ${__fc_color[$d]-} ]]; then
      dag::_dfs "$d" || return 1
    fi
  done
  __fc_color[$n]=2
  unset '__fc_path[-1]'
  return 0
}

dag::closure() {
  local -n __cl_needs=$1 __cl_out=$2
  shift 2
  local -a __cl_stack=("$@") __cl_deps=()
  local __cl_n
  __cl_out=()
  while (( ${#__cl_stack[@]} )); do
    __cl_n=${__cl_stack[-1]}
    unset '__cl_stack[-1]'
    [[ -z ${__cl_out[$__cl_n]-} ]] || continue
    __cl_out[$__cl_n]=1
    read -r -a __cl_deps <<< "${__cl_needs[$__cl_n]-}"
    __cl_stack+=("${__cl_deps[@]}")
  done
}
