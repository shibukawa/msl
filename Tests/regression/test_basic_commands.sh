# test_basic_commands.sh — 基本コマンド実行テスト
# runner.sh から source される

if ! "$MSL" list 2>/dev/null | grep -q .; then
  skip_test "basic command tests" "no installed instance"
  return 0
fi
if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "basic command tests" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "basic command tests" "$LIVE_READY_REASON"
  return 0
fi

# --- echo ---
run_test_output "echo hello" "hello" "$MSL" run echo hello

# --- exit code: true → 0 ---
run_test "exit code pass (true)" "$MSL" run true

# --- exit code: false → non-zero ---
run_test_expect_fail "exit code fail (false)" "$MSL" run false

# --- uname → Linux ---
run_test_output "uname -s" "Linux" "$MSL" run uname -s

# --- whoami → current runtime user ---
run_test_output "whoami" "${USER:-}" "$MSL" run whoami

# --- multi-arg command ---
run_test_output "echo multi args" "hello world" "$MSL" run echo hello world

# --- environment: PATH exists ---
run_test_output "env PATH" "PATH=" "$MSL" run env

# --- cat /etc/os-release → Ubuntu ---
run_test_output "os-release Ubuntu" "Ubuntu" "$MSL" run cat /etc/os-release

# --- timeout: fast command within timeout ---
run_test_output "run with timeout" "done" "$MSL" run --timeout 10 echo done

# --- timeout: slow command exceeds timeout ---
run_test_expect_fail "run timeout exceeded" "$MSL" run --timeout 1 sleep 30

# --- status check ---
run_test "msl status" "$MSL" status
