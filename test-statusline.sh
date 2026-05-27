#!/usr/bin/env bash
# Test suite for statusline-command.sh

SCRIPT="statusline-command.sh"
TMPFILE="${TMPDIR:-/tmp}/sl_stderr_$$"
PASS=0
FAIL=0
TOTAL=0

run_test() {
  local name="$1" json="$2"
  TOTAL=$((TOTAL + 1))
  local errors=""

  # Capture stdout and stderr separately
  local stdout exit_code
  stdout=$(echo "$json" | bash "$SCRIPT" 2>"$TMPFILE")
  exit_code=$?
  local stderr
  stderr=$(cat "$TMPFILE" 2>/dev/null)

  # Test 1: exit code 0
  if [ "$exit_code" -ne 0 ]; then
    errors="${errors}\n    EXIT CODE: $exit_code (expected 0)"
  fi

  # Test 2: exactly 1 line of output
  local line_count
  line_count=$(printf '%s' "$stdout" | wc -l | tr -d ' ')
  # wc -l counts newlines; a single line with no trailing newline = 0, with = 1
  # printf '%s' strips trailing newline, so single line = 0
  if [ "$line_count" -ne 0 ]; then
    errors="${errors}\n    LINE COUNT: $((line_count + 1)) lines (expected 1)"
  fi

  # Test 3: no stderr output (jq errors, etc.)
  if [ -n "$stderr" ]; then
    errors="${errors}\n    STDERR: $(echo "$stderr" | head -1)"
  fi

  # Test 4: output is non-empty
  if [ -z "$stdout" ]; then
    errors="${errors}\n    OUTPUT: empty"
  fi

  # Test 5: ends with reset sequence
  local raw
  raw=$(printf '%s' "$stdout" | cat -v)
  if ! echo "$raw" | grep -qF '[0m'; then
    errors="${errors}\n    TRAILING RESET: missing"
  fi

  if [ -z "$errors" ]; then
    PASS=$((PASS + 1))
    printf "  \033[32m✓\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "  \033[31m✗\033[0m %s%b\n" "$name" "$errors"
  fi
}

echo ""
echo "━━━ Statusline Test Suite ━━━"
echo ""

# --- Scenario 1: Full payload, output_style as string ---
run_test "Full payload (style=string)" '{
  "workspace":{"current_dir":"/Users/tedserbinski/Documents/projects"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":4.2},
  "cost":{"total_lines_added":35,"total_lines_removed":31},
  "rate_limits":{"five_hour":{"used_percentage":2.1}},
  "output_style":"Explanatory",
  "session_name":"statusline",
  "session_id":"abc12345-def6-7890-abcd-ef1234567890",
  "effortLevel":"high"
}'

# --- Scenario 2: Full payload, output_style as object ---
run_test "Full payload (style=object)" '{
  "workspace":{"current_dir":"/Users/tedserbinski/Documents/projects"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":55},
  "cost":{"total_lines_added":100,"total_lines_removed":50},
  "rate_limits":{"five_hour":{"used_percentage":45}},
  "output_style":{"name":"Learning"},
  "session_name":"test-session",
  "session_id":"abc12345"
}'

# --- Scenario 3: Unnamed session ---
run_test "Unnamed session (shows [id])" '{
  "workspace":{"current_dir":"/Users/tedserbinski/Documents/projects"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":10},
  "session_name":"",
  "session_id":"abc12345-def6-7890"
}'

# --- Scenario 4: No session at all ---
run_test "No session info (shows [none])" '{
  "workspace":{"current_dir":"/Users/tedserbinski/Documents/projects"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":10}
}'

# --- Scenario 5: Empty JSON ---
run_test "Empty JSON object" '{}'

# --- Scenario 6: Red thresholds ---
run_test "High usage (red bars, >=80%)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Sonnet 4.6"},
  "context_window":{"used_percentage":92},
  "rate_limits":{"five_hour":{"used_percentage":85}}
}'

# --- Scenario 7: Yellow thresholds ---
run_test "Medium usage (yellow bars, 50-79%)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Haiku 4.5"},
  "context_window":{"used_percentage":65},
  "rate_limits":{"five_hour":{"used_percentage":55}}
}'

# --- Scenario 8: Green/zero ---
run_test "Zero usage (green bars)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":0},
  "rate_limits":{"five_hour":{"used_percentage":0}}
}'

# --- Scenario 9: 100% ---
run_test "100% usage (full bars)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":100},
  "rate_limits":{"five_hour":{"used_percentage":100}}
}'

# --- Scenario 10: Boundary values ---
run_test "Boundary: exactly 50%" '{
  "context_window":{"used_percentage":50},
  "rate_limits":{"five_hour":{"used_percentage":50}}
}'

run_test "Boundary: exactly 80%" '{
  "context_window":{"used_percentage":80},
  "rate_limits":{"five_hour":{"used_percentage":80}}
}'

