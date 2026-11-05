#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init preflight

main() {
  local -a required=(awk sed grep sort tar gzip sha256sum find df mktemp wc)
  local -a optional=(openssl curl flock timeout)
  local -a missing=()
  local cmd label dir
  local -i min_mb=${SLUICE_MIN_FREE_MB:-256} free_mb

  for cmd in "${required[@]}"; do
    core::have "$cmd" || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    stage::fail "missing required command(s): ${missing[*]}" PRE-001
  fi
  stage::metric required_commands "${#required[@]}"

  for cmd in "${optional[@]}"; do
    if core::have "$cmd"; then
      stage::metric "has_$cmd" true
    else
      stage::metric "has_$cmd" false
      stage::finding low PRE-002 "optional command '$cmd' not found; features that need it will be skipped"
    fi
  done

  stage::metric bash_version "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
  stage::metric platform "$OSTYPE"
  stage::metric user "${USER:-${LOGNAME:-unknown}}"
  stage::metric euid "$EUID"
  if (( EUID == 0 )); then
    stage::finding info PRE-003 "running as root; prefer a dedicated service account"
  fi

  local -A dirs=(
    [workspace]=${SLUICE_WORKSPACE:-}
    [backup_dir]=${SLUICE_BACKUP_DIR:-}
    [publish_root]=${SLUICE_PUBLISH_ROOT:-}
    [run_dir]=${SLUICE_RUN_DIR:-}
  )
  for label in workspace backup_dir publish_root run_dir; do
    dir=${dirs[$label]}
    [[ -n $dir ]] || continue
    if ! mkdir -p -- "$dir" 2>/dev/null || [[ ! -w $dir ]]; then
      stage::fail "$label is not writable: $dir" PRE-004
    fi
    if ! preflight::free_mb "$dir"; then
      stage::finding low PRE-005 "cannot determine free space for $label ($dir)"
      continue
    fi
    free_mb=$REPLY
    stage::metric "free_mb_$label" "$free_mb"
    if (( free_mb < min_mb )); then
      stage::finding high PRE-006 "only $free_mb MiB free for $label ($dir); at least $min_mb MiB required"
    fi
  done
}

preflight::free_mb() {
  local _ avail=""
  { read -r _ && read -r _ _ _ avail _; } < <(df -Pk -- "$1" 2>/dev/null) || return 1
  [[ $avail =~ ^[0-9]+$ ]] || return 1
  REPLY=$(( avail / 1024 ))
}

main "$@"
stage::finish
