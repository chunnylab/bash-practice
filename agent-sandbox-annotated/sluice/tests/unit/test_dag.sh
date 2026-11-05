#!/usr/bin/env bash
# tests/unit/test_dag.sh - lib/dag.sh graph algorithms.

core::import dag

# a and e have no dependencies (wave 1), b and c need a (wave 2), d needs
# both (wave 3). Inside a wave, definition order wins.
test_waves_follow_dependencies_and_definition_order() {
  local -a nodes=(a b c d e) order=()
  local -A needs=([a]="" [b]="a" [c]="a" [d]="b c" [e]="") level=()
  dag::waves nodes needs order level
  assert::eq 'a e b c d' "${order[*]}"
  assert::eq '1 2 2 3 1' "${level[a]} ${level[b]} ${level[c]} ${level[d]} ${level[e]}"
}

# x needs z, z needs y, y needs x: the error must show the cycle itself, not
# just "cycle detected". "start" is fine and stays out of the path.
test_cycles_are_reported_as_a_readable_path() {
  local -a nodes=(start x y z) order=()
  local -A needs=([start]="" [x]="z start" [y]="x" [z]="y") level=()
  if dag::waves nodes needs order level; then
    return 1
  fi
  assert::eq 'x -> z -> y -> x' "$REPLY"
}

# All problems are reported in one pass, not one per attempt.
test_validate_reports_every_unknown_and_self_dependency() {
  local -a nodes=(a b c)
  local -A needs=([a]="a" [b]="ghost" [c]="a phantom")
  assert::rc 1 dag::validate nodes needs
  assert::contains "$T_OUT" "job 'a' cannot depend on itself"
  assert::contains "$T_OUT" "job 'b' needs unknown job 'ghost'"
  assert::contains "$T_OUT" "job 'c' needs unknown job 'phantom'"
}

# c needs b needs a: the closure of c is {a, b, c}; d and e stay out.
test_closure_collects_transitive_dependencies_only() {
  local -A needs=([a]="" [b]="a" [c]="b" [d]="a" [e]="") out=()
  dag::closure needs out c
  assert::eq '1 1 1' "${out[a]-} ${out[b]-} ${out[c]-}"
  assert::eq '' "${out[d]-}${out[e]-}"
}
