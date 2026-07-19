#!/usr/bin/env bash
# Claude Code status line — compact braille style

# All status fields are assigned in a single eval of jq @sh output (see below); shellcheck
# can't trace assignments through eval, so SC2154 ("referenced but not assigned") is a false
# positive for every one of them. Suppress it file-wide rather than at each use site.
# shellcheck disable=SC2154

input=$(cat)

# One timestamp per render — every freshness/expiry check below compares against this instead
# of spawning its own `date` subprocess.
now_ts=$(date +%s)

# --- ANSI colors ---
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_GREY="\033[38;5;245m"
C_LAVENDER="\033[38;5;147m"
C_BLUE="\033[38;5;75m"
C_SEAGREEN="\033[38;5;78m"
C_DIM_WHITE="\033[38;5;250m"
C_RESET="\033[0m"

# --- Progress bar helpers (set variables, no subshells) ---
# Sets _bar_result (colored bar) and _pct_color (the same threshold color, for the % text).
build_bar() {
  local pct=${1:-0} total=${2:-10}
  local filled=$(( (pct * total + 50) / 100 ))
  local bar=""
  # 10 cells = 10% increments. Braille fill: ⣿ (all 8 dots, gap-free) for filled, ⣀ (low baseline
  # dots) for the empty track. Swap these two glyphs to restyle (e.g. █/░ solid, ⡇/⡀ thin).
  for ((i=0; i<filled; i++));     do bar="${bar}⣿"; done
  for ((i=filled; i<total; i++)); do bar="${bar}⣀"; done
  _pct_color="$C_GREEN"
  (( pct >= 50 )) && _pct_color="$C_YELLOW"
  (( pct >= 80 )) && _pct_color="$C_RED"
  _bar_result="${_pct_color}${bar}${C_RESET}"
}

# Round a possibly-fractional percentage to an int in _pct_int, clamped to 0–100: the API can
# report fractionally over 100 when a window is fully spent (e.g. 100.6 → "101%"), and a
# bar/percentage past 100 reads as a bug, not a state. Garbage input clamps to 0.
clamp_pct() {
  printf -v _pct_int "%.0f" "${1:-0}" 2>/dev/null
  _pct_int=${_pct_int:-0}
  (( _pct_int < 0 )) && _pct_int=0
  (( _pct_int > 100 )) && _pct_int=100
}

