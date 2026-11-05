#!/usr/bin/env bash
# =============================================================================
# lib/core.sh - the runtime foundation of sluice
# =============================================================================
#
# Every entrypoint (bin/sluice, every stages/*.sh, tests/run.sh) sources this
# file before anything else. Sourcing it:
#
#   1. refuses to run on a bash older than 5.1,
#   2. switches the shell into "strict mode",
#   3. installs ERR / EXIT / signal traps (stack traces + a cleanup stack),
#   4. defines a tiny module system (core::import) used by the rest of lib/,
#   5. provides small, fork-free helpers that everything else builds on.
#
# CONVENTIONS ESTABLISHED HERE AND FOLLOWED EVERYWHERE
#
#   * Namespaces. Public functions are named <module>::<verb>, private ones
#     <module>::_<verb>. Bash accepts ':' in function names, so we get
#     namespaces for free and `declare -F | grep '^declare -f json::'` lists
#     a module's API.
#
#   * Scalar return values go into the global variable REPLY instead of being
#     printed. `x=$(f)` forks a subshell for every call - cheap on Linux, but
#     painfully slow on Git Bash/Cygwin where fork() is emulated. Callers copy
#     REPLY right away because the next helper call overwrites it:
#         json::escape "$s"; escaped=$REPLY
#
#   * Collections are returned through namerefs (`local -n out=$1`). Inside
#     those functions every local variable carries a unique prefix (e.g.
#     __ini_line) so it can never shadow the caller's variable that the
#     nameref points to - the classic nameref "circular reference" trap.
#
#   * Exit codes follow sysexits(3) wherever one fits (EX_* constants below);
#     stages additionally use EX_WARN (10) and EX_SKIP (20) to talk to the
#     scheduler.
# =============================================================================

# -----------------------------------------------------------------------------
# Version gate. It must run FIRST and use only syntax that bash 3.2 (macOS'
# /bin/bash) can parse, otherwise the ancient shells it is meant to reject
# would choke on newer syntax before ever printing the friendly message.
# We need 5.1 for `wait -n -p` (the parallel scheduler) and $SRANDOM.
# When this file is executed instead of sourced, BASH_SOURCE[0] equals $0
# and `return` would be an error, so we `exit` instead.
# -----------------------------------------------------------------------------
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
  printf 'sluice: bash >= 5.1 is required, but this is bash %s\n' "${BASH_VERSION}" >&2
  if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    exit 69
  fi
  return 69
fi

# Include guard: a second `source` in the same shell is a no-op. The guard
# variable is deliberately NOT exported, so every new bash process (each stage
# script, for example) initialises its own copy of the runtime.
[[ -z ${__SLUICE_CORE_LOADED-} ]] || return 0
declare -gr __SLUICE_CORE_LOADED=1

# -----------------------------------------------------------------------------
# Strict mode.
#   errexit   (-e)  abort when a command fails (with well-known exceptions:
#                   conditions of if/while, the left side of && and ||, ...)
#   errtrace  (-E)  let functions, subshells and command substitutions inherit
#                   the ERR trap, so stack traces work everywhere
#   nounset   (-u)  referencing an unset variable is an error, not ""
#   pipefail        a pipeline fails if ANY member fails, not just the last
#   inherit_errexit makes $(...) honour errexit as well (off by default!)
#   extglob         enables +(..), @(..), !(..) patterns, used for trimming
#   nullglob        a glob matching nothing expands to nothing instead of
#                   itself, so `for f in *.log` never sees a literal "*.log"
# umask 027: files we create are never world-readable. Backups and reports
# contain sensitive data; stages that publish to a web root opt out locally.
# -----------------------------------------------------------------------------
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit extglob nullglob
umask 027

