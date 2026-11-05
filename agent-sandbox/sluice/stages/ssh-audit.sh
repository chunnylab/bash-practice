#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init ssh-audit

declare -gA SSH_VAL=() SSH_SRC=()
declare -ga SSH_FILES=()
declare -gi SSH_MATCH=0 SSH_TOTAL=0 SSH_PASSED=0
declare -g SSH_BASE=.

main() {
  local cfg=${SLUICE_SSHD_CONFIG:-/etc/ssh/sshd_config}
  [[ -r $cfg ]] || stage::skip "sshd config not readable: $cfg"
  [[ $cfg != */* ]] || SSH_BASE=${cfg%/*}
  ssh::parse "$cfg" 0

  ssh::rule SSH-001 critical PermitRootLogin eq 'no~prohibit-password,without-password,forced-commands-only' \
    prohibit-password "root must not log in directly; use a personal account and sudo"
  ssh::rule SSH-002 high PasswordAuthentication eq no yes \
    "password logins invite credential stuffing and brute force; use keys"
  ssh::rule SSH-003 critical PermitEmptyPasswords eq no no \
    "accounts with empty passwords must never be able to log in"
  ssh::rule SSH-004 medium KbdInteractiveAuthentication eq no yes \
    "keyboard-interactive authentication can fall back to passwords"
  ssh::rule SSH-005 low X11Forwarding eq no no \
    "X11 forwarding exposes the client's display to the server"
  ssh::rule SSH-006 medium MaxAuthTries le 4 6 \
    "limit authentication attempts per connection"
  ssh::rule SSH-007 low LoginGraceTime tle 60 120 \
    "unauthenticated connections should be dropped quickly"
  ssh::rule SSH-008 low ClientAliveInterval trange 1:900 0 \
    "idle sessions should be detected and reaped"
  ssh::rule SSH-009 medium HostbasedAuthentication eq no no \
    "host-based trust is spoofable"
  ssh::rule SSH-010 medium IgnoreRhosts eq yes yes \
    "legacy .rhosts files must be ignored"
  ssh::rule SSH-011 low AllowAgentForwarding eq no yes \
    "a compromised server can use a forwarded agent to reach other hosts"
  ssh::rule SSH-012 medium Ciphers nomatch '(^|,)(3des-cbc|blowfish-cbc|cast128-cbc|arcfour[^,]*|aes(128|192|256)-cbc|rijndael-cbc[^,]*)(,|$)' \
    '(default)' "CBC-mode and RC4 ciphers are obsolete"
  ssh::rule SSH-013 medium MACs nomatch '(^|,)(hmac-md5[^,]*|hmac-sha1-96[^,]*|umac-64[^,]*|hmac-ripemd160[^,]*)(,|$)' \
    '(default)' "MD5, truncated SHA-1 and 64-bit MACs are weak"

  stage::metric config "$cfg"
  stage::metric files_parsed "${#SSH_FILES[@]}"
  stage::metric match_blocks "$SSH_MATCH"
  stage::metric rules_total "$SSH_TOTAL"
  stage::metric rules_passed "$SSH_PASSED"
  stage::metric score_pct $(( SSH_PASSED * 100 / SSH_TOTAL ))

  local kw
  for kw in "${!SSH_VAL[@]}"; do
    printf '%s\t%s\t%s\n' "$kw" "${SSH_VAL[$kw]}" "${SSH_SRC[$kw]}"
  done | LC_ALL=C sort > "$STAGE_OUT/effective.tsv"
}

ssh::parse() {
  local file=$1 line kw arg pattern inc LC_ALL=C
  local -i depth=$2 lineno=0
  local -a patterns=() matches=()
  if (( depth > 8 )); then
    stage::finding medium SSH-INCLUDE "Include nesting deeper than 8 levels at $file"
    return 0
  fi
  if [[ ! -r $file ]]; then
    stage::finding low SSH-INCLUDE "included file is not readable: $file"
    return 0
  fi
  SSH_FILES+=("$file")
  while IFS= read -r line || [[ -n $line ]]; do
    (( ++lineno ))
    core::trim "${line%$'\r'}"
    line=$REPLY
    [[ -n $line && $line != '#'* ]] || continue
    [[ $line =~ ^([A-Za-z][A-Za-z0-9]*)([[:space:]]*=[[:space:]]*|[[:space:]]+)(.*)$ ]] || continue
    kw=${BASH_REMATCH[1],,}
    arg=${BASH_REMATCH[3]}
    if [[ $arg == \"*\" ]]; then
      arg=${arg:1:-1}
    fi
    case $kw in
      match)
        SSH_MATCH=1
        return 0
        ;;
      include)
        read -r -a patterns <<< "$arg"
        for pattern in "${patterns[@]}"; do
          [[ $pattern == /* ]] || pattern=$SSH_BASE/$pattern
          stage::expand_globs matches "$pattern"
          for inc in "${matches[@]}"; do
            ssh::parse "$inc" $(( depth + 1 ))
          done
        done
        ;;
      *)
        if [[ -z ${SSH_VAL[$kw]+set} ]]; then
          SSH_VAL[$kw]=$arg
          SSH_SRC[$kw]=$file:$lineno
        fi
        ;;
    esac
  done < "$file"
}

ssh::seconds() {
  local v=${1,,}
  local -i total=0 n
  [[ $v =~ ^([0-9]+[smhdw]?)+$ ]] || return 1
  while [[ $v =~ ^([0-9]+)([smhdw]?) ]]; do
    n=$(( 10#${BASH_REMATCH[1]} ))
    case ${BASH_REMATCH[2]} in
      m) n=$(( n * 60 )) ;;
      h) n=$(( n * 3600 )) ;;
      d) n=$(( n * 86400 )) ;;
      w) n=$(( n * 604800 )) ;;
    esac
    total=$(( total + n ))
    v=${v:${#BASH_REMATCH[0]}}
  done
  REPLY=$total
}

ssh::rule() {
  local code=$1 sev=$2 name=$3 op=$4 arg=$5 default=$6 why=$7
  local kw=${3,,} val lc shown
  local -i ok=0
  val=${SSH_VAL[$kw]:-$default}
  lc=${val,,}
  (( ++SSH_TOTAL ))
  case $op in
    eq)
      if [[ $lc == "${arg%%~*}" ]]; then
        ok=1
      elif [[ $arg == *~* && ",${arg#*~}," == *",$lc,"* ]]; then
        sev=low
      fi
      ;;
    le)
      if [[ $lc =~ ^[0-9]+$ ]] && (( 10#$lc <= arg )); then ok=1; fi
      ;;
    tle)
      if ssh::seconds "$lc" && (( REPLY <= arg )); then ok=1; fi
      ;;
    trange)
      if ssh::seconds "$lc" && (( REPLY >= ${arg%%:*} && REPLY <= ${arg#*:} )); then ok=1; fi
      ;;
    nomatch)
      if [[ $val == "(default)" || ! $lc =~ $arg ]]; then ok=1; fi
      ;;
  esac
  if (( ok )); then
    (( ++SSH_PASSED ))
    return 0
  fi
  if [[ -n ${SSH_SRC[$kw]-} ]]; then
    shown="'$val' (set in ${SSH_SRC[$kw]})"
  else
    shown="'$val' (OpenSSH default; not set explicitly)"
  fi
  stage::finding "$sev" "$code" "$name is $shown: $why"
}

main "$@"
stage::finish
