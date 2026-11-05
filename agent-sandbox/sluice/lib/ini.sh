#!/usr/bin/env bash

ini::parse() {
  local __ini_file=$1
  local -n __ini_cfg=$2 __ini_keys=$3 __ini_sections=$4
  local __ini_line __ini_section="" __ini_key __ini_val
  local -i __ini_no=0 __ini_errors=0
  local -r __ini_hdr='^\[[[:space:]]*([A-Za-z][A-Za-z0-9_-]*)([[:space:]]+([A-Za-z0-9][A-Za-z0-9_.-]*))?[[:space:]]*\]$'
  local -r __ini_kv='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'

  if [[ ! -r $__ini_file ]]; then
    log::error "ini: cannot read '$__ini_file'"
    return "$EX_DATAERR"
  fi

  while IFS= read -r __ini_line || [[ -n $__ini_line ]]; do
    (( ++__ini_no ))
    core::trim "${__ini_line%$'\r'}"
    __ini_line=$REPLY
    case $__ini_line in
      '' | '#'* | ';'*) continue ;;
    esac

    if [[ $__ini_line =~ $__ini_hdr ]]; then
      __ini_section=${BASH_REMATCH[1],,}${BASH_REMATCH[3]:+.${BASH_REMATCH[3]}}
      if core::in_list "$__ini_section" "${__ini_sections[@]}"; then
        ini::_err "duplicate section [${BASH_REMATCH[1]}${BASH_REMATCH[3]:+ ${BASH_REMATCH[3]}}]"
        continue
      fi
      __ini_sections+=("$__ini_section")
    elif [[ $__ini_line =~ $__ini_kv ]]; then
      if [[ -z $__ini_section ]]; then
        ini::_err "key '${BASH_REMATCH[1]}' appears before any [section]"
        continue
      fi
      __ini_key=$__ini_section.${BASH_REMATCH[1]}
      __ini_val=${BASH_REMATCH[2]}
      if [[ ${#__ini_val} -ge 2 && $__ini_val == \"*\" ]]; then
        __ini_val=${__ini_val:1:-1}
      fi
      if [[ -n ${__ini_cfg[$__ini_key]+set} ]]; then
        ini::_err "duplicate key '${BASH_REMATCH[1]}' in [${__ini_section/./ }]"
        continue
      fi
      __ini_cfg[$__ini_key]=$__ini_val
      __ini_keys+=("$__ini_key")
    else
      ini::_err "cannot parse line: $__ini_line"
    fi
  done < "$__ini_file"

  (( __ini_errors == 0 )) || return "$EX_DATAERR"
}

ini::_err() {
  log::error "$__ini_file:$__ini_no: $1"
  (( ++__ini_errors ))
}
