# test_cache_sharing_live.sh — Step23 live cache-sharing checks
# runner.sh から source される

if [ "${MSL_LIVE_TESTS:-0}" != "1" ]; then
  skip_test "step23 cache sharing integration" "set MSL_LIVE_TESTS=1 to enable"
  return 0
fi
if ! ensure_live_ready; then
  skip_test "step23 cache sharing integration" "$LIVE_READY_REASON"
  return 0
fi

CACHE_INSTANCE="$("$MSL" list 2>/dev/null | sed -e 's/ \[default\]$//' | awk '{print $1}' | head -n 1)"

if [ -z "$CACHE_INSTANCE" ]; then
  skip_test "step23 cache sharing integration" "no installed instance"
  return 0
fi
HOST_CACHE_ROOT="$HOME/Library/Application Support/msl/caches"
METADATA_FILE="${MSL_HOME:-$HOME}/Library/Application Support/msl/distros/$CACHE_INSTANCE/metadata.json"

run_test "step23 stop before cache-sharing checks" "$MSL" stop --all
run_test_output "step23 metadata has cacheSharing" "\"cacheSharing\"" \
  /bin/sh -lc "cat \"$METADATA_FILE\""

run_test_output "step23 cache status enabled" "enabled=true" \
  "$MSL" cache status
run_test_output "step23 cache status rust disabled by default" "tool.rust=false" \
  "$MSL" cache status

run_test "step23 apt archives bind mount when apt exists" \
  "$MSL" --instance "$CACHE_INSTANCE" run --timeout 30 sh -lc 'if command -v apt-get >/dev/null 2>&1; then awk '"'"'$5=="/var/cache/apt/archives"{found=1} END{exit(found?0:1)}'"'"' /proc/self/mountinfo; else exit 0; fi'
run_test "step23 apt lists bind mount when apt exists" \
  "$MSL" --instance "$CACHE_INSTANCE" run --timeout 30 sh -lc 'if command -v apt-get >/dev/null 2>&1; then awk '"'"'$5=="/var/lib/apt/lists"{found=1} END{exit(found?0:1)}'"'"' /proc/self/mountinfo; else exit 0; fi'
run_test "step23 apk bind mount when apk exists" \
  "$MSL" --instance "$CACHE_INSTANCE" run --timeout 30 sh -lc 'if command -v apk >/dev/null 2>&1; then awk '"'"'$5=="/var/cache/apk"{found=1} END{exit(found?0:1)}'"'"' /proc/self/mountinfo; else exit 0; fi'
run_test "step23 host cache apt dir created" test -d "$HOST_CACHE_ROOT/apt"
run_test "step23 host cache apk dir created" test -d "$HOST_CACHE_ROOT/apk"

run_test "step23 stop after cache-sharing checks" "$MSL" stop --all
