#!/usr/bin/env bash
#
# Runs the action's real steps against the mock API and asserts the outcomes.
#
# The steps are extracted from action.yml rather than copied, so this cannot
# drift from what actually ships. GitHub's `${{ inputs.x }}` expressions are
# substituted with the env vars the workflow would have provided.
#
#   bash ./script/test-local.sh
#
# Invoked via `bash` in docs and CI so it works even where the executable bit
# was lost (a web-UI upload or plain file copy drops mode 100755).
#
set -uo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-8787}"
API_BASE="http://127.0.0.1:$PORT"
PASSES=0
FAILURES=0

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "pip install pyyaml first"; exit 1; }

# Pull one step's script out of action.yml and resolve the expressions it uses.
extract_step() {
  python3 - "$1" <<'PY'
import re, sys, yaml
name = sys.argv[1]
steps = yaml.safe_load(open("action.yml"))["runs"]["steps"]
step = next(s for s in steps if s["name"] == name)
script = step["run"]
# `${{ inputs.foo-bar }}` and `${{ steps.x.outputs.foo }}` become $FOO_BAR / $FOO,
# which the harness exports below. Everything else expands to empty.
def sub(m):
    expr = m.group(1).strip()
    if expr.startswith("inputs."):
        return "${" + expr.split(".", 1)[1].replace("-", "_").upper() + ":-}"
    if expr.startswith("steps.") and ".outputs." in expr:
        return "${" + expr.rsplit(".", 1)[1].replace("-", "_").upper() + ":-}"
    if expr == "github.token":
        return "${GH_TOKEN:-}"
    return ""
print(re.sub(r"\$\{\{(.*?)\}\}", sub, script))
PY
}

# GITHUB_OUTPUT lines become shell vars for the next step, the way the runner does it.
load_outputs() {
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    export "$(echo "$k" | tr 'a-z-' 'A-Z_')"="$v"
  done < "$GITHUB_OUTPUT"
}

assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "    ok   $label"
    PASSES=$((PASSES + 1))
  else
    echo "    FAIL $label — expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

run_scenario() {
  local scenario="$1" expect_submit_rc="$2" expect_gate_rc="$3"
  shift 3

  echo ""
  echo "── $scenario ──"

  SCENARIO="$scenario" PORT="$PORT" POLLS_BEFORE_DONE=1 \
    python3 script/mock_api.py &
  local mock_pid=$!
  # Wait for the port instead of sleeping a fixed amount.
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "$API_BASE/v1/scan/x/status" && break
    sleep 0.1
  done

  local workdir
  workdir=$(mktemp -d)
  export GITHUB_OUTPUT="$workdir/out"
  export GITHUB_STEP_SUMMARY="$workdir/summary"
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"

  # Inputs, as the workflow would supply them.
  export API_KEY="test-key" API_BASE URL="https://example.com"
  export MIN_SCORE="${MIN_SCORE_OVERRIDE:-80}" SCAN_MODE="${SCAN_MODE_OVERRIDE:-single}"
  export MAX_PAGES="${MAX_PAGES_OVERRIDE:-1}" INCLUDE_SUBDOMAINS="true"
  export AUTH_TARGET="${AUTH_TARGET_OVERRIDE:-}" FAIL_ON_SCAN_ERROR="${FAIL_ON_SCAN_ERROR_OVERRIDE:-false}"
  export MAX_WAIT_MINUTES="2" COMMENT_ON_PR="false"
  export IDEMPOTENCY_KEY="${IDEMPOTENCY_KEY_OVERRIDE:-}"
  export SCAN_URL="$URL"
  # Simulate the runner environment so the default idempotency key is derived.
  export GITHUB_RUN_ID="${GITHUB_RUN_ID_OVERRIDE:-99887766}" GITHUB_RUN_ATTEMPT="2"

  # Stable path so per-scenario checks can grep the submit output (the workdir
  # is torn down before the run returns).
  bash -c "$(extract_step 'Submit scan')" >/tmp/adaguard_test_submit.log 2>&1
  local submit_rc=$?
  cp /tmp/adaguard_test_submit.log "$workdir/submit.log"
  assert "submit exit code" "$expect_submit_rc" "$submit_rc"

  if [ "$submit_rc" -eq 0 ]; then
    load_outputs
    : > "$GITHUB_OUTPUT"
    bash -c "$(extract_step 'Wait for results')" >"$workdir/poll.log" 2>&1
    assert "poll exit code" "0" "$?"
    load_outputs

    : > "$GITHUB_OUTPUT"
    bash -c "$(extract_step 'Report')" >"$workdir/report.log" 2>&1
    load_outputs

    bash -c "$(extract_step 'Apply gate')" >"$workdir/gate.log" 2>&1
    assert "gate exit code" "$expect_gate_rc" "$?"
  fi

  # Extra per-scenario assertions passed in as "description|expected|actual-command".
  local check
  for check in "$@"; do
    local desc="${check%%|*}"; local rest="${check#*|}"
    local exp="${rest%%|*}"; local cmd="${rest#*|}"
    assert "$desc" "$exp" "$(eval "$cmd" 2>/dev/null)"
  done

  kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null
  rm -rf "$workdir"
  unset SCORE PASSED CRITICAL WARNING INFO PAGES SCAN_STATUS AUTH_STATUS SCAN_ID ERROR
}

