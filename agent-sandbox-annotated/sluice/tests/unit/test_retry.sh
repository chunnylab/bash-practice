#!/usr/bin/env bash
# tests/unit/test_retry.sh - lib/retry.sh. A recording sleeper replaces the
# real sleep, so these tests are instant and the delays can be inspected.

core::import retry

# ---- commands driven by retry::run --------------------------------------------
# They count their calls in CALLS. `seen` and `SLEEPS` are locals of the
# calling test, reached through bash's dynamic scoping.

_record_sleep() {
  SLEEPS+=("$1")
}

_flaky() {
  (( ++CALLS ))
  (( CALLS >= $1 ))
}

_fail7() {
  (( ++CALLS ))
  return 7
}

_skip20() {
  (( ++CALLS ))
  return 20
}

_note_attempt() {
  seen+="$RETRY_ATTEMPT/$RETRY_MAX "
  (( RETRY_ATTEMPT == 3 ))
}

_abort() {
  (( ++CALLS ))
  RETRY_ABORT=1
  return 1
}

# ---- tests ------------------------------------------------------------------------

# Fails twice, succeeds on attempt 3, with two backoff sleeps in between.
test_retries_until_success() {
  local -a SLEEPS=()
  local RETRY_SLEEP=_record_sleep
  CALLS=0
  retry::run -a 5 -b 100 -m 1000 -- _flaky 3
  assert::eq 3 "$CALLS"
  assert::eq 2 "${#SLEEPS[@]}" "one backoff between consecutive attempts"
}

# After the last attempt, the command's own exit status is returned.
test_gives_up_with_the_last_exit_code() {
  local RETRY_SLEEP=:
  CALLS=0
  if retry::run -a 3 -- _fail7; then
    return 1
  else
    assert::eq 7 "$?"
  fi
  assert::eq 3 "$CALLS"
}

# An exit code listed with -x ends the loop immediately.
test_final_exit_codes_are_not_retried() {
  local RETRY_SLEEP=:
  CALLS=0
  if retry::run -a 5 -x "10 20" -- _skip20; then
    return 1
  else
    assert::eq 20 "$?"
  fi
  assert::eq 1 "$CALLS"
}

# Full jitter: every delay lies in [0, min(max, base * 2^(attempt-1))].
test_backoff_is_capped_and_jittered() {
  local -a SLEEPS=() caps=(100 200 300 300 300)
  local RETRY_SLEEP=_record_sleep
  local -i i
  CALLS=0
  retry::run -a 6 -b 100 -m 300 -- _flaky 99 || :
  assert::eq 5 "${#SLEEPS[@]}"
  for (( i = 0; i < 5; i++ )); do
    if (( SLEEPS[i] < 0 || SLEEPS[i] > caps[i] )); then
      printf 'delay %d = %d exceeds cap %d\n' "$i" "${SLEEPS[i]}" "${caps[i]}" >&2
      return 1
    fi
  done
}

# RETRY_ATTEMPT and RETRY_MAX are readable inside the command, thanks to
# dynamic scoping.
test_attempt_counters_are_visible_to_the_command() {
  local RETRY_SLEEP=:
  local seen=""
  retry::run -a 4 -- _note_attempt
  assert::eq '1/4 2/4 3/4 ' "$seen"
}

# Setting RETRY_ABORT - as the scheduler's TERM trap does - stops the loop.
test_abort_flag_stops_further_attempts() {
  local RETRY_SLEEP=:
  CALLS=0
  retry::run -a 5 -- _abort || :
  assert::eq 1 "$CALLS"
}

# An unknown option and a missing command are usage errors (64).
test_usage_errors() {
  assert::rc 64 retry::run -z 1 -- true
  assert::rc 64 retry::run -a 2 --
}