# -----------------------------------------------------------------------------
# Locate the installation. SLUICE_HOME may be inherited from the parent
# process (the engine exports it to every job); otherwise we derive it from
# this file's own location: <home>/lib/core.sh. `cd -P` resolves symlinked
# directories so the path we export is canonical.
# -----------------------------------------------------------------------------
if [[ -z ${SLUICE_HOME-} ]]; then
  __core_src=${BASH_SOURCE[0]}
  [[ $__core_src == */* ]] || __core_src=./$__core_src
  SLUICE_HOME=$(cd -P -- "${__core_src%/*}/.." && pwd)
  unset __core_src
fi
export SLUICE_HOME
declare -gr SLUICE_LIB=$SLUICE_HOME/lib
declare -gr SLUICE_VERSION=1.0.0

# Exit codes. EX_WARN/EX_SKIP are sluice's own; the rest mirror sysexits.h so
# that supervisors (systemd, cron wrappers, CI) can tell "usage error" (64)
# from "bad input data" (65) from "try again later" (75).
declare -gri EX_OK=0 EX_FAIL=1 EX_WARN=10 EX_SKIP=20 EX_USAGE=64 EX_DATAERR=65 \
  EX_UNAVAILABLE=69 EX_SOFTWARE=70 EX_CANTCREAT=73 EX_TEMPFAIL=75 EX_CONFIG=78

# -----------------------------------------------------------------------------
# Module system.
#
# core::import json log ...   sources lib/<name>.sh exactly once per process.
#
# A subtle trap: `source` executed INSIDE a function runs the sourced file in
# that function's scope, so a plain `declare -A FOO=()` at the top of a module
# would create a variable local to core::import that vanishes on return.
# That is why every module declares its globals with `declare -g`.
# The module is marked as loaded *before* sourcing it, which makes circular
# imports harmless instead of infinitely recursive.
# -----------------------------------------------------------------------------
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

# core::die MESSAGE [EXIT_CODE] - log an error and terminate the process.
# Uses the structured logger once lib/log.sh is loaded, plain stderr before.
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

# -----------------------------------------------------------------------------
# ERR trap: print a stack trace for unexpected failures.
#
# The trap string passes "$?" and "$BASH_COMMAND" as arguments so that both
# are captured at the exact moment of failure, before any other command can
# change them. Inside the handler FUNCNAME[0] is the handler itself, so frame
# i (i >= 1) is: function FUNCNAME[i], defined in BASH_SOURCE[i], currently at
# line BASH_LINENO[i-1]. Paths are shown relative to SLUICE_HOME for brevity.
# -----------------------------------------------------------------------------
core::_on_err() {
  local -i rc=$1 i
  local cmd=$2
  printf '%s: unexpected failure (exit %d) while running: %s\n' "${0##*/}" "$rc" "$cmd" >&2
  for (( i = 1; i < ${#FUNCNAME[@]}; i++ )); do
    printf '    at %-30s %s:%s\n' "${FUNCNAME[i]}" "${BASH_SOURCE[i]#"$SLUICE_HOME/"}" "${BASH_LINENO[i - 1]}" >&2
  done
}
trap 'core::_on_err "$?" "$BASH_COMMAND"' ERR

# -----------------------------------------------------------------------------
# Cleanup stack, in the spirit of Go's `defer`.
#
#   core::on_exit rm -rf -- "$tmpdir"
#
# Each hook is serialised with printf '%q' - the one blessed way to turn an
# argv into a string that `eval` will split back into EXACTLY the same argv,
# whatever spaces, quotes or globs the arguments contain.
#
# Hooks remember the PID ($BASHPID, which - unlike $$ - is correct inside
# subshells) that registered them, and only that process runs them. Without
# this, a background subshell that inherited the array could delete its
# parent's temporary directory while the parent is still using it.
# Hooks run in reverse registration order (LIFO), like destructors.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Signals. On INT/TERM/HUP we run the cleanup stack, restore the default
# disposition and re-send the signal to ourselves. Simply calling `exit 130`
# would hide from our parent that we died *because of* a signal - a shell loop
# running us would then keep iterating after the user pressed Ctrl-C. Dying
# by the same signal is the cooperative behaviour (see "Proper handling of
# SIGINT/SIGQUIT", Martin Cracauer).
# -----------------------------------------------------------------------------
core::_on_signal() {
  local sig=$1
  trap - EXIT
  core::_run_exit_hooks
  trap - "$sig"
  kill -s "$sig" "$BASHPID"
}

# core::install_traps - (re)install the EXIT/signal traps. Subshells start
# with traps reset, so code that runs in `( ... )` or `&` and wants its
# cleanup hooks honoured calls this first.
core::install_traps() {
  trap core::_run_exit_hooks EXIT
  trap 'core::_on_signal INT' INT
  trap 'core::_on_signal TERM' TERM
  trap 'core::_on_signal HUP' HUP
}
core::install_traps

# -----------------------------------------------------------------------------
# Small helpers. None of them forks a process.
# -----------------------------------------------------------------------------

# core::have CMD - true if CMD is an executable, builtin or function.
core::have() {
  command -v -- "$1" >/dev/null 2>&1
}

# core::require CMD... - die with EX_UNAVAILABLE listing ALL missing commands
# (reporting one at a time makes users fix-and-retry repeatedly).
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

# core::trim STRING -> REPLY without leading/trailing whitespace.
# +([[:space:]]) is an extglob pattern: "one or more whitespace characters";
# ## and %% remove the longest matching prefix/suffix.
core::trim() {
  local s=$1
  s=${s##+([[:space:]])}
  REPLY=${s%%+([[:space:]])}
}

# core::in_list NEEDLE ITEM... - membership test with exact string equality.
# The right-hand side of == inside [[ ]] is a PATTERN unless quoted, hence
# the quotes around "$needle".
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

# core::join SEPARATOR ITEM... -> REPLY. Works with multi-character
# separators, which the `local IFS=,; "${a[*]}"` trick cannot do.
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

# core::parse_bool VALUE -> REPLY=1|0, or returns 1 for anything unrecognised.
# ${1,,} lower-cases the value (bash 4+ case-modification expansion).
core::parse_bool() {
  case ${1,,} in
    1 | true | yes | on) REPLY=1 ;;
    0 | false | no | off) REPLY=0 ;;
    *) return 1 ;;
  esac
}

# core::is_true VALUE - predicate form of parse_bool; unknown values are false.
core::is_true() {
  core::parse_bool "${1-}" && (( REPLY == 1 ))
}

# core::parse_duration_ms VALUE -> REPLY in milliseconds.
# Accepts "250ms", "30", "30s", "5m", "2h". A bare number means seconds.
# `10#` forces base 10: without it bash reads "08" as an (invalid) octal
# number - a classic bug whenever numbers come from user input or dates.
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

# core::to_centi DECIMAL -> REPLY = value * 100 as an integer ("2.5" -> 250).
# Bash arithmetic is integer-only; scaling to hundredths lets us compare
# thresholds such as "1.5 percent" exactly, without forking bc or awk.
core::to_centi() {
  [[ $1 =~ ^([0-9]+)(\.([0-9]+))?$ ]] || return 1
  local frac=${BASH_REMATCH[3]}00
  REPLY=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2} ))
}

