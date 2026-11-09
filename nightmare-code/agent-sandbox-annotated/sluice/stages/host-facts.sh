#!/usr/bin/env bash
# =============================================================================
# stages/host-facts.sh - inventory of the host (a tiny `facter`/`ohai`)
# =============================================================================
#
# Reads /proc and a few tools directly - no `free | awk`, no `uptime | sed`
# chains - and writes facts.json plus threshold findings:
#
#   memory used  >= SLUICE_MEM_WARN_PCT  (80) medium, >= SLUICE_MEM_CRIT_PCT  (90) high
#   disk used    >= SLUICE_DISK_WARN_PCT (80) medium, >= SLUICE_DISK_CRIT_PCT (90) high
#   load average per CPU >= SLUICE_LOAD_WARN_PER_CPU (2.0)              medium
#   uptime       >= SLUICE_UPTIME_WARN_DAYS (365)                       low
#
# Everything degrades gracefully: on a system without /proc (macOS) or with a
# partial emulation of it (Git Bash), missing facts are recorded as unknown.
# =============================================================================

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init host-facts

main() {
  local os="" kernel_name="" kernel="" arch="" k v line load1=0.00 load5=0.00 load15=0.00 ips=""
  local -i cpus=0 up_s=0 mem_total=0 mem_avail=0 mem_free=0 buffers=0 cached=0 mem_used_pct=0
  local -i mem_warn=${SLUICE_MEM_WARN_PCT:-80} mem_crit=${SLUICE_MEM_CRIT_PCT:-90}
  local -i disk_warn=${SLUICE_DISK_WARN_PCT:-80} disk_crit=${SLUICE_DISK_CRIT_PCT:-90}
  local -i uptime_warn=${SLUICE_UPTIME_WARN_DAYS:-365} load_c=0 limit_c

  # /etc/os-release is KEY=value with optional quotes. It is parsed, never
  # sourced: sourcing a system file just to read one value is how scripts
  # end up executing whatever someone put there.
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r k v; do
      if [[ $k == PRETTY_NAME ]]; then
        v=${v#\"}
        os=${v%\"}
        break
      fi
    done < /etc/os-release
  fi
  # One `uname` process for three facts: `< <(cmd)` feeds the command's
  # output to `read` in the CURRENT shell (a `uname | read` pipeline would
  # assign the variables in a subshell and lose them).
  read -r kernel_name kernel arch < <(uname -srm)
  [[ -n $os ]] || os=$kernel_name

  # nproc honours CPU affinity and cgroup limits (what a container is really
  # allowed to use); counting "processor" lines in /proc/cpuinfo is the
  # fallback. A broken nproc yields 0, and then the fallback applies.
  if core::have nproc; then
    cpus=$(nproc 2>/dev/null) || cpus=0
  fi
  if (( cpus == 0 )) && [[ -r /proc/cpuinfo ]]; then
    while IFS= read -r line; do
      [[ $line != processor* ]] || (( ++cpus ))
    done < /proc/cpuinfo
  fi
  (( cpus > 0 )) || cpus=1

  # /proc/loadavg: "0.52 0.48 0.40 1/123 4567"; /proc/uptime: "12345.67 ..."
  if [[ -r /proc/loadavg ]]; then
    read -r load1 load5 load15 _ < /proc/loadavg
  fi
  if [[ -r /proc/uptime ]]; then
    read -r line _ < /proc/uptime
    up_s=${line%%.*}
  fi

  # MemAvailable (Linux >= 3.14) is the kernel's own estimate of memory that
  # can be used without swapping; older kernels and emulations lack it, so
  # we fall back to the classic free + buffers + cache approximation.
  if [[ -r /proc/meminfo ]]; then
    while read -r k v _; do
      case $k in
        MemTotal:) mem_total=$v ;;
        MemAvailable:) mem_avail=$v ;;
        MemFree:) mem_free=$v ;;
        Buffers:) buffers=$v ;;
        Cached:) cached=$v ;;
      esac
    done < /proc/meminfo
    (( mem_avail > 0 )) || mem_avail=$(( mem_free + buffers + cached ))
  fi
  if (( mem_total > 0 )); then
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  fi

  # `ip -o` prints one line per address:
  #   "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0 ..."
  # so fields 3 and 4 are the family and the address/prefix. `scope global`
  # leaves out loopback and link-local addresses.
  if core::have ip; then
    while read -r _ _ k v _; do
      [[ $k == inet || $k == inet6 ]] || continue
      ips+="${ips:+ }$v"
    done < <(ip -o addr show scope global 2>/dev/null)
  fi

  time::fmt_uptime "$up_s"
  local uptime_human=$REPLY
  stage::metric hostname "${HOSTNAME:-unknown}"
  stage::metric os "$os"
  stage::metric kernel "$kernel"
  stage::metric arch "$arch"
  stage::metric cpus "$cpus"
  stage::metric load1 "$load1"
  stage::metric load5 "$load5"
  stage::metric load15 "$load15"
  stage::metric uptime_seconds "$up_s"
  stage::metric uptime "$uptime_human"
  stage::metric mem_total_mb $(( mem_total / 1024 ))
  stage::metric mem_available_mb $(( mem_avail / 1024 ))
  stage::metric mem_used_pct "$mem_used_pct"
  stage::metric ip_addresses "${ips:-unknown}"

  if (( mem_total > 0 )); then
    if (( mem_used_pct >= mem_crit )); then
      stage::finding high HOST-MEM "memory ${mem_used_pct}% used (critical threshold ${mem_crit}%)"
    elif (( mem_used_pct >= mem_warn )); then
      stage::finding medium HOST-MEM "memory ${mem_used_pct}% used (warning threshold ${mem_warn}%)"
    fi
  fi

  # Load is a decimal: compare it in hundredths, per CPU, integer-only.
  core::to_centi "${SLUICE_LOAD_WARN_PER_CPU:-2.0}" || stage::fail "SLUICE_LOAD_WARN_PER_CPU must be a decimal number"
  limit_c=$REPLY
  if core::to_centi "$load1"; then
    load_c=$REPLY
    if (( load_c / cpus >= limit_c )); then
      stage::finding medium HOST-LOAD "1-minute load $load1 on $cpus CPU(s) is at or above ${SLUICE_LOAD_WARN_PER_CPU:-2.0} per CPU"
    fi
  fi

  if (( up_s / 86400 >= uptime_warn )); then
    stage::finding low HOST-UPTIME "up $uptime_human: the running kernel probably lacks security fixes; schedule a reboot"
  fi

  local -a disks=()
  host::disks disks
  host::write_facts "$os" "$kernel" "$arch" "$cpus" "$load1" "$load5" "$load15" "$up_s" \
    "$mem_total" "$mem_avail" "$mem_used_pct" "$ips" "${disks[@]}"
}

