#!/usr/bin/env bash
# Test suite for statusline-command.sh

SCRIPT="statusline-command.sh"
TMPFILE="${TMPDIR:-/tmp}/sl_stderr_$$"
PASS=0
FAIL=0
TOTAL=0

# Isolate the cross-session rate-limit snapshot from the developer's real one, and give each
# scenario a clean slate — the sync tests below manage the file explicitly.
# The snapshot is keyed by logged-in account; CLAUDE_SL_ACCOUNT pins it so the suite never reads
# the developer's ~/.claude.json (and the account-switch tests can move between accounts at will).
CLAUDE_SL_CACHE_DIR=$(mktemp -d)
export CLAUDE_SL_CACHE_DIR
CLAUDE_SL_ACCOUNT="acct-a"
export CLAUDE_SL_ACCOUNT
RATE_CACHE="$CLAUDE_SL_CACHE_DIR/claude-sl-rate-acct-a"
RATE_CACHE_B="$CLAUDE_SL_CACHE_DIR/claude-sl-rate-acct-b"
trap 'rm -rf "$CLAUDE_SL_CACHE_DIR"' EXIT

run_test() {
  local name="$1" json="$2"
  TOTAL=$((TOTAL + 1))
  local errors=""
  rm -f "$RATE_CACHE" "$RATE_CACHE_B" "$CLAUDE_SL_CACHE_DIR"/claude-sl-seen-*

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

# --- Scenario 17a: 5-hour reset renders as a CLOCK TIME (never a date) ---
# A 5h-window reset is always <24h away, so it must show the time — even when it crosses midnight.
# Regression: a 1am-tomorrow reset must read "1:10am", not the calendar date "May 27".
RESET_SOON=$(($(date +%s) + 14400))   # 4h out — frequently lands after midnight
run_test "Reset: 5h shows clock time" "{
  \"workspace\":{\"current_dir\":\"/tmp\"},
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_SOON}}}
}"
rm -f "$RATE_CACHE"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_SOON}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qE '↻[0-9]{1,2}:[0-9]{2}(am|pm)' && ! echo "$out" | grep -qE '↻[A-Z][a-z][a-z] +[0-9]'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m 5h reset renders a clock time (not a date)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m 5h reset should be a clock time — output: %s\n" "$out"
fi

# --- Scenario 17b: No pacing glyphs, even at high usage ---
rm -f "$RATE_CACHE"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":95,\"resets_at\":${RESET_SOON}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if ! echo "$out" | grep -qE '⚠|⇡|⇣'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m No pacing glyphs (⚠/⇡/⇣) shown\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Unexpected pacing glyph — output: %s\n" "$out"
fi

# --- Scenario 17d: Past reset = window rolled over → usage resets to 0%, no ↻ ---
# Regression: a stale payload used to keep showing the old used% (e.g. a pegged 100%+) after the
# window had already reset; it must render as a fresh window instead.
RESET_PAST=$(($(date +%s) - 100))
rm -f "$RATE_CACHE"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":101,\"resets_at\":${RESET_PAST}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 0%' && ! echo "$out" | grep -qF '↻' && ! echo "$out" | grep -qF '101'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Expired window rolls over to 0%% (no stale %%, no ↻)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Expired window should show 0%% with no ↻ — output: %s\n" "$out"
fi

# --- Scenario 17e: Far-future reset (beyond the window) is hidden ---
RESET_FAR=$(($(date +%s) + 100000))   # ~27h, well beyond the 5h window
rm -f "$RATE_CACHE"
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":${RESET_FAR}}}}" | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if ! echo "$out" | grep -qF '↻'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Far-future reset (beyond window) hidden\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Far-future reset should hide ↻ — output: %s\n" "$out"
fi

