#!/usr/bin/env bash
# Claude Code status line — compact braille style

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
  @sh "effort=\(.effortLevel // .effort_level // .effort // "")",
  @sh "five_hour_pct=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_hour_reset=\(.rate_limits.five_hour.resets_at // 0)",
  @sh "cc_version=\(.version // "")"
')"
model="${model#Claude }"

# --- Git branch (cached for 5 seconds to avoid slow git calls) ---
git_branch=""
if [ -n "$cwd" ]; then
  cache_file="${TMPDIR:-/tmp}/claude-sl-git-cache"
  cache_age=999999999
  if [ -f "$cache_file" ]; then
    cache_age=$(( $(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0) ))
  fi
  if [ "$cache_age" -ge 5 ]; then
    if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
      git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    fi
    printf '%s' "$git_branch" > "$cache_file" 2>/dev/null
  else
    git_branch=$(cat "$cache_file" 2>/dev/null)
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

# Git branch
if [ -n "$git_branch" ]; then
  parts+=("${C_GREEN}⎇ ${git_branch}${C_RESET}")
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
  parts+=("${_pct_color}⛁${C_RESET} ${_bar_result} ${ctx_int}%")
else
  parts+=("${C_GREY}⛁ --${C_RESET}")
fi

# Rate limit bar
# Pace delta: how far ahead/behind you are vs. linear burn-through of the window.
# ⇡N% (red) = used N% more than time-proportional → slow down.
# ⇣N% (green) = used N% less than time-proportional → headroom.
# Hidden when |delta| < PACE_THRESHOLD to reduce noise.
PACE_THRESHOLD=3
if [ -n "$five_hour_pct" ]; then
  printf -v fh_int "%.0f" "$five_hour_pct" 2>/dev/null
  build_bar "$fh_int"
  pct_color_val "$fh_int"
  pace=""
  if [[ "$five_hour_reset" =~ ^[0-9]+$ ]] && (( five_hour_reset > 0 )); then
    secs_remaining=$(( five_hour_reset - $(date +%s) ))
    # Window is 5h = 18000s. Skip if reset is in the past or impossibly far.
    if (( secs_remaining > 0 && secs_remaining <= 18000 )); then
      expected=$(( (18000 - secs_remaining) * 100 / 18000 ))
      delta=$(( fh_int - expected ))
      if (( delta >= PACE_THRESHOLD )); then
        pace=" ${C_RED}⇡${delta}%${C_RESET}"
      elif (( delta <= -PACE_THRESHOLD )); then
        pace=" ${C_GREEN}⇣$(( -delta ))%${C_RESET}"
      fi
    fi
  fi
  parts+=("${_pct_color}⏱${C_RESET} ${_bar_result} ${fh_int}%${pace}")
else
  parts+=("${C_GREY}⏱ --${C_RESET}")
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
