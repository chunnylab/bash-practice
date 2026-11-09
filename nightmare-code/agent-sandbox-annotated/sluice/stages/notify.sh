#!/usr/bin/env bash
# =============================================================================
# stages/notify.sh - send the run summary to a chat webhook
# =============================================================================
#
# Builds a Slack-compatible payload (Block Kit). Discord accepts the same
# payload at "<webhook>/slack"; Mattermost and Rocket.Chat accept it as is.
# SLUICE_WEBHOOK_FORMAT=generic sends sluice's own JSON instead.
#
# The payload is ALWAYS written to artifacts/notify/payload.json. Without a
# webhook (the default) the stage then reports "skipped", so you can review
# exactly what would have been sent.
#
# Config
#   SLUICE_WEBHOOK_URL      incoming webhook URL (a secret: keep it in .env)
#   SLUICE_WEBHOOK_FORMAT   slack | generic                     (slack)
#   SLUICE_NOTIFY_ON        always | warn | failure | never      (always)
#
# Delivery uses retry::run (3 attempts, jittered backoff), a 10 s timeout per
# request, and logs the webhook as scheme://host/... only, because the path
# of a webhook URL IS its credential.
# =============================================================================

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
core::import retry
stage::init notify

# Last HTTP status seen. It is recorded as a metric once, after delivery has
# settled: metrics.tsv must hold one value per key, not one per attempt.
declare -g NOTIFY_HTTP_STATUS=""

