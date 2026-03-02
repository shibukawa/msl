# test_filesystem.sh — ファイルシステム共有テスト
# runner.sh から source される

if ! "$MSL" --list 2>/dev/null | grep -q .; then
  skip_test "filesystem tests" "no installed instance"
  return 0
fi
if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "filesystem tests" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "filesystem tests" "$LIVE_READY_REASON"
  return 0
fi

# --- /mnt/msl exists (macOS shared dir) ---
run_test "shared dir /mnt/msl exists" "$MSL" run test -d /mnt/msl

# --- home directory is bind-mounted ---
run_test "home dir exists" "$MSL" run test -d /root

# --- write and read a temp file ---
run_test_output "write and read file" "msl-test-ok" \
  "$MSL" run sh -c 'echo msl-test-ok > /tmp/msl-regtest && cat /tmp/msl-regtest && rm /tmp/msl-regtest'

# --- /proc and /sys exist ---
run_test "proc filesystem" "$MSL" run test -d /proc
run_test "proc meminfo readable" "$MSL" run test -r /proc/meminfo
run_test "free command works" "$MSL" run sh -lc "free >/dev/null"
run_test "sys filesystem" "$MSL" run test -d /sys

# --- /dev/null works ---
run_test "dev null" "$MSL" run sh -c 'echo test > /dev/null'
