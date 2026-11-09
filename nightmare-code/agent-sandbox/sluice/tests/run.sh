#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) __tests_dir=${BASH_SOURCE[0]%/*} ;;
  *) __tests_dir=. ;;
esac
SLUICE_HOME=$(cd -P -- "$__tests_dir/.." && pwd)
export SLUICE_HOME
unset __tests_dir
source "$SLUICE_HOME/lib/core.sh"
core::import log time

declare -gi T_TOTAL=0 T_PASS=0 T_FAIL=0 T_SKIP=0
declare -ga T_FAILED=()

tests::discover() {
  local -n __td_out=$2
  local __td_line
  __td_out=()
  while IFS= read -r __td_line; do
    if [[ $__td_line =~ ^(test_[A-Za-z0-9_]+)\(\)[[:space:]]*\{ ]]; then
      __td_out+=("${BASH_REMATCH[1]}")
    fi
  done < "$1"
}

tests::run_one() {
  ( tests::_sandbox "$1" "$2" )
}

tests::_sandbox() {
  local v
  for v in "${!SLUICE_@}"; do
    case $v in
      SLUICE_HOME | SLUICE_LIB | SLUICE_VERSION) ;;
      *) unset "$v" ;;
    esac
  done
  TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sluice-test.XXXXXXXX")
  core::install_traps
  core::on_exit rm -rf -- "$TEST_TMP"
  export TEST_TMP SLUICE_VAR_DIR=$TEST_TMP/var SLUICE_WORKSPACE=$TEST_TMP/ws
  export NO_COLOR=1 LC_ALL=C SLUICE_LOG_LEVEL=${TEST_LOG_LEVEL:-warn}
  log::configure
  cd -- "$TEST_TMP" || exit
  source "$SLUICE_HOME/tests/helpers.sh"
  source "$1"
  "$2"
}

tests::main() {
  local filter=${1:-} file t name out line
  local -a files=("$SLUICE_HOME"/tests/unit/test_*.sh "$SLUICE_HOME"/tests/integration/test_*.sh) tests=()
  local -i rc started
  time::now_ms
  started=$REPLY
  printf 'TAP version 13\n'
  for file in "${files[@]}"; do
    tests::discover "$file" tests
    for t in "${tests[@]}"; do
      name=${file#"$SLUICE_HOME/tests/"}
      name=${name%.sh}::${t#test_}
      [[ -z $filter || $name == *"$filter"* ]] || continue
      (( ++T_TOTAL ))
      if out=$(tests::run_one "$file" "$t" 2>&1); then
        rc=0
      else
        rc=$?
      fi
      case $rc in
        0)
          (( ++T_PASS ))
          printf 'ok %d - %s\n' "$T_TOTAL" "$name"
          ;;
        200)
          (( ++T_SKIP ))
          printf 'ok %d - %s # SKIP %s\n' "$T_TOTAL" "$name" "${out##*SKIP: }"
          ;;
        *)
          (( ++T_FAIL ))
          T_FAILED+=("$name")
          printf 'not ok %d - %s (exit %d)\n' "$T_TOTAL" "$name" "$rc"
          while IFS= read -r line; do
            printf '#   %s\n' "$line"
          done <<< "$out"
          ;;
      esac
    done
  done
  printf '1..%d\n' "$T_TOTAL"
  time::now_ms
  time::fmt_duration $(( REPLY - started ))
  printf '# %d passed, %d failed, %d skipped in %s (bash %s, %s)\n' \
    "$T_PASS" "$T_FAIL" "$T_SKIP" "$REPLY" "$BASH_VERSION" "$OSTYPE"
  for name in "${T_FAILED[@]}"; do
    printf '# FAILED: %s\n' "$name"
  done
  if (( T_TOTAL == 0 )); then
    printf '# no test matches "%s"\n' "$filter"
    exit 1
  fi
  if (( T_FAIL > 0 )); then
    exit 1
  fi
  exit 0
}

tests::main "$@"