# --- Rate-limit segment builder ---
# Renders one rate window the way Claude Code's own /usage view does: glyph + bar + used% + the
# absolute time the window resets. No pacing/projection — just "how much used, and when it resets".
#   ↻1:10am = resets within a day, shown as the clock time (even when it's after midnight).
#   ↻Jun 1  = resets further out — shown as month/day (the weekly window). Result in _rate_segment.
build_rate_segment() {
  local used_raw="$1" reset_ts="$2" window="$3" glyph="$4"
  clamp_pct "$used_raw"
  local u_int="$_pct_int"
  build_bar "$u_int"
  local reset=""
  if [[ "$reset_ts" =~ ^[0-9]+$ ]] && (( reset_ts > 0 )); then
    # Trust the reset only when it's in the future and no further out than the window itself
    # (guards stale/garbage timestamps).
    if (( reset_ts > now_ts && reset_ts - now_ts <= window )); then
      # Within 24h → clock time (%l:%M%p), even across midnight; further out → month/day (%b %e).
      # The choice is by time-to-reset, NOT calendar date — a 5h window resetting at 1am tomorrow
      # should read "1:10am", not "May 27". Both formats produced in one `date` call.
      local fmt; fmt=$(date -r "$reset_ts" '+%l:%M%p|%b %e')
      local r
      if (( reset_ts - now_ts <= 86400 )); then r="${fmt%%|*}"; else r="${fmt#*|}"; fi
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

# --- Rate-limit sync across sessions (login/logout, concurrent sessions) ---
# Claude Code only refreshes rate_limits after an API call, so any one session's payload can be
# stale in two ways: a brand-new session (or fresh login) has no rate_limits at all until its first
# response, and an idle session keeps reporting a window that already reset — including a pegged
# "100% used" long after the limit came back. Fix both with a tiny shared snapshot file: every
# session publishes the freshest rate data it has seen, and every render uses whichever snapshot
# (this payload vs the shared file) is genuinely fresher. Freshness rules, per window:
#   1. an unexpired snapshot beats an expired one (expired = resets_at in the past)
#   2. same real window (equal resets_at) → the higher used% is newer (usage only grows)
#   3. otherwise the live payload wins. In particular, two UNEXPIRED snapshots with different
#      resets_at can't both describe the current window (a new window only starts after the old
#      one expires, which rule 1 already handles) — the cached anchor is from another account,
#      plan, or a shifted reset schedule, so the payload straight from the API is the truth.
#      Preferring the later anchor here would let one bad snapshot pin the file until it expires.
# If the winner is itself expired, the window has rolled over: usage renders as 0% with no ↻,
# because the next window's anchor is unknown until the next API response.
# CLAUDE_SL_CACHE_DIR overrides the location (used by the test suite for isolation).
rate_cache="${CLAUDE_SL_CACHE_DIR:-${TMPDIR:-/tmp}}/claude-sl-rate"

# args: pct_a reset_a pct_b reset_b — leaves the fresher snapshot in _w_pct/_w_reset
pick_window() {
  local pa="$1" ra="$2" pb="$3" rb="$4"
  [[ "$ra" =~ ^[0-9]+$ ]] || ra=0
  [[ "$rb" =~ ^[0-9]+$ ]] || rb=0
  local ia=0 ib=0
  printf -v ia "%.0f" "${pa:-0}" 2>/dev/null
  printf -v ib "%.0f" "${pb:-0}" 2>/dev/null
  local ea=0 eb=0
  (( ra > 0 && ra <= now_ts )) && ea=1
  (( rb > 0 && rb <= now_ts )) && eb=1
  _w_pct="$pa"; _w_reset="$ra"
  if [ -z "$pa" ]; then
    _w_pct="$pb"; _w_reset="$rb"
  elif [ -n "$pb" ]; then
    # Rule 2 only applies when the tied resets_at names a real window (> 0); with no reset info
    # on either side, the live payload always wins over the file.
    if (( (ea && !eb) || (rb == ra && ra > 0 && ib > ia) )); then
      _w_pct="$pb"; _w_reset="$rb"
    fi
  fi
  # Winner already expired → the window rolled over; show a fresh (empty) window.
  if [ -n "$_w_pct" ] && (( _w_reset > 0 && _w_reset <= now_ts )); then
    _w_pct=0; _w_reset=0
  fi
}

cached_5pct="" cached_5rst="" cached_7pct="" cached_7rst=""
if [ -f "$rate_cache" ]; then
  IFS=$'\037' read -r cached_5pct cached_5rst cached_7pct cached_7rst < "$rate_cache" 2>/dev/null
fi
payload_had_rate=""
if [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ]; then payload_had_rate=1; fi
pick_window "$five_hour_pct" "$five_hour_reset" "$cached_5pct" "$cached_5rst"
five_hour_pct="$_w_pct"; five_hour_reset="$_w_reset"
pick_window "$seven_day_pct" "$seven_day_reset" "$cached_7pct" "$cached_7rst"
seven_day_pct="$_w_pct"; seven_day_reset="$_w_reset"
# Publish the merged snapshot only when this payload actually carried rate data — a data-less
# tick (new session pre-first-response) must never rewrite the shared file it just read from.
# Atomic mktemp+mv, same pattern as the git cache below.
if [ -n "$payload_had_rate" ]; then
  tmp_rate=$(mktemp "${rate_cache}.XXXXXX" 2>/dev/null)
  if [ -n "$tmp_rate" ]; then
    printf '%s\037%s\037%s\037%s' "$five_hour_pct" "$five_hour_reset" "$seven_day_pct" "$seven_day_reset" > "$tmp_rate" \
      && mv "$tmp_rate" "$rate_cache"
  fi
fi

# --- Git branch (cached for 5 seconds to avoid slow git calls) ---
# Cache key includes cwd so concurrent sessions in different repos don't clash.
# Using parameter expansion (not shasum) keeps this subprocess-free.
# Atomic write via mktemp+mv prevents partial reads on concurrent ticks.
git_branch=""
git_worktree=""
git_added=""
git_removed=""
if [ -n "$cwd" ]; then
  cache_file="${TMPDIR:-/tmp}/claude-sl-git${cwd//\//_}"
  cache_age=999999999
  if [ -f "$cache_file" ]; then
    cache_age=$(( now_ts - $(stat -f%m "$cache_file" 2>/dev/null || echo 0) ))
  fi
  if [ "$cache_age" -ge 5 ]; then
    if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
      git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
      # A linked worktree's git-dir is <repo>/.git/worktrees/<id>; the main worktree's isn't —
      # use that to detect "am I in a linked worktree?". But DON'T label with git's internal <id>:
      # git derives it by sanitizing/deduplicating the checkout basename, so it can degrade to a
      # bare "0", "-", "1", etc. on collision or special characters. Label with the checkout
      # directory's own name (via --show-toplevel) — the name the user actually recognizes.
      gitdir=$(git -C "$cwd" --no-optional-locks rev-parse --absolute-git-dir 2>/dev/null)
      case "$gitdir" in
        */worktrees/*)
          wt_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
          git_worktree="${wt_toplevel##*/}"
          ;;
      esac

      # Lines changed in THIS branch/worktree since it forked off the mainline: every line that
      # differs from the fork point (merge-base), committed AND uncommitted. We diff the working
      # tree against the merge-base commit (two-dot, not three-dot commit..commit) so staged +
      # unstaged edits to tracked files count alongside committed ones. Brand-new UNTRACKED files
      # are intentionally excluded — they'd otherwise pull in generated, non-gitignored dirs
      # (build output, tool indexes) and inflate the count; a new file lands here once you stage it.
      #
      # Pick the fork point against the first mainline ref that actually exists and shares history:
      # prefer the LOCAL main/master (what you branched from, and kept current), then the remote
      # equivalents for a fresh clone/worktree that has no local mainline yet. If none yield a
      # merge-base — e.g. you ARE on main, or an orphan branch — fall back to HEAD, which collapses
      # the diff to "uncommitted changes only".
      diff_base="HEAD"
      for cand in main master origin/HEAD origin/main origin/master; do
        git -C "$cwd" --no-optional-locks rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1 || continue
        mb=$(git -C "$cwd" --no-optional-locks merge-base HEAD "$cand" 2>/dev/null)
        if [ -n "$mb" ]; then diff_base="$mb"; break; fi
      done
      # numstat columns are <added>\t<removed>\t<path>; binary files report "-" for both, so skip
      # those rather than summing a literal dash.
      git_stats=$(git -C "$cwd" --no-optional-locks diff --numstat "$diff_base" 2>/dev/null \
        | awk '{ if ($1 != "-") a += $1; if ($2 != "-") r += $2 } END { printf "%d\t%d", a, r }')
      IFS=$'\t' read -r git_added git_removed <<< "$git_stats"
    fi
    # Cache fields are separated by the ASCII Unit Separator (\037): "<branch>\037<worktree>\037
    # <added>\037<removed>" (worktree empty in the main checkout; added/removed empty outside a git
    # repo). It must NOT be tab/space/newline: those are IFS-whitespace, and `read` collapses runs
    # of IFS-whitespace into a single delimiter — so an empty worktree field (the common case) would
    # vanish and shift <added> into the worktree slot (rendering a bogus "↳ 35"). \037 is a
    # non-whitespace delimiter that read keeps as a literal field boundary, preserving empties, and
    # it can never occur in a branch name, path, or count.
    tmp_cache=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)
    if [ -n "$tmp_cache" ]; then
      printf '%s\037%s\037%s\037%s' "$git_branch" "$git_worktree" "$git_added" "$git_removed" > "$tmp_cache" \
        && mv "$tmp_cache" "$cache_file"
    fi
  else
    IFS=$'\037' read -r git_branch git_worktree git_added git_removed < "$cache_file" 2>/dev/null
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

