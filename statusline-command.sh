#!/usr/bin/env bash
# Claude Code status line — compact braille style

# All status fields are assigned in a single eval of jq @sh output (see below); shellcheck
# can't trace assignments through eval, so SC2154 ("referenced but not assigned") is a false
# positive for every one of them. Suppress it file-wide rather than at each use site.
# shellcheck disable=SC2154

# Builtin read instead of $(cat): one fewer process per tick. read returns non-zero at EOF,
# which is expected here.
IFS= read -r -d '' input || true

# One timestamp per render — every freshness/expiry check below compares against this instead
# of spawning its own `date` subprocess. $EPOCHSECONDS is bash 5's builtin clock; bash 3.2 (stock
# macOS) falls back to date.
if [ -n "${EPOCHSECONDS-}" ]; then now_ts=$EPOCHSECONDS; else now_ts=$(date +%s); fi

# File modification time in epoch seconds: BSD/macOS stat first, then GNU/Linux. Only used off the
# hot path (stale-lock checks); per-tick freshness is kept inside the cache files themselves.
file_mtime() { stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null; }

# --- ANSI colors ---
# Green / yellow / red mean "how much is used" (plus git's +added/-removed), so a yellow gauge
# never reads like the folder or model name. Row 1's location is a sky-blue folder, thistle-pink
# worktree and lavender branch, and the model is Claude's terracotta. The session's messaging name
# is link blue — it's the address other sessions use. Neither blue has green in it, so neither
# reads like the +added count.
# The codes are real ESC bytes ($'…'), and the output is printed with %s: content (paths, branch
# and style names) is never run through printf's %b, where a folder named "a\cb" would cut the
# statusline off at the \c.
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_GREY=$'\033[38;5;245m'
C_LAVENDER=$'\033[38;5;147m'
C_BLUE=$'\033[38;5;75m'
C_SKY=$'\033[38;5;117m'
C_ORANGE=$'\033[38;5;173m'
C_THISTLE=$'\033[38;5;182m'
C_FAINT=$'\033[38;5;240m'     # structure, not content: the · separators and the bars' empty track
C_RESET=$'\033[0m'

# --- Available width ---
# Claude Code captures this script's output, so tput/stty can't see the terminal — but it exports
# COLUMNS with the terminal's width before each run. Rows that don't fit are compacted and then
# wrapped at their " · " separators (see "Build rows"), so a phone-width terminal shows everything
# on a few short lines instead of cutting each row off with "…". The margin covers the padding
# Claude Code puts around the statusline. CLAUDE_SL_WIDTH sets the usable width directly; 0, or no
# COLUMNS at all (older Claude Code), means "don't fit" and every row stays on one line.
max_w=0
if [[ "${CLAUDE_SL_WIDTH-}" =~ ^[0-9]+$ ]]; then
  max_w=$CLAUDE_SL_WIDTH
elif [[ "${COLUMNS-}" =~ ^[0-9]+$ ]] && (( COLUMNS > 4 )); then
  max_w=$(( COLUMNS - 4 ))
