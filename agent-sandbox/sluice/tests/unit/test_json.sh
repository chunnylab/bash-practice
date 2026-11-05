#!/usr/bin/env bash

core::import json

test_escape_quotes_backslashes_and_whitespace_controls() {
  json::escape $'quote " backslash \\ newline \n tab \t cr \r'
  assert::eq 'quote \" backslash \\ newline \n tab \t cr \r' "$REPLY"
}

test_escape_other_control_characters() {
  json::escape $'a\x01b\x1fc\x7fd'
  assert::eq $'a\\u0001b\\u001fc\x7fd' "$REPLY"
}

test_object_with_typed_fields() {
  json::object "name=web 01" "cpus:n=8" "ok:b=true" "tags:raw=[1,2]" "gone:null=" \
    "auto_num:a=42" "auto_padded:a=007" "auto_bool:a=false" "eq=a=b=c"
  assert::eq '{"name":"web 01","cpus":8,"ok":true,"tags":[1,2],"gone":null,"auto_num":42,"auto_padded":"007","auto_bool":false,"eq":"a=b=c"}' "$REPLY"
}

test_invalid_values_are_rejected() {
  if json::object "x:n=12abc" 2> /dev/null; then return 1; fi
  if json::object "x:b=yes" 2> /dev/null; then return 1; fi
  if json::object "no-equals-sign" 2> /dev/null; then return 1; fi
  if json::encode unknown-type v 2> /dev/null; then return 1; fi
}

test_number_grammar_follows_rfc_8259() {
  local n
  for n in 0 -1 3.14 1e10 -2.5E-3 10; do
    json::is_number "$n"
  done
  for n in 01 +1 .5 1. 0x10 '' 1e -; do
    if json::is_number "$n"; then
      printf 'accepted invalid number %q\n' "$n" >&2
      return 1
    fi
  done
}

test_arrays_and_nesting_produce_valid_json() {
  json::array s a 'b"c' $'line\nbreak'
  local arr=$REPLY
  assert::eq '["a","b\"c","line\nbreak"]' "$arr"
  json::array n
  assert::eq '[]' "$REPLY"
  json::object "list:raw=$arr" "nested:raw={\"k\":[true,null]}" "unicode=héllo ✔"
  printf '%s\n' "$REPLY" > doc.json
  assert::json doc.json
}
