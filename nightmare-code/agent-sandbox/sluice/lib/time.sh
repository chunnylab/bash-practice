#!/usr/bin/env bash

declare -gA __TIME_MONTH=(
  [jan]=1 [feb]=2 [mar]=3 [apr]=4 [may]=5 [jun]=6
  [jul]=7 [aug]=8 [sep]=9 [oct]=10 [nov]=11 [dec]=12
)
declare -gra TIME_MONTH_ABBR=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

time::now_ms() {
  local t=$EPOCHREALTIME
  REPLY=$(( ${t%[.,]*} * 1000 + 10#${t#*[.,]} / 1000 ))
}

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

time::epoch_utc() {
  time::days_from_civil "$1" "$2" "$3"
  REPLY=$(( REPLY * 86400 + 10#$4 * 3600 + 10#$5 * 60 + 10#$6 ))
}

time::week_index() {
  REPLY=$(( ($1 + 3) / 7 ))
}

time::parse_openssl_date() {
  local -r re='^([A-Za-z]{3})[[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2})[[:space:]]+([0-9]{4})[[:space:]]+GMT$'
  [[ $1 =~ $re ]] || return 1
  local mon=${__TIME_MONTH[${BASH_REMATCH[1],,}]-}
  [[ -n $mon ]] || return 1
  time::epoch_utc "${BASH_REMATCH[6]}" "$mon" "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

time::utc_stamp() {
  TZ=UTC printf -v REPLY '%(%Y%m%dT%H%M%SZ)T' "${1:--1}"
}

time::iso_utc() {
  TZ=UTC printf -v REPLY '%(%Y-%m-%dT%H:%M:%SZ)T' "${1:--1}"
}

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

time::fmt_uptime() {
  local -i s=$1
  printf -v REPLY '%dd %dh %02dm' $(( s / 86400 )) $(( s % 86400 / 3600 )) $(( s % 3600 / 60 ))
}
