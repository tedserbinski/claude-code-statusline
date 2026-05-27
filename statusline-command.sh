#!/usr/bin/env bash
# Claude Code status line — compact braille style

# All status fields are assigned in a single eval of jq @sh output (see below); shellcheck
# can't trace assignments through eval, so SC2154 ("referenced but not assigned") is a false
# positive for every one of them. Suppress it file-wide rather than at each use site.
# shellcheck disable=SC2154

input=$(cat)

# --- ANSI colors ---
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_GREY="\033[38;5;245m"
C_LAVENDER="\033[38;5;147m"
C_DIM_WHITE="\033[38;5;250m"
C_RESET="\033[0m"

# --- Progress bar helpers (set variables, no subshells) ---
build_bar() {
  local pct=${1:-0} total=${2:-10}
  local filled=$(( (pct * total + 50) / 100 ))
  local bar=""
  # 10 cells = 10% increments. Braille fill: ⣿ (all 8 dots, gap-free) for filled, ⣀ (low baseline
  # dots) for the empty track. Swap these two glyphs to restyle (e.g. █/░ solid, ⡇/⡀ thin).
  for ((i=0; i<filled; i++));     do bar="${bar}⣿"; done
  for ((i=filled; i<total; i++)); do bar="${bar}⣀"; done
  local color="$C_GREEN"
  (( pct >= 50 )) && color="$C_YELLOW"
  (( pct >= 80 )) && color="$C_RED"
  _bar_result="${color}${bar}${C_RESET}"
}

pct_color_val() {
  _pct_color="$C_GREEN"
  (( ${1:-0} >= 50 )) && _pct_color="$C_YELLOW"
  (( ${1:-0} >= 80 )) && _pct_color="$C_RED"
}

# --- Rate-limit segment builder ---
# Renders one rate window the way Claude Code's own /usage view does: glyph + bar + used% + the
# absolute time the window resets. No pacing/projection — just "how much used, and when it resets".
#   ↻1:10am = resets within a day, shown as the clock time (even when it's after midnight).
#   ↻Jun 1  = resets further out — shown as month/day (the weekly window). Result in _rate_segment.
build_rate_segment() {
  local used_raw="$1" reset_ts="$2" window="$3" glyph="$4"
  local u_int; printf -v u_int "%.0f" "$used_raw" 2>/dev/null
  build_bar "$u_int"
  pct_color_val "$u_int"
  local reset=""
  if [[ "$reset_ts" =~ ^[0-9]+$ ]] && (( reset_ts > 0 )); then
    # Trust the reset only when it's in the future and no further out than the window itself
    # (guards stale/garbage timestamps).
    local now; now=$(date +%s)
    if (( reset_ts > now && reset_ts - now <= window )); then
      # Within 24h → clock time (%l:%M%p), even across midnight; further out → month/day (%b %e).
      # The choice is by time-to-reset, NOT calendar date — a 5h window resetting at 1am tomorrow
      # should read "1:10am", not "May 27". Both formats produced in one `date` call.
      local fmt; fmt=$(date -r "$reset_ts" '+%l:%M%p|%b %e')
      local r
      if (( reset_ts - now <= 86400 )); then r="${fmt%%|*}"; else r="${fmt#*|}"; fi
      r="${r//  / }"; r="${r# }"; r="${r//AM/am}"; r="${r//PM/pm}"   # "  8:10PM" → "8:10pm"
      reset=" ${C_GREY}↻${r}${C_RESET}"
    fi
  fi
  _rate_segment="${_pct_color}${glyph} ${u_int}%${C_RESET} ${_bar_result}${reset}"
}

# --- Extract all fields in a single jq call ---
eval "$(echo "$input" | jq -r '
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "model=\(.model.display_name // "")",
  @sh "ctx_pct=\(.context_window.used_percentage // "")",
  @sh "lines_added=\(.cost.total_lines_added // "")",
  @sh "lines_removed=\(.cost.total_lines_removed // "")",
  @sh "output_style=\((.output_style | if type == "object" then .name // "" else . // "" end))",
  @sh "vim_mode=\(.vim.mode // "")",
  @sh "session_name=\(.session_name // "")",
  @sh "session_id=\(.session_id // "")",
  @sh "effort=\((.effort | if type == "object" then .level // "" else . // "" end) // .effortLevel // .effort_level // "")",
  @sh "five_hour_pct=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_hour_reset=\(.rate_limits.five_hour.resets_at // 0)",
  @sh "seven_day_pct=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "seven_day_reset=\(.rate_limits.seven_day.resets_at // 0)",
  @sh "cc_version=\(.version // "")"
')"
model="${model#Claude }"
# Compact any "(1M context)" / "(200K context)" annotation to just the size token, so every
# model name stays short regardless of tier: "Opus 4.7 (1M context)" → "Opus 4.7 1M".
if [[ "$model" =~ ^(.+)\ \(([0-9]+[KMkm])\ context\)$ ]]; then
  model="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
fi

# --- Git branch (cached for 5 seconds to avoid slow git calls) ---
# Cache key includes cwd so concurrent sessions in different repos don't clash.
# Using parameter expansion (not shasum) keeps this subprocess-free.
# Atomic write via mktemp+mv prevents partial reads on concurrent ticks.
git_branch=""
git_worktree=""
if [ -n "$cwd" ]; then
  cache_file="${TMPDIR:-/tmp}/claude-sl-git${cwd//\//_}"
  cache_age=999999999
  if [ -f "$cache_file" ]; then
    cache_age=$(( $(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0) ))
  fi
  if [ "$cache_age" -ge 5 ]; then
    if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
      git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
      # A linked worktree's git-dir is <repo>/.git/worktrees/<name>; the main worktree's isn't.
      # Use that <name> as the worktree label so you can tell which checkout you're in.
      gitdir=$(git -C "$cwd" --no-optional-locks rev-parse --absolute-git-dir 2>/dev/null)
      case "$gitdir" in */worktrees/*) git_worktree="${gitdir##*/}" ;; esac
    fi
    # Cache is tab-separated: "<branch>\t<worktree>" (worktree empty in the main checkout).
    tmp_cache=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)
    if [ -n "$tmp_cache" ]; then
      printf '%s\t%s' "$git_branch" "$git_worktree" > "$tmp_cache" && mv "$tmp_cache" "$cache_file"
    fi
  else
    IFS=$'\t' read -r git_branch git_worktree < "$cache_file" 2>/dev/null
  fi
