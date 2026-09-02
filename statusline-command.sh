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
cache_dir="${CLAUDE_SL_CACHE_DIR:-${TMPDIR:-/tmp}}"
account="${CLAUDE_SL_ACCOUNT-}"
if [ -z "${CLAUDE_SL_ACCOUNT+set}" ]; then
  acct_cache="${cache_dir}/claude-sl-account"
  acct_age=999999999
  if [ -f "$acct_cache" ]; then
    acct_age=$(( now_ts - $(stat -f%m "$acct_cache" 2>/dev/null || echo 0) ))
  fi
  if [ "$acct_age" -ge 5 ]; then
    cc_config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    if [ -r "$cc_config" ]; then
      # Indexing a missing/null .oauthAccount yields null in jq, so this stays quiet when logged out.
      account=$(jq -r '.oauthAccount.accountUuid // .oauthAccount.emailAddress // ""' "$cc_config" 2>/dev/null)
    fi
    # Reduce to a safe filename component — the uuid already is one, an email address isn't.
    account="${account//[^A-Za-z0-9._-]/_}"
    # Temp files are dot-prefixed so they can never be globbed as an account snapshot below.
    tmp_acct=$(mktemp "${cache_dir}/.claude-sl-account.XXXXXX" 2>/dev/null)
    if [ -n "$tmp_acct" ]; then
      printf '%s' "$account" > "$tmp_acct" && mv "$tmp_acct" "$acct_cache"
    fi
  else
    IFS= read -r account < "$acct_cache" 2>/dev/null
  fi
fi
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
    tmp_seen=$(mktemp "${cache_dir}/.claude-sl-seen.XXXXXX" 2>/dev/null)
    if [ -n "$tmp_seen" ]; then
      printf '%s\037%s\037%s\037%s\037%s\037%s' "$account" "$five_hour_pct" "$five_hour_reset" \
        "$seven_day_pct" "$seven_day_reset" "$now_ts" > "$tmp_seen" && mv "$tmp_seen" "$seen_record"
    fi
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
# file it just read from. Atomic mktemp+mv, same pattern as the git cache below.
if [ -n "$payload_had_rate" ]; then
  tmp_rate=$(mktemp "${cache_dir}/.claude-sl-rate.XXXXXX" 2>/dev/null)
  if [ -n "$tmp_rate" ]; then
    printf '%s\037%s\037%s\037%s\037%s\037%s' "$five_hour_pct" "$five_hour_reset" "$seven_day_pct" "$seven_day_reset" \
      "$five_hour_at" "$seven_day_at" > "$tmp_rate" && mv "$tmp_rate" "$rate_cache"
  fi
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
# 10 minutes, and the result is cached per account. Set CLAUDE_SL_USAGE_TTL=0 to disable the
# endpoint entirely; CLAUDE_SL_USAGE_TOKEN / CLAUDE_SL_USAGE_URL override the token and URL (the
# test suite points the URL at a local fixture).
usage_ttl="${CLAUDE_SL_USAGE_TTL-180}"
[[ "$usage_ttl" =~ ^[0-9]+$ ]] || usage_ttl=180
usage_file="${cache_dir}/claude-sl-usage"
[ -n "$account" ] && usage_file="${usage_file}-${account}"
api_5pct="" api_5rst="" api_7pct="" api_7rst="" api_at=""
if [ -f "$usage_file" ]; then
  IFS=$'\037' read -r api_5pct api_5rst api_7pct api_7rst api_at < "$usage_file" 2>/dev/null
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
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  fi
  if [ -z "$creds" ]; then
    local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    [ -r "$creds_file" ] && creds=$(cat "$creds_file" 2>/dev/null)
  fi
  [ -n "$creds" ] || return 1
  _token=$(printf '%s' "$creds" | jq -r --argjson now_ms "$(( now_ts * 1000 ))" '
    .claudeAiOauth
    | if (.accessToken // "") != "" and ((.expiresAt // 0) == 0 or .expiresAt > $now_ms)
      then .accessToken else "" end' 2>/dev/null)
  [ -n "$_token" ]
}

# Fetch once, in the background. Writes "<5h%>\037<5h reset>\037<7d%>\037<7d reset>\037<fetched_at>"
# to $usage_file on success, or "<http code>\037<time>" to $usage_file.err on failure.
fetch_usage_in_background() {
  local lock="${usage_file}.lock"
  # mkdir is atomic: the first session to get it fetches, the rest skip. A lock older than a
  # minute belongs to a fetch that died (killed mid-flight, machine slept) and is reclaimed.
  if ! mkdir "$lock" 2>/dev/null; then
    local lock_age=$(( now_ts - $(stat -f%m "$lock" 2>/dev/null || echo "$now_ts") ))
    (( lock_age >= 60 )) || return 0
    rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
  fi
  (
    trap 'rm -rf "$lock"' EXIT
    read_oauth_token || exit 0
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
    parsed=$(printf '%s' "$body" | jq -r '
      def epoch: try (
        capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<f>[0-9]+))?(?<z>Z|\\+00:00)$") as $m
        | ($m.b + "Z" | fromdateiso8601) + (if (($m.f // "0") | tonumber) > 0 then 1 else 0 end)
      ) catch 0;
      [ (.five_hour.utilization // ""), (.five_hour.resets_at | epoch),
        (.seven_day.utilization // ""), (.seven_day.resets_at | epoch) ]
      | map(tostring) | join("\u001f")' 2>/dev/null)
    local fetched_at; fetched_at=$(date +%s)
    if { [ "$code" = "200" ] || [ "$code" = "000" ]; } && [[ "$parsed" =~ ^[0-9] ]]; then
      local tmp; tmp=$(mktemp "${cache_dir}/.claude-sl-usage.XXXXXX" 2>/dev/null) || exit 0
      printf '%s\037%s' "$parsed" "$fetched_at" > "$tmp" && mv "$tmp" "$usage_file"
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
  err_at=0
  if [ -f "${usage_file}.err" ]; then
    IFS=$'\037' read -r _ err_at < "${usage_file}.err" 2>/dev/null
    [[ "$err_at" =~ ^[0-9]+$ ]] || err_at=0
  fi
  if (( now_ts - newest_at >= usage_ttl )) && (( now_ts - err_at >= 600 )); then
    fetch_usage_in_background
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
