#!/usr/bin/env bash
# =============================================================================
# stages/publish.sh - zero-downtime release of the report to a web root
# =============================================================================
#
# The Capistrano layout, used by countless deploy tools:
#
#   $SLUICE_PUBLISH_ROOT/
#     releases/20261104T020000Z-91ab/   older release
#     releases/20261105T020000Z-7f3a/   newest release
#     current -> releases/20261105T020000Z-7f3a
#
# A web server serves .../current. Switching releases is ONE rename(2) of a
# symlink, which is atomic: every request sees either the old or the new
# release, never a mixture or a missing file. (`ln -sfn` is NOT atomic: it
# unlinks the old link and then creates the new one, leaving a gap.)
#
# Steps: stage the release -> health-check it -> switch -> health-check
# through `current` -> on failure switch back (rollback) -> prune old
# releases, never touching the current or the previous one.
#
# Config
#   SLUICE_PUBLISH_ROOT         web root to manage
#   SLUICE_PUBLISH_KEEP         releases to keep (5)
#   SLUICE_PUBLISH_HEALTHCHECK  optional command; receives the release path
#                               as its last argument, e.g.
#                               "curl -fsS -o /dev/null http://localhost/status/"
# =============================================================================

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
core::import lock
stage::init publish

main() {
  local root=${SLUICE_PUBLISH_ROOT:-} src=${SLUICE_ARTIFACTS:-}/report id=${SLUICE_RUN_ID:-}
  local current previous="" rel
  local -i keep=${SLUICE_PUBLISH_KEEP:-5}

  [[ -n $root ]] || stage::skip "SLUICE_PUBLISH_ROOT is not set"
  [[ -r $src/index.html ]] || stage::skip "no rendered report found at $src/index.html"
  if [[ -z $id ]]; then
    time::utc_stamp
    id=manual-$REPLY
  fi
  # Web servers usually run as another user, so everything below the web
  # root - including the directories created right here - must be
  # world-readable, unlike the rest of sluice's output (umask 027).
  umask 022
  mkdir -p -- "$root/releases"
  core::can_symlink "$root" \
    || stage::skip "$root does not support symbolic links; atomic release switching is unavailable here"
  lock::acquire "$root/.publish.lock" 30 || stage::fail "another publish holds the lock on $root" PUB-LOCK

  current=$root/current
  if [[ -L $current ]]; then
    previous=$(readlink -- "$current")
  fi
  rel=releases/$id

  if (( STAGE_DRY_RUN )); then
    log::info "dry-run: would publish $rel (current: ${previous:-none})"
    stage::metric release "$rel (dry-run)"
    return 0
  fi
  [[ ! -e $root/$rel ]] || stage::fail "release $rel already exists" PUB-EXISTS

  mkdir -- "$root/$rel"
  cp -- "$src/index.html" "$src/report.md" "$src/report.json" "$root/$rel/"
  publish::seal "$root/$rel" "$id"

  # ${root:?} aborts if root were ever empty, so this rm -rf can never
  # expand to "rm -rf /releases/...".
  if ! publish::healthcheck "$root/$rel" "$id"; then
    rm -rf -- "${root:?}/$rel"
    stage::fail "release $id failed its pre-switch health check" PUB-HEALTH
  fi

  publish::switch "$rel" "$current"
  if ! publish::healthcheck "$current" "$id"; then
    if [[ -n $previous ]]; then
      publish::switch "$previous" "$current"
    else
      rm -f -- "$current"
    fi
    rm -rf -- "${root:?}/$rel"
    stage::fail "release $id failed its post-switch health check; rolled back to ${previous:-nothing}" PUB-ROLLBACK
  fi
  log::info "release switched" current="$rel" previous="${previous:-none}"

  publish::prune "$root" "$keep" "$rel" "$previous"
  stage::metric release "$rel"
  stage::metric previous "${previous:-none}"
  stage::metric url "$current/index.html"
}

# Seal the release: a checksum manifest plus a small RELEASE descriptor.
publish::seal() {
  local dir=$1 id=$2
  ( cd -- "$dir" && sha256sum index.html report.md report.json > RELEASE.sha256 )
  time::iso_utc
  printf 'id=%s\ncreated=%s\nhost=%s\nsluice=%s\n' "$id" "$REPLY" "${HOSTNAME:-unknown}" "$SLUICE_VERSION" > "$dir/RELEASE"
}

# Built-in health check: the page exists, belongs to THIS run (the
# data-run-id attribute written by report.sh) and matches its seal.
# -F makes grep treat the pattern as a fixed string, not a regex.
publish::healthcheck() {
  local path=$1 id=$2
  local -a custom=()
  if [[ -n ${SLUICE_PUBLISH_HEALTHCHECK:-} ]]; then
    read -r -a custom <<< "$SLUICE_PUBLISH_HEALTHCHECK"
    "${custom[@]}" "$path"
    return
  fi
  if [[ ! -s $path/index.html ]]; then
    log::error "health check: $path/index.html is missing or empty"
    return 1
  fi
  if ! grep -qF -- "data-run-id=\"$id\"" "$path/index.html"; then
    log::error "health check: $path/index.html does not belong to run $id"
    return 1
  fi
  if ! ( cd -- "$path" && sha256sum -c --quiet RELEASE.sha256 ) >/dev/null 2>&1; then
    log::error "health check: checksum mismatch in $path"
    return 1
  fi
}

# Atomic switch: create the new link under a temporary name, then rename it
# over `current`. GNU mv -T ("no target directory") is essential: without it
# mv would see that `current` resolves to a directory and move the new link
# INTO it. BSD mv lacks -T, hence the explicit, logged fallback.
publish::switch() {
  local target=$1 link=$2 tmp=$2.next.$BASHPID
  rm -f -- "$tmp"
  ln -s -- "$target" "$tmp"
  if mv -T -- "$tmp" "$link" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp"
  log::warn "mv -T is not available; falling back to a NON-atomic ln -sfn"
  ln -sfn -- "$target" "$link"
}

# Keep the newest KEEP releases (names start with a UTC timestamp, so the
# glob's lexical order is chronological), plus whatever current and previous
# point at, even if they are older.
publish::prune() {
  local root=$1 cur=$3 prev=$4 d name
  local -i keep=$2 i n=0 pruned=0
  local -a rels=("$root"/releases/*/)
  for (( i = ${#rels[@]} - 1; i >= 0; i-- )); do
    d=${rels[i]%/}
    name=releases/${d##*/}
    (( ++n ))
    if (( n <= keep )) || [[ $name == "$cur" || $name == "$prev" ]]; then
      continue
    fi
    rm -rf -- "$d"
    (( ++pruned ))
    log::info "pruned release $name"
  done
  stage::metric releases_kept $(( n - pruned ))
  stage::metric releases_pruned "$pruned"
}

main "$@"
stage::finish