echo "Testing the action against the mock API"

run_scenario pass 0 0 \
  "score is 91|91|echo \$SCORE" \
  "passed is true|true|echo \$PASSED" \
  "sends scan_mode single|single|jq -r .scan_mode /tmp/adaguard_mock_request.json" \
  "sends min_score as a number|number|jq -r '.min_score|type' /tmp/adaguard_mock_request.json" \
  "omits max_pages in single mode|null|jq -r '.max_pages' /tmp/adaguard_mock_request.json" \
  "derives idempotency key from run+attempt+URL|gha-99887766-2-100680ad546c|jq -r '.\"idempotency-key\"' /tmp/adaguard_mock_headers.json"

# An explicit key must win over the derived default.
IDEMPOTENCY_KEY_OVERRIDE="my-own-key" run_scenario pass 0 0 \
  "explicit idempotency key is used verbatim|my-own-key|jq -r '.\"idempotency-key\"' /tmp/adaguard_mock_headers.json"

# A replay returns an already-completed scan; the action must still succeed and gate on it.
run_scenario idempotent_replay 0 0 \
  "replay still produces a score|91|echo \$SCORE"

run_scenario fail_score 0 1 \
  "score is 42|42|echo \$SCORE" \
  "passed is false|false|echo \$PASSED"

# The one both earlier versions got wrong: a high score must still fail, and the
# message must blame the expired session rather than the score.
run_scenario expired_fallback 0 1 \
  "score is high|95|echo \$SCORE" \
  "passed is false despite the score|false|echo \$PASSED" \
  "auth_status surfaced|expired_fallback|echo \$AUTH_STATUS"

run_scenario scan_error 0 0 \
  "scan status failed|failed|echo \$SCAN_STATUS"

FAIL_ON_SCAN_ERROR_OVERRIDE=true run_scenario scan_error 0 1

run_scenario unauthorized 1 0

# Both 429s fail the build, but must be told apart in the message: quota won't
# clear by retrying, the hourly throttle will.
run_scenario quota 1 0 \
  "quota message names it as quota|1|grep -ci 'quota' /tmp/adaguard_test_submit.log" \
  "quota message shows usage|1|grep -c '30/30' /tmp/adaguard_test_submit.log" \
  "quota message does NOT call it transient|0|grep -ci 'transient' /tmp/adaguard_test_submit.log"

run_scenario rate_limit 1 0 \
  "rate-limit message says transient|1|grep -ci 'transient' /tmp/adaguard_test_submit.log" \
  "rate-limit message surfaces retry-after|1|grep -c '42s' /tmp/adaguard_test_submit.log" \
  "rate-limit message does NOT say quota reached|0|grep -ci 'quota reached' /tmp/adaguard_test_submit.log"

SCAN_MODE_OVERRIDE=crawl MAX_PAGES_OVERRIDE=25 \
run_scenario pass 0 0 \
  "sends max_pages in crawl mode|25|jq -r '.max_pages' /tmp/adaguard_mock_request.json" \
  "sends include_subdomains as a bool|boolean|jq -r '.include_subdomains|type' /tmp/adaguard_mock_request.json" \
  "never sends the ignored exclude_paths field|null|jq -r '.exclude_paths' /tmp/adaguard_mock_request.json" \
  "never sends the ignored viewport field|null|jq -r '.viewport' /tmp/adaguard_mock_request.json"

AUTH_TARGET_OVERRIDE=latest run_scenario pass 0 0 \
  "sends auth_target, not the legacy field|latest|jq -r '.auth_target' /tmp/adaguard_mock_request.json" \
  "never sends auth_session_id|null|jq -r '.auth_session_id' /tmp/adaguard_mock_request.json"

echo ""
echo "──────────────────────────────"
echo "$PASSES passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ] || exit 1
