# test_step7_cli_surface.sh — Step7 CLI surface contract tests
# runner.sh から source される

# --- msl provision removed (no dedicated compatibility message) ---
run_test_expect_fail "provision removed" "$MSL" provision

# --- explicit missing instance fails before VM attach ---
run_test_expect_fail_output "explicit missing instance" "instance 'missing-step7' not found" \
  "$MSL" --instance missing-step7 run true

# --- subcommand-side --instance is passed through command argv, not parsed globally ---
run_test_expect_fail_output "subcommand instance passthrough" "instance 'global-step7' not found" \
  "$MSL" --instance global-step7 run echo --instance inner-step7
