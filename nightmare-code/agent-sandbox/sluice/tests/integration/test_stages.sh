#!/usr/bin/env bash

_access_log() {
  t::write "$1" <<'LOG'
10.0.0.1 - - [05/Nov/2026:10:00:01 +0000] "GET / HTTP/1.1" 200 512 "-" "curl/8.0" 0.010
10.0.0.1 - - [05/Nov/2026:10:00:02 +0000] "GET /api/orders?id=1 HTTP/1.1" 200 1024 "-" "curl/8.0" 0.020
10.0.0.2 - - [05/Nov/2026:10:00:03 +0000] "GET /api/orders?id=2 HTTP/1.1" 200 1024 "-" "Mozilla/5.0 (X11; Linux)" 0.030
10.0.0.2 - - [05/Nov/2026:10:00:04 +0000] "POST /login HTTP/1.1" 302 0 "-" "Mozilla/5.0 (X11; Linux)" 0.040
10.0.0.3 - - [05/Nov/2026:10:01:05 +0000] "GET /missing HTTP/1.1" 404 128 "-" "bot" 0.005
10.0.0.1 - - [05/Nov/2026:10:01:06 +0000] "GET /api/orders HTTP/1.1" 500 64 "-" "curl/8.0" 1.500
10.0.0.1 - - [05/Nov/2026:10:01:07 +0000] "GET /api/orders HTTP/1.1" 502 64 "-" "curl/8.0" 2.000
10.0.0.4 - - [05/Nov/2026:10:01:08 +0000] "GET / HTTP/1.1" 200 512 "-" "curl/8.0" 0.015
this line is garbage
10.0.0.1 - - [05/Nov/2026:10:02:09 +0000] "GET /static/app.js HTTP/1.1" 304 0 "-" "curl/8.0" -
LOG
}

test_log_insights_computes_exact_metrics_and_findings() {
  _access_log logs/access.log
  export SLUICE_ACCESS_LOGS=$TEST_TMP/logs/access.log
  t::stage log-insights
  assert::eq 10 "$T_RC" "stage should warn"
  local spec
  for spec in requests=9 malformed_lines=1 bytes_total=3328 status_2xx=4 status_3xx=2 status_4xx=1 \
    status_5xx=2 unique_clients=4 error_rate_5xx_bp=2222 latency_p50_ms=20 latency_p90_ms=2000 \
    latency_p99_ms=2000 latency_avg_ms=453 latency_max_ms=2000 latency_samples=8 peak_rpm=4 \
    peak_minute=05/Nov/2026:10:00; do
    t::metric log-insights "${spec%%=*}"
    assert::eq "${spec#*=}" "$REPLY" "${spec%%=*}"
  done
  assert::eq $'paths\t1\t4\t/api/orders' "$(sed -n 1p artifacts/log-insights/top.tsv)"
  assert::eq $'paths\t3\t1\t/login' "$(sed -n 3p artifacts/log-insights/top.tsv)"
  t::findings log-insights
  assert::eq $'high LOG-5XX\ninfo LOG-HOTSPOT\nlow LOG-PARSE\nmedium LOG-CLIENT\nmedium LOG-P99' "$REPLY"
  assert::json artifacts/log-insights/insights.json
  assert::json artifacts/log-insights/summary.json
}

test_log_insights_reads_gzip_rotations_and_is_awk_portable() {
  _access_log logs/access.log
  gzip -c logs/access.log > logs/access.log.1.gz
  export SLUICE_ACCESS_LOGS="$TEST_TMP/logs/access.log*"
  t::stage log-insights
  t::metric log-insights requests
  assert::eq 18 "$REPLY" "plain + gzip rotation"
  if core::have mawk; then
    cp artifacts/log-insights/raw.tsv gawk.tsv
    SLUICE_AWK=mawk t::stage log-insights
    assert::eq "$(LC_ALL=C sort gawk.tsv)" "$(LC_ALL=C sort artifacts/log-insights/raw.tsv)" "mawk output differs"
  fi
}

test_log_insights_skips_without_logs() {
  export SLUICE_ACCESS_LOGS="$TEST_TMP/nothing/*.log"
  t::stage log-insights
  assert::eq 20 "$T_RC"
}