fi
# Visible width of a string in _w: its length without the color codes. The codes are removed as
# literal strings, one per color — a single extglob pattern would do it in one pass, but is several
# times slower, and painfully so on bash 3.2.
vis_width() {
  local plain="$1" code
  for code in "$C_RESET" "$C_FAINT" "$C_GREY" "$C_GREEN" "$C_YELLOW" "$C_RED" \
              "$C_SKY" "$C_LAVENDER" "$C_THISTLE" "$C_ORANGE" "$C_BLUE"; do
    plain="${plain//"$code"/}"
  done
  _w=${#plain}
}

# --- Progress bar helpers (set variables, no subshells) ---
# Sets _bar_result (colored bar, with its leading space) and _pct_color (the same threshold color,
# for the % text). bar_cells shrinks to 5 and then 0 when row 2 is too wide for the terminal; at 0
# the bar is dropped and the colored percentage carries the reading.
bar_cells=10
build_bar() {
  local pct=${1:-0} total=${2:-$bar_cells}
  local filled=$(( (pct * total + 50) / 100 ))
  local fill="" track=""
  # 10 cells = 10% increments (5 cells = 20% on a narrow terminal). Braille fill: ⣿ (all 8 dots, gap-free) for filled, ⣀ (low baseline
  # dots) for the empty track. Swap these two glyphs to restyle (e.g. █/░ solid, ⡇/⡀ thin).
  for ((i=0; i<filled; i++));     do fill="${fill}⣿"; done
  for ((i=filled; i<total; i++)); do track="${track}⣀"; done
  _pct_color="$C_GREEN"
  (( pct >= 50 )) && _pct_color="$C_YELLOW"
  (( pct >= 80 )) && _pct_color="$C_RED"
  # Only the used part carries the threshold color; the empty track recedes into dark grey, so
  # a 15% bar reads as a short green stub rather than ten cells of green.
  _bar_result=""
  (( total > 0 )) && _bar_result=" ${_pct_color}${fill}${C_FAINT}${track}${C_RESET}"
}

# Round a possibly-fractional percentage to an int in _pct_int, clamped to 0–100: the API can
# report fractionally over 100 when a window is fully spent (e.g. 100.6 → "101%"), and a
# bar/percentage past 100 reads as a bug, not a state. Garbage input clamps to 0.
# Rounded with string ops rather than printf "%.0f": printf parses numbers in the user's locale, so
# under a comma-decimal one (de_DE, fr_FR, …) "42.6" is an invalid number — it printed an error
# and truncated to 42. Negative, exponent-form (jq prints tiny values as 1e-05) and non-numeric
# input all fall through to 0.
clamp_pct() {
  local v="${1:-0}" frac=""
  _pct_int=0
  [[ "$v" == *.* ]] && frac="${v#*.}"
  v="${v%%.*}"
  if [[ "$v" =~ ^[0-9]{1,6}$ ]] && [[ "$frac" =~ ^[0-9]*$ ]]; then
    _pct_int=$(( 10#$v ))
    [[ "$frac" == [5-9]* ]] && _pct_int=$(( _pct_int + 1 ))
  fi
  (( _pct_int > 100 )) && _pct_int=100
}

# --- Rate-limit segment builder ---
# Renders one rate window the way Claude Code's own /usage view does: glyph + bar + used% + the
# absolute time the window resets. No pacing/projection — just "how much used, and when it resets".
#   ↻1:10am = resets within a day, shown as the clock time (even when it's after midnight).
#   ↻Jun 1  = resets further out — shown as month/day (the weekly window). Result in _rate_segment.
build_rate_segment() {
  # $5 (optional) is extra text placed after the bar and before the reset time.
  local used_raw="$1" reset_ts="$2" window="$3" glyph="$4" extra="${5-}"
  clamp_pct "$used_raw"
  local u_int="$_pct_int"
  build_bar "$u_int"
  local reset=""
  if [[ "$reset_ts" =~ ^[0-9]+$ ]] && (( reset_ts > 0 )); then
    # Trust the reset only when it's in the future and no further out than the window itself
    # (guards stale/garbage timestamps).
    if (( reset_ts > now_ts && reset_ts - now_ts <= window )); then
      # Within 24h → clock time (%I:%M%p), even across midnight; further out → month/day (%b %e).
      # The choice is by time-to-reset, NOT calendar date — a 5h window resetting at 1am tomorrow
      # should read "1:10am", not "May 27". Both formats come from one formatting call:
      # bash 4.2+ formats the time itself (printf %(…)T — no fork, and portable: GNU date's -r
      # means "a file's mtime", not "this epoch"). Stock macOS bash 3.2 falls back to BSD date -r.
      # Only POSIX conversions are used (%I, not the %l extension some libcs lack), and the 24-hour
      # form rides along because %p is EMPTY in locales with no am/pm (de_DE, fr_FR, …), where a
      # bare "8:10" would be ambiguous.
      local fmt
      if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
        printf -v fmt '%(%I:%M%p|%H:%M|%b %e)T' "$reset_ts"
      else
        fmt=$(date -r "$reset_ts" '+%I:%M%p|%H:%M|%b %e')
      fi
      local r="${fmt%%|*}" rest="${fmt#*|}"
      if (( reset_ts - now_ts > 86400 )); then
        r="${rest#*|}"
      elif [[ "$r" == *[0-9] ]]; then
        r="${rest%%|*}"                                   # no am/pm in this locale → "20:10"
      else
        r="${r#0}"; r="${r//AM/am}"; r="${r//PM/pm}"      # "08:10PM" → "8:10pm"
      fi
      r="${r//  / }"; r="${r# }"                          # "Jun  1" → "Jun 1"
      reset=" ${C_GREY}↻${r}${C_RESET}"
    fi
  fi
  _rate_segment="${_pct_color}${glyph} ${u_int}%${C_RESET}${_bar_result}${extra:+ $extra}${reset}"
}

# --- Find jq ---
# jq is the one process every tick starts, so which jq matters. Version-manager shims (mise, asdf,
# …) are wrapper scripts that take longer to launch than jq takes to run — 17 ms against 3 ms for
# the real binary, half of a whole render — so a jq in a ".../shims" directory is passed over when
# a real one exists anywhere. The usual install locations are searched after $PATH too, because
# Claude Code started from a GUI launcher or an IDE often gets a minimal PATH without Homebrew's
# bin. All builtin tests, no fork. CLAUDE_SL_JQ pins the binary.
find_jq() {
  jq_bin="${CLAUDE_SL_JQ-}"
  if [ -n "$jq_bin" ]; then [ -x "$jq_bin" ]; return; fi
  local IFS=: dir shim=""
  set -f   # no globbing while $PATH is split on ":"
  for dir in $PATH /usr/bin /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.nix-profile/bin"; do
    [ -n "$dir" ] && [ -f "$dir/jq" ] && [ -x "$dir/jq" ] || continue
    case "$dir" in
      */shims|*/shims/*) [ -n "$shim" ] || shim="$dir/jq" ;;
      *) jq_bin="$dir/jq"; break ;;
    esac
  done
  set +f
  [ -n "$jq_bin" ] || jq_bin="$shim"
  [ -n "$jq_bin" ]
}
if ! find_jq; then
  # Say so, rather than render a row of empty gauges that looks like a Claude Code problem.
  printf '%s' "${C_RESET}${C_YELLOW}statusline: jq not found — install jq (brew install jq / apt install jq)${C_RESET}"
  exit 0
fi

# --- Extract all fields in a single jq call ---
# Every field is read through a helper that turns "wrong shape" into "missing": the payload has
# changed shape between Claude Code versions before (effort and output_style have each been a
# string and an object), and one jq type error would otherwise abort the whole program and blank
# every field after it. s() keeps strings and numbers, p() keeps numbers, n() keeps a whole number
# (an epoch).
cwd="" model="" ctx_pct="" output_style="" session_id="" effort="" cc_version="" fast_mode=""
five_hour_pct="" five_hour_reset=0 seven_day_pct="" seven_day_reset=0
eval "$("$jq_bin" -r '
  def s(f): (try f catch null) | if type == "string" or type == "number" then . else "" end;
  def p(f): (try f catch null) | if type == "number" then . else "" end;
  def n(f): (try f catch null) | if type == "number" then floor else 0 end;
  @sh "cwd=\((s(.workspace.current_dir) | select(. != "")) // s(.cwd))",
  @sh "model=\(s(.model.display_name))",
  @sh "ctx_pct=\(p(.context_window.used_percentage))",
  @sh "output_style=\(s(.output_style | if type == "object" then .name else . end))",
  @sh "session_id=\(s(.session_id))",
  @sh "effort=\(s((.effort | if type == "object" then .level else . end) // .effortLevel // .effort_level))",
  @sh "five_hour_pct=\(p(.rate_limits.five_hour.used_percentage))",
  @sh "five_hour_reset=\(n(.rate_limits.five_hour.resets_at))",
  @sh "seven_day_pct=\(p(.rate_limits.seven_day.used_percentage))",
  @sh "seven_day_reset=\(n(.rate_limits.seven_day.resets_at))",
  @sh "cc_version=\(s(.version))",
  @sh "fast_mode=\(if (try .fast_mode catch null) == true then "1" else "" end)"
' <<< "$input" 2>/dev/null)"
model="${model#Claude }"
# Compact any "(1M context)" / "(200K context)" annotation to just the size token, so every
# model name stays short regardless of tier: "Opus 4.7 (1M context)" → "Opus 4.7 1M".
if [[ "$model" =~ ^(.+)\ \(([0-9]+[KMkm])\ context\)$ ]]; then
  model="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
fi

# --- Cache directory ---
# Every cache below lives here. macOS's $TMPDIR is already private to the user and is used as is.
# Anywhere the temp dir is shared — Linux, where $TMPDIR is usually unset and /tmp belongs to
# everyone, or a $TMPDIR pointed at /tmp — the caches get a private per-uid subdirectory (created
# once, mode 700). "Shared" is judged with builtin tests: not ours (-O), or sticky (-k) like /tmp.
# The subdirectory is only trusted when it's a real directory we own: cache files are written
# under predictable names, so a directory another user created first (or a symlink they planted)
# would let them read usage data or redirect our writes. If the temp dir is missing or read-only
# (a stale $TMPDIR, a sandbox), fall back to ~/.cache — with no writable cache every tick would
# re-run git and nothing would sync between sessions.
# CLAUDE_SL_CACHE_DIR overrides it (the test suite uses this for isolation).
private_dir() {   # $1 = directory to create if needed; succeeds only if it's ours and writable
  # shellcheck disable=SC2174  # -m applying to the leaf only is what's wanted
  [ -d "$1" ] || mkdir -p -m 700 "$1" 2>/dev/null
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -w "$1" ]
}
if [ -n "${CLAUDE_SL_CACHE_DIR-}" ]; then
  cache_dir="$CLAUDE_SL_CACHE_DIR"
else
  cache_dir="${TMPDIR:-/tmp}"
  [ "$cache_dir" = "/" ] || cache_dir="${cache_dir%/}"
  if ! { [ -d "$cache_dir" ] && [ -O "$cache_dir" ] && [ -w "$cache_dir" ] && [ ! -k "$cache_dir" ]; }; then
    if private_dir "${cache_dir%/}/claude-sl-${UID}"; then
      cache_dir="${cache_dir%/}/claude-sl-${UID}"
    elif private_dir "${XDG_CACHE_HOME:-$HOME/.cache}/claude-sl"; then
      cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sl"
    fi
  fi
fi

# --- Which Claude account is logged in? ---
# Rate limits belong to an account, and Claude Code's login is global — /login switches every
# running session at once — so the shared snapshot below is keyed by account. Switching away and
# back then restores that account's own last-known usage instead of showing the other account's.
# The id comes from oauthAccount in ~/.claude.json (CLAUDE_CONFIG_DIR relocates the dir), which is
# rewritten the moment a login completes. That file can grow large on long-lived installs, so the
# lookup is cached for 5s — the same TTL as the git cache, and far shorter than a login flow takes,
# so a switch is still picked up effectively immediately.
# CLAUDE_SL_ACCOUNT pins the id explicitly (used by the test suite). An unknown account — logged
# out, or API-key auth, which has no subscription rate limits at all — falls back to the
# unsuffixed snapshot, which is also what installs that predate this keying already use.
# The same lookup also yields the account's email address, shown on row 3 so you can see which
# login a session is on. CLAUDE_SL_ACCOUNT_LABEL pins/overrides what is displayed.
account="${CLAUDE_SL_ACCOUNT-}"
account_label=""
if [ -z "${CLAUDE_SL_ACCOUNT+set}" ]; then
  # Record format: "<checked_at>\037<account>\037<email>". The check time lives in the file so its
  # age costs a builtin read rather than a stat fork. A file from an older version (bare account)
  # reads as never checked and is refreshed.
  # Sessions started with different CLAUDE_CONFIG_DIRs are different logins running side by side,
  # so each config dir gets its own record — one shared record would hand profile A's account to
  # profile B for up to 5s, and B would then publish its usage into A's snapshot.
  acct_cache="${cache_dir}/claude-sl-account"
  if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
    acct_key="${CLAUDE_CONFIG_DIR//[^A-Za-z0-9._-]/_}"
    (( ${#acct_key} > 100 )) && acct_key="${acct_key: -100}"
    acct_cache="${acct_cache}-${acct_key}"
  fi
  acct_at="" cached_account="" cached_label=""
  [ -f "$acct_cache" ] && IFS=$'\037' read -r acct_at cached_account cached_label < "$acct_cache" 2>/dev/null
  [[ "$acct_at" =~ ^[0-9]+$ ]] || acct_at=0
  if (( now_ts - acct_at >= 5 )); then
    cc_config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    if [ -r "$cc_config" ]; then
      # Indexing a missing/null .oauthAccount yields null in jq, so this stays quiet when logged out.
      IFS=$'\037' read -r account account_label < <("$jq_bin" -r '
        .oauthAccount | "\(.accountUuid // .emailAddress // "")\u001f\(.emailAddress // "")"' "$cc_config" 2>/dev/null)
    fi
    # Reduce to a safe filename component — the uuid already is one, an email address isn't.
    account="${account//[^A-Za-z0-9._-]/_}"
    # Temp files are dot-prefixed so they can never be globbed as an account snapshot below, and
    # named by PID ($$) so concurrent sessions never share one — no mktemp fork needed.
    tmp_acct="${cache_dir}/.claude-sl-account.$$"
    printf '%s\037%s\037%s' "$now_ts" "$account" "$account_label" > "$tmp_acct" 2>/dev/null && mv "$tmp_acct" "$acct_cache"
  else
    account="$cached_account"; account_label="$cached_label"
  fi
fi
[ -n "${CLAUDE_SL_ACCOUNT_LABEL+set}" ] && account_label="$CLAUDE_SL_ACCOUNT_LABEL"
account_label="${account_label//[^[:print:]]/}"
# --- Rate-limit sync across sessions (login/logout, concurrent sessions, limit changes) ---
# Claude Code holds rate limits in memory per process, filled in only from API response headers,
# so any one session's payload can be stale: a brand-new session has no rate_limits until its
# first response, and an idle session replays the same numbers — a pegged 100%, the window as it
# stood before a limit boost, the account you switched away from — until its next API call.
# Nothing in the payload says WHEN those numbers were fetched, so this script measures it: a
# process only changes its rate limits when a new response arrives, so a value that differs from
# what this session reported on its previous tick was fetched now, and an unchanged value is a
# replay that keeps its original fetch time. Every session records what it last reported (keyed by
# session id) and publishes its observation to a per-account shared snapshot; every render shows
# whichever observation — this payload's or the shared file's — is newer. Freshness is never
# inferred from the numbers themselves: "usage only grows within a window" is false the moment a
# limit is boosted or reset, and that inference once pinned a spent window at 100% until it expired.
# Per window:
#   1. an unexpired observation beats an expired one (expired = resets_at in the past). A payload
#      still anchored to a window that ended was fetched before it ended, so anything anchored to
#      the window that followed is newer — a fact that holds even for a session with no record yet.
#   2. otherwise the later fetch wins; ties go to the live payload.
# If the winner is itself expired, the window has rolled over: usage renders as 0% with no ↻,
# because the next window's anchor is unknown until the next API response.
# CLAUDE_SL_CACHE_DIR overrides the location (used by the test suite for isolation).
rate_cache="${cache_dir}/claude-sl-rate"
[ -n "$account" ] && rate_cache="${rate_cache}-${account}"

# --- What did THIS session report last tick, and when was it fetched? ---
# Record format: "<account>\037<5h%>\037<5h reset>\037<7d%>\037<7d reset>\037<fetched_at>".
#   - no record yet              → first sight: fetched now (a new process prefetches its quota
#                                  at startup, so its first numbers are genuinely fresh)
#   - values changed             → fetched now, under the current account
#   - unchanged, same account    → a replay; keep the recorded fetch time
#   - unchanged, account changed → these numbers belong to the account this session was logged
#                                  into when it fetched them. /login is global, so an idle session
#                                  keeps replaying the previous account's limits: drop them —
#                                  neither render nor publish them as the new account's.
observed_at="$now_ts"
seen_record=""
[ -n "$session_id" ] && seen_record="${cache_dir}/claude-sl-seen-${session_id//[^A-Za-z0-9._-]/_}"
if [ -n "$seen_record" ] && { [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ]; }; then
  seen_acct="" seen_5pct="" seen_5rst="" seen_7pct="" seen_7rst="" seen_at=""
  if [ -f "$seen_record" ]; then
    IFS=$'\037' read -r seen_acct seen_5pct seen_5rst seen_7pct seen_7rst seen_at < "$seen_record" 2>/dev/null
  fi
  if [ -f "$seen_record" ] && [ "$five_hour_pct" = "$seen_5pct" ] && [ "$five_hour_reset" = "$seen_5rst" ] \
     && [ "$seven_day_pct" = "$seen_7pct" ] && [ "$seven_day_reset" = "$seen_7rst" ]; then
    if [ "$seen_acct" = "$account" ]; then
      [[ "$seen_at" =~ ^[0-9]+$ ]] && observed_at="$seen_at"
    else
      five_hour_pct=""; five_hour_reset=0; seven_day_pct=""; seven_day_reset=0
    fi
  else
    # Temp files are dot-prefixed so they can never be globbed as an account snapshot below.
    tmp_seen="${cache_dir}/.claude-sl-seen.$$"
    printf '%s\037%s\037%s\037%s\037%s\037%s' "$account" "$five_hour_pct" "$five_hour_reset" \
      "$seven_day_pct" "$seven_day_reset" "$now_ts" > "$tmp_seen" 2>/dev/null && mv "$tmp_seen" "$seen_record"
  fi
fi

# Second guard for the same carry-over, covering a session that has no record yet (it started
# under an older version of this script, or its record was cleaned out of $TMPDIR): a payload that
# matches another account's snapshot exactly — same used% AND the same resets_at second — is that
# account's data. Windows are anchored per account at first use, so two accounts never share a
# reset second; the exact match is what makes this safe. Each window is judged on its own.
for other in "${cache_dir}"/claude-sl-rate "${cache_dir}"/claude-sl-rate-*; do
  # Nothing left to vet once both windows have been dropped (or never arrived).
  [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ] || break
  # Skip this account's own snapshot, and the unexpanded glob when no other account has one.
  [ -f "$other" ] && [ "$other" != "$rate_cache" ] || continue
  other_5pct="" other_5rst="" other_7pct="" other_7rst=""
  IFS=$'\037' read -r other_5pct other_5rst other_7pct other_7rst _ < "$other" 2>/dev/null
  if [ -n "$five_hour_pct" ] && [ "$five_hour_pct" = "$other_5pct" ] \
     && [ "$five_hour_reset" = "$other_5rst" ] && [[ "$five_hour_reset" =~ ^[1-9][0-9]*$ ]]; then
    five_hour_pct=""; five_hour_reset=0
  fi
  if [ -n "$seven_day_pct" ] && [ "$seven_day_pct" = "$other_7pct" ] \
     && [ "$seven_day_reset" = "$other_7rst" ] && [[ "$seven_day_reset" =~ ^[1-9][0-9]*$ ]]; then
    seven_day_pct=""; seven_day_reset=0
  fi
done

# args: pct_a reset_a seen_a pct_b reset_b seen_b — a is the live payload, b the shared snapshot.
# Leaves the winner in _w_pct/_w_reset/_w_seen.
pick_window() {
  local pa="$1" ra="$2" ta="$3" pb="$4" rb="$5" tb="$6"
  [[ "$ra" =~ ^[0-9]+$ ]] || ra=0
  [[ "$rb" =~ ^[0-9]+$ ]] || rb=0
  [[ "$ta" =~ ^[0-9]+$ ]] || ta=0
  [[ "$tb" =~ ^[0-9]+$ ]] || tb=0
  local ea=0 eb=0
  (( ra > 0 && ra <= now_ts )) && ea=1
  (( rb > 0 && rb <= now_ts )) && eb=1
  _w_pct="$pa"; _w_reset="$ra"; _w_seen="$ta"
  if [ -z "$pa" ]; then
    _w_pct="$pb"; _w_reset="$rb"; _w_seen="$tb"
  elif [ -n "$pb" ]; then
    if (( (ea && !eb) || (ea == eb && tb > ta) )); then
      _w_pct="$pb"; _w_reset="$rb"; _w_seen="$tb"
    fi
  fi
  # Winner already expired → the window rolled over; show a fresh (empty) window.
  if [ -n "$_w_pct" ] && (( _w_reset > 0 && _w_reset <= now_ts )); then
    _w_pct=0; _w_reset=0
  fi
}

# Snapshot format: "<5h%>\037<5h reset>\037<7d%>\037<7d reset>\037<5h fetched_at>\037<7d fetched_at>".
# The fetch times trail so a file written by an older version (four fields) reads as fetched at
# time 0 — older than anything live — instead of shifting the weekly fields.
cached_5pct="" cached_5rst="" cached_7pct="" cached_7rst="" cached_5at="" cached_7at=""
if [ -f "$rate_cache" ]; then
  IFS=$'\037' read -r cached_5pct cached_5rst cached_7pct cached_7rst cached_5at cached_7at < "$rate_cache" 2>/dev/null
fi
payload_had_rate=""
if [ -n "$five_hour_pct" ] || [ -n "$seven_day_pct" ]; then payload_had_rate=1; fi
pick_window "$five_hour_pct" "$five_hour_reset" "$observed_at" "$cached_5pct" "$cached_5rst" "$cached_5at"
five_hour_pct="$_w_pct"; five_hour_reset="$_w_reset"; five_hour_at="$_w_seen"
pick_window "$seven_day_pct" "$seven_day_reset" "$observed_at" "$cached_7pct" "$cached_7rst" "$cached_7at"
seven_day_pct="$_w_pct"; seven_day_reset="$_w_reset"; seven_day_at="$_w_seen"
# Publish the merged snapshot only when this payload actually carried rate data — a data-less
# tick (new session pre-first-response, or a dropped carry-over) must never rewrite the shared
# file it just read from — and only when the merged result differs from what's already there (an
# idle tick replays the same numbers; rewriting them would cost a write + mv fork every tick).
# Atomic temp+mv, same pattern as the git cache below.
rate_line="${five_hour_pct}"$'\037'"${five_hour_reset}"$'\037'"${seven_day_pct}"$'\037'"${seven_day_reset}"$'\037'"${five_hour_at}"$'\037'"${seven_day_at}"
cached_line="${cached_5pct}"$'\037'"${cached_5rst}"$'\037'"${cached_7pct}"$'\037'"${cached_7rst}"$'\037'"${cached_5at}"$'\037'"${cached_7at}"
rate_changed=""
[ "$rate_line" != "$cached_line" ] && rate_changed=1
if [ -n "$payload_had_rate" ] && [ -n "$rate_changed" ]; then
  tmp_rate="${cache_dir}/.claude-sl-rate.$$"
  printf '%s' "$rate_line" > "$tmp_rate" 2>/dev/null && mv "$tmp_rate" "$rate_cache"
fi

# --- Authoritative usage from Anthropic's OAuth usage endpoint (what the /usage view shows) ---
# The header-fed observations above can only change when some session makes an API call. If
# every session is idle when Anthropic boosts or resets a limit, nothing updates until one of
# them does. GET https://api.anthropic.com/api/oauth/usage is the source the /usage view reads —
# it takes the OAuth token Claude Code already holds (macOS Keychain "Claude Code-credentials";
# ~/.claude/.credentials.json elsewhere) and returns both windows as 0–100 percentages with ISO
# reset times, which land within a second of the header anchors. Its result is simply one more
# timestamped observation for pick_window, so the newest of {live payload, shared snapshot, API}
# wins under the same two rules.
# The call never blocks a tick: it runs detached in the background, and only when the newest
# observation on hand is older than CLAUDE_SL_USAGE_TTL seconds (default 180 — this endpoint 429s
# aggressively when polled faster; active sessions refresh from headers every turn, so in practice
# it fires only while idle). One fetch per account at a time (mkdir lock), failures back off for
# 10 minutes (a missing or expired token for 1), and the result is cached per account. Set CLAUDE_SL_USAGE_TTL=0 to disable the
# endpoint entirely; CLAUDE_SL_USAGE_TOKEN / CLAUDE_SL_USAGE_URL override the token and URL (the
# test suite points the URL at a local fixture).
usage_ttl="${CLAUDE_SL_USAGE_TTL-180}"
[[ "$usage_ttl" =~ ^[0-9]+$ ]] || usage_ttl=180
usage_file="${cache_dir}/claude-sl-usage"
[ -n "$account" ] && usage_file="${usage_file}-${account}"
# The endpoint also reports what the statusline payload doesn't carry at all: per-model weekly
# limits ("weekly_scoped" — e.g. a Fable-only allowance that can run out before the all-models
# one). They trail the record as "<model>=<used%>=<reset>;…", and the one for the model this
# session is running gets its own gauge on row 2.
api_5pct="" api_5rst="" api_7pct="" api_7rst="" api_at="" api_scoped=""
if [ -f "$usage_file" ]; then
  IFS=$'\037' read -r api_5pct api_5rst api_7pct api_7rst api_at api_scoped < "$usage_file" 2>/dev/null
fi
[[ "$api_at" =~ ^[0-9]+$ ]] || api_at=0
model_limit_name="" model_limit_pct="" model_limit_reset=0
if [ -n "$api_scoped" ] && [ -n "$model" ]; then
  IFS=';' read -r -a scoped_limits <<< "$api_scoped"
  for entry in "${scoped_limits[@]}"; do
    IFS='=' read -r s_name s_pct s_reset <<< "$entry"
    [ -n "$s_name" ] && [[ "$s_pct" =~ ^[0-9] ]] && [[ "$model" == *"$s_name"* ]] || continue
    [[ "$s_reset" =~ ^[0-9]+$ ]] || s_reset=0
    # A limit whose reset has passed has rolled over; its old reading means nothing now.
    (( s_reset > 0 && s_reset <= now_ts )) && continue
    model_limit_name="$s_name"; model_limit_pct="$s_pct"; model_limit_reset="$s_reset"
    break
  done
fi
pick_window "$five_hour_pct" "$five_hour_reset" "$five_hour_at" "$api_5pct" "$api_5rst" "$api_at"
five_hour_pct="$_w_pct"; five_hour_reset="$_w_reset"; five_hour_at="$_w_seen"
pick_window "$seven_day_pct" "$seven_day_reset" "$seven_day_at" "$api_7pct" "$api_7rst" "$api_at"
seven_day_pct="$_w_pct"; seven_day_reset="$_w_reset"; seven_day_at="$_w_seen"

# Read the OAuth access token Claude Code is logged in with. Empty when unavailable or expired
# (Claude Code refreshes an expired token on its next API call; until then there is nothing to do).
read_oauth_token() {
  _token="${CLAUDE_SL_USAGE_TOKEN-}"
  [ -n "$_token" ] && return 0
  local creds=""
  if [[ "${OSTYPE-}" == darwin* ]]; then
    # With CLAUDE_CONFIG_DIR set, Claude Code stores that profile's login under its own Keychain
    # item: the service name gains "-<first 8 hex of sha256(config dir)>". Reading the plain item
    # there would fetch the DEFAULT profile's usage and file it under this profile's account. If
    # the hash can't be computed the lookup simply misses — it never falls back to the plain item.
    local service="Claude Code-credentials" dir_hash
    if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
      dir_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 2>/dev/null)
      service="${service}-${dir_hash:0:8}"
    fi
    creds=$(security find-generic-password -s "$service" -w 2>/dev/null)
  fi
  if [ -z "$creds" ]; then
    local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    [ -r "$creds_file" ] && creds=$(cat "$creds_file" 2>/dev/null)
  fi
  [ -n "$creds" ] || return 1
  _token=$(printf '%s' "$creds" | "$jq_bin" -r --argjson now_ms "$(( now_ts * 1000 ))" '
    .claudeAiOauth
    | if (.accessToken // "") != "" and ((.expiresAt // 0) == 0 or .expiresAt > $now_ms)
      then .accessToken else "" end' 2>/dev/null)
  [ -n "$_token" ]
}

# Fetch once, in the background. Writes
# "<5h%>\037<5h reset>\037<7d%>\037<7d reset>\037<fetched_at>\037<per-model limits>"
# to $usage_file on success, or "<http code>\037<time>" to $usage_file.err on failure.
fetch_usage_in_background() {
  local lock="${usage_file}.lock"
  # mkdir is atomic: the first session to get it fetches, the rest skip. A lock older than a
  # minute belongs to a fetch that died (killed mid-flight, machine slept) and is reclaimed.
  if ! mkdir "$lock" 2>/dev/null; then
    local lock_mtime; lock_mtime=$(file_mtime "$lock"); [[ "$lock_mtime" =~ ^[0-9]+$ ]] || lock_mtime=$now_ts
    local lock_age=$(( now_ts - lock_mtime ))
    (( lock_age >= 60 )) || return 0
    rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
  fi
  (
    trap 'rm -rf "$lock"' EXIT
    # No usable token (expired until Claude Code's next API call refreshes it, or none stored):
    # leave a short-lived marker so the Keychain isn't re-queried on every tick meanwhile.
    if ! read_oauth_token; then
      printf 'notoken\037%s' "$now_ts" > "${usage_file}.err" 2>/dev/null
      exit 0
    fi
    local url="${CLAUDE_SL_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
    local resp code body parsed
    # User-Agent matters: without Claude Code's own UA the endpoint answers from a far stricter
    # rate-limit bucket. The trailing http code is split off the body below.
    resp=$(curl -sS -m 10 -w $'\n%{http_code}' \
      -H "Authorization: Bearer ${_token}" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/${cc_version}" \
      -H "Accept: application/json" "$url" 2>/dev/null)
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    # resets_at is ISO 8601 with fractional seconds and a +00:00 offset. jq's fromdateiso8601
    # only reads "...SSZ", so strip the fraction and normalise the zero offset; any other offset
    # (or a null) yields 0 = "no anchor". Round a fractional instant UP so it matches the header
    # anchor for the same window (59.77s → :00) instead of rendering a minute earlier.
    parsed=$(printf '%s' "$body" | "$jq_bin" -r '
      def epoch: try (
        capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<f>[0-9]+))?(?<z>Z|\\+00:00)$") as $m
        | ($m.b + "Z" | fromdateiso8601) + (if (($m.f // "0") | tonumber) > 0 then 1 else 0 end)
      ) catch 0;
      [ (.five_hour.utilization // ""), (.five_hour.resets_at | epoch),
        (.seven_day.utilization // ""), (.seven_day.resets_at | epoch),
        ([ (try .limits[] catch empty)
           | select(type == "object" and .kind == "weekly_scoped" and (.percent | type) == "number")
           | ((try .scope.model.display_name catch null) // "" | tostring | gsub("[^A-Za-z0-9 .-]"; "")) as $name
           | select($name != "")
           | "\($name)=\(.percent)=\(.resets_at | epoch)" ] | join(";")) ]
      | map(tostring) | join("\u001f")' 2>/dev/null)
    local fetched_at; fetched_at=${EPOCHSECONDS:-$(date +%s)}
    # Either window may be null — an account can have a weekly limit and no 5-hour window at all —
    # so the answer is good when at least one of them carries a number.
    local got_5pct got_5rst got_7pct got_7rst got_scoped
    IFS=$'\037' read -r got_5pct got_5rst got_7pct got_7rst got_scoped <<< "$parsed"
    if { [ "$code" = "200" ] || [ "$code" = "000" ]; } && { [[ "$got_5pct" =~ ^[0-9] ]] || [[ "$got_7pct" =~ ^[0-9] ]]; }; then
      local tmp="${cache_dir}/.claude-sl-usage.$$"
      printf '%s\037%s\037%s\037%s\037%s\037%s' "$got_5pct" "$got_5rst" "$got_7pct" "$got_7rst" \
        "$fetched_at" "$got_scoped" > "$tmp" 2>/dev/null && mv "$tmp" "$usage_file"
      rm -f "${usage_file}.err"
    else
      printf '%s\037%s' "${code:-000}" "$fetched_at" > "${usage_file}.err" 2>/dev/null
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
}

if (( usage_ttl > 0 )) && [ -n "$account" ] && [ -n "$cc_version" ]; then
  newest_at=0
  for t in "$five_hour_at" "$seven_day_at" "$api_at"; do
    [[ "$t" =~ ^[0-9]+$ ]] && (( t > newest_at )) && newest_at="$t"
  done
  err_at=0 err_code="" backoff=600
  if [ -f "${usage_file}.err" ]; then
    IFS=$'\037' read -r err_code err_at < "${usage_file}.err" 2>/dev/null
    [[ "$err_at" =~ ^[0-9]+$ ]] || err_at=0
    # A missing/expired token clears itself on Claude Code's next API call: retry after a minute.
    [ "$err_code" = "notoken" ] && backoff=60
  fi
  # Per-model limits come from nowhere else, so headers can't keep them fresh: an account that
  # has any is re-asked every 5 minutes even while active (never faster — the endpoint 429s).
  scoped_due=0
  if [ -n "$api_scoped" ]; then
    scoped_ttl=$(( usage_ttl > 300 ? usage_ttl : 300 ))
    (( now_ts - api_at >= scoped_ttl )) && scoped_due=1
  fi
  if { (( now_ts - newest_at >= usage_ttl )) || (( scoped_due )); } && (( now_ts - err_at >= backoff )); then
    fetch_usage_in_background
  fi
fi

# --- Git branch + lines changed (cached; refreshed on a 5s TTL OR the moment the checkout moves) ---
# Cache key includes cwd so concurrent sessions in different repos don't clash.
# Using parameter expansion (not shasum) keeps this subprocess-free.
# Atomic write (PID-named temp file + mv) prevents partial reads on concurrent ticks.
#
# Cache fields are separated by the ASCII Unit Separator (\037):
#   "<branch>\037<worktree>\037<added>\037<removed>\037<gitdir>\037<head>\037<written_at>"
# (worktree empty in the main checkout; added/removed/gitdir/head empty outside a git repo). It
# must NOT be tab/space/newline: those are IFS-whitespace, and `read` collapses runs of
# IFS-whitespace into a single delimiter — so an empty worktree field (the common case) would
# vanish and shift <added> into the worktree slot (rendering a bogus "↳ 35"). \037 is a
# non-whitespace delimiter that read keeps as a literal field boundary, preserving empties, and it
# can never occur in a branch name, path, or count.
#
# <gitdir>/<head>/<written_at> exist so a cache HIT costs zero subprocesses and a branch switch is
# picked up on the very next tick instead of up to 5s later (the way gitstatusd and starship key on
# repo state rather than wall-clock): <head> is the literal content of $gitdir/HEAD ("ref: refs/
# heads/x", or a hash when detached), which git rewrites on every checkout; and bash's builtin
# `-nt` compares the index's mtime against the cache file's, which catches checkout/add/commit/
# reset/stash without a stat(1) fork. Unstaged edits don't touch the index, so those still ride the
# 5s TTL. GIT_OPTIONAL_LOCKS=0 (git's env form of --no-optional-locks, covering every call below)
# matters here: without it, `git diff` would opportunistically rewrite the index after refreshing
# its stat cache and re-trigger us forever.
export GIT_OPTIONAL_LOCKS=0
git_branch=""
git_worktree=""
git_added=""
git_removed=""
if [ -n "$cwd" ]; then
  git_key="${cwd//\//_}"
  # A file name tops out at 255 bytes. A deep path used as the name would make every cache write
  # fail — silently, so git would run in full on every tick. Long keys become a hash of the whole
  # path plus its recognisable tail (builtin arithmetic; multi-byte characters can be 4 bytes each,
  # hence the conservative lengths).
  if (( ${#git_key} > 60 )); then
    key_hash=0
    for (( i = 0; i < ${#git_key}; i++ )); do
      printf -v key_ch '%d' "'${git_key:i:1}" 2>/dev/null
      key_hash=$(( (key_hash * 31 + ${key_ch:-0}) & 0x7fffffff ))
    done
    git_key="_${key_hash}_${git_key: -40}"
  fi
  cache_file="${cache_dir}/claude-sl-git${git_key}"
  c_gitdir=""; c_head=""; c_at=""
  if [ -f "$cache_file" ]; then
    IFS=$'\037' read -r git_branch git_worktree git_added git_removed c_gitdir c_head c_at < "$cache_file" 2>/dev/null
  fi
  [[ "$c_at" =~ ^[0-9]+$ ]] || c_at=0
  refresh=0
  if (( now_ts - c_at >= 5 )); then
    refresh=1
  elif [ -n "$c_gitdir" ]; then
    head_now=""
    [ -r "$c_gitdir/HEAD" ] && read -r head_now < "$c_gitdir/HEAD"
    if [ "$head_now" != "$c_head" ] || [ "$c_gitdir/index" -nt "$cache_file" ]; then refresh=1; fi
  fi
  if [ "$refresh" = 1 ]; then
    git_branch=""; git_worktree=""; git_added=""; git_removed=""
    gitdir=""; toplevel=""; head_now=""
    # ONE rev-parse answers "am I in a repo / where is the git-dir / where is the checkout root /
    # what branch" (it used to be four calls). On an unborn branch the exit is non-zero but the
    # first two lines still print; on unborn AND detached the branch line is the literal "HEAD".
    { read -r gitdir; read -r toplevel; read -r git_branch; } < <(
      git -C "$cwd" rev-parse --absolute-git-dir --show-toplevel --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$gitdir" ]; then
      if [ -z "$git_branch" ] || [ "$git_branch" = "HEAD" ]; then
        # Unborn (symbolic-ref still knows the branch name) or detached (short hash).
        git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
          || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
      fi
      [ -r "$gitdir/HEAD" ] && read -r head_now < "$gitdir/HEAD"
      # A linked worktree's git-dir is <repo>/.git/worktrees/<id>; the main worktree's isn't —
      # use that to detect "am I in a linked worktree?". But DON'T label with git's internal <id>:
      # git derives it by sanitizing/deduplicating the checkout basename, so it can degrade to a
      # bare "0", "-", "1", etc. on collision or special characters. Label with the checkout
      # directory's own name (via --show-toplevel) — the name the user actually recognizes.
      case "$gitdir" in
        */worktrees/*) git_worktree="${toplevel##*/}" ;;
      esac

      # Lines changed in THIS branch/worktree since it forked off its base: every line that
      # differs from the fork point (merge-base), committed AND uncommitted. We diff the working
      # tree against the merge-base commit (two-dot, not three-dot commit..commit) so staged +
      # unstaged edits to tracked files count alongside committed ones. Brand-new UNTRACKED files
      # are intentionally excluded — they'd otherwise pull in generated, non-gitignored dirs
      # (build output, tool indexes) and inflate the count; a new file lands here once you stage it.
      #
      # The base is the newest point where this branch agrees with ANY of its candidate parents:
      #   * the mainline refs (main/master, origin/HEAD for repos whose default branch is named
      #     something else, and origin/main|master);
      #   * for STACKED branches, the recorded parent — whichever tool recorded it: gh's
      #     `branch.<b>.gh-merge-base`, git-town's `git-town-branch.<b>.parent`, Graphite's
      #     `refs/branch-metadata/<b>` blob, or plain git's local upstream (`branch.<b>.remote=.`
      #     + `branch.<b>.merge=refs/heads/<parent>`). Without this, a child branch would count
      #     every line of its parent as its own.
      # All candidates go into ONE `git merge-base HEAD a b c...` call: with 3+ args git returns
      # the merge-base of HEAD and a *hypothetical merge of all the others*, i.e. the newest
      # common ancestor with any of them. That is exactly what makes a STALE local main harmless —
      # after `git merge origin/main` into a feature branch, merge-base(HEAD, main) is still the
      # original fork point (so +86750/-122827 of upstream work looked like yours), but
      # origin/main's is the merged tip, and the hypothetical merge picks it. Same for a stale
      # parent: it's the child's tip after `git merge origin/parent`, or the mainline tip if the
      # parent was merged and deleted. On main itself the base is HEAD, so only uncommitted lines
      # count. Candidates that don't exist are dropped first (merge-base refuses unknown refs).
      parent=""
      if [ -n "$git_branch" ]; then
        # ONE `git config` read covers gh, git-town and local-upstream at once. Keys are matched
        # exactly in the loop (not in the regexp) so branch names with regex chars are safe.
        up_remote=""; up_merge=""
        while read -r key val; do
          case "$key" in
            "branch.${git_branch}.gh-merge-base") parent="$val" ;;
            "git-town-branch.${git_branch}.parent") [ -n "$parent" ] || parent="$val" ;;
            "branch.${git_branch}.remote") up_remote="$val" ;;
            "branch.${git_branch}.merge") up_merge="$val" ;;
          esac
        done < <(git -C "$cwd" config --get-regexp \
          '^(branch|git-town-branch)\..*\.(gh-merge-base|parent|remote|merge)$' 2>/dev/null)
        # A local upstream (remote ".") is git's own way to say "this branch stacks on that one".
        if [ -z "$parent" ] && [ "$up_remote" = "." ] && [ "${up_merge#refs/heads/}" != "$up_merge" ]; then
          parent="${up_merge#refs/heads/}"
        fi
      fi
      # No tool recorded a parent? Git itself usually did: the branch's first reflog entry reads
      # "branch: Created from <start-point>" when it was made with an explicit start point
      # (`git checkout -b child parent`, `git worktree add -b child <path> parent`). Read with
      # builtins, no subprocess. Branch refs' reflogs live in the COMMON git-dir, not a linked
      # worktree's private one. "Created from HEAD" (no start point given) tells us nothing, so it's
      # skipped. It's a fallback candidate, kept apart from $parent so Graphite still gets its turn.
      created_from=""
      if [ -z "$parent" ] && [ -n "$git_branch" ]; then
        common="$gitdir"
        if [ -r "$gitdir/commondir" ]; then
          read -r common < "$gitdir/commondir"
          [ "${common#/}" = "$common" ] && common="$gitdir/$common"
        fi
        first_log=""
        [ -r "$common/logs/refs/heads/$git_branch" ] && read -r first_log < "$common/logs/refs/heads/$git_branch"
        if [[ "$first_log" == *$'\t'"branch: Created from "* ]]; then
          created_from="${first_log#*$'\t'branch: Created from }"
          created_from="${created_from#refs/heads/}"
          created_from="${created_from#refs/remotes/}"
          created_from="${created_from#origin/}"
          case "$created_from" in
            HEAD|"$git_branch"|main|master) created_from="" ;;
          esac
        fi
      fi
      bases=()
      gt_meta=""
      # ONE for-each-ref tells us which candidate refs exist (it used to be a rev-parse --verify
      # per candidate), and whether Graphite has metadata for this branch.
      while read -r ref; do
        case "$ref" in
          refs/branch-metadata/*) gt_meta="$ref" ;;
          "") ;;
          *) bases+=("$ref") ;;
        esac
      done < <(git -C "$cwd" for-each-ref --format='%(refname)' \
        refs/heads/main refs/heads/master refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master \
        ${parent:+"refs/heads/$parent" "refs/remotes/origin/$parent"} \
        ${created_from:+"refs/heads/$created_from" "refs/remotes/origin/$created_from"} \
        ${git_branch:+"refs/branch-metadata/$git_branch"} 2>/dev/null)
      if [ -z "$parent" ] && [ -n "$gt_meta" ]; then
        # Graphite: the ref points at a JSON blob {"parentBranchName":"...", ...}. Only Graphite
        # users pay for these two extra calls.
        gt_json=$(git -C "$cwd" cat-file -p "$gt_meta" 2>/dev/null)
        if [[ "$gt_json" =~ \"parentBranchName\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
          parent="${BASH_REMATCH[1]}"
          while read -r ref; do
            [ -n "$ref" ] && bases+=("$ref")
          done < <(git -C "$cwd" for-each-ref --format='%(refname)' \
            "refs/heads/$parent" "refs/remotes/origin/$parent" 2>/dev/null)
        fi
      fi
      diff_base="HEAD"
      if [ "${#bases[@]}" -gt 0 ]; then
        # --all: a stacked branch that ALSO merged main in has two best common ancestors — the
        # parent's tip and main's tip, neither containing the other. Plain merge-base picks one
        # arbitrarily, and the diff then counts the other side's lines as ours (+7192 instead of
        # +54 in a real repo). What we want is "both sides merged", so diff against the tree
        # `merge-tree` builds from the two (git >= 2.38; its first output line is the tree id, even
        # on conflict — conflicted files then carry markers, a small over-count we accept). This
        # extra call happens only in the multi-base case; on older git we fall back to one base.
        mbs=()
        while read -r ref; do [ -n "$ref" ] && mbs+=("$ref"); done < <(
          git -C "$cwd" merge-base --all HEAD "${bases[@]}" 2>/dev/null)
        if [ "${#mbs[@]}" -gt 0 ]; then
          diff_base="${mbs[0]}"
          if [ "${#mbs[@]}" -gt 1 ]; then
            mt=""
            read -r mt < <(git -C "$cwd" merge-tree --write-tree "${mbs[0]}" "${mbs[1]}" 2>/dev/null)
            [[ "$mt" =~ ^[0-9a-f]{40,64}$ ]] && diff_base="$mt"
          fi
        fi
      fi
      # --shortstat lets git do the summing (no awk fork); LC_ALL=C pins the English words we
      # parse. Binary files aren't counted, and a clean tree prints nothing at all.
      stat_line=$(LC_ALL=C git -C "$cwd" diff --shortstat "$diff_base" 2>/dev/null)
      git_added=0; git_removed=0
      [[ "$stat_line" =~ ([0-9]+)\ insertion ]] && git_added="${BASH_REMATCH[1]}"
      [[ "$stat_line" =~ ([0-9]+)\ deletion ]] && git_removed="${BASH_REMATCH[1]}"
    fi
    tmp_cache="${cache_file}.$$"
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s' \
      "$git_branch" "$git_worktree" "$git_added" "$git_removed" "$gitdir" "$head_now" "$now_ts" > "$tmp_cache" 2>/dev/null \
      && mv "$tmp_cache" "$cache_file"
  fi
fi

# --- Installed Claude Code version (read from versioned symlink) ---
# ~/.local/bin/claude is a symlink whose target ends in the version. Checked every tick (no cache),
# so an auto-update shows up right away. CLAUDE_SL_INSTALLED_VERSION pins it (used by the test suite).
installed_version="${CLAUDE_SL_INSTALLED_VERSION-}"
if [ -z "${CLAUDE_SL_INSTALLED_VERSION+set}" ] && [ -n "$cc_version" ]; then
  claude_bin=$(command -v claude 2>/dev/null)
  if [ -n "$claude_bin" ] && [ -L "$claude_bin" ]; then
    # Common case first: the symlink already resolves to the running version's binary — a builtin
    # -ef (same inode) check, no readlink fork. Only a mismatch needs the target's name.
    if [ "$claude_bin" -ef "$HOME/.local/share/claude/versions/$cc_version" ]; then
      installed_version="$cc_version"
    else
      # Only the native installer's symlink ends in a version. npm's points at ".../cli.js" and
      # Homebrew's at ".../claude", which used to render as a permanent "vcli.js ↑".
      target=$(readlink "$claude_bin" 2>/dev/null)
      installed_version="${target##*/}"
      [[ "$installed_version" =~ ^[0-9]+(\.[0-9]+)+ ]] || installed_version=""
    fi
  fi
