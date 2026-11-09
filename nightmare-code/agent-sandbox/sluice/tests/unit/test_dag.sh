#!/usr/bin/env bash

core::import dag

test_waves_follow_dependencies_and_definition_order() {
  local -a nodes=(a b c d e) order=()
  local -A needs=([a]="" [b]="a" [c]="a" [d]="b c" [e]="") level=()
  dag::waves nodes needs order level
  assert::eq 'a e b c d' "${order[*]}"
  assert::eq '1 2 2 3 1' "${level[a]} ${level[b]} ${level[c]} ${level[d]} ${level[e]}"
}

test_cycles_are_reported_as_a_readable_path() {
  local -a nodes=(start x y z) order=()
  local -A needs=([start]="" [x]="z start" [y]="x" [z]="y") level=()
  if dag::waves nodes needs order level; then
    return 1
  fi
  assert::eq 'x -> z -> y -> x' "$REPLY"
}

test_validate_reports_every_unknown_and_self_dependency() {
  local -a nodes=(a b c)
  local -A needs=([a]="a" [b]="ghost" [c]="a phantom")
  assert::rc 1 dag::validate nodes needs
  assert::contains "$T_OUT" "job 'a' cannot depend on itself"
  assert::contains "$T_OUT" "job 'b' needs unknown job 'ghost'"
  assert::contains "$T_OUT" "job 'c' needs unknown job 'phantom'"
}

test_closure_collects_transitive_dependencies_only() {
  local -A needs=([a]="" [b]="a" [c]="b" [d]="a" [e]="") out=()
  dag::closure needs out c
  assert::eq '1 1 1' "${out[a]-} ${out[b]-} ${out[c]-}"
  assert::eq '' "${out[d]-}${out[e]-}"
}
