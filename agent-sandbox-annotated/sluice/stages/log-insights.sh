#!/usr/bin/env bash
# =============================================================================
# stages/log-insights.sh - traffic, error and latency analytics for nginx
# =============================================================================
#
# Config
#   SLUICE_ACCESS_LOGS           globs, e.g. "/var/log/nginx/access.log*"
#                                (plain and .gz files may be mixed)
#   SLUICE_TOP_N                 entries per top list (5)
#   SLUICE_MAX_5XX_PCT           5xx share that raises a high finding (2)
#   SLUICE_MAX_P99_MS            p99 latency that raises a medium finding (1500)
#   SLUICE_MAX_CLIENT_SHARE_PCT  one client's share of traffic considered
#                                suspicious - scraper or abuse (30)
#   SLUICE_AWK                   awk implementation to use (awk)
#
# Artifacts: raw.tsv (awk output), top.tsv, insights.json
# =============================================================================

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init log-insights

main() {
  local -a patterns=() files=() readable=() top_rows=()
  local -A metric=()
  local f kind a b c d awk=${SLUICE_AWK:-awk} raw=$STAGE_OUT/raw.tsv
  local -i top_n=${SLUICE_TOP_N:-5} max_p99=${SLUICE_MAX_P99_MS:-1500} max_5xx_bp max_share_bp

  # Percent thresholds -> basis points (x100), matching the awk output, so
  # "1.5" percent is compared exactly without floating point.
  core::to_centi "${SLUICE_MAX_5XX_PCT:-2}" || stage::fail "SLUICE_MAX_5XX_PCT must be a decimal percentage"
  max_5xx_bp=$REPLY
  core::to_centi "${SLUICE_MAX_CLIENT_SHARE_PCT:-30}" || stage::fail "SLUICE_MAX_CLIENT_SHARE_PCT must be a decimal percentage"
  max_share_bp=$REPLY

  stage::split_list patterns "${SLUICE_ACCESS_LOGS:-}"
  (( ${#patterns[@]} )) || stage::skip "SLUICE_ACCESS_LOGS is not set"
  stage::expand_globs files "${patterns[@]}"
  for f in "${files[@]}"; do
    if [[ -f $f && -r $f ]]; then
      readable+=("$f")
    else
      log::warn "not a readable file: $f"
    fi
  done
  (( ${#readable[@]} )) || stage::skip "no readable access log matches: ${patterns[*]}"
  stage::metric log_files "${#readable[@]}"

  # gzip -cdf decompresses to stdout, and -f passes NON-gzip input through
  # untouched, so a live access.log and rotated access.log.2.gz files can be
  # streamed together. LC_ALL=C gives awk byte semantics and a '.' decimal
  # point regardless of the user's locale. Thanks to pipefail, a corrupt .gz
  # file fails this whole pipeline instead of silently truncating the data.
  if ! gzip -cdf -- "${readable[@]}" | LC_ALL=C "$awk" -v top_n="$top_n" -f "$SLUICE_LIB/awk/access-log.awk" > "$raw"; then
    stage::fail "could not parse the access logs (gzip or $awk failed)" LOG-IO
  fi

  while IFS=$'\t' read -r kind a b c d; do
    case $kind in
      metric)
        metric[$a]=$b
        stage::metric "$a" "$b"
        ;;
      top) top_rows+=("$a"$'\t'"$b"$'\t'"$c"$'\t'"$d") ;;
    esac
  done < "$raw"
  printf '%s\n' "${top_rows[@]}" > "$STAGE_OUT/top.tsv"

  (( ${metric[requests]:-0} > 0 )) || stage::skip "the access logs contain no parseable requests"
  logs::findings
  logs::write_json
}

# Basis points -> "2.22" (percent with two decimals).
logs::pct() {
  printf -v REPLY '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 ))
}

logs::findings() {
  local row list rank count key
  local -i requests=${metric[requests]} share
  local -i rate=${metric[error_rate_5xx_bp]:-0} p99=${metric[latency_p99_ms]:-0} bad=${metric[malformed_lines]:-0}

  if (( rate >= max_5xx_bp )); then
    logs::pct "$rate"
    stage::finding high LOG-5XX "5xx error rate ${REPLY}% (${metric[status_5xx]} of $requests requests) exceeds ${SLUICE_MAX_5XX_PCT:-2}%"
  fi
  if (( p99 > max_p99 )); then
    stage::finding medium LOG-P99 "p99 latency ${p99} ms exceeds ${max_p99} ms (p50 ${metric[latency_p50_ms]} ms, max ${metric[latency_max_ms]} ms)"
  fi
  if (( bad > 0 )); then
    stage::finding low LOG-PARSE "$bad line(s) did not match the expected log format"
  fi
  for row in "${top_rows[@]}"; do
    IFS=$'\t' read -r list rank count key <<< "$row"
    if [[ $list == clients && $rank == 1 ]]; then
      share=$(( count * 10000 / requests ))
      if (( share >= max_share_bp )); then
        logs::pct "$share"
        stage::finding medium LOG-CLIENT "client $key sent ${REPLY}% of all requests ($count) - scraper, bot or abuse?"
      fi
    elif [[ $list == error_paths && $rank == 1 ]]; then
      stage::finding info LOG-HOTSPOT "most server errors: $key ($count)"
    fi
  done
}

# insights.json = all metrics (auto-typed) + one array of {rank,count,key}
# objects per top list.
logs::write_json() {
  local k row list rank count key
  local -a spec=() paths=() clients=() errs=()
  for k in "${!metric[@]}"; do
    spec+=("$k:a=${metric[$k]}")
  done
  for row in "${top_rows[@]}"; do
    IFS=$'\t' read -r list rank count key <<< "$row"
    json::object "rank:n=$rank" "count:n=$count" "key=$key"
    case $list in
      paths) paths+=("$REPLY") ;;
      clients) clients+=("$REPLY") ;;
      error_paths) errs+=("$REPLY") ;;
    esac
  done
  json::array raw "${paths[@]}"
  spec+=("top_paths:raw=$REPLY")
  json::array raw "${clients[@]}"
  spec+=("top_clients:raw=$REPLY")
  json::array raw "${errs[@]}"
  spec+=("top_error_paths:raw=$REPLY")
  json::object "${spec[@]}"
  core::atomic_write "$STAGE_OUT/insights.json" "$REPLY"$'\n'
}

main "$@"
stage::finish