fi

# Determine if an update is available (installed version differs from running version)
update_available=""
if [ -n "$installed_version" ] && [ -n "$cc_version" ] && [ "$installed_version" != "$cc_version" ]; then
  update_available="1"
fi

# --- Session messaging name ---
# Claude Code sessions message each other by a short name ("loretta-76", "<repo>-d4"), not by the
# session UUID. The name isn't in the statusline payload; each running session records it in
# <config>/sessions/<pid>.json next to its sessionId. The statusline is normally a child of that
# claude process, so $PPID.json is tried first (one read, no fork); otherwise one grep finds the
# file holding this session_id. Read every tick, so a /rename shows up immediately.
# CLAUDE_SL_SESSIONS_DIR overrides the directory (used by the test suite).
messaging_name=""
if [ -n "$session_id" ]; then
  sessions_dir="${CLAUDE_SL_SESSIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions}"
  # Where the last tick found it, remembered per session so the grep runs once, not every tick.
  sess_hint="${cache_dir}/claude-sl-sessfile-${session_id//[^A-Za-z0-9._-]/_}"
  sess_file="${sessions_dir}/${PPID}.json"
  sess_json=""
  [ -r "$sess_file" ] && IFS= read -r -d '' sess_json < "$sess_file"
  if [[ "$sess_json" != *"\"$session_id\""* ]] && [ -f "$sess_hint" ]; then
    IFS= read -r sess_file < "$sess_hint"
    sess_json=""
    [ -r "$sess_file" ] && IFS= read -r -d '' sess_json < "$sess_file"
  fi
  if [[ "$sess_json" != *"\"$session_id\""* ]] && [ -d "$sessions_dir" ]; then
    sess_file=$(grep -lF -- "\"$session_id\"" "$sessions_dir"/*.json 2>/dev/null)
    sess_file="${sess_file%%$'\n'*}"
    sess_json=""
    if [ -n "$sess_file" ]; then
      IFS= read -r -d '' sess_json < "$sess_file"
      printf '%s\n' "$sess_file" > "$sess_hint" 2>/dev/null
    fi
  fi
  if [[ "$sess_json" == *"\"$session_id\""* ]] \
     && [[ "$sess_json" =~ \"name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    messaging_name="${BASH_REMATCH[1]}"
  fi
fi

# --- Daily cache prune ---
# Every session leaves small files behind: a seen-record and session-file hint per session id, a
# git cache per directory ever rendered, and a temp file if a tick was killed between write and
# mv. macOS empties $TMPDIR of untouched files after a few days; Linux's /tmp often isn't cleaned
# until reboot. So once a day (stamp file, builtin read) a detached find drops anything of ours
# untouched for 7 days — every one of these files is rebuilt on demand, so nothing live is lost.
prune_stamp="${cache_dir}/claude-sl-pruned"
pruned_at=0
[ -f "$prune_stamp" ] && read -r pruned_at < "$prune_stamp" 2>/dev/null
[[ "$pruned_at" =~ ^[0-9]+$ ]] || pruned_at=0
if (( now_ts - pruned_at >= 86400 )); then
  printf '%s' "$now_ts" > "$prune_stamp" 2>/dev/null
  ( find "$cache_dir" -maxdepth 1 \( -name 'claude-sl-*' -o -name '.claude-sl-*' \) \
      ! -name 'claude-sl-pruned' -mtime +7 -exec rm -rf {} + ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi

# --- Build rows ---
# Three rows, one question each:
#   row 1 — where:        dir ↳ worktree ⎇ branch · lines changed
#   row 2 — how it runs:  model + effort/fast/style · context · 5-hour · weekly · pending update
#   row 3 — who:          computer · logged-in account · messaging name
# On a wide terminal that is exactly three lines. When a row is wider than the terminal (a phone,
# a narrow split) it first sheds what it can spare — row 1 abbreviates the path to "…/parent/folder", then "…/folder",
# row 2 halves its bars, drops them (the colored percentages stay), then shortens its labels — and whatever still doesn't fit wraps
# onto a continuation line at a " · " boundary. Nothing is ever cut off mid-segment.
session_row=()
usage_row=()
identity_row=()

# Total visible width of a row's segments once joined with " · ", in _row_w.
row_width() {
  local seg
  _row_w=0
  for seg in "$@"; do
    vis_width "$seg"
    _row_w=$(( _row_w + _w + (_row_w > 0 ? 3 : 0) ))
  done
}

# --- Row 1: where ---
# Directory + worktree label + git branch are ONE segment, joined by plain spaces (no " · "
# between them — they're a single "where am I" group); lines changed is the second segment.
# $1 abbreviates the directory: "parent" → "…/<parent>/<folder>", "short" → "…/<folder>".
build_session_row() {
  session_row=()
  local location="" display_dir=""
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
    local folder="${display_dir##*/}"
    # Abbreviate only when it actually removes something: "~/repo" and "/repo" stay as they are.
    local head="${display_dir%/*}"       # everything before the folder
    local parent="${head##*/}"           # the folder's parent ("~" or "" at the top)
    if [ "${1-}" = "parent" ] && [ -n "$folder" ] && [ -n "$parent" ] && [ "$parent" != "~" ] \
       && [ "${head%/*}" != "$head" ] && [ -n "${head%/*}" ]; then
      display_dir="…/${parent}/${folder}"
    elif [ "${1-}" = "short" ] && [ -n "$folder" ] && [ -n "$head" ] && [ "$head" != "~" ]; then
      display_dir="…/${folder}"
    fi
    location="${C_SKY}${display_dir}${C_RESET}"
    # Skip the label when it would just repeat the folder name (~/…/worktree02 ↳ worktree02); it
    # stays when the folder shows something else, e.g. the repo root of a .claude/worktrees/ checkout.
    if [ -n "$git_worktree" ] && [ "$git_worktree" != "$folder" ]; then
      location="${location} ${C_THISTLE}↳ ${git_worktree}${C_RESET}"
    fi
  fi
  [ -n "$git_branch" ] && location="${location:+$location }${C_LAVENDER}⎇ ${git_branch}${C_RESET}"
  [ -n "$location" ] && session_row+=("$location")
  # Lines changed (real git diff vs the branch's fork point — committed + uncommitted).
  # Hidden on a clean tree so +0/-0 never adds noise.
  if [ "${git_added:-0}" != "0" ] || [ "${git_removed:-0}" != "0" ]; then
    session_row+=("${C_GREEN}+${git_added:-0}${C_RESET}/${C_RED}-${git_removed:-0}${C_RESET}")
  fi
}
build_session_row
if (( max_w > 0 && ${#session_row[@]} > 0 )); then
  # Too wide: keep one parent folder for context ("…/Github/repo") if the whole row then fits;
  # otherwise show the folder alone ("…/repo"), which keeps the branch and lines-changed on the
  # same line rather than wrapping them.
  for shorter in parent short; do
    row_width "${session_row[@]}"
    (( _row_w > max_w )) || break
    build_session_row "$shorter"
  done
fi

# --- Row 2: how it runs ---
# compact_labels=1 — the last resort on a narrow terminal, after the bars are gone — switches to
# short forms: the model family as Fab/Son/Hai (Opus is already four letters), effort as
# lo/med/hi/xhi, and a pending update as a bare "↑" without the version.
compact_labels=0
short_model() {   # $1 = a model name; result in _short
  _short="${1/Fable/Fab}"; _short="${_short/Sonnet/Son}"; _short="${_short/Haiku/Hai}"
}
build_usage_row() {
  usage_row=()
  # Model, with effort, fast mode and a non-default output style beside it in grey
  # ("◆ Opus 5.5 medium fast ☰Learning") — all describe how Claude is running.
  local model_mods="" effort_label="$effort" model_label="$model" limit_label="$model_limit_name"
  if (( compact_labels )); then
    short_model "$model"; model_label="$_short"
    short_model "$model_limit_name"; limit_label="$_short"
    case "$effort" in
      low) effort_label="lo" ;; medium) effort_label="med" ;; high) effort_label="hi" ;; xhigh) effort_label="xhi" ;;
    esac
  fi
  [ -n "$effort_label" ] && model_mods="$effort_label"
  [ -n "$fast_mode" ] && model_mods="${model_mods:+$model_mods }fast"
  if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
    model_mods="${model_mods:+$model_mods }☰${output_style}"
  fi
  if [ -n "$model" ]; then
    usage_row+=("${C_ORANGE}◆ ${model_label}${C_RESET}${model_mods:+ ${C_GREY}${model_mods}${C_RESET}}")
  elif [ -n "$model_mods" ]; then
    usage_row+=("${C_GREY}${model_mods}${C_RESET}")
  fi

  # Context bar
  if [ -n "$ctx_pct" ]; then
    # Same clamp as the rate windows: a full context can report a hair over 100 ("101%").
    clamp_pct "$ctx_pct"
    build_bar "$_pct_int"
    usage_row+=("${_pct_color}⛁ ${_pct_int}%${C_RESET}${_bar_result}")
  else
    usage_row+=("${C_GREY}⛁ --${C_RESET}")
  fi

  # Rate limit bars — 5-hour (⏱) session window and 7-day (⧖) weekly window.
  # Each renders identically via build_rate_segment; both windows degrade independently
  # (the docs note either may be absent), so the weekly segment is simply skipped when missing.
  if [ -n "$five_hour_pct" ]; then
    build_rate_segment "$five_hour_pct" "$five_hour_reset" 18000 "⏱"
    usage_row+=("$_rate_segment")
  elif [ -z "$seven_day_pct" ]; then
    # Nothing known yet about either window: a placeholder until the first numbers arrive. When
    # the weekly window IS known and the 5-hour one isn't, the account simply has no 5-hour window
    # right now (the usage endpoint reports it as null), so the segment is left out rather than
    # shown as a "--" that looks like missing data.
    usage_row+=("${C_GREY}⏱ --${C_RESET}")
  fi
  # This model's own weekly limit, when the account has one, rides inside the weekly segment in
  # parentheses — "⧖ 81% ⣿⣿⣿⣿⣿⣿⣿⣿⣀⣀ (Fable 89%) ↻Nov 16" — in its own threshold color. The two
  # normally reset together, so the one ↻ covers both; if the model's reset differs it is shown
  # inside the parentheses. With no all-models window to attach to, it stands as its own segment.
  local limit_note=""
  if [ -n "$model_limit_pct" ] && [ -n "$seven_day_pct" ]; then
    local drift=$(( model_limit_reset - seven_day_reset )) limit_reset=""
    if (( model_limit_reset > 0 )) && (( drift <= -60 || drift >= 60 )); then
      local saved_cells=$bar_cells
      bar_cells=0; build_rate_segment "$model_limit_pct" "$model_limit_reset" 604800 "x"; bar_cells=$saved_cells
      limit_reset="${_rate_segment#*%"$C_RESET"}"      # just the " ↻…" part, if any
    fi
    clamp_pct "$model_limit_pct"; build_bar "$_pct_int" 0
    limit_note="${C_GREY}(${_pct_color}${limit_label} ${_pct_int}%${C_RESET}${limit_reset}${C_GREY})${C_RESET}"
  fi
  if [ -n "$seven_day_pct" ]; then
    build_rate_segment "$seven_day_pct" "$seven_day_reset" 604800 "⧖" "$limit_note"
    usage_row+=("$_rate_segment")
  elif [ -n "$model_limit_pct" ]; then
    build_rate_segment "$model_limit_pct" "$model_limit_reset" 604800 "⧖ ${limit_label}"
    usage_row+=("$_rate_segment")
  fi

  # Pending update: shown only when the installed Claude Code differs from the one running, as the
  # version a restart will bring ("v2.1.297 ↑"). The running version is hidden — it only matters
  # when it's out of date. ↑ rather than ↻, which already means "resets at" on this row. It ends the
  # row, as the least-needed item.
  if [ -n "$update_available" ]; then
    if (( compact_labels )); then
      usage_row+=("${C_GREEN}↑${C_RESET}")
    else
      usage_row+=("${C_GREEN}v${installed_version} ↑${C_RESET}")
    fi
  fi
}
build_usage_row
if (( max_w > 0 )); then
  # Too wide: halve the bars (5 cells, 20% each), then drop them, then shorten the labels.
  for narrower in 5 0 labels; do
    row_width "${usage_row[@]}"
    (( _row_w > max_w )) || break
    if [ "$narrower" = labels ]; then compact_labels=1; else bar_cells=$narrower; fi
    build_usage_row
  done
