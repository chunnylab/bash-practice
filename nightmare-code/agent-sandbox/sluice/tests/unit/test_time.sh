#!/usr/bin/env bash

test_days_from_civil_known_dates() {
  local spec d
  for spec in 1970-01-01=0 1970-01-02=1 1969-12-31=-1 2000-03-01=11017 2024-02-29=19782 2026-11-05=20762; do
    d=${spec%%=*}
    time::days_from_civil "${d:0:4}" "${d:5:2}" "${d:8:2}"
    assert::eq "${spec#*=}" "$REPLY" "$d"
  done
}

test_epoch_utc_and_openssl_dates() {
  time::parse_openssl_date 'Nov  5 13:42:03 2026 GMT'
  assert::eq $(( 20762 * 86400 + 13 * 3600 + 42 * 60 + 3 )) "$REPLY"
  time::epoch_utc 2026 08 09 08 09 09
  assert::eq 1786262949 "$REPLY"
  if date -u -d @0 > /dev/null 2>&1; then
    assert::eq 2026-08-09T08:09:09 "$(date -u -d @1786262949 +%FT%T)" "cross-check with GNU date"
  fi
  if time::parse_openssl_date 'not a date'; then return 1; fi
  if time::parse_openssl_date 'Foo  5 13:42:03 2026 GMT'; then return 1; fi
}

test_week_index_starts_on_monday() {
  local mon sun next
  time::days_from_civil 2026 11 02
  time::week_index "$REPLY"
  mon=$REPLY
  time::days_from_civil 2026 11 08
  time::week_index "$REPLY"
  sun=$REPLY
  time::days_from_civil 2026 11 09
  time::week_index "$REPLY"
  next=$REPLY
  assert::eq "$mon" "$sun" "Monday and Sunday share a week"
  assert::eq $(( mon + 1 )) "$next" "the next Monday starts a new week"
}

test_duration_and_uptime_formatting() {
  local spec
  for spec in 0=0ms 850=850ms 2410=2.41s 59999=59.99s 187000=3m07s 3900000=1h05m; do
    time::fmt_duration "${spec%%=*}"
    assert::eq "${spec#*=}" "$REPLY"
  done
  time::fmt_uptime $(( 12 * 86400 + 4 * 3600 + 3 * 60 ))
  assert::eq '12d 4h 03m' "$REPLY"
}

test_utc_stamps_ignore_the_local_timezone() {
  TZ=Asia/Bangkok time::utc_stamp 0
  assert::eq 19700101T000000Z "$REPLY"
  time::iso_utc 1786262949
  assert::eq 2026-08-09T08:09:09Z "$REPLY"
}

test_now_ms_is_monotonic_enough() {
  local -i a b
  time::now_ms
  a=$REPLY
  sleep 0.02
  time::now_ms
  b=$REPLY
  (( b - a >= 15 && b - a < 2000 )) || { printf 'unexpected delta %d ms\n' $(( b - a )) >&2; return 1; }
}
