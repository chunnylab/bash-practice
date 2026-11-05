#!/usr/bin/env bash
# tests/unit/test_lock.sh - lib/lock.sh, both backends. Contention is tested
# between separate processes, which is how locks are used for real.

core::import lock

# Exit status of a separate bash process that tries to take LOCK without
# waiting: 0 = acquired, 75 = busy.
_contender() {
  "$BASH" -c 'source "$SLUICE_HOME/lib/core.sh"; core::import lock; lock::acquire "$1" 0' _ "$1"
}

# The holder `exec`s sleep: the PID stays the same and the lock fd stays
# open, so killing that PID is exactly "the lock holder died".
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

# flock: the kernel releases the lock when the holder dies.
test_flock_backend_excludes_and_releases_on_death() {
  test::require_cmd flock
  _contention_for flock
}

# mkdir: the dead holder's directory stays behind; the next contender sees
# that the owner PID is gone and reclaims the lock.
test_mkdir_backend_excludes_and_recovers_from_dead_holder() {
  _contention_for mkdir
}

# A lock directory left by a process that no longer exists (its PID comes
# from a finished `sleep 0`) is taken over, and the owner file names us.
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

# Releasing twice is harmless, and the lock is free afterwards.
test_release_is_idempotent() {
  lock::acquire "$TEST_TMP/x.lock" 0
  lock::release "$TEST_TMP/x.lock"
  lock::release "$TEST_TMP/x.lock"
  assert::rc 0 _contender "$TEST_TMP/x.lock"
}

# With a wait budget, acquire blocks until the one-second holder exits.
test_waiting_acquire_succeeds_when_the_holder_finishes() {
  local l=$TEST_TMP/wait.lock
  ( lock::acquire "$l" 0 && : > "$TEST_TMP/held" && exec sleep 1 ) &
  t::wait_for 10 test -e "$TEST_TMP/held"
  lock::acquire "$l" 10
}
