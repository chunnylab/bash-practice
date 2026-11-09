#!/usr/bin/env bash
# =============================================================================
# stages/backup.sh - checksummed archives with grandfather-father-son retention
# =============================================================================
#
#   <dest>/backup-20261105T064203Z.tar.gz          the archive
#   <dest>/backup-20261105T064203Z.tar.gz.sha256   sidecar checksum
#
# Inside every archive sits MANIFEST.sha256 - the checksum of every file at
# backup time - so stages/backup-verify.sh can prove a RESTORE is bit-exact,
# not merely that the archive decompresses.
#
# Safety properties:
#   * atomic publication: the archive is written as *.partial and renamed
#     into place only when complete, so a crash never leaves a truncated file
#     that looks like a valid backup;
#   * a lock in the destination stops two backups from interleaving;
#   * umask 077: backups are readable by their owner only;
#   * retention only ever deletes files whose names match its exact pattern.
#
# Retention (restic-style GFS): walking from newest to oldest, keep the
# newest archive of each of the last N days, N weeks and N months that HAVE
# backups. One archive can satisfy several rules at once.
#
# Config
#   SLUICE_BACKUP_SOURCES        directories/files to archive
#   SLUICE_BACKUP_DIR            destination directory
#   SLUICE_BACKUP_PREFIX         file name prefix (backup)
#   SLUICE_BACKUP_KEEP_DAILY     7
#   SLUICE_BACKUP_KEEP_WEEKLY    4
#   SLUICE_BACKUP_KEEP_MONTHLY   6
# =============================================================================

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
core::import lock
stage::init backup

