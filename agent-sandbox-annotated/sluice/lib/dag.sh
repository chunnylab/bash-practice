#!/usr/bin/env bash
# =============================================================================
# lib/dag.sh - directed acyclic graph algorithms for job dependencies
# =============================================================================
#
# A graph is described by two caller-owned variables, passed BY NAME:
#
#   nodes   indexed array of node names, in definition order
#   needs   associative array: node -> space-separated list of nodes it
#           depends on ("report" -> "host-facts log-insights ...")
#
# Bash has no arrays of arrays, so an adjacency list is stored as a string
# and split on demand with `read -r -a`. Node names are validated elsewhere
# to contain no whitespace or glob characters, which keeps that split exact.
#
# The algorithms are O(V^2) on purpose: pipelines have tens of jobs, not
# millions, and the simple versions are easier to verify than clever ones.
# =============================================================================

# dag::validate NODES NEEDS - report unknown and self dependencies (all of
# them, not just the first). Returns 1 if the graph is malformed.
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

# -----------------------------------------------------------------------------
# dag::waves NODES NEEDS ORDER_OUT LEVEL_OUT
#
# Kahn's topological sort, organised in "waves": wave 1 holds every node
# without dependencies, wave k every node whose dependencies all live in
# waves < k. Inside a wave, definition order is kept, so the result is
# deterministic and matches how a human reads the pipeline file.
#
#   ORDER_OUT  indexed array   - all nodes, wave by wave (a valid topo order)
#   LEVEL_OUT  associative     - node -> wave number
#
# If a pass emits no node while nodes remain, those nodes form (or depend on)
# a cycle: the function returns 1 with a readable cycle path in REPLY.
# A wave is computed completely BEFORE its nodes are marked done, so two
# nodes of the same wave can never depend on each other.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# dag::_find_cycle NODES NEEDS DONE -> REPLY = "a -> b -> c -> a"
#
# Depth-first search with the classic three colours: unvisited, 1 = on the
# current path ("grey"), 2 = finished ("black"). Meeting a grey node means
# we walked back into our own path: that slice of the path is the cycle.
# Nodes already scheduled (DONE) cannot be part of a cycle and are skipped.
# -----------------------------------------------------------------------------
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

# Recursive step. It reads and writes the __fc_* variables of dag::_find_cycle
# through dynamic scoping; namerefs declared there are visible here as well.
# Returns 1 ("stop") as soon as a cycle has been written to REPLY.
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

# -----------------------------------------------------------------------------
# dag::closure NEEDS OUT_ASSOC TARGET... - OUT_ASSOC[node]=1 for every target
# and everything it transitively needs (what `make target` would build).
# Iterative DFS with an explicit stack; ${stack[-1]} is the top element and
# `unset 'stack[-1]'` pops it. The single quotes stop the shell from treating
# [-1] as a glob before unset sees it.
# -----------------------------------------------------------------------------
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
