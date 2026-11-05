#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
  printf 'sluice: bash >= 5.1 is required, but this is bash %s\n' "${BASH_VERSION}" >&2
  if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    exit 69
  fi
  return 69
fi

[[ -z ${__SLUICE_CORE_LOADED-} ]] || return 0
declare -gr __SLUICE_CORE_LOADED=1

set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit extglob nullglob
umask 027

if [[ -z ${SLUICE_HOME-} ]]; then
  __core_src=${BASH_SOURCE[0]}
  [[ $__core_src == */* ]] || __core_src=./$__core_src
  SLUICE_HOME=$(cd -P -- "${__core_src%/*}/.." && pwd)
  unset __core_src
fi
export SLUICE_HOME
declare -gr SLUICE_LIB=$SLUICE_HOME/lib
declare -gr SLUICE_VERSION=1.0.0

declare -gri EX_OK=0 EX_FAIL=1 EX_WARN=10 EX_SKIP=20 EX_USAGE=64 EX_DATAERR=65 \
  EX_UNAVAILABLE=69 EX_SOFTWARE=70 EX_CANTCREAT=73 EX_TEMPFAIL=75 EX_CONFIG=78

declare -gA __CORE_MODULES=([core]=1)

core::import() {
  local __mod
  for __mod in "$@"; do
    [[ -z ${__CORE_MODULES[$__mod]-} ]] || continue
    __CORE_MODULES[$__mod]=1
    if [[ ! -r $SLUICE_LIB/$__mod.sh ]]; then
      core::die "core::import: no module named '$__mod' in $SLUICE_LIB" "$EX_SOFTWARE"
    fi
    source "$SLUICE_LIB/$__mod.sh"
  done
}

core::die() {
  local msg=${1-unknown error}
  local -i code=${2:-$EX_FAIL}
  if declare -F log::error >/dev/null; then
    log::error "$msg"
  else
    printf '%s: error: %s\n' "${0##*/}" "$msg" >&2
  fi
  exit "$code"
}

core::_on_err() {
  local -i rc=$1 i
  local cmd=$2
  printf '%s: unexpected failure (exit %d) while running: %s\n' "${0##*/}" "$rc" "$cmd" >&2
  for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
    printf '    at %-30s %s:%s\n' "${FUNCNAME[i]}" "${BASH_SOURCE[i]#"$SLUICE_HOME/"}" "${BASH_LINENO[i - 1]}" >&2
  done
}
trap 'core::_on_err "$?" "$BASH_COMMAND"' ERR

declare -ga __CORE_HOOKS=() __CORE_HOOK_PIDS=()

core::on_exit() {
  local hook
  printf -v hook '%q ' "$@"
  __CORE_HOOKS+=("$hook")
  __CORE_HOOK_PIDS+=("$BASHPID")
}

core::_run_exit_hooks() {
  local -i i
  for (( i = ${#__CORE_HOOKS[@]} - 1; i >= 0; i-- )); do
    [[ ${__CORE_HOOK_PIDS[i]} == "$BASHPID" ]] || continue
    eval "${__CORE_HOOKS[i]}" || :
  done
  __CORE_HOOKS=()
  __CORE_HOOK_PIDS=()
}

core::_on_signal() {
  local sig=$1
  trap - EXIT
  core::_run_exit_hooks
  trap - "$sig"
  kill -s "$sig" "$BASHPID"
}

core::install_traps() {
  trap core::_run_exit_hooks EXIT
  trap 'core::_on_signal INT' INT
  trap 'core::_on_signal TERM' TERM
  trap 'core::_on_signal HUP' HUP
}
core::install_traps

core::have() {
  command -v -- "$1" >/dev/null 2>&1
}

core::require() {
  local -a missing=()
  local c
  for c in "$@"; do
    core::have "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    core::die "missing required command(s): ${missing[*]}" "$EX_UNAVAILABLE"
  fi
}

core::trim() {
  local s=$1
  s=${s##+([[:space:]])}
  REPLY=${s%%+([[:space:]])}
}

core::in_list() {
  local needle=$1 item
  shift
  for item in "$@"; do
    if [[ $item == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

core::join() {
  local sep=$1 item
  shift
  REPLY=${1-}
  (( $# )) || return 0
  shift
  for item in "$@"; do
    REPLY+=$sep$item
  done
}

core::parse_bool() {
  case ${1,,} in
    1 | true | yes | on) REPLY=1 ;;
    0 | false | no | off) REPLY=0 ;;
    *) return 1 ;;
  esac
}

core::is_true() {
  core::parse_bool "${1-}" && (( REPLY == 1 ))
}

core::parse_duration_ms() {
  [[ ${1,,} =~ ^([0-9]+)(ms|s|m|h)?$ ]] || return 1
  local -i n=$(( 10#${BASH_REMATCH[1]} ))
  case ${BASH_REMATCH[2]:-s} in
    ms) REPLY=$n ;;
    s) REPLY=$(( n * 1000 )) ;;
    m) REPLY=$(( n * 60000 )) ;;
    h) REPLY=$(( n * 3600000 )) ;;
  esac
}

core::to_centi() {
  [[ $1 =~ ^([0-9]+)(\.([0-9]+))?$ ]] || return 1
  local frac=${BASH_REMATCH[3]}00
  REPLY=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2} ))
}

core::interpolate() {
  local rest=$1 out="" name
  local -r re='\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}'
  while [[ $rest =~ $re ]]; do
    out+=${rest%%"${BASH_REMATCH[0]}"*}
    name=${BASH_REMATCH[1]}
    if [[ -n ${!name+set} ]] && [[ -n ${!name} || -z ${BASH_REMATCH[2]} ]]; then
      out+=${!name}
    elif [[ -n ${BASH_REMATCH[2]} ]]; then
      out+=${BASH_REMATCH[3]}
    else
      REPLY=$name
      return 1
    fi
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
  REPLY=$out$rest
}

core::atomic_write() {
  local dest=$1 tmp
  if [[ $dest == */* ]]; then
    tmp=${dest%/*}/.${dest##*/}
  else
    tmp=.$dest
  fi
  tmp+=.$BASHPID.$SRANDOM.tmp
  if (( $# > 1 )); then
    printf '%s' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$dest"
}

core::mktemp_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sluice-${1:-tmp}.XXXXXXXX") \
    || core::die "cannot create a temporary directory" "$EX_CANTCREAT"
  core::on_exit rm -rf -- "$dir"
  REPLY=$dir
}

core::can_symlink() {
  local dir=$1 target link
  target=$dir/.sluice-probe-target.$BASHPID
  link=$dir/.sluice-probe-link.$BASHPID
  : > "$target" || return 1
  if ln -s -- "${target##*/}" "$link" 2>/dev/null && [[ -L $link ]]; then
    rm -f -- "$link" "$target"
    return 0
  fi
  rm -rf -- "$link" "$target"
  return 1
}

core::is_secret_name() {
  [[ ${1^^} =~ (TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|WEBHOOK|API_?KEY|PRIVATE) ]]
}