main() {
  local -a sources=() tar_args=()
  local -A seen=()
  local src base parent dest prefix name archive staging hash
  local -i files=0 bytes=0 rc=0

  stage::split_list sources "${SLUICE_BACKUP_SOURCES:-}"
  (( ${#sources[@]} )) || stage::skip "SLUICE_BACKUP_SOURCES is not set"
  dest=${SLUICE_BACKUP_DIR:-}
  [[ -n $dest ]] || stage::fail "SLUICE_BACKUP_DIR is not set" BKP-CONFIG
  prefix=${SLUICE_BACKUP_PREFIX:-backup}
  [[ $prefix =~ ^[A-Za-z0-9._-]+$ ]] || stage::fail "invalid SLUICE_BACKUP_PREFIX '$prefix'" BKP-CONFIG

  # Each source is archived relative to its parent (tar -C parent base), so
  # /srv/app/config is stored as "config/...". Two sources with the same base
  # name would overwrite each other inside the archive - refuse that.
  for src in "${sources[@]}"; do
    [[ $src == / ]] || src=${src%/}
    if [[ ! -e $src ]]; then
      stage::finding high BKP-SOURCE "backup source does not exist: $src"
      continue
    fi
    base=${src##*/}
    parent=${src%/*}
    [[ $src == */* ]] || parent=.
    [[ -n $parent ]] || parent=/
    if [[ -n ${seen[$base]-} ]]; then
      stage::fail "sources '$src' and '${seen[$base]}' share the name '$base' and would collide in the archive" BKP-COLLISION
    fi
    seen[$base]=$src
    tar_args+=(-C "$parent" "$base")
  done
  (( ${#tar_args[@]} )) || stage::fail "none of the backup sources exist" BKP-SOURCE

  mkdir -p -- "$dest"
  lock::acquire "$dest/.sluice-backup.lock" 30 || stage::fail "another backup is writing to $dest" BKP-LOCK

  time::utc_stamp
  name=$prefix-$REPLY.tar.gz
  archive=$dest/$name
  stage::metric archive_name "$name"

  if (( STAGE_DRY_RUN )); then
    log::info "dry-run: would write $archive"
    backup::retention "$dest" "$prefix" ""
    return 0
  fi

  umask 077
  core::mktemp_dir backup
  staging=$REPLY
  backup::manifest "$staging/MANIFEST.sha256" "${tar_args[@]}"
  files=$(wc -l < "$staging/MANIFEST.sha256")

  # GNU tar exit codes: 0 ok, 1 "some files changed while being read" (the
  # archive is still usable), 2 fatal. Distinguishing them avoids throwing
  # away a good backup of a busy directory.
  if tar -czf "$archive.partial" -C "$staging" MANIFEST.sha256 "${tar_args[@]}" 2> "$STAGE_OUT/tar.err"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 1 )); then
    stage::finding medium BKP-CHANGED "files changed while being archived; see tar.err"
  elif (( rc != 0 )); then
    rm -f -- "$archive.partial"
    stage::fail "tar failed with exit $rc: $(head -n 1 "$STAGE_OUT/tar.err")" BKP-TAR
  fi

  read -r hash _ < <(sha256sum < "$archive.partial")
  printf '%s  %s\n' "$hash" "$name" > "$archive.sha256.partial"
  mv -f -- "$archive.partial" "$archive"
  mv -f -- "$archive.sha256.partial" "$archive.sha256"
  bytes=$(wc -c < "$archive")

  stage::metric archive "$archive"
  stage::metric archive_bytes "$bytes"
  stage::metric archive_sha256 "$hash"
  stage::metric files "$files"
  stage::metric sources $(( ${#tar_args[@]} / 3 ))
  log::info "archive written" archive="$archive" files="$files" bytes="$bytes"

  backup::retention "$dest" "$prefix" "$name"
}

# backup::manifest OUT (-C PARENT BASE)... - sha256 of every regular file,
# with paths exactly as they appear in the archive. sort -z orders the
# NUL-separated names deterministically; xargs -0 -r passes them safely and
# runs nothing for an empty list; `--` protects names starting with '-'.
backup::manifest() {
  local out=$1
  shift
  : > "$out"
  while (( $# >= 3 )); do
    if ! ( cd -- "$2" && find "$3" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -- ) >> "$out" 2>> "$STAGE_OUT/manifest.err"; then
      stage::finding high BKP-UNREADABLE "some files under $2/$3 could not be read; see manifest.err"
    fi
    shift 3
  done
}

# backup::retention DEST PREFIX JUST_CREATED
# Globs sort lexically, and the names embed a UTC timestamp, so iterating the
# glob result backwards visits archives from newest to oldest. The regex
# mixes a QUOTED part ("$prefix", matched literally even if it contained
# regex characters) with unquoted regex syntax.
backup::retention() {
  local dest=$1 prefix=$2 created=$3 f base reasons month
  local -a all=("$dest/$prefix"-*.tar.gz)
  local -A days=() weeks=() months=()
  local -i i nd=0 nw=0 nm=0 kept=0 pruned=0 day week
  local -i keep_d=${SLUICE_BACKUP_KEEP_DAILY:-7} keep_w=${SLUICE_BACKUP_KEEP_WEEKLY:-4} keep_m=${SLUICE_BACKUP_KEEP_MONTHLY:-6}

  : > "$STAGE_OUT/retention.tsv"
  for (( i = ${#all[@]} - 1; i >= 0; i-- )); do
    f=${all[i]}
    base=${f##*/}
    [[ $base =~ ^"$prefix"-([0-9]{4})([0-9]{2})([0-9]{2})T[0-9]{6}Z\.tar\.gz$ ]] || continue
    time::days_from_civil "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    day=$REPLY
    time::week_index "$day"
    week=$REPLY
    month=${BASH_REMATCH[1]}${BASH_REMATCH[2]}

    reasons=""
    if [[ -n $created && $base == "$created" ]]; then
      reasons=newest
    fi
    if (( nd < keep_d )) && [[ -z ${days[$day]-} ]]; then
      days[$day]=1
      (( ++nd ))
      reasons+=${reasons:+,}daily
    fi
    if (( nw < keep_w )) && [[ -z ${weeks[$week]-} ]]; then
      weeks[$week]=1
      (( ++nw ))
      reasons+=${reasons:+,}weekly
    fi
    if (( nm < keep_m )) && [[ -z ${months[$month]-} ]]; then
      months[$month]=1
      (( ++nm ))
      reasons+=${reasons:+,}monthly
    fi

    if [[ -n $reasons ]]; then
      (( ++kept ))
      printf '%s\tkeep\t%s\n' "$base" "$reasons" >> "$STAGE_OUT/retention.tsv"
    else
      (( ++pruned ))
      printf '%s\tprune\t-\n' "$base" >> "$STAGE_OUT/retention.tsv"
      if (( STAGE_DRY_RUN )); then
        log::info "dry-run: would prune $base"
      else
        rm -f -- "$f" "$f.sha256"
        log::info "pruned $base"
      fi
    fi
  done
  stage::metric retained "$kept"
  stage::metric pruned "$pruned"
}

main "$@"
stage::finish
