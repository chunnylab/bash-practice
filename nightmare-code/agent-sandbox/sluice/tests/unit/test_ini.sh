#!/usr/bin/env bash

core::import ini

_parse() {
  local -A cfg=()
  local -a keys=() sections=()
  local k
  ini::parse "$1" cfg keys sections || return
  P_SECTIONS=${sections[*]}
  P_CFG=""
  for k in "${keys[@]}"; do
    P_CFG+="$k=${cfg[$k]}|"
  done
}

test_sections_keys_quotes_and_comments() {
  t::write p.ini <<'INI'
# leading comment
; semicolon comment

[pipeline]
name = demo
description = "  padded  "
equation = a=b

[job build]
run=stages/build.sh
INI
  _parse p.ini
  assert::eq 'pipeline job.build' "$P_SECTIONS"
  assert::eq 'pipeline.name=demo|pipeline.description=  padded  |pipeline.equation=a=b|job.build.run=stages/build.sh|' "$P_CFG"
}

test_crlf_line_endings_and_missing_final_newline() {
  printf '[s]\r\nk = v\r\nlast = x' > crlf.ini
  _parse crlf.ini
  assert::eq 's.k=v|s.last=x|' "$P_CFG"
}

test_every_error_is_reported_with_its_line_number() {
  t::write bad.ini <<'INI'
orphan = 1
[s]
a = 1
a = 2
this is not ini
[s]
INI
  assert::rc 65 _parse bad.ini
  assert::contains "$T_OUT" "bad.ini:1: key 'orphan' appears before any [section]"
  assert::contains "$T_OUT" "bad.ini:4: duplicate key 'a' in [s]"
  assert::contains "$T_OUT" "bad.ini:5: cannot parse line: this is not ini"
  assert::contains "$T_OUT" "bad.ini:6: duplicate section [s]"
}

test_missing_file_is_a_data_error() {
  assert::rc 65 _parse does-not-exist.ini
  assert::contains "$T_OUT" "cannot read 'does-not-exist.ini'"
}