main() {
  local metrics=${SLUICE_ARTIFACTS:-}/report/metrics.tsv overall policy url format payload
  local -A m=()
  local k v
  policy=${SLUICE_NOTIFY_ON:-always}
  format=${SLUICE_WEBHOOK_FORMAT:-slack}

  [[ -r $metrics ]] || stage::skip "no report metrics to notify about"
  while IFS=$'\t' read -r k v; do m[$k]=$v; done < "$metrics"
  overall=${m[overall]:-unknown}

  case $policy in
    always) ;;
    never) stage::skip "notifications disabled (SLUICE_NOTIFY_ON=never)" ;;
    warn) [[ $overall == warn || $overall == failed ]] || stage::skip "status '$overall' is below the 'warn' threshold" ;;
    failure) [[ $overall == failed ]] || stage::skip "status '$overall' is not a failure" ;;
    *) stage::fail "SLUICE_NOTIFY_ON must be always|warn|failure|never (got '$policy')" NOTIFY-CONFIG ;;
  esac

  case $format in
    slack) notify::slack_payload "$overall" ;;
    generic) notify::generic_payload "$overall" ;;
    *) stage::fail "SLUICE_WEBHOOK_FORMAT must be slack|generic (got '$format')" NOTIFY-CONFIG ;;
  esac
  payload=$STAGE_OUT/payload.json
  core::atomic_write "$payload" "$REPLY"$'\n'

  url=${SLUICE_WEBHOOK_URL:-}
  [[ -n $url ]] || stage::skip "no SLUICE_WEBHOOK_URL configured; payload saved to ${payload#"${SLUICE_RUN_DIR:-}/"}"
  [[ $url =~ ^https?://[^/[:space:]]+ ]] || stage::fail "SLUICE_WEBHOOK_URL must be an http(s) URL" NOTIFY-CONFIG
  # Copy the match NOW: BASH_REMATCH is global and the very next [[ =~ ]]
  # anywhere (the JSON encoder uses one) would overwrite it.
  local endpoint=${BASH_REMATCH[0]}/...
  if (( STAGE_DRY_RUN )); then
    stage::skip "dry-run: payload not sent"
  fi
  core::have curl || stage::fail "curl is required to deliver notifications" NOTIFY-CURL

  log::info "posting notification" endpoint="$endpoint" format="$format"
  if ! retry::run -a 3 -b 1000 -m 8000 -- notify::post "$url" "$payload"; then
    stage::metric http_status "${NOTIFY_HTTP_STATUS:-none}"
    stage::fail "webhook delivery failed after 3 attempts (endpoint $endpoint)" NOTIFY-DELIVERY
  fi
  stage::metric http_status "$NOTIFY_HTTP_STATUS"
  stage::metric delivered true
  stage::metric format "$format"
}

# One delivery attempt. The body is fed through stdin (--data-binary @-)
# instead of @file: Windows builds of curl would otherwise receive an MSYS
# path they cannot open. -w prints only the HTTP status code; the response
# body goes to a file for debugging.
notify::post() {
  local url=$1 file=$2
  if ! NOTIFY_HTTP_STATUS=$(curl -sS -o "$STAGE_OUT/response.txt" -w '%{http_code}' --max-time 10 -X POST \
    -H 'Content-Type: application/json' --data-binary @- "$url" < "$file"); then
    log::warn "webhook request failed (network or TLS error)"
    return 1
  fi
  if [[ $NOTIFY_HTTP_STATUS != 2?? ]]; then
    log::warn "webhook answered HTTP $NOTIFY_HTTP_STATUS"
    return 1
  fi
}

# Top findings as Slack mrkdwn bullet lines (at most 5).
notify::top_findings() {
  local f=${SLUICE_ARTIFACTS:-}/report/findings_all.tsv sev job code msg out=""
  local -i n=0
  if [[ -r $f ]]; then
    while IFS=$'\t' read -r sev job code msg && (( n < 5 )); do
      out+="• [$sev] $job $code: $msg"$'\n'
      (( ++n ))
    done < "$f"
  fi
  REPLY=${out:-No findings.}
}

notify::slack_payload() {
  local overall=$1 icon title fields top context head section
  case $overall in
    ok) icon=':white_check_mark:' ;;
    warn) icon=':warning:' ;;
    *) icon=':rotating_light:' ;;
  esac
  title="${SLUICE_PIPELINE_NAME:-sluice}: ${overall^^}"

  json::object "type=mrkdwn" "text=*Host*"$'\n'"${HOSTNAME:-unknown}"
  fields=$REPLY
  json::object "type=mrkdwn" "text=*Run*"$'\n'"\`${SLUICE_RUN_ID:-adhoc}\`"
  fields+=,$REPLY
  json::object "type=mrkdwn" "text=*Jobs reported*"$'\n'"${m[jobs_reported]:-?}"
  fields+=,$REPLY
  json::object "type=mrkdwn" "text=*Findings*"$'\n'"${m[findings_critical]:-0} critical, ${m[findings_high]:-0} high, ${m[findings_medium]:-0} medium"
  fields+=,$REPLY

  json::object "type=plain_text" "text=$icon $title" "emoji:b=true"
  json::object "type=header" "text:raw=$REPLY"
  head=$REPLY
  json::object "type=section" "fields:raw=[$fields]"
  section=$REPLY
  notify::top_findings
  json::object "type=mrkdwn" "text=*Top findings*"$'\n'"$REPLY"
  json::object "type=section" "text:raw=$REPLY"
  top=$REPLY
  json::object "type=mrkdwn" "text=sluice $SLUICE_VERSION · report: ${m[report_md]:-n/a}"
  json::object "type=context" "elements:raw=[$REPLY]"
  context=$REPLY
  json::object "text=$icon $title on ${HOSTNAME:-unknown}" "blocks:raw=[$head,$section,$top,$context]"
}

notify::generic_payload() {
  local overall=$1 sev job code msg
  local -a items=()
  local f=${SLUICE_ARTIFACTS:-}/report/findings_all.tsv
  if [[ -r $f ]]; then
    while IFS=$'\t' read -r sev job code msg; do
      json::object "severity=$sev" "job=$job" "code=$code" "message=$msg"
      items+=("$REPLY")
    done < "$f"
  fi
  json::array raw "${items[@]}"
  json::object "pipeline=${SLUICE_PIPELINE_NAME:-sluice}" "run_id=${SLUICE_RUN_ID:-adhoc}" \
    "host=${HOSTNAME:-unknown}" "status=$overall" "findings_total:a=${m[findings_total]:-0}" \
    "findings:raw=$REPLY" "report=${m[report_md]:-}"
}

main "$@"
stage::finish
