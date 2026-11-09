#!/usr/bin/env bash
# =============================================================================
# lib/time.sh - clocks, calendar arithmetic and duration formatting
# =============================================================================
#
# date(1) differs wildly between GNU, BSD and BusyBox (`date -d` is GNU-only),
# and every call forks a process. Everything here is pure bash arithmetic:
#
#   * $EPOCHREALTIME / $EPOCHSECONDS (bash 5) give the clock without forking;
#   * printf '%(fmt)T' formats an epoch with strftime(3);
#   * civil-date <-> day-number conversion uses Howard Hinnant's algorithms
#     ("chrono-compatible low-level date algorithms"), exact for every date
#     of the proleptic Gregorian calendar.
# =============================================================================

declare -gA __TIME_MONTH=(
  [jan]=1 [feb]=2 [mar]=3 [apr]=4 [may]=5 [jun]=6
  [jul]=7 [aug]=8 [sep]=9 [oct]=10 [nov]=11 [dec]=12
)
declare -gra TIME_MONTH_ABBR=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

# time::now_ms -> REPLY: milliseconds since the Unix epoch.
# EPOCHREALTIME looks like "1793886123.033288" (or with a comma in some
# locales). 10# stops bash from reading the "033288" fraction as octal.
time::now_ms() {
  local t=$EPOCHREALTIME
  REPLY=$(( ${t%[.,]*} * 1000 + 10#${t#*[.,]} / 1000 ))
}

# -----------------------------------------------------------------------------
# time::days_from_civil YEAR MONTH DAY -> REPLY = days since 1970-01-01.
#
# The trick is to start the year on March 1st: February (with its leap day)
# becomes the LAST month, so leap years only affect the end of the
# "computational year". Then:
#   era  = 400-year cycle the date lies in (146097 days each)
#   yoe  = year of era      [0, 399]
#   doy  = day of year      [0, 365], with March = month 0; the expression
#          (153*mp + 2)/5 yields the cumulative days of months 31,30,31,30,31,
#          31,30,31,30,31,31,28/29 - a well-known closed form
#   doe  = day of era       [0, 146096]
# 719468 is the number of days from 0000-03-01 to 1970-01-01.
# -----------------------------------------------------------------------------
time::days_from_civil() {
  local -i y=$(( 10#$1 )) m=$(( 10#$2 )) d=$(( 10#$3 )) era yoe mp doy doe
  if (( m <= 2 )); then
    y=$(( y - 1 ))
  fi
  era=$(( (y >= 0 ? y : y - 399) / 400 ))
  yoe=$(( y - era * 400 ))
  mp=$(( (m + 9) % 12 ))
  doy=$(( (153 * mp + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  REPLY=$(( era * 146097 + doe - 719468 ))
}

# time::epoch_utc Y M D H M S -> REPLY = Unix timestamp of that UTC instant.
time::epoch_utc() {
  time::days_from_civil "$1" "$2" "$3"
  REPLY=$(( REPLY * 86400 + 10#$4 * 3600 + 10#$5 * 60 + 10#$6 ))
}

# time::week_index DAYS -> REPLY: index of the Monday-based week containing
# day number DAYS. 1970-01-01 was a Thursday, so shifting by 3 makes every
# week start on a Monday. Used for "keep N weekly backups".
time::week_index() {
  REPLY=$(( ($1 + 3) / 7 ))
}

# time::parse_openssl_date "Nov  5 13:42:03 2027 GMT" -> REPLY epoch.
# This is the format `openssl x509 -enddate` prints; note the space-padded
# day of month, absorbed by [[:space:]]+.
time::parse_openssl_date() {
  local -r re='^([A-Za-z]{3})[[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2})[[:space:]]+([0-9]{4})[[:space:]]+GMT$'
  [[ $1 =~ $re ]] || return 1
  local mon=${__TIME_MONTH[${BASH_REMATCH[1],,}]-}
  [[ -n $mon ]] || return 1
  time::epoch_utc "${BASH_REMATCH[6]}" "$mon" "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

# time::utc_stamp [EPOCH] -> REPLY like 20261105T064203Z (sortable, compact,
# filename-safe). -1 means "now" for printf's %(...)T.
time::utc_stamp() {
  TZ=UTC printf -v REPLY '%(%Y%m%dT%H%M%SZ)T' "${1:--1}"
}

# time::iso_utc [EPOCH] -> REPLY like 2026-11-05T06:42:03Z (RFC 3339).
time::iso_utc() {
  TZ=UTC printf -v REPLY '%(%Y-%m-%dT%H:%M:%SZ)T' "${1:--1}"
}

# time::fmt_duration MILLISECONDS -> REPLY: "850ms", "2.41s", "3m07s", "1h05m".
time::fmt_duration() {
  local -i ms=$1
  if (( ms < 1000 )); then
    REPLY=${ms}ms
  elif (( ms < 60000 )); then
    printf -v REPLY '%d.%02ds' $(( ms / 1000 )) $(( ms % 1000 / 10 ))
  elif (( ms < 3600000 )); then
    printf -v REPLY '%dm%02ds' $(( ms / 60000 )) $(( ms % 60000 / 1000 ))
  else
    printf -v REPLY '%dh%02dm' $(( ms / 3600000 )) $(( ms % 3600000 / 60000 ))
  fi
}

# time::fmt_uptime SECONDS -> REPLY: "12d 4h 03m".
time::fmt_uptime() {
  local -i s=$1
  printf -v REPLY '%dd %dh %02dm' $(( s / 86400 )) $(( s % 86400 / 3600 )) $(( s % 3600 / 60 ))
}
