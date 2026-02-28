#!/bin/bash
# runner.sh — msl リグレッションテスト実行
# 前提: install 済み instance がある場合は run 系テストも実行可能
set -uo pipefail

MSL="${MSL:-./.build/debug/msl}"
MSL_LIVE_TESTS="${MSL_LIVE_TESTS:-0}"
PASSED=0
FAILED=0
SKIPPED=0
ERRORS=()

# --- helpers ---

run_test() {
  local name="$1"; shift
  echo -n "  $name ... "
  local output
  if output=$("$@" 2>&1); then
    ((PASSED++))
    echo "PASS"
    return 0
  else
    local rc=$?
    ((FAILED++))
    ERRORS+=("$name (rc=$rc)")
    echo "FAIL (rc=$rc)"
    if [ -n "$output" ]; then
      echo "    output: $(echo "$output" | head -3)"
    fi
    return 1
  fi
}

# run_test_expect_fail: expects the command to return non-zero
run_test_expect_fail() {
  local name="$1"; shift
  echo -n "  $name ... "
  local output
  if output=$("$@" 2>&1); then
    ((FAILED++))
    ERRORS+=("$name (expected failure but got rc=0)")
    echo "FAIL (expected non-zero exit)"
    return 1
  else
    ((PASSED++))
    echo "PASS"
    return 0
  fi
}

# run_test_expect_fail_output: expects non-zero and output contains expected string
run_test_expect_fail_output() {
  local name="$1"
  local expected="$2"
  shift 2
  echo -n "  $name ... "
  local output
  if output=$("$@" 2>&1); then
    ((FAILED++))
    ERRORS+=("$name (expected failure but got rc=0)")
    echo "FAIL (expected non-zero exit)"
    return 1
  else
    if echo "$output" | grep -q "$expected"; then
      ((PASSED++))
      echo "PASS"
      return 0
    fi
    ((FAILED++))
    ERRORS+=("$name (expected output missing '$expected')")
    echo "FAIL (output missing '$expected')"
    echo "    got: $(echo "$output" | head -3)"
    return 1
  fi
}

# run_test_output: run command and check output contains expected string
run_test_output() {
  local name="$1"
  local expected="$2"
  shift 2
  echo -n "  $name ... "
  local output
  if output=$("$@" 2>&1); then
    if echo "$output" | grep -q "$expected"; then
      ((PASSED++))
      echo "PASS"
      return 0
    else
      ((FAILED++))
      ERRORS+=("$name (output missing '$expected')")
      echo "FAIL (output missing '$expected')"
      echo "    got: $(echo "$output" | head -3)"
      return 1
    fi
  else
    local rc=$?
    ((FAILED++))
    ERRORS+=("$name (rc=$rc)")
    echo "FAIL (rc=$rc)"
    return 1
  fi
}

skip_test() {
  local name="$1"
  local reason="$2"
  echo "  $name ... SKIP ($reason)"
  ((SKIPPED++))
}

# --- banner ---
echo "=== msl regression tests ==="
echo "MSL=$MSL"
echo "MSL_LIVE_TESTS=$MSL_LIVE_TESTS"
echo ""

# --- source test files ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for t in "$SCRIPT_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  echo "[$(basename "$t")]"
  source "$t"
  echo ""
done

# --- summary ---
echo "=== Results: $PASSED passed, $FAILED failed, $SKIPPED skipped ==="
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "Failures:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi
[ "$FAILED" -eq 0 ] || exit 1