fi

# --- Row 3: who ---
# Computer: bash's own $HOSTNAME (no fork), minus the domain — "Teds-Mac-Studio.local" →
# "Teds-Mac-Studio". It tells sessions on different machines (ssh, remote control) apart.
# CLAUDE_SL_HOST overrides it (a friendlier name; empty hides it). Account: the logged-in email
# from the account lookup above; absent with API-key auth. CLAUDE_SL_IDENTITY=0 hides both.
if [ "${CLAUDE_SL_IDENTITY-1}" != "0" ]; then
  host="${CLAUDE_SL_HOST-${HOSTNAME%%.*}}"
  host="${host//[^[:print:]]/}"
  [ -n "$host" ] && identity_row+=("${C_GREY}⌂ ${host}${C_RESET}")
  [ -n "$account_label" ] && identity_row+=("${C_GREY}${account_label}${C_RESET}")
fi
# The messaging name other sessions use to reach this one, shown as @name since it's an address.
# Falls back to #<first 8 chars of the session UUID> on versions that don't write one — # marks an
# id you can't message.
if [ -n "$messaging_name" ]; then
  identity_row+=("${C_BLUE}@${messaging_name}${C_RESET}")
elif [ -n "$session_id" ]; then
  identity_row+=("${C_BLUE}#${session_id:0:8}${C_RESET}")
