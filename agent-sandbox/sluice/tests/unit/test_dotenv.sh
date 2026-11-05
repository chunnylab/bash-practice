#!/usr/bin/env bash

core::import dotenv

test_quoting_escapes_and_comments() {
  t::write t.env <<'ENV'
# comment line
export PLAIN=hello world   # inline comment
SINGLE='literal ${HOME} \n'
DOUBLE="line1\nline2 \"q\" \\n \$HOME"
EMPTY=
URL=https://example.com/a#fragment
SPACED   =   value with spaces
ENV
  dotenv::load t.env
  assert::eq 'hello world' "$PLAIN"
  assert::eq 'literal ${HOME} \n' "$SINGLE"
  assert::eq $'line1\nline2 "q" \\n $HOME' "$DOUBLE"
  assert::eq '' "$EMPTY"
  assert::eq 'https://example.com/a#fragment' "$URL"
  assert::eq 'value with spaces' "$SPACED"
}

test_environment_wins_unless_override_is_requested() {
  export KEEP_ME=from-env
  printf 'KEEP_ME=from-file\nFRESH=new\n' > t.env
  dotenv::load t.env
  assert::eq from-env "$KEEP_ME"
  assert::eq new "$FRESH"
  dotenv::load t.env 1
  assert::eq from-file "$KEEP_ME"
}

test_interpolation_defaults_and_escaped_dollars() {
  printf '%s\n' 'BASE_DIR=/srv' 'DATA_DIR="${BASE_DIR}/data"' 'OPT=${MISSING_FOR_TEST:-fallback}' \
    'ESCAPED="\${BASE_DIR}"' > t.env
  dotenv::load t.env
  assert::eq /srv/data "$DATA_DIR"
  assert::eq fallback "$OPT"
  assert::eq '${BASE_DIR}' "$ESCAPED"
}

test_errors_are_collected_and_protected_names_refused() {
  printf '%s\n' 'GOOD=1' 'BAD=${MISSING_FOR_TEST}' 'not a pair' 'Q="unterminated' 'SLUICE_HOME=/tmp/evil' > t.env
  local home=$SLUICE_HOME
  assert::rc 78 dotenv::load t.env
  assert::contains "$T_OUT" 't.env:2: undefined variable ${MISSING_FOR_TEST}'
  assert::contains "$T_OUT" 't.env:3: expected KEY=VALUE'
  assert::contains "$T_OUT" 't.env:4: unterminated double-quoted value'
  assert::contains "$T_OUT" 'refusing to set protected variable SLUICE_HOME'
  dotenv::load t.env 2> /dev/null || :
  assert::eq "$home" "$SLUICE_HOME"
  assert::eq 1 "$GOOD"
}
