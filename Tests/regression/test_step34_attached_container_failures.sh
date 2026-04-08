# test_step34_attached_container_failures.sh — Step34 failure-injection checks
# runner.sh から source される

MSL_HOME_DIR="${MSL_HOME:-$HOME}"
APP_SUPPORT_DIR="$MSL_HOME_DIR/Library/Application Support/msl"
MSL_LOG_FILE="$APP_SUPPORT_DIR/runtime/logs/msl.log"

if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "step34 attached-container failures" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "step34 attached-container failures" "$LIVE_READY_REASON"
  return 0
fi
if ! command -v curl >/dev/null 2>&1; then
  skip_test "step34 attached-container failures" "curl not installed"
  return 0
fi

STEP34_INSTANCE="$("$MSL" list 2>/dev/null | sed -e 's/ \[default\]$//' | awk 'NR==1 {print $1}')"
if [ -z "$STEP34_INSTANCE" ]; then
  skip_test "step34 attached-container failures" "no installed instance"
  return 0
fi

run_test "step34 failures stop before checks" "$MSL" stop --all
run_test "step34 failures boot instance" "$MSL" --instance "$STEP34_INSTANCE" run --timeout 20 true

STEP34_SOCKET="$(ls -t /tmp/msl-attached-*.sock 2>/dev/null | head -1)"
if [ -z "$STEP34_SOCKET" ]; then
  skip_test "step34 failure API checks" "attached socket not found under /tmp"
  return 0
fi

run_test_output "step34 unsupported endpoint rejected" "docker_api_unsupported_endpoint" \
  /bin/sh -lc "curl -sS --unix-socket '$STEP34_SOCKET' http://localhost/v1.41/unsupported || true"

run_test_output "step34 unknown container rejected" "container_not_found" \
  /bin/sh -lc "curl -sS --unix-socket '$STEP34_SOCKET' -X POST -H 'Content-Type: application/json' -d '{\"Cmd\":[\"/bin/sh\"]}' http://localhost/v1.41/containers/no-such/exec || true"

run_test_output "step34 api reject log emitted" "ok" \
  /bin/sh -lc "grep -q '\"event\":\"attached_api_rejected\"' '$MSL_LOG_FILE' && echo ok"

# F4: host code CLI missing path injection should emit code_cli_not_found.
# Keep an absolute MSL path so PATH override only affects child process lookup.
run_test "step34 code-open request under PATH=/bin" \
  /bin/sh -lc "PATH=/bin '$MSL' --instance '$STEP34_INSTANCE' run --timeout 10 code . >/dev/null 2>&1 || true"

run_test_output "step34 code_cli_not_found logged" "ok" \
  /bin/sh -lc "grep -q '\"event\":\"attached_open_failed\"' '$MSL_LOG_FILE' && grep -q '\"reason\":\"code_cli_not_found\"' '$MSL_LOG_FILE' && echo ok"

run_test "step34 failures stop after checks" "$MSL" stop --all
