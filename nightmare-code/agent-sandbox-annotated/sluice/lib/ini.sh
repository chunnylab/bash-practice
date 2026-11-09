#!/usr/bin/env bash
# =============================================================================
# lib/ini.sh - a strict INI parser
# =============================================================================
#
# Grammar (one construct per line, surrounding whitespace ignored):
#
#   # comment            ; comment       blank lines are ignored too
#   [section]            [type name]     e.g. [pipeline], [job backup]
#   key = value          key = "  quoted keeps outer spaces  "
#
# Results are delivered into the caller's variables (namerefs):
#
#   local -A cfg=(); local -a keys=() sections=()
#   ini::parse pipeline.ini cfg keys sections
#   ${cfg[job.backup.run]}   -> "stages/backup.sh"
#   keys                     -> every "section.key" in file order
#   sections                 -> every section id in file order
#
# "[type name]" becomes the section id "type.name". Order is preserved
# because it is meaningful: jobs are listed (and tie-broken) in file order,
# and [env] entries may refer to entries defined above them.
#
# Strictness is a feature: duplicate keys, duplicate sections, keys outside a
# section and unparseable lines are all errors reported as file:line, and ALL
# errors are reported in one pass - like a compiler, not one at a time.
# =============================================================================

# ini::parse FILE CFG_ASSOC KEYS_ARRAY SECTIONS_ARRAY
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

  # `read -r` keeps backslashes literal; IFS= keeps leading whitespace.
  # `|| [[ -n $__ini_line ]]` processes a final line that lacks a trailing
  # newline: read returns 1 at EOF but has still filled the variable.
  while IFS= read -r __ini_line || [[ -n $__ini_line ]]; do
    (( ++__ini_no ))
    # Tolerate CRLF files saved by Windows editors.
    core::trim "${__ini_line%$'\r'}"
    __ini_line=$REPLY
    case $__ini_line in
      '' | '#'* | ';'*) continue ;;
    esac

    if [[ $__ini_line =~ $__ini_hdr ]]; then
      # ${x:+word} expands to word only when x is non-empty, so [pipeline]
      # becomes "pipeline" and [job backup] becomes "job.backup".
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
      # "..." keeps leading/trailing spaces; ${v:1:-1} drops the quotes.
      if [[ ${#__ini_val} -ge 2 && $__ini_val == \"*\" ]]; then
        __ini_val=${__ini_val:1:-1}
      fi
      # ${arr[k]+set} distinguishes "absent" from "present but empty".
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

# Reports an error at the current position. It reads __ini_file/__ini_no and
# increments __ini_errors of the calling ini::parse through dynamic scoping.
ini::_err() {
  log::error "$__ini_file:$__ini_no: $1"
  (( ++__ini_errors ))
}