# -----------------------------------------------------------------------------
# core::interpolate TEMPLATE -> REPLY
#
# Expands ${NAME} and ${NAME:-default} using the current environment WITHOUT
# eval, so a value like '$(rm -rf ~)' in a config file stays inert text.
# On failure (unset variable and no default) it returns 1 with the offending
# variable name in REPLY.
#
# How it works: [[ =~ ]] finds the leftmost ${...}; BASH_REMATCH[0] is the
# whole match. ${rest%%"$match"*} is everything before it (the quotes make
# the match literal instead of a pattern), ${rest#*"$match"} everything after.
# ${!name} is indirect expansion: the value of the variable whose NAME is in
# $name, and ${!name+set} expands to "set" only if that variable exists.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# core::atomic_write PATH [CONTENT]
#
# Writes CONTENT (or stdin when omitted) to a temporary file in the SAME
# directory, then renames it over PATH. rename(2) within one filesystem is
# atomic: concurrent readers see either the complete old file or the complete
# new one, never a half-written file. That property is what lets the
# scheduler read job status files while jobs are still finishing.
# -----------------------------------------------------------------------------
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

# core::mktemp_dir [LABEL] -> REPLY: a private temp directory that is removed
# automatically when the current process exits.
core::mktemp_dir() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sluice-${1:-tmp}.XXXXXXXX") \
    || core::die "cannot create a temporary directory" "$EX_CANTCREAT"
  core::on_exit rm -rf -- "$dir"
  REPLY=$dir
}

# -----------------------------------------------------------------------------
# core::can_symlink DIR - does the filesystem at DIR support real symlinks?
#
# Needed because Git Bash/MSYS2 emulates `ln -s` by COPYING the target unless
# native symlinks are enabled. That is why the probe links to a tiny empty
# file: probing with `ln -s . link` would deep-copy the whole directory.
# -----------------------------------------------------------------------------
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

# core::is_secret_name NAME - heuristic used to redact values in snapshots.
# ${1^^} upper-cases the name so "webhook_url" and "WEBHOOK_URL" both match.
core::is_secret_name() {
  [[ ${1^^} =~ (TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|WEBHOOK|API_?KEY|PRIVATE) ]]
}
