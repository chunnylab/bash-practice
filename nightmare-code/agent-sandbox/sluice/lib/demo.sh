#!/usr/bin/env bash

core::import log time

demo::seed() {
  local ws=$1
  local -i reseed=${2:-0}
  local -a entries=()
  if [[ -e $ws/.seeded ]]; then
    if (( reseed == 0 )); then
      log::info "reusing demo workspace (refreshing yesterday's access log)" path="$ws"
      demo::access_logs "$ws/logs"
      return 0
    fi
    rm -rf -- "${ws:?}"
  elif [[ -d $ws ]]; then
    entries=("$ws"/* "$ws"/.[!.]* "$ws"/..?*)
    if (( ${#entries[@]} )); then
      core::die "refusing to seed $ws: it is not empty and was not created by 'sluice demo'" "$EX_CANTCREAT"
    fi
  fi

  mkdir -p -- "$ws"/{logs,ssh/sshd_config.d,srv/app/{public,uploads,bin,config},data/{db,media},backups,certs,www}
  demo::access_logs "$ws/logs"
  demo::sshd "$ws/ssh"
  demo::app "$ws/srv/app"
  demo::data "$ws/data"
  demo::history "$ws/backups"
  demo::certs "$ws/certs"
  time::iso_utc
  printf 'seeded=%s\nby=sluice %s\n' "$REPLY" "$SLUICE_VERSION" > "$ws/.seeded"
  log::info "demo workspace seeded" path="$ws"
}

demo::_clf_day() {
  local stamp d m y
  TZ=UTC printf -v stamp '%(%d %m %Y)T' "$1"
  read -r d m y <<< "$stamp"
  REPLY=$d/${TIME_MONTH_ABBR[10#$m - 1]}/$y
}

demo::access_logs() {
  local dir=$1 yesterday before
  demo::_clf_day $(( EPOCHSECONDS - 86400 ))
  yesterday=$REPLY
  demo::_clf_day $(( EPOCHSECONDS - 2 * 86400 ))
  before=$REPLY
  LC_ALL=C awk -v day="$yesterday" -v n=4000 -v seed=42 -v incident=1 \
    -f "$SLUICE_LIB/awk/gen-access-log.awk" > "$dir/access.log"
  LC_ALL=C awk -v day="$before" -v n=2500 -v seed=7 -v incident=0 \
    -f "$SLUICE_LIB/awk/gen-access-log.awk" | gzip -c > "$dir/access.log.1.gz"
}

demo::sshd() {
  local dir=$1
  cat > "$dir/sshd_config" <<'SSHD'
Include sshd_config.d/*.conf

Port 22
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding yes
MaxAuthTries 6
LoginGraceTime 2m
ClientAliveInterval 300
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-cbc
Subsystem sftp /usr/lib/openssh/sftp-server

Match User deploy
    PasswordAuthentication yes
    PermitRootLogin yes
SSHD
  printf 'PasswordAuthentication yes\n' > "$dir/sshd_config.d/50-cloud-init.conf"
}

demo::app() {
  local app=$1
  printf '<!doctype html><title>demo</title><h1>It works</h1>\n' > "$app/public/index.html"
  printf 'not really a png\n' > "$app/uploads/avatar-1.png"
  printf '%s\n' '#!/bin/sh' 'echo "nightly report helper"' > "$app/bin/report-helper"
  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'ZGVtbyBrZXkgLSBub3QgYSByZWFsIHNlY3JldA==' \
    '-----END OPENSSH PRIVATE KEY-----' > "$app/config/id_ed25519"
  printf 'DB_PASSWORD=demo-not-a-real-secret\n' > "$app/config/.env"
  printf '[app]\nlisten = 127.0.0.1:8080\n' > "$app/config/app.ini"
  chmod 0777 "$app/uploads" 2>/dev/null || :
  chmod 0666 "$app/uploads/avatar-1.png" 2>/dev/null || :
  chmod 4755 "$app/bin/report-helper" 2>/dev/null || :
  chmod 0644 "$app/config/id_ed25519" "$app/config/.env" 2>/dev/null || :
}

demo::data() {
  local dir=$1
  local -i i
  {
    printf 'id,customer,total_cents,created_at\n'
    for (( i = 1; i <= 200; i++ )); do
      printf '%d,customer-%03d,%d,2026-10-%02d\n' "$i" $(( i % 37 )) $(( i * 7919 % 50000 )) $(( i % 28 + 1 ))
    done
  } > "$dir/db/orders.csv"
  {
    printf 'id,email\n'
    for (( i = 1; i <= 37; i++ )); do
      printf '%d,user%02d@example.com\n' "$i" "$i"
    done
  } > "$dir/db/customers.csv"
  printf 'payload line %d\n' {1..64} > "$dir/media/blob.dat"
  printf 'file names with spaces must survive backup and restore\n' > "$dir/media/release notes.txt"
}

demo::history() {
  local dir=$1
  local -i d
  for (( d = 1; d <= 150; d += (d < 14 ? 1 : 4) )); do
    time::utc_stamp $(( EPOCHSECONDS - d * 86400 - 3600 ))
    : > "$dir/backup-$REPLY.tar.gz"
  done
}

demo::certs() {
  local dir=$1 spec name days
  if ! core::have openssl; then
    log::warn "openssl not found: the demo has no certificates to check"
    return 0
  fi
  (
    cd -- "$dir" || exit
    for spec in healthy.demo.example:400 expiring.demo.example:20 critical.demo.example:3; do
      name=${spec%%:*}
      days=${spec##*:}
      if ! MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$name.key" -out "$name.pem" -days "$days" -subj "/CN=$name" > /dev/null 2>&1; then
        log::warn "could not create the demo certificate $name"
      fi
    done
  )
}
