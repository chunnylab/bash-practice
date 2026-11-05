#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init backup-verify

main() {
  local archive="" expected="" actual restore
  local -a candidates=()
  local -i total=0 failed=0

  if stage::tsv_get "${SLUICE_ARTIFACTS:-/nonexistent}/backup/metrics.tsv" archive; then
    archive=$REPLY
  elif [[ -n ${SLUICE_BACKUP_DIR:-} ]]; then
    candidates=("$SLUICE_BACKUP_DIR/${SLUICE_BACKUP_PREFIX:-backup}"-*.tar.gz)
    (( ${#candidates[@]} == 0 )) || archive=${candidates[-1]}
  fi
  [[ -n $archive ]] || stage::skip "no backup archive to verify"
  [[ -f $archive ]] || stage::fail "archive vanished before verification: $archive" BKV-MISSING
  stage::metric archive "$archive"

  if [[ -r $archive.sha256 ]]; then
    read -r expected _ < "$archive.sha256"
    read -r actual _ < <(sha256sum < "$archive")
    [[ $expected == "$actual" ]] || stage::fail "checksum mismatch for ${archive##*/}: sidecar $expected, actual $actual" BKV-CHECKSUM
    stage::metric checksum ok
  else
    stage::finding high BKV-SIDECAR "no checksum sidecar for ${archive##*/}; integrity cannot be proven"
  fi

  gzip -t -- "$archive" 2>/dev/null || stage::fail "gzip integrity test failed for ${archive##*/}" BKV-GZIP

  core::mktemp_dir restore
  restore=$REPLY
  tar -xzf "$archive" -C "$restore" --no-same-owner 2> "$STAGE_OUT/restore.err" \
    || stage::fail "extraction failed for ${archive##*/}; see restore.err" BKV-EXTRACT
  [[ -r $restore/MANIFEST.sha256 ]] || stage::fail "archive contains no MANIFEST.sha256" BKV-MANIFEST

  total=$(wc -l < "$restore/MANIFEST.sha256")
  if ! ( cd -- "$restore" && sha256sum -c --quiet MANIFEST.sha256 ) > "$STAGE_OUT/verify.log" 2>&1; then
    failed=$(grep -c 'FAILED' "$STAGE_OUT/verify.log" || :)
    stage::metric files_failed "$failed"
    stage::fail "$failed of $total restored file(s) do not match the manifest; see verify.log" BKV-RESTORE
  fi
  stage::metric files_verified "$total"
  log::info "restore verified" archive="${archive##*/}" files="$total"
}

main "$@"
stage::finish