test_ssh_audit_follows_include_first_match_and_match_rules() {
  t::write ssh/sshd_config <<'SSHD'
#PermitRootLogin yes
Include conf.d/*.conf
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries=3
LoginGraceTime 1m30s
ClientAliveInterval 300
AllowAgentForwarding no
KbdInteractiveAuthentication no

Match User legacy
    PermitRootLogin yes
    X11Forwarding yes
SSHD
  printf 'PasswordAuthentication yes\n' | t::write ssh/conf.d/10-first.conf
  printf 'PasswordAuthentication no\nX11Forwarding no\n' | t::write ssh/conf.d/20-second.conf
  export SLUICE_SSHD_CONFIG=$TEST_TMP/ssh/sshd_config
  t::stage ssh-audit
  assert::eq 10 "$T_RC"
  t::findings ssh-audit
  assert::eq $'high SSH-002\nlow SSH-007' "$REPLY"
  assert::contains "$(< artifacts/ssh-audit/findings.tsv)" "conf.d/10-first.conf:1"
  t::metric ssh-audit files_parsed
  assert::eq 3 "$REPLY"
  t::metric ssh-audit rules_passed
  assert::eq 11 "$REPLY"
  t::metric ssh-audit match_blocks
  assert::eq 1 "$REPLY"
}

test_ssh_audit_flags_defaults_and_weak_algorithms() {
  printf '%s\n' 'PermitRootLogin prohibit-password' 'X11Forwarding yes' \
    'Ciphers aes128-ctr,aes256-cbc' 'MACs hmac-sha2-256,hmac-md5' | t::write sshd_config
  export SLUICE_SSHD_CONFIG=$TEST_TMP/sshd_config
  t::stage ssh-audit
  t::findings ssh-audit
  assert::eq $'high SSH-002\nlow SSH-001\nlow SSH-005\nlow SSH-007\nlow SSH-008\nlow SSH-011\nmedium SSH-004\nmedium SSH-006\nmedium SSH-012\nmedium SSH-013' "$REPLY"
}

test_fs_audit_flags_risky_permissions() {
  test::require_posix_fs
  mkdir -p srv/uploads srv/sticky srv/bin srv/keys
  : > srv/uploads/ww.txt
  : > srv/bin/helper
  : > srv/keys/id_ed25519
  : > srv/keys/id_ed25519.pub
  : > srv/keys/tls.key
  : > srv/.env
  : > srv/.env.example
  chmod 0666 srv/uploads/ww.txt
  chmod 0777 srv/uploads
  chmod 1777 srv/sticky
  chmod 4755 srv/bin/helper
  chmod 0644 srv/keys/id_ed25519 srv/keys/id_ed25519.pub srv/.env srv/.env.example
  chmod 0600 srv/keys/tls.key
  export SLUICE_FS_AUDIT_PATHS=$TEST_TMP/srv
  t::stage fs-audit
  assert::eq 10 "$T_RC"
  local spec
  for spec in world_writable=1 world_writable_dir=1 setid=1 key_exposed=1 env_exposed=1; do
    t::metric fs-audit "count_${spec%%=*}"
    assert::eq "${spec#*=}" "$REPLY" "${spec%%=*}"
  done
  export SLUICE_FS_SUID_ALLOWLIST=$TEST_TMP/srv/bin/helper
  t::stage fs-audit
  t::metric fs-audit count_setid
  assert::eq 0 "$REPLY" "allowlisted setuid file"
}

test_fs_audit_caps_the_number_of_listed_findings() {
  test::require_posix_fs
  local -i i
  mkdir -p many
  for (( i = 0; i < 7; i++ )); do
    : > "many/f$i"
    chmod 0666 "many/f$i"
  done
  export SLUICE_FS_AUDIT_PATHS=$TEST_TMP/many SLUICE_FS_MAX_REPORT=3
  t::stage fs-audit
  t::metric fs-audit count_world_writable
  assert::eq 7 "$REPLY"
  assert::contains "$(< artifacts/fs-audit/findings.tsv)" "... and 4 more"
}

test_cert_expiry_classifies_by_remaining_days() {
  test::require_cmd openssl
  mkdir -p certs
  t::cert healthy 400 certs
  t::cert expiring 20 certs
  t::cert critical 3 certs
  cat certs/healthy.pem certs/critical.pem > certs/bundle.pem
  export SLUICE_CERT_PATHS="$TEST_TMP/certs/*.pem"
  t::stage cert-expiry
  assert::eq 10 "$T_RC"
  t::metric cert-expiry certificates_checked
  assert::eq 5 "$REPLY" "4 files, one of them a 2-certificate bundle"
  t::findings cert-expiry
  assert::eq $'high CERT-CRITICAL\nhigh CERT-CRITICAL\nmedium CERT-WARNING' "$REPLY"
  t::metric cert-expiry soonest_expiry_days
  assert::match "$REPLY" '^[23]$'
}

test_cert_expiry_checks_a_live_tls_endpoint() {
  test::require_cmd openssl timeout
  [[ $OSTYPE == linux* ]] || test::skip "needs a POSIX openssl to run a local TLS server"
  local -i port=$(( 20000 + SRANDOM % 20000 )) server
  mkdir -p certs
  t::cert live 15 certs
  openssl s_server -quiet -accept "127.0.0.1:$port" -cert certs/live.pem -key certs/live.key > /dev/null 2>&1 &
  server=$!
  core::on_exit kill "$server"
  t::wait_for 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2> /dev/null || test::skip "local TLS server did not start"
  export SLUICE_CERT_ENDPOINTS=127.0.0.1:$port SLUICE_CERT_PATHS=
  t::stage cert-expiry
  t::metric cert-expiry certificates_checked
  assert::eq 1 "$REPLY"
  t::findings cert-expiry
  assert::eq 'medium CERT-WARNING' "$REPLY"
}

_backup_sources() {
  mkdir -p data/sub conf
  printf 'hello\n' > data/a.txt
  printf 'spaces survive\n' > "data/sub/with space.txt"
  printf 'k=v\n' > conf/app.ini
  export SLUICE_BACKUP_SOURCES="$TEST_TMP/data $TEST_TMP/conf" SLUICE_BACKUP_DIR=$TEST_TMP/backups
}

test_backup_archives_verifies_and_applies_gfs_retention() {
  _backup_sources
  mkdir -p backups
  local stamp
  for stamp in 20250310T020000Z 20250309T020000Z 20250309T010000Z 20250308T020000Z \
    20250303T020000Z 20250220T020000Z 20250115T020000Z; do
    : > "backups/backup-$stamp.tar.gz"
  done
  : > backups/unrelated-file.tar.gz
  export SLUICE_BACKUP_KEEP_DAILY=3 SLUICE_BACKUP_KEEP_WEEKLY=2 SLUICE_BACKUP_KEEP_MONTHLY=2
  t::stage backup
  assert::eq 0 "$T_RC" "backup stage"
  t::metric backup retained
  assert::eq 3 "$REPLY"
  t::metric backup pruned
  assert::eq 5 "$REPLY"
  t::metric backup files
  assert::eq 3 "$REPLY"
  assert::file backups/backup-20250310T020000Z.tar.gz
  assert::file backups/backup-20250309T020000Z.tar.gz
  assert::no_file backups/backup-20250309T010000Z.tar.gz
  assert::no_file backups/backup-20250115T020000Z.tar.gz
  assert::file backups/unrelated-file.tar.gz
  t::metric backup archive
  local archive=$REPLY
  assert::contains "$(tar -tzf "$archive")" "data/sub/with space.txt"
  assert::contains "$(tar -tzf "$archive")" "MANIFEST.sha256"

  t::stage backup-verify
  assert::eq 0 "$T_RC" "verification of a good archive"
  t::metric backup-verify files_verified
  assert::eq 3 "$REPLY"
}

test_backup_verify_detects_a_corrupted_archive() {
  _backup_sources
  t::stage backup
  t::metric backup archive
  local archive=$REPLY
  printf 'garbage' >> "$archive"
  t::stage backup-verify
  assert::eq 1 "$T_RC"
  assert::contains "$(< artifacts/backup-verify/findings.tsv)" "BKV-CHECKSUM"
}

test_backup_verify_detects_content_that_differs_from_the_manifest() {
  _backup_sources
  t::stage backup
  t::metric backup archive
  local archive=$REPLY hash
  mkdir unpacked
  tar -xzf "$archive" -C unpacked
  printf 'tampered\n' > unpacked/data/a.txt
  tar -czf "$archive" -C unpacked .
  read -r hash _ < <(sha256sum < "$archive")
  printf '%s  %s\n' "$hash" "${archive##*/}" > "$archive.sha256"
  t::stage backup-verify
  assert::eq 1 "$T_RC"
  assert::contains "$(< artifacts/backup-verify/findings.tsv)" "1 of 3 restored file(s) do not match the manifest"
}