fi

# --- Join and output ---
# Each row's segments are joined with " · " and, when the width is known, wrapped onto a
# continuation line wherever the next segment wouldn't fit. Lines are separated by a newline
# (Claude Code renders one status row per line). Every line starts with a reset, which overrides
# Claude Code's ambient dim styling (pattern from ccstatusline), and the output never ends in a
# bare newline.
rows=()
add_row() {
  local line="" line_w=0 seg
  for seg in "$@"; do
    _w=0; (( max_w > 0 )) && vis_width "$seg"
    if [ -z "$line" ]; then
      line="$seg"; line_w=$_w
    elif (( max_w > 0 && line_w + 3 + _w > max_w )); then
      rows+=("$line"); line="$seg"; line_w=$_w
    else
      line="${line} ${C_FAINT}·${C_RESET} ${seg}"; line_w=$(( line_w + 3 + _w ))
    fi
  done
  [ -n "$line" ] && rows+=("$line")
}
(( ${#session_row[@]} > 0 )) && add_row "${session_row[@]}"
# usage_row always holds at least the context segment
add_row "${usage_row[@]}"
(( ${#identity_row[@]} > 0 )) && add_row "${identity_row[@]}"
# A spacer row after the last row separates the statusline from Claude Code's own footer below it (mode,
# shells, agents, the PR link, workflow progress). It's a lone space rather than a bare trailing
# newline, which Claude Code may count or trim unpredictably. CLAUDE_SL_SPACER=0 turns it off.
[ "${CLAUDE_SL_SPACER-1}" != "0" ] && rows+=(" ")
out=""
for row in "${rows[@]}"; do out="${out:+$out$'\n'}${C_RESET}${row}${C_RESET}"; done
printf '%s' "$out"
