#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init fs-audit

main() {
  local -a roots=() existing=() allow=()
  local r
  local -i max=${SLUICE_FS_MAX_REPORT:-25}

  stage::split_list roots "${SLUICE_FS_AUDIT_PATHS:-}"
  (( ${#roots[@]} )) || stage::skip "SLUICE_FS_AUDIT_PATHS is not set"
  for r in "${roots[@]}"; do
    if [[ -d $r ]]; then
      existing+=("$r")
    else
      stage::finding low FS-PATH "audit path does not exist: $r"
    fi
  done
  (( ${#existing[@]} )) || stage::skip "none of the audit paths exist"
  stage::split_list allow "${SLUICE_FS_SUID_ALLOWLIST:-/usr/bin/sudo /usr/bin/su /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/newgrp /usr/bin/gpasswd /usr/bin/mount /usr/bin/umount /usr/bin/pkexec /usr/bin/fusermount3 /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper}"
  stage::metric roots "${#existing[@]}"

  fs::scan WORLD-WRITABLE high "world-writable file" -type f -perm -0002
  fs::scan WORLD-WRITABLE-DIR medium "world-writable directory without the sticky bit" \
    -type d -perm -0002 ! -perm -1000
  fs::scan SETID medium "setuid/setgid file" -type f \( -perm -4000 -o -perm -2000 \)
  fs::scan KEY-EXPOSED high "private key readable by group or others" -type f \
    \( -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' -o -name '*.key' \) \
    \( -perm -0040 -o -perm -0004 \)
  fs::scan ENV-EXPOSED medium "dotenv secrets file readable by everyone" -type f \
    \( -name '.env' -o \( -name '.env.*' ! -name '*.example' ! -name '*.sample' \) \) -perm -0004
  case $OSTYPE in
    cygwin* | msys*) log::info "ownership check skipped: Windows accounts are not POSIX users" ;;
    *) fs::scan UNOWNED low "file whose owner or group no longer exists" \( -nouser -o -nogroup \) ;;
  esac
}

fs::scan() {
  local code=$1 sev=$2 label=$3 path
  local -i n=0
  shift 3
  while IFS= read -r -d '' path; do
    if [[ $code == SETID ]] && core::in_list "$path" "${allow[@]}"; then
      continue
    fi
    (( ++n ))
    if (( n <= max )); then
      stage::finding "$sev" "FS-$code" "$label: $path"
    fi
  done < <(find "${existing[@]}" -xdev "$@" -print0 2>/dev/null)
  if (( n > max )); then
    stage::finding "$sev" "FS-$code" "... and $(( n - max )) more (raise SLUICE_FS_MAX_REPORT to list them)"
  fi
  local metric=${code,,}
  stage::metric "count_${metric//-/_}" "$n"
}

main "$@"
stage::finish