# --- Scenario 17e2: Percentages clamp at 100 (context and rate windows) ---
# The payload can report fractionally over 100 when everything is spent; "101%"/"105%" must
# never render.
rm -f "$RATE_CACHE"
RESET_LIVE=$(($(date +%s) + 7200))
out=$(echo "{\"model\":{\"display_name\":\"Claude Opus 4.7\"},\"context_window\":{\"used_percentage\":100.6},\"rate_limits\":{\"five_hour\":{\"used_percentage\":105,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⛁ 100%' && echo "$out" | grep -qF '⏱ 100%' && ! echo "$out" | grep -qE '10[15]%'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Over-100 payload clamps to 100%% (no 101%%)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Percentages should clamp at 100 — output: %s\n" "$out"
fi

# --- Scenario 17e3: New session inherits the shared rate snapshot ---
# A fresh session (or fresh login) has no rate_limits until its first API response; it must show
# the last-known live window from the shared snapshot instead of "⏱ --".
rm -f "$RATE_CACHE"
echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # session A publishes
out=$(echo '{"model":{"display_name":"x"}}' | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')  # session B, no rate data yet
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 63%' && ! echo "$out" | grep -qF '⏱ --'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m New session inherits shared rate snapshot (63%%, not --)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m New session should inherit cached 63%% — output: %s\n" "$out"
fi

# --- Scenario 17e4: Stale session defers to a fresher shared snapshot ---
# An idle session still reporting an expired window (pegged over 100%) must pick up the live
# window another session published — usage AND reset time re-sync.
rm -f "$RATE_CACHE"
echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # fresh session publishes
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":101,\"resets_at\":${RESET_PAST}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 55%' && echo "$out" | grep -qF '↻' && ! echo "$out" | grep -qF '101'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Stale session re-syncs to fresher snapshot (55%% + ↻)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Stale session should show fresher 55%% with ↻ — output: %s\n" "$out"
fi

# --- Scenario 17e5: A boosted or reset limit lowers used% in the SAME window — live data wins ---
# Regression: the merge used to assume usage only grows within a window and kept the higher
# percentage. Anthropic can raise a limit mid-window ("your limits are temporarily boosted") or
# reset one, which lowers utilization without moving resets_at — the old rule then pinned a spent
# window at 100% until it expired, while /usage showed 1%. A session whose numbers changed since
# its last tick has a fresh API response, and that response is the truth.
rm -f "$RATE_CACHE" "$CLAUDE_SL_CACHE_DIR"/claude-sl-seen-*
echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-1\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":70,\"resets_at\":${RESET_LIVE}},\"seven_day\":{\"used_percentage\":100,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-1\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":${RESET_LIVE}},\"seven_day\":{\"used_percentage\":1,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 30%' && echo "$out" | grep -qF '⧖ 1%' && ! echo "$out" | grep -qF '100%'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Boosted limit: live 30%%/1%% beats the cached 70%%/100%% in the same window\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Live data after a boost should win — output: %s\n" "$out"
fi

# --- Scenario 17e5b: An idle session replaying old numbers does NOT overwrite fresher data ---
# The flip side of 17e5: a session whose numbers are UNCHANGED since its last tick has no new
# response, so its observation keeps its original fetch time and loses to anything newer. The
# record is written directly with a fetch time in the past, because a real replay is separated
# from the fresh publish by more than the one-second clock this suite runs inside.
rm -f "$RATE_CACHE" "$CLAUDE_SL_CACHE_DIR"/claude-sl-seen-*
printf 'acct-a\03730\037%s\037\0370\037%s' "$RESET_LIVE" "$(($(date +%s) - 600))" > "$CLAUDE_SL_CACHE_DIR/claude-sl-seen-sess-idle"
echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-2\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":70,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # fresh session publishes
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-idle\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":30,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 70%' && grep -qF '70' "$RATE_CACHE"; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Idle session's replayed 30%% defers to the fresher 70%% (and doesn't publish it)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Idle replay should lose to fresher data — output: %s\n" "$out"
fi

# --- Scenario 17e5c: A snapshot from an older script version (no fetch times) never pins ---
rm -f "$RATE_CACHE" "$CLAUDE_SL_CACHE_DIR"/claude-sl-seen-*
printf '100\037%s\037100\037%s' "$RESET_LIVE" "$RESET_LIVE" > "$RATE_CACHE"   # four-field legacy file
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-3\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":${RESET_LIVE}},\"seven_day\":{\"used_percentage\":2,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 5%' && echo "$out" | grep -qF '⧖ 2%'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Legacy four-field snapshot reads as oldest; live 5%%/2%% wins\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Legacy snapshot should never beat live data — output: %s\n" "$out"
fi

# --- Scenario 17e6: Live payload beats a cached snapshot with a mismatched (later) anchor ---
# Two unexpired snapshots with different resets_at can't be the same window; the cached one is
# from another account/plan or a shifted reset schedule. The live API data must win — under the
# old "later resets_at wins" rule, the bad cache entry pinned the display until it expired.
rm -f "$RATE_CACHE"
RESET_WK_LIVE=$(($(date +%s) + 1 * 86400))
RESET_WK_STALE=$(($(date +%s) + 4 * 86400))
printf '34\037%s\03753\037%s' "$RESET_LIVE" "$RESET_WK_STALE" > "$RATE_CACHE"   # poisoned weekly snapshot
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":36,\"resets_at\":${RESET_LIVE}},\"seven_day\":{\"used_percentage\":94,\"resets_at\":${RESET_WK_LIVE}}}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⧖ 94%' && ! echo "$out" | grep -qF '53'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Live 94%% beats cached 53%% with mismatched later anchor\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Live 94%% should beat mismatched cache — output: %s\n" "$out"
fi

# --- Scenario 17e7: A different account does NOT inherit the previous account's snapshot ---
# Rate limits are per account. After /login to another account, its first (data-less) ticks must
# show "⏱ --", not the account you just left.
rm -f "$RATE_CACHE" "$RATE_CACHE_B"
echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # account A publishes
out=$(echo '{"model":{"display_name":"x"}}' | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ --' && ! echo "$out" | grep -qF '63'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Switched account shows -- instead of the previous account's 63%%\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Switched account leaked previous usage — output: %s\n" "$out"
fi

# --- Scenario 17e8: Switching back restores that account's own last-known window ---
# The whole point of keying by account: account A's snapshot survived the trip through B.
out=$(echo '{"model":{"display_name":"x"}}' | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 63%'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Switching back restores account A's own 63%% immediately\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Switching back should restore 63%% — output: %s\n" "$out"
fi

# --- Scenario 17e9: Carried-over rate data from the previous account is ignored ---
# Claude Code keeps rate limits in memory per process, so a session that was already running when
# you switched accounts keeps reporting the OLD account's numbers — same used%, same resets_at —
# until its next API call. That payload must neither render nor be published as the new account's.
rm -f "$RATE_CACHE_B"
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":${RESET_LIVE}}}}" | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ --' && [ ! -f "$RATE_CACHE_B" ]; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Carried-over payload from previous account ignored (and not published)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Carried-over payload should be ignored — output: %s\n" "$out"
fi

# --- Scenario 17e10: Same used%% on a DIFFERENT anchor is real data, not carry-over ---
# The carry-over guard keys on the exact reset second; an equal percentage alone must not suppress
# the new account's genuinely fresh window.
rm -f "$RATE_CACHE_B"
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":$((RESET_LIVE + 37))}}}" | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 63%' && echo "$out" | grep -qF '↻' && [ -f "$RATE_CACHE_B" ]; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Same %% on a different anchor is trusted as the new account's data\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Fresh data for the new account was wrongly suppressed — output: %s\n" "$out"
fi

# --- Scenario 17e11: Carry-over is caught by the session record even after the old account moves on ---
# The exact-match guard (17e9) fails once the old account makes another call: its snapshot moves
# to 65% while the idle session still replays 63%, so nothing matches any more. The per-session
# record still knows those 63% were fetched under account A, so they must still be dropped.
rm -f "$RATE_CACHE" "$RATE_CACHE_B" "$CLAUDE_SL_CACHE_DIR"/claude-sl-seen-*
echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-old\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # sess-old fetches under A
echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-new\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":65,\"resets_at\":${RESET_LIVE}}}}" | bash "$SCRIPT" >/dev/null 2>&1   # A moves on to 65%
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-old\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":63,\"resets_at\":${RESET_LIVE}}}}" | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')   # sess-old replays under B
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ --' && [ ! -f "$RATE_CACHE_B" ]; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Replay under a new account is attributed to the old one via the session record\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Session record should attribute the replay to account A — output: %s\n" "$out"
fi

# --- Scenario 17e12: The same session's FIRST new response under the new account is trusted ---
# Once sess-old actually makes a call as account B its numbers change, and from then on they are
# B's: rendered, published to B's snapshot, and the record re-homed so later replays stay B's.
out=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-old\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":12,\"resets_at\":$((RESET_LIVE + 900))}}}" | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
out2=$(echo "{\"model\":{\"display_name\":\"x\"},\"session_id\":\"sess-old\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":12,\"resets_at\":$((RESET_LIVE + 900))}}}" | CLAUDE_SL_ACCOUNT=acct-b bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')   # replay, now as B
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 12%' && echo "$out2" | grep -qF '⏱ 12%' && grep -qF '12' "$RATE_CACHE_B" \
   && grep -qF 'acct-b' "$CLAUDE_SL_CACHE_DIR/claude-sl-seen-sess-old"; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Session's first new response under account B is trusted and re-homes the record\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m New response under B should be trusted — output: %s / %s\n" "$out" "$out2"
fi

# --- Scenario 17e13: Account A's snapshot was not poisoned by any of the above ---
out=$(echo '{"model":{"display_name":"x"}}' | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF '⏱ 65%'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Account A still shows its own 65%% after the switch dance\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Account A's snapshot was disturbed — output: %s\n" "$out"
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

# --- Scenario 17i: Linked worktree labels the branch element (main checkout doesn't) ---
WT_BASE=$(mktemp -d)
WT_MAIN="$WT_BASE/repo"
mkdir -p "$WT_MAIN"
(git -C "$WT_MAIN" init -q -b main && git -C "$WT_MAIN" commit --allow-empty -q -m init) 2>/dev/null
git -C "$WT_MAIN" worktree add -q "$WT_BASE/repo-wt" -b wt-branch >/dev/null 2>&1
out_main=$(echo "{\"workspace\":{\"current_dir\":\"$WT_MAIN\"},\"model\":{\"display_name\":\"x\"}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
out_wt=$(echo "{\"workspace\":{\"current_dir\":\"$WT_BASE/repo-wt\"},\"model\":{\"display_name\":\"x\"}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
# Icon-agnostic: in the worktree the location segment carries BOTH the worktree name (as the
# directory tail and again as the "↳ <name>" label → repo-wt appears twice) and the branch
# ("wt-branch"); the main checkout has no worktree label so "repo-wt" never appears there.
wt_label_count=$(echo "$out_wt" | grep -oF 'repo-wt' | wc -l | tr -d ' ')
if [ "$wt_label_count" -ge 2 ] && echo "$out_wt" | grep -qF 'wt-branch' && ! echo "$out_main" | grep -qF 'repo-wt'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Linked worktree labels the branch element\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Worktree label wrong — wt:%s main:%s\n" "$out_wt" "$out_main"
fi
git -C "$WT_MAIN" worktree remove --force "$WT_BASE/repo-wt" 2>/dev/null
rm -rf "$WT_BASE"

# --- Scenario 17i2: Worktree label uses the checkout dir name, not git's internal id ---
# git's internal worktree id (.git/worktrees/<id>) is a sanitized/deduped basename and can degrade
# to a bare "0", "-", etc. The label must come from the real checkout directory, never that id.
WT2_BASE=$(mktemp -d)
WT2_MAIN="$WT2_BASE/repo"
mkdir -p "$WT2_MAIN"
(git -C "$WT2_MAIN" init -q -b main && git -C "$WT2_MAIN" commit --allow-empty -q -m init) 2>/dev/null
# Force a degenerate internal id: a checkout whose basename sanitizes to a non-name, so git stores
# it under .git/worktrees/ as something like "-" rather than the directory's real name.
git -C "$WT2_MAIN" worktree add -q "$WT2_BASE/.#" -b odd-branch >/dev/null 2>&1
wt2_id=$(git -C "$WT2_BASE/.#" rev-parse --absolute-git-dir 2>/dev/null | sed 's#.*/##')
out_wt2=$(echo "{\"workspace\":{\"current_dir\":\"$WT2_BASE/.#\"},\"model\":{\"display_name\":\"x\"}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
# The bare internal id (e.g. "-") must NOT appear as the standalone "↳ <id>" label; the branch must.
if echo "$out_wt2" | grep -qF 'odd-branch' && ! echo "$out_wt2" | grep -qF "↳ ${wt2_id} "; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Worktree label uses checkout dir name, not git's internal id\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Worktree label leaked internal id '%s' — wt:%s\n" "$wt2_id" "$out_wt2"
fi
git -C "$WT2_MAIN" worktree remove --force "$WT2_BASE/.#" 2>/dev/null
rm -rf "$WT2_BASE"

# --- Scenario 17i3: Cached render with empty worktree field doesn't leak the line count ---
# The git cache stores "<branch><sep><worktree><sep><added><sep><removed>". On a main checkout the
# worktree field is EMPTY; if the separator were IFS-whitespace, `read` would collapse the empty
# field on the cache-HIT path and slide <added> into the worktree slot (a bogus "↳ 35"). Exercise
# the cache by rendering the SAME cwd twice in quick succession (2nd read comes from cache) with a
# tree that has line changes, and assert no spurious "↳ <number>" label appears.
CACHE_REPO=$(mktemp -d)
(
  cd "$CACHE_REPO" || exit
  git init -q -b main && git config user.email t@t.com && git config user.name t
  printf 'a\nb\nc\n' > f.txt && git add . && git commit -qm init
  printf 'a\nb\nc\nd\ne\n' > f.txt           # +2 uncommitted changes → non-empty +N/-N
) 2>/dev/null
in_json="{\"workspace\":{\"current_dir\":\"$CACHE_REPO\"},\"model\":{\"display_name\":\"x\"}}"
echo "$in_json" | bash "$SCRIPT" >/dev/null 2>&1   # 1st: populates cache
out_cached=$(echo "$in_json" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')  # 2nd: cache hit
TOTAL=$((TOTAL + 1))
if echo "$out_cached" | grep -qF '+2' && ! echo "$out_cached" | grep -qE '↳ [0-9]'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Cached render with empty worktree field keeps the line count out of the ↳ slot\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Cache roundtrip leaked line count into worktree label — %s\n" "$out_cached"
fi
rm -rf "$CACHE_REPO"

# --- Scenario 17j: +N/-N counts real git lines since the fork (committed + staged + unstaged) ---
# The segment must reflect actual .git state vs the branch's merge-base, NOT session telemetry.
# Build a branch off main with a committed change, a staged + an unstaged edit, plus an untracked
# file and a .gitignored file — both of which must be EXCLUDED. Hand-computed truth = +5/-1.
LR_BASE=$(mktemp -d)
(
  cd "$LR_BASE" || exit
  git init -q -b main && git config user.email t@t.com && git config user.name t
  printf 'a\nb\nc\n' > base.txt && git add . && git commit -qm init
  git checkout -qb feature
  printf 'a\nB-CHANGED\nc\nd\ne\n' > base.txt && git commit -qam c1          # committed +2/-1
  printf 'a\nB-CHANGED\nc\nd\ne\nf\n' > base.txt && git add base.txt          # staged +1
  printf 'a\nB-CHANGED\nc\nd\ne\nf\ng\n' > base.txt                           # unstaged +1
  printf 'n1\nn2\nn3\n' > untracked.txt                                       # untracked — excluded
  printf 'ignored.txt\n' > .gitignore && printf 'x\ny\n' > ignored.txt        # untracked/ignored — excluded
) >/dev/null 2>&1
# base.txt vs fork: added B-CHANGED,d,e,f,g = +5, removed b = -1. untracked.txt, .gitignore and
# ignored.txt are all untracked and therefore NOT counted. Total = +5 / -1.
rm -f "${TMPDIR:-/tmp}/claude-sl-git${LR_BASE//\//_}" 2>/dev/null
out_lr=$(echo "{\"workspace\":{\"current_dir\":\"$LR_BASE\"},\"model\":{\"display_name\":\"x\"}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if echo "$out_lr" | grep -qF '+5/-1'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m +N/-N counts tracked git lines since fork (untracked excluded)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Lines-since-fork wrong — expected +5/-1 in: %s\n" "$out_lr"
fi
rm -rf "$LR_BASE"

# --- Scenario 17k: clean tree (no changes since fork) hides the +N/-N segment ---
CL_BASE=$(mktemp -d)
(
  cd "$CL_BASE" || exit
  git init -q -b main && git config user.email t@t.com && git config user.name t
  printf 'a\nb\n' > f.txt && git add . && git commit -qm init
) >/dev/null 2>&1
rm -f "${TMPDIR:-/tmp}/claude-sl-git${CL_BASE//\//_}" 2>/dev/null
out_cl=$(echo "{\"workspace\":{\"current_dir\":\"$CL_BASE\"},\"model\":{\"display_name\":\"x\"}}" | bash "$SCRIPT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
TOTAL=$((TOTAL + 1))
if ! echo "$out_cl" | grep -qE '\+[0-9]+/-[0-9]+'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Clean tree hides +N/-N segment\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Clean tree should hide +N/-N — got: %s\n" "$out_cl"
fi
rm -rf "$CL_BASE"

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

# --- Scenario 17h: Model name shortening (strip "Claude", compact "(1M context)") ---
out=$(echo '{"model":{"display_name":"Claude Opus 4.7 (1M context)"}}' | bash "$SCRIPT" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if echo "$out" | grep -qF 'Opus 4.7 1M' && ! echo "$out" | grep -qF 'context'; then
  PASS=$((PASS + 1))
  printf "  \033[32m✓\033[0m Model name shortened (Opus 4.7 1M)\n"
else
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m Model name not shortened — output: %s\n" "$out"
fi

# --- Scenario 19: 7-day weekly window renders (⧖ + dated reset) ---
RESET_7D=$(($(date +%s) + 4 * 86400))   # 4 days out → a different calendar date
run_test "Weekly window renders (⧖ + dated reset)" "{
  \"model\":{\"display_name\":\"Claude Opus 4.7\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":40},\"seven_day\":{\"used_percentage\":38,\"resets_at\":${RESET_7D}}}
}"
rm -f "$RATE_CACHE"
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
rm -f "$RATE_CACHE"
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
