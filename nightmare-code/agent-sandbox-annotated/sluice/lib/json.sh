#!/usr/bin/env bash
# =============================================================================
# lib/json.sh - JSON encoding in pure bash (no jq, no python)
# =============================================================================
#
# Encoding is the easy half of JSON and the only half sluice needs: stages
# exchange data through simple TSV files and emit JSON for the outside world
# (webhooks, dashboards, `jq` users).
#
# The central idea is a TYPED FIELD SPEC, "key[:type]=value":
#
#   json::object "host=web-01" "cpus:n=8" "healthy:b=true" "tags:raw=$arr"
#   -> {"host":"web-01","cpus":8,"healthy":true,"tags":[...]}
#
#   type  meaning
#   s     string (default)      n     number (validated against JSON grammar)
#   b     boolean true|false     a     auto: number/bool if it looks like one
#   raw   pre-encoded JSON       null  JSON null (value ignored)
#
# Being explicit about types avoids the classic "is 007 a number?" ambiguity
# and lets nested documents be assembled from already-encoded fragments.
# =============================================================================

# -----------------------------------------------------------------------------
# json::escape STRING -> REPLY (without the surrounding quotes)
#
# Order matters: backslashes are doubled FIRST, otherwise the backslashes we
# introduce for \" and \n would themselves be doubled.
#
# A note on the replacement strings. In ${s//\\/\\\\} the replacement word
# undergoes quote removal, so the four backslashes become two. Bash 5.2 added
# `shopt patsub_replacement` (on by default), which makes an unquoted & in
# the replacement mean "the matched text" - harmless here because no
# replacement below contains a '&'. The HTML escaper in stages/report.sh
# shows the defensive form for when it does: quote it, ${s//</"&lt;"}.
#
# Fast path: most strings contain no control characters, so the per-byte
# work below is skipped entirely when [[:cntrl:]] does not match.
# -----------------------------------------------------------------------------
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

# Escape the remaining C0 control characters as \u00XX. This helper operates
# on the CALLER's local variable `s`: bash uses dynamic scoping, so a function
# sees the locals of every function above it on the call stack.
# NUL (0x00) is skipped because bash strings cannot contain it at all.
json::_escape_rest() {
  local -i i
  local ch hex
  for (( i = 1; i < 32; i++ )); do
    printf -v hex '%02x' "$i"
    # %b expands backslash escapes in its ARGUMENT, so the escape is built
    # from data and the format string stays constant.
    printf -v ch '%b' "\\x$hex"
    if [[ $s == *"$ch"* ]]; then
      s=${s//"$ch"/\\u00$hex}
    fi
  done
}

# json::is_number VALUE - the exact JSON number grammar (RFC 8259 section 6):
# no leading zeros, no "+", no bare ".5", optional fraction and exponent.
json::is_number() {
  [[ $1 =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

json::_bad() {
  printf 'json: invalid %s: %q\n' "$1" "$2" >&2
}

# json::encode TYPE VALUE -> REPLY (one encoded JSON value)
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

# json::object SPEC... -> REPLY, where SPEC is "key[:type]=value".
# ${spec%%=*} is everything before the FIRST '=', ${spec#*=} everything after
# it, so values may themselves contain '=' characters.
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

# json::array TYPE ITEM... -> REPLY, every item encoded with the same TYPE.
#   json::array s a b c      -> ["a","b","c"]
#   json::array raw "$o1" "$o2"  (an array of objects built earlier)
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