# host::disks OUT_ARRAY - usage of the root filesystem and of every directory
# sluice writes to. `df -P` columns: fs, size, used, avail, use%, mount. The
# mount point is read LAST so it may contain spaces. Each mount is reported
# once even when several directories live on it. The header line is skipped
# because its use% column does not end in '%'.
#
# ${VAR:+"$VAR"} expands to the quoted value when VAR is non-empty and to
# NOTHING AT ALL (not even an empty argument) otherwise - the idiom for
# optional arguments.
host::disks() {
  local -n __hd_out=$1
  local fs size used avail pct mnt
  local -A seen=()
  __hd_out=()
  while read -r fs size used avail pct mnt; do
    [[ $pct == *% ]] || continue
    [[ -z ${seen[$mnt]-} ]] || continue
    seen[$mnt]=1
    pct=${pct%\%}
    json::object "mount=$mnt" "filesystem=$fs" "size_kb:n=$size" "used_kb:n=$used" "avail_kb:n=$avail" "used_pct:n=$pct"
    __hd_out+=("$REPLY")
    stage::metric "disk_used_pct $mnt" "$pct"
    if (( pct >= disk_crit )); then
      stage::finding high HOST-DISK "filesystem $mnt is ${pct}% full (critical threshold ${disk_crit}%)"
    elif (( pct >= disk_warn )); then
      stage::finding medium HOST-DISK "filesystem $mnt is ${pct}% full (warning threshold ${disk_warn}%)"
    fi
  done < <(df -Pk -- / ${SLUICE_WORKSPACE:+"$SLUICE_WORKSPACE"} ${SLUICE_BACKUP_DIR:+"$SLUICE_BACKUP_DIR"} 2>/dev/null)
}

# host::write_facts OS KERNEL ... IPS DISK_JSON... - the twelve scalars come
# first, the disk objects (any number) after them. Beyond $9, positional
# parameters need braces: $10 would mean "$1 followed by a 0".
host::write_facts() {
  local os=$1 kernel=$2 arch=$3 cpus=$4 l1=$5 l5=$6 l15=$7 up=$8 mt=$9 ma=${10} mp=${11} ips=${12}
  shift 12
  local disks loadavg memory iplist
  local -a ip_arr=()
  read -r -a ip_arr <<< "$ips"
  json::array raw "$@"
  disks=$REPLY
  json::array a "$l1" "$l5" "$l15"
  loadavg=$REPLY
  json::object "total_kb:n=$mt" "available_kb:n=$ma" "used_pct:n=$mp"
  memory=$REPLY
  json::array s "${ip_arr[@]}"
  iplist=$REPLY
  time::iso_utc
  json::object "hostname=${HOSTNAME:-unknown}" "os=$os" "kernel=$kernel" "arch=$arch" "cpus:n=$cpus" \
    "loadavg:raw=$loadavg" "uptime_seconds:n=$up" "memory:raw=$memory" "disks:raw=$disks" \
    "ip_addresses:raw=$iplist" "bash=$BASH_VERSION" "collected_at=$REPLY"
  core::atomic_write "$STAGE_OUT/facts.json" "$REPLY"$'\n'
}

main "$@"
stage::finish
