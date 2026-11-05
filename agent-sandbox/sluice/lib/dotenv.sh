#!/usr/bin/env bash

dotenv::load() {
  local file=$1 line key
  local -i override=${2:-0} lineno=0 errors=0
  local -r re='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'

  if [[ ! -r $file ]]; then
    log::error "dotenv: cannot read '$file'"
    return "$EX_CONFIG"
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    (( ++lineno ))
    core::trim "${line%$'\r'}"
    line=$REPLY
    if [[ -z $line || $line == '#'* ]]; then
      continue
    fi
    if [[ ! $line =~ $re ]]; then
      log::error "dotenv: $file:$lineno: expected KEY=VALUE"
      (( ++errors ))
      continue
    fi
    key=${BASH_REMATCH[2]}
    if dotenv::_protected "$key"; then
      log::warn "dotenv: $file:$lineno: refusing to set protected variable $key"
      continue
    fi
    if ! dotenv::_decode "${BASH_REMATCH[3]}"; then
      log::error "dotenv: $file:$lineno: $REPLY"
      (( ++errors ))
      continue
    fi
    if (( override )) || [[ -z ${!key+set} ]]; then
      export "$key=$REPLY"
    fi
  done < "$file"

  (( errors == 0 )) || return "$EX_CONFIG"
}

dotenv::_protected() {
  case $1 in
    BASH* | SHELLOPTS | EUID | UID | PPID | IFS | EX_* | __* | SLUICE_HOME | SLUICE_LIB | SLUICE_VERSION) return 0 ;;
  esac
  return 1
}

dotenv::_decode() {
  local raw=$1 v
  local -r sq_re="^'([^']*)'([[:space:]]+#.*)?$"
  local -r dq_re='^"((\\.|[^"\\])*)"([[:space:]]+#.*)?$'
  case $raw in
    \'*)
      if [[ ! $raw =~ $sq_re ]]; then
        REPLY="unterminated single-quoted value"
        return 1
      fi
      REPLY=${BASH_REMATCH[1]}
      return 0
      ;;
    \"*)
      if [[ ! $raw =~ $dq_re ]]; then
        REPLY="unterminated double-quoted value"
        return 1
      fi
      v=${BASH_REMATCH[1]}
      v=${v//\\\\/$'\x01'}
      v=${v//\\\$/$'\x02'}
      v=${v//\\n/$'\n'}
      v=${v//\\t/$'\t'}
      v=${v//\\\"/\"}
      ;;
    *)
      v=${raw%%+([[:space:]])#*}
      ;;
  esac
  if ! core::interpolate "$v"; then
    REPLY="undefined variable \${$REPLY} (use \${$REPLY:-default} or define it first)"
    return 1
  fi
  v=${REPLY//$'\x01'/\\}
  REPLY=${v//$'\x02'/\$}
}
