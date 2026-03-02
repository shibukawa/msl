# test_networking.sh — ネットワーク疎通テスト
# runner.sh から source される

if ! "$MSL" --list 2>/dev/null | grep -q .; then
  skip_test "networking tests" "no installed instance"
  return 0
fi
if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "networking tests" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "networking tests" "$LIVE_READY_REASON"
  return 0
fi

# --- loopback interface ---
run_test_output "loopback interface" "lo" "$MSL" run ip link show lo

# --- DNS resolution (check /etc/resolv.conf exists) ---
run_test "resolv.conf exists" "$MSL" run test -f /etc/resolv.conf

# --- ping localhost (1 packet, 2s timeout) ---
run_test "ping localhost" "$MSL" run --timeout 5 ping -c 1 -W 2 127.0.0.1

# --- curl / wget availability check ---
# These may not be installed in the base image, so we skip if not found
if "$MSL" run which curl >/dev/null 2>&1; then
  run_test "curl localhost reachable" "$MSL" run --timeout 5 curl -sf -o /dev/null http://localhost/ || true
else
  skip_test "curl connectivity" "curl not installed in guest"
fi
