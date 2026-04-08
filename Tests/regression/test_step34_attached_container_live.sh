# test_step34_attached_container_live.sh — Step34 attached-container live smoke checks
# runner.sh から source される

MSL_HOME_DIR="${MSL_HOME:-$HOME}"
APP_SUPPORT_DIR="$MSL_HOME_DIR/Library/Application Support/msl"
MSL_LOG_FILE="$APP_SUPPORT_DIR/runtime/logs/msl.log"

if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "step34 attached-container live" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "step34 attached-container live" "$LIVE_READY_REASON"
  return 0
fi
if ! command -v curl >/dev/null 2>&1; then
  skip_test "step34 attached-container live" "curl not installed"
  return 0
fi

STEP34_INSTANCE="$("$MSL" list 2>/dev/null | sed -e 's/ \[default\]$//' | awk 'NR==1 {print $1}')"
if [ -z "$STEP34_INSTANCE" ]; then
  skip_test "step34 attached-container live" "no installed instance"
  return 0
fi

run_test "step34 stop before live checks" "$MSL" stop --all
run_test "step34 boot instance" "$MSL" --instance "$STEP34_INSTANCE" run --timeout 20 true

STEP34_SOCKET="$(ls -t /tmp/msl-attached-*.sock 2>/dev/null | head -1)"
if [ -z "$STEP34_SOCKET" ]; then
  skip_test "step34 docker api smoke" "attached socket not found under /tmp"
  return 0
fi

run_test_output "step34 version endpoint" "\"ApiVersion\":\"1.41\"" \
  /bin/sh -lc "curl -fsS --unix-socket '$STEP34_SOCKET' http://localhost/v1.41/version"

run_test_output "step34 containers endpoint" "\"Id\":\"msl-" \
  /bin/sh -lc "curl -fsS --unix-socket '$STEP34_SOCKET' http://localhost/v1.41/containers/json"

STEP34_VM_ID="$(curl -fsS --unix-socket "$STEP34_SOCKET" http://localhost/v1.41/containers/json | sed -n 's/.*\"Id\":\"\\([^\"]*\\)\".*/\\1/p' | head -1)"
if [ -z "$STEP34_VM_ID" ]; then
  skip_test "step34 exec smoke" "failed to parse vm id from containers/json"
  return 0
fi

STEP34_EXEC_ID="$(curl -fsS --unix-socket "$STEP34_SOCKET" -X POST -H 'Content-Type: application/json' \
  -d '{"Cmd":["/bin/sh","-lc","echo step34-attached"],"Tty":false}' \
  "http://localhost/v1.41/containers/$STEP34_VM_ID/exec" | sed -n 's/.*\"Id\":\"\\([^\"]*\\)\".*/\\1/p' | head -1)"
if [ -z "$STEP34_EXEC_ID" ]; then
  skip_test "step34 exec smoke" "failed to parse exec id"
  return 0
fi

run_test_output "step34 exec start returns 101" "101 Switching Protocols" \
  /bin/sh -lc "curl -i -sS --max-time 5 --unix-socket '$STEP34_SOCKET' -X POST -H 'Content-Type: application/json' -d '{\"Detach\":false,\"Tty\":false}' 'http://localhost/v1.41/exec/$STEP34_EXEC_ID/start' || true"

run_test_output "step34 observability attached_api_request" "ok" \
  /bin/sh -lc "grep -q '\"event\":\"attached_api_request\"' '$MSL_LOG_FILE' && echo ok"
run_test_output "step34 observability attached_exec_started" "ok" \
  /bin/sh -lc "grep -q '\"event\":\"attached_exec_started\"' '$MSL_LOG_FILE' && echo ok"

run_test "step34 stop after live checks" "$MSL" stop --all