# --- Scenario 11: Vim mode ---
run_test "Vim mode active" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"},
  "vim":{"mode":"NORMAL"},
  "context_window":{"used_percentage":10}
}'

# --- Scenario 12: Default style (hidden) ---
run_test "Default style (hidden)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"},
  "output_style":"default",
  "context_window":{"used_percentage":10}
}'

# --- Scenario 13: Null style ---
run_test "Null output_style" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"},
  "output_style":null,
  "context_window":{"used_percentage":10}
}'

# --- Scenario 14: Effort levels ---
run_test "Effort: low (effortLevel key)" '{
  "model":{"display_name":"Claude Opus 4.6"},
  "effortLevel":"low"
}'

run_test "Effort: medium (effort_level key)" '{
  "model":{"display_name":"Claude Opus 4.6"},
  "effort_level":"medium"
}'

# --- Scenario 15: Path with spaces ---
run_test "Path with spaces" '{
  "workspace":{"current_dir":"/Users/tedserbinski/My Projects/cool app"},
  "model":{"display_name":"Claude Opus 4.6"},
  "context_window":{"used_percentage":10}
}'

# --- Scenario 16: No context/rate data (pending indicators) ---
run_test "No context/rate data (-- indicators)" '{
  "workspace":{"current_dir":"/tmp"},
  "model":{"display_name":"Claude Opus 4.6"}
}'

# --- Scenario 17a: Reset renders as an absolute time (clock today, or a date) ---
RESET_SOON=$(($(date +%s) + 600))
run_test "Reset: absolute time renders" "{
  \"workspace\":{\"current_dir\":\"/tmp\"},
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_SOON}}}
}"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_SOON}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
# Must show ↻ + a valid format: clock time (8:10pm) today, or month/day if it rolled past midnight.
if echo "$out" | grep -qE '↻([0-9]{1,2}:[0-9]{2}(am|pm)|[A-Z][a-z][a-z] +[0-9]{1,2})'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Reset renders as an absolute time\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Reset not a valid absolute time — output: %s\n" "$out"
fi

# --- Scenario 17b: No pacing glyphs, even at high usage ---
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":95,\"resets_at\":${RESET_SOON}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if ! echo "$out" | grep -qE '⚠|⇡|⇣'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m No pacing glyphs (⚠/⇡/⇣) shown\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Unexpected pacing glyph — output: %s\n" "$out"
fi

# --- Scenario 17d: Past reset is hidden (bar shown, no ↻) ---
RESET_PAST=$(($(date +%s) - 100))
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_PAST}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '40%' && ! echo "$out" | grep -qF '↻'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Past reset hidden (no ↻)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Past reset should hide ↻ — output: %s\n" "$out"
fi

# --- Scenario 17e: Far-future reset (beyond the window) is hidden ---
RESET_FAR=$(($(date +%s) + 100000))   # ~27h, well beyond the 5h window
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_FAR}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if ! echo "$out" | grep -qF '↻'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Far-future reset (beyond window) hidden\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Far-future reset should hide ↻ — output: %s\n" "$out"
fi

