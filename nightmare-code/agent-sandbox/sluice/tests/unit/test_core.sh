#!/usr/bin/env bash

test_interpolate_expands_variables() {
  local NAME=world
  core::interpolate 'hello ${NAME}!'
  assert::eq 'hello world!' "$REPLY"
}

test_interpolate_defaults_apply_to_unset_and_empty() {
  local EMPTY=""
  core::interpolate '${UNSET_FOR_TEST:-a}/${EMPTY:-b}/${EMPTY}'
  assert::eq 'a/b/' "$REPLY"
}

test_interpolate_fails_on_unset_without_default() {
  if core::interpolate 'x ${UNSET_FOR_TEST} y'; then
    return 1
  fi
  assert::eq UNSET_FOR_TEST "$REPLY"
}

test_interpolate_never_executes_code() {
  core::interpolate 'a $(touch pwned) `touch pwned2` b'
  assert::eq 'a $(touch pwned) `touch pwned2` b' "$REPLY"
  assert::no_file pwned
  assert::no_file pwned2
}

test_trim_join_and_in_list() {
  core::trim $'  \t padded value \n'
  assert::eq 'padded value' "$REPLY"
  core::join ' -> ' a b c
  assert::eq 'a -> b -> c' "$REPLY"
  core::join ,
  assert::eq '' "$REPLY"
  core::in_list b a b c
  if core::in_list 'a*' abc; then
    return 1
  fi
}

test_parse_duration_ms() {
  local spec
  for spec in 250ms=250 30=30000 30s=30000 5m=300000 2h=7200000 08s=8000; do
    core::parse_duration_ms "${spec%%=*}"
    assert::eq "${spec#*=}" "$REPLY" "duration ${spec%%=*}"
  done
  if core::parse_duration_ms 5x; then return 1; fi
  if core::parse_duration_ms ''; then return 1; fi
}

test_to_centi_and_parse_bool() {
  local spec
  for spec in 2=200 2.5=250 1.25=125 0.05=5 1.999=199; do
    core::to_centi "${spec%%=*}"
    assert::eq "${spec#*=}" "$REPLY" "centi ${spec%%=*}"
  done
  if core::to_centi abc; then return 1; fi
  core::parse_bool YES
  assert::eq 1 "$REPLY"
  core::parse_bool off
  assert::eq 0 "$REPLY"
  if core::parse_bool maybe; then return 1; fi
}

test_atomic_write_leaves_no_temporary_files() {
  core::atomic_write out.txt 'first'
  printf 'second\n' | core::atomic_write out.txt
  assert::eq second "$(< out.txt)"
  local -a leftovers=(.out.txt.*)
  assert::eq 0 "${#leftovers[@]}" "temporary files left behind"
}

test_exit_hooks_run_lifo_only_in_the_owning_process() {
  (
    core::install_traps
    core::on_exit printf '%s\n' first
    core::on_exit printf '%s\n' "second with spaces"
    ( core::install_traps; : )
    :
  ) > hooks.txt
  assert::eq $'second with spaces\nfirst' "$(< hooks.txt)"
}

test_secret_names_are_detected() {
  core::is_secret_name SLUICE_WEBHOOK_URL
  core::is_secret_name db_password
  core::is_secret_name GITHUB_TOKEN
  if core::is_secret_name SLUICE_LOG_LEVEL; then return 1; fi
}
