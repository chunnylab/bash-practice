#!/usr/bin/env bash

assert::eq() {
  [[ $1 == "$2" ]] && return 0
  printf 'assertion failed: %s\n  expected: %q\n  actual:   %q\n' "${3:-values differ}" "$1" "$2" >&2
  return 1
}

assert::ne() {
  [[ $1 != "$2" ]] && return 0
  printf 'assertion failed: %s\n  both are: %q\n' "${3:-values are equal}" "$1" >&2
  return 1
}

assert::match() {
  [[ $1 =~ $2 ]] && return 0
  printf 'assertion failed: %s\n  pattern: %s\n  actual:  %q\n' "${3:-no regex match}" "$2" "$1" >&2
  return 1
}

assert::contains() {
  [[ $1 == *"$2"* ]] && return 0
  printf 'assertion failed: %s\n  missing: %q\n  in:\n%s\n' "${3:-substring not found}" "$2" "${1:0:3000}" >&2
  return 1
}

assert::not_contains() {
  [[ $1 != *"$2"* ]] && return 0
  printf 'assertion failed: %s\n  unexpected: %q\n' "${3:-substring present}" "$2" >&2
  return 1
}

assert::file() {
  [[ -e $1 ]] && return 0
  printf 'assertion failed: file does not exist: %s\n' "$1" >&2
  return 1
}

assert::no_file() {
  [[ ! -e $1 ]] && return 0
  printf 'assertion failed: file should not exist: %s\n' "$1" >&2
  return 1
}

assert::rc() {
  local -i want=$1 got=0
  shift
  T_OUT=$("$@" 2>&1) || got=$?
  (( got == want )) && return 0
  printf 'assertion failed: expected exit %d, got %d from: %s\n--- output (tail) ---\n' "$want" "$got" "$*" >&2
  printf '%s\n' "$T_OUT" | tail -n 40 >&2
  return 1
}

assert::json() {
  python3 -c 'pass' > /dev/null 2>&1 || return 0
  python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" && return 0
  printf 'assertion failed: invalid JSON in %s\n' "$1" >&2
  return 1
}

test::skip() {
  printf 'SKIP: %s\n' "$1"
  exit 200
}

test::require_cmd() {
  local c
  for c in "$@"; do
    core::have "$c" || test::skip "requires '$c'"
  done
}

test::require_posix_fs() {
  local f=$TEST_TMP/.mode-probe
  : > "$f"
  chmod 0604 "$f" 2> /dev/null || :
  [[ -n $(find "$f" -perm 0604 2> /dev/null) ]] || test::skip "filesystem does not store POSIX permissions"
}

test::require_symlinks() {
  core::can_symlink "$TEST_TMP" || test::skip "filesystem does not support symbolic links"
}

t::sluice() {
  "$BASH" "$SLUICE_HOME/bin/sluice" "$@"
}

t::write() {
  mkdir -p -- "$(dirname -- "$1")"
  cat > "$1"
}

t::stage() {
  export SLUICE_ARTIFACTS=$TEST_TMP/artifacts SLUICE_JOB_DIR=$TEST_TMP/jobs/$1
  mkdir -p -- "$SLUICE_JOB_DIR"
  T_RC=0
  T_OUT=$("$BASH" "$SLUICE_HOME/stages/$1.sh" 2>&1) || T_RC=$?
}

t::metric() {
  local k v
  REPLY=""
  while IFS=$'\t' read -r k v; do
    if [[ $k == "$2" ]]; then
      REPLY=$v
      return 0
    fi
  done < "$TEST_TMP/artifacts/$1/metrics.tsv"
  printf 'metric %s/%s not found\n' "$1" "$2" >&2
  return 1
}

t::findings() {
  local sev code out=""
  while IFS=$'\t' read -r sev code _; do
    out+="$sev $code"$'\n'
  done < "$TEST_TMP/artifacts/$1/findings.tsv"
  REPLY=$(printf '%s' "$out" | LC_ALL=C sort)
}

t::latest_run() {
  local id
  IFS= read -r id < "$SLUICE_VAR_DIR/runs/LATEST"
  REPLY=$SLUICE_VAR_DIR/runs/$id
}

t::status() {
  IFS=$'\t' read -r S_STATE S_RC S_ATTEMPTS S_START S_END S_NOTE < "$1/jobs/$2/status"
}

t::meta() {
  local k v
  while IFS='=' read -r k v; do
    if [[ $k == "$2" ]]; then
      REPLY=$v
      return 0
    fi
  done < "$1/run.meta"
  return 1
}

t::wait_for() {
  local -i deadline
  time::now_ms
  deadline=$(( REPLY + $1 * 1000 ))
  shift
  until "$@"; do
    time::now_ms
    (( REPLY < deadline )) || return 1
    sleep 0.05
  done
}

t::job_started() {
  local -a hits=("$SLUICE_VAR_DIR"/runs/*/jobs/"$1"/stdout.log)
  (( ${#hits[@]} > 0 ))
}

t::cert() {
  ( cd -- "$3" && MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -keyout "$1.key" -out "$1.pem" -days "$2" -subj "/CN=$1" > /dev/null 2>&1 )
}
