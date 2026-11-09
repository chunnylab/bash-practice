#!/usr/bin/env bash

json::escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  if [[ $s == *[[:cntrl:]]* ]]; then
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    if [[ $s == *[[:cntrl:]]* ]]; then
      json::_escape_rest
    fi
  fi
  REPLY=$s
}

json::_escape_rest() {
  local -i i
  local ch hex
  for (( i = 1; i < 32; i++ )); do
    printf -v hex '%02x' "$i"
    printf -v ch '%b' "\\x$hex"
    if [[ $s == *"$ch"* ]]; then
      s=${s//"$ch"/\\u00$hex}
    fi
  done
}

json::is_number() {
  [[ $1 =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

json::_bad() {
  printf 'json: invalid %s: %q\n' "$1" "$2" >&2
}

json::encode() {
  case $1 in
    s)
      json::escape "$2"
      REPLY="\"$REPLY\""
      ;;
    n)
      json::is_number "$2" || { json::_bad number "$2"; return 1; }
      REPLY=$2
      ;;
    b)
      case $2 in
        true | false) REPLY=$2 ;;
        *) json::_bad boolean "$2"; return 1 ;;
      esac
      ;;
    a)
      if json::is_number "$2" || [[ $2 == true || $2 == false ]]; then
        REPLY=$2
      else
        json::escape "$2"
        REPLY="\"$REPLY\""
      fi
      ;;
    raw) REPLY=$2 ;;
    null) REPLY=null ;;
    *)
      json::_bad type "$1"
      return 1
      ;;
  esac
}

json::object() {
  local spec key type val out="" sep=""
  for spec in "$@"; do
    if [[ $spec != *=* ]]; then
      json::_bad "field spec (expected key[:type]=value)" "$spec"
      return 1
    fi
    key=${spec%%=*}
    type=s
    if [[ $key == *:* ]]; then
      type=${key##*:}
      key=${key%:*}
    fi
    json::encode "$type" "${spec#*=}" || return 1
    val=$REPLY
    json::escape "$key"
    out+="$sep\"$REPLY\":$val"
    sep=,
  done
  REPLY="{$out}"
}

json::array() {
  local type=$1 item out="" sep=""
  shift
  for item in "$@"; do
    json::encode "$type" "$item" || return 1
    out+=$sep$REPLY
    sep=,
  done
  REPLY="[$out]"
}