fi

# --- Installed Claude Code version (read from versioned symlink) ---
# ~/.local/bin/claude is a symlink whose target ends in the version.
# readlink is a single syscall (<1ms), cheaper than the stat+date math a cache would cost.
installed_version=""
if [ -n "$cc_version" ]; then
  claude_bin=$(command -v claude 2>/dev/null)
  if [ -n "$claude_bin" ] && [ -L "$claude_bin" ]; then
    target=$(readlink "$claude_bin" 2>/dev/null)
    installed_version="${target##*/}"
  fi
fi

# Determine if an update is available (installed version differs from running version)
update_available=""
if [ -n "$installed_version" ] && [ -n "$cc_version" ] && [ "$installed_version" != "$cc_version" ]; then
  update_available="1"
fi

# --- Build parts ---
parts=()

# Session: only show if unnamed
if [ -z "$session_name" ]; then
  if [ -n "$session_id" ]; then
    parts+=("${C_LAVENDER}[${session_id:0:8}]${C_RESET}")
  else
    parts+=("${C_LAVENDER}[none]${C_RESET}")
  fi
fi

# Directory
if [ -n "$cwd" ]; then
  parts+=("${C_CYAN}${cwd/#$HOME/~}${C_RESET}")
fi

# Git branch (+ worktree label, with its own icon, when inside a linked worktree)
if [ -n "$git_branch" ]; then
  if [ -n "$git_worktree" ]; then
    parts+=("${C_GREEN}⎇ ${git_branch} ${C_LAVENDER}↳ ${git_worktree}${C_RESET}")
  else
    parts+=("${C_GREEN}⎇ ${git_branch}${C_RESET}")
  fi
fi

# Lines changed
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  parts+=("${C_GREEN}+${lines_added:-0}${C_RESET}/${C_RED}-${lines_removed:-0}${C_RESET}")
fi

# Model
if [ -n "$model" ]; then
  parts+=("${C_YELLOW}◆ ${model}${C_RESET}")
fi

# Context bar
if [ -n "$ctx_pct" ]; then
  printf -v ctx_int "%.0f" "$ctx_pct" 2>/dev/null
  build_bar "$ctx_int"
  pct_color_val "$ctx_int"
  parts+=("${_pct_color}⛁ ${ctx_int}%${C_RESET} ${_bar_result}")
else
  parts+=("${C_GREY}⛁ --${C_RESET}")
fi

# Rate limit bars — 5-hour (⏱) session window and 7-day (⧖) weekly window.
# Each renders identically via build_rate_segment; both windows degrade independently
# (the docs note either may be absent), so the weekly segment is simply skipped when missing.
if [ -n "$five_hour_pct" ]; then
  build_rate_segment "$five_hour_pct" "$five_hour_reset" 18000 "⏱"
  parts+=("$_rate_segment")
else
  parts+=("${C_GREY}⏱ --${C_RESET}")
fi
if [ -n "$seven_day_pct" ]; then
  build_rate_segment "$seven_day_pct" "$seven_day_reset" 604800 "⧖"
  parts+=("$_rate_segment")
fi

# Output style (hidden when default)
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  parts+=("\033[35m☰${output_style}${C_RESET}")
fi

# Effort level
if [ -n "$effort" ]; then
  parts+=("${C_GREY}effort:${effort}${C_RESET}")
fi

# Vim mode
if [ -n "$vim_mode" ]; then
  parts+=("${C_GREY}vim:${vim_mode}${C_RESET}")
fi

# Claude Code version (shown at the end; green ↻ when a newer version is installed)
if [ -n "$cc_version" ]; then
  update_marker=""
  if [ -n "$update_available" ]; then
    update_marker="${C_GREEN}↻${C_DIM_WHITE}"
  fi
  parts+=("${C_DIM_WHITE}v${cc_version}${update_marker}${C_RESET}")
fi

# --- Join and output ---
line="${parts[0]}"
for part in "${parts[@]:1}"; do
  line="${line} · ${part}"
done
# Leading reset overrides Claude Code's dim styling (pattern from ccstatusline)
printf '\033[0m%b\033[0m' "$line"
