#!/usr/bin/env bash

case ${BASH_SOURCE[0]} in
  */*) source "${BASH_SOURCE[0]%/*}/../lib/stage.sh" ;;
  *) source ../lib/stage.sh ;;
esac
stage::init report

declare -ga R_JOBS=() R_LATER=() R_FINDINGS=()
declare -gA R_STATE=() R_TOOK=() R_ATTEMPTS=() R_NOTE=() R_SEV=()
declare -g R_OVERALL=ok R_ARTIFACTS=""

main() {
  local run=${SLUICE_RUN_DIR:-} sev
  [[ -n $run && -r $run/jobs.order ]] || stage::skip "the report needs a sluice run context (SLUICE_RUN_DIR)"
  R_ARTIFACTS=${SLUICE_ARTIFACTS:-$run/artifacts}

  report::collect "$run"
  report::markdown | core::atomic_write "$STAGE_OUT/report.md"
  report::html | core::atomic_write "$STAGE_OUT/index.html"
  report::json

  stage::metric overall "$R_OVERALL"
  stage::metric jobs_reported "${#R_JOBS[@]}"
  stage::metric findings_total "${#R_FINDINGS[@]}"
  for sev in critical high medium low info; do
    stage::metric "findings_$sev" "${R_SEV[$sev]:-0}"
  done
  stage::metric report_md "$STAGE_OUT/report.md"
  stage::metric report_html "$STAGE_OUT/index.html"
  log::info "report written" status="$R_OVERALL" findings="${#R_FINDINGS[@]}"
}

report::collect() {
  local run=$1 job state att start end note sev code msg f row
  local -a order=()
  mapfile -t order < "$run/jobs.order"
  for job in "${order[@]}"; do
    [[ $job != "$STAGE_NAME" ]] || continue
    f=$run/jobs/$job/status
    if [[ ! -r $f ]]; then
      R_LATER+=("$job")
      continue
    fi
    IFS=$'\t' read -r state _ att start end note < "$f" || :
    R_JOBS+=("$job")
    R_STATE[$job]=$state
    R_ATTEMPTS[$job]=$att
    R_NOTE[$job]=$note
    time::fmt_duration $(( end - start ))
    R_TOOK[$job]=$REPLY
    case $state in
      failed | timeout | cancelled | interrupted) R_OVERALL=failed ;;
      warn) [[ $R_OVERALL == failed ]] || R_OVERALL=warn ;;
    esac

    f=$R_ARTIFACTS/$job/findings.tsv
    [[ -r $f ]] || continue
    while IFS=$'\t' read -r sev code msg; do
      R_FINDINGS+=("${__STAGE_RANK[$sev]:-0}"$'\t'"$sev"$'\t'"$job"$'\t'"$code"$'\t'"$msg")
      R_SEV[$sev]=$(( ${R_SEV[$sev]:-0} + 1 ))
    done < "$f"
  done

  if (( ${#R_FINDINGS[@]} )); then
    mapfile -t R_FINDINGS < <(printf '%s\n' "${R_FINDINGS[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k3,3 -k4,4)
  fi
  : > "$STAGE_OUT/findings_all.tsv"
  for row in "${R_FINDINGS[@]}"; do
    printf '%s\n' "${row#*$'\t'}" >> "$STAGE_OUT/findings_all.tsv"
  done
}

report::md() {
  local s=${1//|/\\|}
  REPLY=${s//$'\n'/ }
}

report::markdown() {
  local job row sev code msg k v f started generated
  time::iso_utc $(( ${SLUICE_RUN_STARTED_MS:-0} / 1000 ))
  started=$REPLY
  time::iso_utc
  generated=$REPLY

  printf '# %s - run report\n\n' "${SLUICE_PIPELINE_NAME:-sluice}"
  printf '| | |\n|---|---|\n'
  printf '| Status | **%s** |\n' "${R_OVERALL^^}"
  printf '| Run | `%s` |\n' "${SLUICE_RUN_ID:-adhoc}"
  printf '| Host | `%s` |\n' "${HOSTNAME:-unknown}"
  printf '| Started | %s |\n' "$started"
  printf '| Generated | %s by sluice %s |\n\n' "$generated" "$SLUICE_VERSION"

  printf '## Jobs\n\n| Job | State | Duration | Attempts | Note |\n|---|---|---:|---:|---|\n'
  for job in "${R_JOBS[@]}"; do
    report::md "${R_NOTE[$job]}"
    printf '| %s | %s | %s | %s | %s |\n' "$job" "${R_STATE[$job]}" "${R_TOOK[$job]}" "${R_ATTEMPTS[$job]}" "$REPLY"
  done
  if (( ${#R_LATER[@]} )); then
    printf '\n_Scheduled after this report: %s._\n' "${R_LATER[*]}"
  fi

  printf '\n## Findings (%d)\n\n' "${#R_FINDINGS[@]}"
  if (( ${#R_FINDINGS[@]} == 0 )); then
    printf 'No findings.\n'
  else
    printf '| Severity | Job | Code | Finding |\n|---|---|---|---|\n'
    for row in "${R_FINDINGS[@]}"; do
      IFS=$'\t' read -r _ sev job code msg <<< "$row"
      report::md "$msg"
      printf '| %s | %s | %s | %s |\n' "$sev" "$job" "$code" "$REPLY"
    done
  fi

  printf '\n## Metrics\n'
  for job in "${R_JOBS[@]}"; do
    f=$R_ARTIFACTS/$job/metrics.tsv
    [[ -s $f ]] || continue
    printf '\n### %s\n\n| Metric | Value |\n|---|---|\n' "$job"
    while IFS=$'\t' read -r k v; do
      report::md "$v"
      printf '| %s | %s |\n' "$k" "$REPLY"
    done < "$f"
  done
}

report::json() {
  local job row sev code msg k v f jobs finds metrics counts later
  local -a j=() fl=() per=() m=()
  for job in "${R_JOBS[@]}"; do
    json::object "name=$job" "state=${R_STATE[$job]}" "duration=${R_TOOK[$job]}" \
      "attempts:a=${R_ATTEMPTS[$job]}" "note=${R_NOTE[$job]}"
    j+=("$REPLY")
    m=()
    f=$R_ARTIFACTS/$job/metrics.tsv
    if [[ -r $f ]]; then
      while IFS=$'\t' read -r k v; do m+=("$k:a=$v"); done < "$f"
    fi
    json::object "${m[@]}"
    per+=("$job:raw=$REPLY")
  done
  for row in "${R_FINDINGS[@]}"; do
    IFS=$'\t' read -r _ sev job code msg <<< "$row"
    json::object "severity=$sev" "job=$job" "code=$code" "message=$msg"
    fl+=("$REPLY")
  done
  json::array raw "${j[@]}"
  jobs=$REPLY
  json::array raw "${fl[@]}"
  finds=$REPLY
  json::object "${per[@]}"
  metrics=$REPLY
  json::object "critical:n=${R_SEV[critical]:-0}" "high:n=${R_SEV[high]:-0}" "medium:n=${R_SEV[medium]:-0}" \
    "low:n=${R_SEV[low]:-0}" "info:n=${R_SEV[info]:-0}"
  counts=$REPLY
  json::array s "${R_LATER[@]}"
  later=$REPLY
  time::iso_utc
  json::object "pipeline=${SLUICE_PIPELINE_NAME:-sluice}" "run_id=${SLUICE_RUN_ID:-adhoc}" \
    "host=${HOSTNAME:-unknown}" "status=$R_OVERALL" "generated_at=$REPLY" "sluice_version=$SLUICE_VERSION" \
    "jobs:raw=$jobs" "scheduled_after:raw=$later" "severity_counts:raw=$counts" \
    "findings:raw=$finds" "metrics:raw=$metrics"
  core::atomic_write "$STAGE_OUT/report.json" "$REPLY"$'\n'
}

report::esc() {
  local s=$1
  s=${s//&/"&amp;"}
  s=${s//</"&lt;"}
  s=${s//>/"&gt;"}
  s=${s//\"/"&quot;"}
  REPLY=$s
}

report::html() {
  local job row sev code msg k v f line jobs_rows="" find_rows="" metric_blocks="" rows
  local pipeline run host generated
  report::esc "${SLUICE_PIPELINE_NAME:-sluice}"
  pipeline=$REPLY
  report::esc "${SLUICE_RUN_ID:-adhoc}"
  run=$REPLY
  report::esc "${HOSTNAME:-unknown}"
  host=$REPLY
  time::iso_utc
  generated=$REPLY

  for job in "${R_JOBS[@]}"; do
    report::esc "${R_NOTE[$job]}"
    printf -v line '<tr><td>%s</td><td><span class="pill %s">%s</span></td><td class="num">%s</td><td class="num">%s</td><td class="note">%s</td></tr>\n' \
      "$job" "${R_STATE[$job]}" "${R_STATE[$job]}" "${R_TOOK[$job]}" "${R_ATTEMPTS[$job]}" "$REPLY"
    jobs_rows+=$line
  done
  for row in "${R_FINDINGS[@]}"; do
    IFS=$'\t' read -r _ sev job code msg <<< "$row"
    report::esc "$msg"
    printf -v line '<tr><td><span class="pill %s">%s</span></td><td>%s</td><td><code>%s</code></td><td>%s</td></tr>\n' \
      "$sev" "$sev" "$job" "$code" "$REPLY"
    find_rows+=$line
  done
  [[ -n $find_rows ]] || find_rows='<tr><td colspan="4" class="note">No findings.</td></tr>'
  for job in "${R_JOBS[@]}"; do
    f=$R_ARTIFACTS/$job/metrics.tsv
    [[ -s $f ]] || continue
    rows=""
    while IFS=$'\t' read -r k v; do
      report::esc "$k"
      k=$REPLY
      report::esc "$v"
      printf -v line '<tr><th>%s</th><td>%s</td></tr>' "$k" "$REPLY"
      rows+=$line
    done < "$f"
    printf -v line '<details><summary>%s</summary><table class="kv">%s</table></details>\n' "$job" "$rows"
    metric_blocks+=$line
  done

  cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${pipeline} - ${R_OVERALL}</title>
<style>
  :root { --bg:#f8fafc; --fg:#0f172a; --muted:#64748b; --card:#ffffff; --line:#e2e8f0;
          --ok:#15803d; --warn:#b45309; --bad:#b91c1c; --info:#0369a1; --skip:#475569; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0b1120; --fg:#e2e8f0; --muted:#94a3b8; --card:#111827; --line:#1f2937;
            --ok:#4ade80; --warn:#fbbf24; --bad:#f87171; --info:#38bdf8; --skip:#94a3b8; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 1040px; margin: 0 auto; padding: 32px 16px 64px; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 16px; margin-bottom: 8px; }
  h1 { font-size: 24px; margin: 0; }
  h2 { font-size: 17px; margin: 32px 0 12px; }
  .meta { color: var(--muted); margin: 0 0 8px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr:last-child > td, tr:last-child > th { border-bottom: 0; }
  thead th { color: var(--muted); font-weight: 600; font-size: 13px; }
  .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .note { color: var(--muted); }
  code { font-size: 13px; }
  .pill { display: inline-block; padding: 1px 10px; border-radius: 999px; font-size: 12px; font-weight: 600;
          border: 1px solid currentColor; text-transform: uppercase; letter-spacing: .03em; }
  .ok { color: var(--ok); } .warn, .medium { color: var(--warn); }
  .failed, .timeout, .critical, .high, .interrupted { color: var(--bad); }
  .low, .info { color: var(--info); } .skipped, .cancelled { color: var(--skip); }
  .status { font-size: 14px; padding: 3px 14px; }
  details { border-bottom: 1px solid var(--line); }
  details:last-child { border-bottom: 0; }
  summary { cursor: pointer; padding: 10px 12px; font-weight: 600; }
  .kv th { width: 40%; font-weight: 500; color: var(--muted); }
  footer { margin-top: 40px; color: var(--muted); font-size: 13px; }
</style>
</head>
<body data-run-id="${run}">
<main>
  <header>
    <h1>${pipeline}</h1>
    <span class="pill status ${R_OVERALL}">${R_OVERALL}</span>
  </header>
  <p class="meta">run <code>${run}</code> on <code>${host}</code> &middot; generated ${generated}</p>

  <h2>Jobs</h2>
  <div class="card"><table>
    <thead><tr><th>Job</th><th>State</th><th class="num">Duration</th><th class="num">Attempts</th><th>Note</th></tr></thead>
    <tbody>
${jobs_rows}    </tbody>
  </table></div>

  <h2>Findings (${#R_FINDINGS[@]})</h2>
  <div class="card"><table>
    <thead><tr><th>Severity</th><th>Job</th><th>Code</th><th>Finding</th></tr></thead>
    <tbody>
${find_rows}    </tbody>
  </table></div>

  <h2>Metrics</h2>
  <div class="card">
${metric_blocks}  </div>

  <footer>Generated by sluice ${SLUICE_VERSION}. Static page: no scripts, no external assets.</footer>
</main>
</body>
</html>
HTML
}

main "$@"
stage::finish