# Location: directory + worktree label + git branch as ONE segment, joined by plain spaces
# (no " · " between them — they're a single "where am I" group). The join loop only inserts
# " · " *between* parts, so keeping these in one array slot suppresses the dot here while
# preserving it before the segments that follow.
location=""
if [ -n "$cwd" ]; then
  # Collapse a leading $HOME to ~. Done as prefix-strip (#) + quoted "~" rather than a /#/
  # pattern substitution: bash 5.2+ tilde-expands a ~ in a substitution's replacement string
  # (turning it back into $HOME → no-op, full path leaks), while bash 3.2 leaves a \~ literal.
  # ${cwd#$HOME} behaves identically across versions, and ~ inside double quotes is never expanded.
  if [ "$cwd" = "$HOME" ] || [ "${cwd#"$HOME"/}" != "$cwd" ]; then
    display_dir="~${cwd#"$HOME"}"
  else
    display_dir="$cwd"
  fi
  # Worktrees live at <repo>/.claude/worktrees/<name>. Collapse that whole tail back to the
  # repo root, then tag on a "↳ <name>" label so the worktree is named without the long path.
  display_dir="${display_dir%%/.claude/worktrees/*}"
  location="${C_YELLOW}${display_dir}${C_RESET}"
  if [ -n "$git_worktree" ]; then
    location="${location} ${C_SEAGREEN}↳ ${git_worktree}${C_RESET}"
  fi
fi
if [ -n "$git_branch" ]; then
  if [ -n "$location" ]; then
    location="${location} ${C_BLUE}⎇ ${git_branch}${C_RESET}"
  else
    location="${C_BLUE}⎇ ${git_branch}${C_RESET}"
  fi
fi
if [ -n "$location" ]; then
  parts+=("$location")
fi

# Lines changed (real git diff vs the branch's fork point — committed + uncommitted).
# Hidden on a clean tree so +0/-0 never adds noise.
if [ "${git_added:-0}" != "0" ] || [ "${git_removed:-0}" != "0" ]; then
  parts+=("${C_GREEN}+${git_added:-0}${C_RESET}/${C_RED}-${git_removed:-0}${C_RESET}")
fi

# Model
if [ -n "$model" ]; then
  parts+=("${C_YELLOW}◆ ${model}${C_RESET}")
fi

# Context bar
if [ -n "$ctx_pct" ]; then
  # Same clamp as the rate windows: a full context can report a hair over 100 ("101%").
  clamp_pct "$ctx_pct"
  build_bar "$_pct_int"
  parts+=("${_pct_color}⛁ ${_pct_int}%${C_RESET} ${_bar_result}")
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
