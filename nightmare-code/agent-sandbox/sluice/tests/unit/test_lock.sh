#!/usr/bin/env bash

core::import lock

_contender() {
  "$BASH" -c 'source "$SLUICE_HOME/lib/core.sh"; core::import lock; lock::acquire "$1" 0' _ "$1"
}

_contention_for() {
  export SLUICE_LOCK_BACKEND=$1
  local l=$TEST_TMP/$1.lock
  local -i holder
  ( lock::acquire "$l" 0 && : > "$TEST_TMP/held" && exec sleep 30 ) &
  holder=$!
  t::wait_for 10 test -e "$TEST_TMP/held"
  assert::rc 75 _contender "$l"
  kill "$holder" 2> /dev/null || :
  wait "$holder" 2> /dev/null || :
  assert::rc 0 _contender "$l"
}

test_flock_backend_excludes_and_releases_on_death() {
  test::require_cmd flock
  _contention_for flock
}

test_mkdir_backend_excludes_and_recovers_from_dead_holder() {
  _contention_for mkdir
}

test_stale_mkdir_lock_is_reclaimed_by_a_waiter() {
  export SLUICE_LOCK_BACKEND=mkdir
  local l=$TEST_TMP/stale.lock pid _
  local -i dead
  sleep 0 &
  dead=$!
  wait "$dead"
  mkdir "$l.d"
  printf '%d %s %d\n' "$dead" "${HOSTNAME:-unknown}" 0 > "$l.d/owner"
  lock::acquire "$l" 2
  read -r pid _ < "$l.d/owner"
  assert::eq "$BASHPID" "$pid"
}

test_release_is_idempotent() {
  lock::acquire "$TEST_TMP/x.lock" 0
  lock::release "$TEST_TMP/x.lock"
  lock::release "$TEST_TMP/x.lock"
  assert::rc 0 _contender "$TEST_TMP/x.lock"
}

test_waiting_acquire_succeeds_when_the_holder_finishes() {
  local l=$TEST_TMP/wait.lock
  ( lock::acquire "$l" 0 && : > "$TEST_TMP/held" && exec sleep 1 ) &
  t::wait_for 10 test -e "$TEST_TMP/held"
  lock::acquire "$l" 10
}
