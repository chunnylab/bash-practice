#!/usr/bin/env bash
# tests/unit/test_stage.sh - lib/stage.sh, the contract every stage follows.
# stage::finish/skip/fail call `exit`, so those tests run the stage code in a
# separate bash process, exactly like the engine does.

# _mini_stage BODY - run BODY as a tiny stage script; exit code in T_RC.
_mini_stage() {
  printf '%s\n' 'source "$SLUICE_HOME/lib/stage.sh"' 'stage::init mini' "$1" > mini.sh
  export SLUICE_ARTIFACTS=$TEST_TMP/artifacts
  T_RC=0
  T_OUT=$("$BASH" mini.sh 2>&1) || T_RC=$?
}

# Separators may be mixed and repeated; empty input gives an empty list.
test_split_list_accepts_commas_spaces_and_newlines() {
  source "$SLUICE_HOME/lib/stage.sh"
  local -a items=()
  stage::split_list items $'a, b c\n d,,e '
  assert::eq 'a|b|c|d|e' "$(IFS='|'; printf '%s' "${items[*]}")"
  stage::split_list items ''
  assert::eq 0 "${#items[@]}"
}

# A directory with a space in its name, a glob matching nothing (dropped)
# and a literal path that does not exist (kept, so a stage can report it).
test_expand_globs_keeps_spaces_and_literals_and_drops_misses() {
  source "$SLUICE_HOME/lib/stage.sh"
  mkdir -p "my logs"
  : > "my logs/a.log"
  : > "my logs/b.log"
  : > "my logs/c.txt"
  local -a got=()
  stage::expand_globs got "$TEST_TMP/my logs/*.log" "$TEST_TMP/none/*.log" "$TEST_TMP/literal.log"
  assert::eq 3 "${#got[@]}"
  assert::eq "$TEST_TMP/my logs/a.log" "${got[0]}"
  assert::eq "$TEST_TMP/my logs/b.log" "${got[1]}"
  assert::eq "$TEST_TMP/literal.log" "${got[2]}"
}

# A medium finding at the default threshold (medium) means exit 10; raising
# SLUICE_WARN_AT to high makes the same finding informational (exit 0).
test_findings_at_the_threshold_turn_the_stage_warn() {
  _mini_stage 'stage::metric answer 42; stage::finding medium T-1 "something to look at"; stage::finish'
  assert::eq 10 "$T_RC"
  assert::json artifacts/mini/summary.json
  assert::contains "$(< artifacts/mini/summary.json)" '"metrics":{"answer":42}'
  SLUICE_WARN_AT=high _mini_stage 'stage::finding medium T-1 "below the raised threshold"; stage::finish'
  assert::eq 0 "$T_RC"
}

# skip exits 20; fail exits 1 and records a critical finding with its code.
test_skip_and_fail_have_distinct_exit_codes() {
  _mini_stage 'stage::skip "nothing to do"'
  assert::eq 20 "$T_RC"
  _mini_stage 'stage::fail "it broke" T-FAIL'
  assert::eq 1 "$T_RC"
  assert::contains "$(< artifacts/mini/findings.tsv)" $'critical\tT-FAIL\tit broke'
}

# Tabs and newlines inside a value would break the TSV format, so they are
# turned into spaces.
test_values_are_flattened_to_one_line() {
  _mini_stage $'stage::metric multi "a\tb\nc"; stage::finish'
  assert::eq $'multi\ta b c' "$(< artifacts/mini/metrics.tsv)"
}

# A misspelt severity is a bug in the stage itself: EX_SOFTWARE (70).
test_unknown_severities_are_programming_errors() {
  _mini_stage 'stage::finding urgent T-1 "no such severity"'
  assert::eq 70 "$T_RC"
}
