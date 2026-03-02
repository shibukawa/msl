# test_step7_runtime_live.sh — Step7 live runtime integration checks
# runner.sh から source される

MSL_HOME_DIR="${MSL_HOME:-$HOME}"
APP_SUPPORT_DIR="$MSL_HOME_DIR/Library/Application Support/msl"

if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "step7 live runtime integration" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "step7 live runtime integration" "$LIVE_READY_REASON"
  return 0
fi

STEP7_INSTANCE_LIST="$("$MSL" --list 2>/dev/null | sed -e 's/ \[default\]$//' | awk '{print $1}')"
STEP7_INSTANCE="$(printf "%s\n" "$STEP7_INSTANCE_LIST" | sed -n '1p')"
STEP7_SECOND_INSTANCE="$(printf "%s\n" "$STEP7_INSTANCE_LIST" | sed -n '2p')"

if [ -z "$STEP7_INSTANCE" ]; then
  skip_test "step7 live boot/attach" "no installed instance"
  skip_test "step7 no-seed boot path" "no installed instance"
  skip_test "step7 diagnostic logs" "no installed instance"
  skip_test "step7 instance mismatch guidance" "no installed instance"
  return 0
fi

# Clean start to make instance selection deterministic.
run_test "step7 stop before live checks" "$MSL" --stop

# I1/I3/I5: explicit instance run succeeds through Step7 boot path.
run_test_output "step7 explicit instance uname" "Linux" \
  "$MSL" --instance "$STEP7_INSTANCE" run --timeout 30 uname -s
run_test_output "step7 run timeout command" "step7-live-ok" \
  "$MSL" --instance "$STEP7_INSTANCE" run --timeout 30 echo step7-live-ok

# I4: seed.iso absence must not block normal boot path.
STEP7_SEED_ISO="$APP_SUPPORT_DIR/distros/$STEP7_INSTANCE/seed.iso"
if [ -f "$STEP7_SEED_ISO" ]; then
  rm -f "$STEP7_SEED_ISO"
fi
run_test_output "step7 boot without seed.iso" "Linux" \
  "$MSL" --instance "$STEP7_INSTANCE" run --timeout 30 uname -s

# I6/I9: forwarded logs and runtime observability should be available.
STEP7_LOG_DIR="$APP_SUPPORT_DIR/logs/instances/$STEP7_INSTANCE"
STEP7_DAEMON_LOG="$APP_SUPPORT_DIR/runtime/logs/daemon.log"

run_test "step7 diagnostic log dir exists" test -d "$STEP7_LOG_DIR"
run_test "step7 init log exists" test -f "$STEP7_LOG_DIR/init.log"
run_test "step7 kernel log exists" test -f "$STEP7_LOG_DIR/kernel.log"
run_test "step7 daemon has runtime_target_resolved" grep -q "runtime_target_resolved" "$STEP7_DAEMON_LOG"
run_test "step7 daemon has kernel_profile_resolved" grep -q "kernel_profile_resolved" "$STEP7_DAEMON_LOG"
run_test "step7 daemon has init_handshake" grep -q "init_handshake_" "$STEP7_DAEMON_LOG"

# I2: mismatch guidance when a different instance is requested against running daemon.
if [ -n "$STEP7_SECOND_INSTANCE" ]; then
  run_test_expect_fail_output "step7 instance mismatch guidance" "run \`msl --stop\` before switching" \
    "$MSL" --instance "$STEP7_SECOND_INSTANCE" run --timeout 5 true
else
  skip_test "step7 instance mismatch guidance" "requires 2 instances"
fi

run_test "step7 stop after live checks" "$MSL" --stop
