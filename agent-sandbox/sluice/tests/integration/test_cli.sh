#!/usr/bin/env bash

test_demo_runs_the_whole_nightly_pipeline() {
  local run state job
  assert::rc 0 t::sluice demo --no-color
  t::latest_run
  run=$REPLY
  t::meta "$run" status
  assert::eq warn "$REPLY" "the demo is designed to produce findings"
  for job in preflight host-facts backup backup-verify report; do
    t::status "$run" "$job"
    assert::eq ok "$S_STATE" "$job"
  done
  for job in log-insights ssh-audit; do
    t::status "$run" "$job"
    assert::eq warn "$S_STATE" "$job"
  done
  t::status "$run" notify
  assert::eq skipped "$S_STATE" "no webhook configured"
  if core::have openssl; then
    t::status "$run" cert-expiry
    assert::eq warn "$S_STATE" "cert-expiry"
  fi
  t::status "$run" publish
  if core::can_symlink "$TEST_TMP"; then
    assert::eq ok "$S_STATE" "publish"
    assert::file "$SLUICE_VAR_DIR/demo/www/current/index.html"
  else
    assert::eq skipped "$S_STATE" "publish without symlink support"
  fi
  assert::contains "$(< "$run/artifacts/report/report.md")" "## Findings"
  assert::contains "$(< "$run/artifacts/ssh-audit/findings.tsv")" "50-cloud-init.conf:1"
  assert::json "$run/artifacts/report/report.json"
  assert::json "$run/artifacts/notify/payload.json"
  assert::contains "$T_OUT" "parallelism x"
  for state in "$run"/env.snapshot "$run"/events.jsonl "$run"/pipeline.ini; do
    assert::file "$state"
  done
}

test_second_demo_run_reuses_the_workspace_and_history() {
  local first second
  t::sluice demo -q > /dev/null 2>&1
  t::latest_run
  first=${REPLY##*/}
  t::sluice demo -q > /dev/null 2>&1
  t::latest_run
  second=${REPLY##*/}
  assert::ne "$first" "$second"
  assert::rc 0 t::sluice runs
  assert::contains "$T_OUT" "$first"
  assert::contains "$T_OUT" "$second"
  assert::rc 0 t::sluice show "${second:0:20}"
  assert::contains "$T_OUT" "backup-verify"
  assert::rc 0 t::sluice show latest ssh-audit
  assert::contains "$T_OUT" "==> stderr.log <=="
}

test_plan_graph_and_validate_describe_the_pipeline() {
  assert::rc 0 t::sluice plan
  assert::contains "$T_OUT" "wave 2 |  host-facts  log-insights  ssh-audit  fs-audit  cert-expiry  backup"
  assert::rc 0 t::sluice graph
  assert::contains "$T_OUT" 'digraph "nightly-ops" {'
  assert::contains "$T_OUT" '"backup" -> "backup-verify";'
  assert::contains "$T_OUT" '"report" [tooltip="Markdown, JSON and HTML report of the whole run", peripheries=2];'
  assert::rc 0 t::sluice validate
  assert::contains "$T_OUT" "OK (11 jobs, 5 waves)"
}

test_usage_errors_exit_64() {
  assert::rc 64 t::sluice frobnicate
  assert::rc 64 t::sluice run --jobs zero
  assert::rc 64 t::sluice run --bogus-option
  assert::rc 64 t::sluice show no-such-run
  assert::rc 0 t::sluice help
  assert::contains "$T_OUT" "Usage:"
  assert::rc 0 t::sluice version
  assert::match "$T_OUT" '^sluice [0-9]+\.[0-9]+\.[0-9]+ '
}

test_bundled_short_options_are_expanded() {
  t::write p.ini <<'INI'
[pipeline]
name = bundles
[job a]
run = true
INI
  assert::rc 0 t::sluice run p.ini -nqj2
  t::latest_run
  assert::contains "$(< "$REPLY/env.snapshot")" "SLUICE_DRY_RUN=1"
}

test_secrets_are_redacted_in_the_environment_snapshot() {
  t::write p.ini <<'INI'
[pipeline]
name = secrets
[job a]
run = true
INI
  SLUICE_WEBHOOK_URL=https://hooks.example.test/T000/B000/TOPSECRET assert::rc 0 t::sluice run p.ini
  t::latest_run
  assert::contains "$(< "$REPLY/env.snapshot")" "SLUICE_WEBHOOK_URL=\\<redacted\\>"
  assert::not_contains "$(< "$REPLY/env.snapshot")" TOPSECRET
}