# --- Scenario 17f: Git cache isolation between repos ---
# Verify that two concurrent sessions in different repos don't share branch cache.
REPO_A=$(mktemp -d)
REPO_B=$(mktemp -d)
(cd "$REPO_A" && git init -q -b branch-alpha 2>/dev/null && git commit --allow-empty -q -m "init" 2>/dev/null)
(cd "$REPO_B" && git init -q -b branch-beta  2>/dev/null && git commit --allow-empty -q -m "init" 2>/dev/null)
out_a=$(echo "{\"workspace\":{\"current_dir\":\"$REPO_A\"},\"model\":{\"display_name\":\"Claude Opus 4.6\"}}" | bash "$SCRIPT" 2>/dev/null)
out_b=$(echo "{\"workspace\":{\"current_dir\":\"$REPO_B\"},\"model\":{\"display_name\":\"Claude Opus 4.6\"}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out_a" | grep -qF 'branch-alpha' && echo "$out_b" | grep -qF 'branch-beta' && ! echo "$out_b" | grep -qF 'branch-alpha'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Git cache isolated per cwd (no cross-repo pollution)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Git cache leak — A:%s  B:%s\n" "$out_a" "$out_b"
fi
rm -rf "$REPO_A" "$REPO_B"

# --- Scenario 17c: Bar renders fill + empty glyphs (currently braille ⡇/⡀) ---
out=$(echo '{"model":{"display_name":"Claude Opus 4.7"},"context_window":{"used_percentage":40}}' | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⣿' && echo "$out" | grep -qF '⣀'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Bar renders braille blocks (⣿/⣀)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Bar not using braille blocks — output: %s\n" "$out"
fi

# --- Scenario 17g: % renders to the LEFT of the bar ---
# Layout #2: "glyph %used bar". Verify "40% ⣿" ordering (digits then a filled cell).
out=$(echo '{"model":{"display_name":"Claude Opus 4.7"},"context_window":{"used_percentage":40}}' | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qE '40% ⣿'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Percentage renders left of the bar (40%% ⣿)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Percentage not left of bar — output: %s\n" "$out"
fi

# --- Scenario 19: 7-day weekly window renders (⧖ + dated reset) ---
RESET_7D=$(($(date +%s) + 4 * 86400))   # 4 days out → a different calendar date
run_test "Weekly window renders (⧖ + dated reset)" "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":40},\"seven_day\":{\"used_percentage\":38,\"resets_at\":${RESET_7D}}}
}"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40},\"seven_day\":{\"used_percentage\":38,\"resets_at\":${RESET_7D}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⧖' && echo "$out" | grep -qE '↻[A-Z][a-z][a-z] +[0-9]'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Weekly renders ⧖ + month/day reset\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Weekly missing ⧖ or dated reset — output: %s\n" "$out"
fi

# --- Scenario 20: Weekly window absent → silently skipped (no ⧖, no --) ---
run_test "Weekly absent (⧖ skipped)" '{
  "model":{"display_name":"Claude Opus 4.7"},
  "rate_limits":{"five_hour":{"used_percentage":40}}
}'
out=$(echo '{"model":{"display_name":"Claude Opus 4.7"},"rate_limits":{"five_hour":{"used_percentage":40}}}' | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if ! echo "$out" | grep -qF '⧖'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Weekly absent correctly skipped (no ⧖)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Weekly should be skipped when absent — output: %s\n" "$out"
fi

# --- Scenario 17: Rapid redraw (consistency) ---
echo ""
echo "  Rapid redraw test (20 iterations)..."
redraw_pass=true
redraw_fail_iter=0
for i in $(seq 1 20); do
  out=$(echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.6"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":15}},"output_style":"Learning","session_name":"test"}' | bash "$SCRIPT" 2>/dev/null)
  lc=$(printf '%s' "$out" | wc -l | tr -d ' ')
  if [ "$lc" -ne 0 ]; then
    redraw_pass=false
    redraw_fail_iter=$i
    break
  fi
done
TOTAL=$((TOTAL + 1))
if $redraw_pass; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Rapid redraw (20x) — all single-line\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Rapid redraw — multi-line at iteration %d\n" "$redraw_fail_iter"
fi

# --- Scenario 18: Performance ---
echo ""
echo "  Performance test (10 iterations)..."
TOTAL=$((TOTAL + 1))
start_s=$(date +%s)
for i in $(seq 1 10); do
  echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.6"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":15}},"output_style":"Learning","session_name":"test"}' | bash "$SCRIPT" > /dev/null 2>&1
done
end_s=$(date +%s)
elapsed=$((end_s - start_s))
if [ "$elapsed" -le 2 ]; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Performance: 10 renders in %ds (≤ 2s)\n" "$elapsed"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Performance: 10 renders in %ds (> 2s)\n" "$elapsed"
fi

# --- Visual output sample ---
echo ""
echo "━━━ Visual Sample Output ━━━"
echo ""
echo '{"workspace":{"current_dir":"/Users/tedserbinski/Documents/projects"},"model":{"display_name":"Claude Opus 4.6"},"context_window":{"used_percentage":23},"cost":{"total_lines_added":35,"total_lines_removed":31},"rate_limits":{"five_hour":{"used_percentage":8}},"output_style":"Learning","session_name":"","session_id":"abc12345-xxxx"}' | bash "$SCRIPT" 2>/dev/null
echo ""
echo '{"workspace":{"current_dir":"/Users/tedserbinski/Documents/projects/loretta"},"model":{"display_name":"Claude Sonnet 4.6"},"context_window":{"used_percentage":67},"cost":{"total_lines_added":200,"total_lines_removed":150},"rate_limits":{"five_hour":{"used_percentage":55}},"output_style":"Explanatory","session_name":"dev-session"}' | bash "$SCRIPT" 2>/dev/null
echo ""
echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4.6"},"context_window":{"used_percentage":91},"rate_limits":{"five_hour":{"used_percentage":88}}}' | bash "$SCRIPT" 2>/dev/null
echo ""
# Both windows live: solid bars, % on the left, absolute reset times (session today, week dated)
echo "{\"workspace\":{\"current_dir\":\"/Users/tedserbinski/Github/loretta\"},\"model\":{\"display_name\":\"Claude Opus 4.7 (1M context)\"},\"context_window\":{\"used_percentage\":74},\"rate_limits\":{\"five_hour\":{\"used_percentage\":84,\"resets_at\":$(($(date +%s)+10800))},\"seven_day\":{\"used_percentage\":38,\"resets_at\":$(($(date +%s)+5*86400))}}}" | bash "$SCRIPT" 2>/dev/null
echo ""

# --- Summary ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m  All %d tests passed ✓\033[0m\n" "$TOTAL"
else
  printf "\033[31m  %d/%d failed\033[0m\n" "$FAIL" "$TOTAL"
fi
echo ""

rm -f "$TMPFILE"
exit "$FAIL"
