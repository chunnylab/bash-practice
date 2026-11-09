#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init cert-expiry

main() {
  local -a patterns=() files=() endpoints=()
  local f ep pem soonest_label=-
  local -i warn_days=${SLUICE_CERT_WARN_DAYS:-30} crit_days=${SLUICE_CERT_CRIT_DAYS:-7}
  local -i now=$EPOCHSECONDS checked=0 soonest=2147483647

  stage::require_cmds openssl
  stage::split_list patterns "${SLUICE_CERT_PATHS:-}"
  stage::expand_globs files "${patterns[@]}"
  stage::split_list endpoints "${SLUICE_CERT_ENDPOINTS:-}"
  (( ${#files[@]} + ${#endpoints[@]} > 0 )) \
    || stage::skip "no certificates configured (SLUICE_CERT_PATHS / SLUICE_CERT_ENDPOINTS)"

  : > "$STAGE_OUT/certificates.tsv"
  for f in "${files[@]}"; do
    if [[ -r $f ]]; then
      cert::scan_file "$f"
    else
      stage::finding medium CERT-MISSING "certificate file not readable: $f"
    fi
  done
  for ep in "${endpoints[@]}"; do
    if pem=$(cert::fetch "$ep") && [[ -n $pem ]]; then
      cert::scan_bundle "$ep" <<< "$pem"
    else
      stage::finding high CERT-UNREACHABLE "could not retrieve a certificate from $ep"
    fi
  done

  stage::metric certificates_checked "$checked"
  if (( checked > 0 )); then
    stage::metric soonest_expiry_days "$soonest"
    stage::metric soonest_expiry "$soonest_label"
  fi
}

cert::fetch() {
  local ep=$1 host port
  host=${ep%:*} port=${ep##*:}
  [[ $ep == *:* ]] || { host=$ep port=443; }
  local -a guard=()
  if core::have timeout; then
    guard=(timeout 15)
  fi
  "${guard[@]}" openssl s_client -connect "$host:$port" -servername "$host" -showcerts < /dev/null 2>/dev/null
}

cert::scan_file() {
  local label=$1
  cert::scan_bundle "$label" < "$1"
}

cert::scan_bundle() {
  local label=$1 line pem=""
  local -i inside=0 idx=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line == '-----BEGIN CERTIFICATE-----' ]]; then
      inside=1
      pem=$line$'\n'
      continue
    fi
    (( inside )) || continue
    pem+=$line$'\n'
    if [[ $line == '-----END CERTIFICATE-----' ]]; then
      inside=0
      (( ++idx ))
      cert::check "$label" "$idx" "$pem"
    fi
  done
  if (( idx == 0 )); then
    stage::finding medium CERT-PARSE "no PEM certificate found in $label"
  fi
}

cert::check() {
  local label=$1 idx=$2 out line subject='?' enddate="" sev="" state=ok
  local -i expires days
  if ! out=$(openssl x509 -noout -subject -enddate -nameopt RFC2253 2>/dev/null <<< "$3"); then
    stage::finding medium CERT-PARSE "certificate #$idx in $label cannot be parsed"
    return 0
  fi
  while IFS= read -r line; do
    case $line in
      subject=*) subject=${line#subject=} ;;
      notAfter=*) enddate=${line#notAfter=} ;;
    esac
  done <<< "$out"
  if ! time::parse_openssl_date "$enddate"; then
    stage::finding medium CERT-PARSE "unrecognised notAfter date '$enddate' in $label"
    return 0
  fi
  expires=$REPLY
  if (( expires >= now )); then
    days=$(( (expires - now) / 86400 ))
  else
    days=$(( -((now - expires + 86399) / 86400) ))
  fi
  (( ++checked ))
  if (( days < soonest )); then
    soonest=$days
    soonest_label="$label#$idx"
  fi

  if (( expires < now )); then
    sev=critical state=expired
  elif (( days < crit_days )); then
    sev=high state=critical
  elif (( days < warn_days )); then
    sev=medium state=warning
  fi
  printf '%s\t%d\t%s\t%s\t%d\t%s\n' "$label" "$idx" "$subject" "$enddate" "$days" "$state" >> "$STAGE_OUT/certificates.tsv"
  if [[ $state == expired ]]; then
    stage::finding critical CERT-EXPIRED "$subject ($label #$idx) EXPIRED $(( -days )) day(s) ago ($enddate)"
  elif [[ -n $sev ]]; then
    stage::finding "$sev" "CERT-${state^^}" "$subject ($label #$idx) expires in $days day(s) ($enddate)"
  fi
}

main "$@"
stage::finish