test_backup_dry_run_changes_nothing() {
  _backup_sources
  mkdir -p backups
  : > backups/backup-20200101T000000Z.tar.gz
  export SLUICE_DRY_RUN=1 SLUICE_BACKUP_KEEP_DAILY=0 SLUICE_BACKUP_KEEP_WEEKLY=0 SLUICE_BACKUP_KEEP_MONTHLY=0
  t::stage backup
  assert::eq 0 "$T_RC"
  local -a archives=(backups/*.tar.gz)
  assert::eq 1 "${#archives[@]}" "no archive written, nothing pruned"
  assert::contains "$(< artifacts/backup/retention.tsv)" $'backup-20200101T000000Z.tar.gz\tprune'
}

test_backup_refuses_colliding_source_names() {
  mkdir -p one/app two/app
  export SLUICE_BACKUP_SOURCES="$TEST_TMP/one/app $TEST_TMP/two/app" SLUICE_BACKUP_DIR=$TEST_TMP/backups
  t::stage backup
  assert::eq 1 "$T_RC"
  assert::contains "$T_OUT" "share the name 'app'"
}

_report_for() {
  mkdir -p artifacts/report
  printf '<html><body data-run-id="%s">report %s</body></html>\n' "$1" "$1" > artifacts/report/index.html
  printf '# report %s\n' "$1" > artifacts/report/report.md
  printf '{"run_id":"%s"}\n' "$1" > artifacts/report/report.json
  export SLUICE_RUN_ID=$1
}

test_publish_switches_atomically_rolls_back_and_prunes() {
  test::require_symlinks
  export SLUICE_PUBLISH_ROOT=$TEST_TMP/www SLUICE_PUBLISH_KEEP=2
  local id
  for id in r1 r2; do
    _report_for "$id"
    t::stage publish
    assert::eq 0 "$T_RC" "publish $id"
  done
  assert::eq releases/r2 "$(readlink www/current)"
  assert::contains "$(< www/current/index.html)" 'data-run-id="r2"'

  printf '%s\n' '[[ $1 != */current ]]' > failing-check.sh
  _report_for r3
  SLUICE_PUBLISH_HEALTHCHECK="$BASH $TEST_TMP/failing-check.sh" t::stage publish
  assert::eq 1 "$T_RC" "post-switch health check failure"
  assert::eq releases/r2 "$(readlink www/current)" "rolled back"
  assert::no_file www/releases/r3

  for id in r4 r5; do
    _report_for "$id"
    t::stage publish
  done
  local -a rels=(www/releases/*)
  assert::eq 'www/releases/r4 www/releases/r5' "${rels[*]}" "keep the newest two"
}

test_publish_skips_without_a_report() {
  export SLUICE_PUBLISH_ROOT=$TEST_TMP/www
  t::stage publish
  assert::eq 20 "$T_RC"
}

_report_metrics() {
  mkdir -p artifacts/report
  printf '%s\t%s\n' overall warn jobs_reported 8 findings_total 2 findings_critical 0 \
    findings_high 1 findings_medium 1 report_md /tmp/report.md > artifacts/report/metrics.tsv
  printf '%s\t%s\t%s\t%s\n' high ssh-audit SSH-002 'PasswordAuthentication is "yes"' \
    medium log-insights LOG-P99 'p99 latency 1900 ms' > artifacts/report/findings_all.tsv
}

test_notify_writes_the_payload_and_skips_without_a_webhook() {
  _report_metrics
  t::stage notify
  assert::eq 20 "$T_RC"
  assert::json artifacts/notify/payload.json
  assert::contains "$(< artifacts/notify/payload.json)" '"type":"header"'
  assert::contains "$(< artifacts/notify/payload.json)" 'PasswordAuthentication is \"yes\"'
}

test_notify_delivers_with_retries_and_redacts_the_url() {
  _report_metrics
  mkdir -p stub
  t::write stub/curl <<'STUB'
#!/usr/bin/env bash
out=/dev/null
while (( $# )); do
  case $1 in
    -o) out=$2; shift ;;
  esac
  shift
done
n=$(( $(cat "$TEST_TMP/curl.calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$TEST_TMP/curl.calls"
cat > "$TEST_TMP/curl.body"
echo ok > "$out"
if (( n == 1 )); then
  printf '503'
else
  printf '200'
fi
STUB
  chmod +x stub/curl
  export PATH=$TEST_TMP/stub:$PATH SLUICE_WEBHOOK_URL=https://hooks.example.test/services/T000/B000/SECRETPART
  t::stage notify
  assert::eq 0 "$T_RC" "delivered on the second attempt"
  assert::eq 2 "$(< curl.calls)"
  assert::eq "$(< artifacts/notify/payload.json)" "$(< curl.body)"
  assert::not_contains "$T_OUT" SECRETPART "webhook secret leaked into the log"
  t::metric notify http_status
  assert::eq 200 "$REPLY"
}

test_notify_policy_can_suppress_messages() {
  _report_metrics
  export SLUICE_NOTIFY_ON=failure
  t::stage notify
  assert::eq 20 "$T_RC"
  assert::contains "$T_OUT" "is not a failure"
}

test_preflight_and_host_facts_succeed_on_this_machine() {
  export SLUICE_WORKSPACE=$TEST_TMP/ws SLUICE_MIN_FREE_MB=1
  t::stage preflight
  assert::match "$T_RC" '^(0|10)$' "preflight"
  t::stage host-facts
  assert::match "$T_RC" '^(0|10)$' "host-facts"
  t::metric host-facts cpus
  assert::match "$REPLY" '^[1-9][0-9]*$'
  assert::json artifacts/host-facts/facts.json
}

test_preflight_fails_on_an_unwritable_directory() {
  test::require_posix_fs
  (( EUID != 0 )) || test::skip "root can write everywhere"
  mkdir -p locked
  chmod 0555 locked
  export SLUICE_BACKUP_DIR=$TEST_TMP/locked/backups
  t::stage preflight
  chmod 0755 locked
  assert::eq 1 "$T_RC"
  assert::contains "$T_OUT" "backup_dir is not writable"
}
