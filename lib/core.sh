#!/usr/bin/env bash
# shellcheck disable=SC2034
[[ -n "${_HERDR_CACHE_CORE_LOADED:-}" ]] && return 0
_HERDR_CACHE_CORE_LOADED=1
readonly HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
readonly SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${HODEX_SESSIONS_DIR:-${CODEX_HOME:-$HOME/.codex}/sessions}}"
readonly STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/cache-hit}"
readonly CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/cache-hit}"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly FLOOR_SECONDS=1800
readonly CEILING_SECONDS=3600
readonly DISPLAY_TTL_MS=86400000
readonly SOURCE="herdr-plugin.cache-hit"
readonly LOCK_DIR="$STATE_DIR/watcher.lock"
readonly SEEN_FILE="$STATE_DIR/seen-panes"
readonly ROLLOUT_INDEX="$STATE_DIR/rollouts.index"
readonly ROLLOUT_INDEX_TTL=15
readonly ACTIVE_RESCAN_SECONDS=15
readonly OBSERVATIONS_FILE="$STATE_DIR/observations.json"
next_wake_delay() {
  local active=${1:-0} transition=${2:-} delay=$ACTIVE_RESCAN_SECONDS
  [[ "$active" =~ ^[0-9]+$ ]] && (( active > 0 )) || return 1
  if [[ "$transition" =~ ^[0-9]+$ ]] && (( transition > 0 && transition < delay )); then
    delay=$transition
  fi
  printf '%s\n' "$delay"
}
require_runtime() { command -v jq >/dev/null 2>&1 || { echo 'cache-hit: jq is required' >&2; return 1; }; }
config_value() {
  [[ -s "$CONFIG_FILE" ]] || return 1
  jq -r --arg agent "$1" --arg key "$2" '
    if (.[$agent] | type) == "object" and (.[$agent] | has($key)) then .[$agent][$key]
    elif (type == "object" and has($key)) then .[$key]
    else empty end
  ' "$CONFIG_FILE" 2>/dev/null
}
config_bool() {
  local value; value=$(config_value "$1" "$2") || value=""
  case "$value" in true|false) printf '%s\n' "$value" ;; *) printf '%s\n' "$3" ;; esac
}
config_str() {
  local agent=$1 key=$2 default=$3 value
  [[ -s "$CONFIG_FILE" ]] || { printf '%s\n' "$default"; return 0; }
  value=$(jq -r --arg agent "$agent" --arg key "$key" --arg default_val "$default" '
    if (.[$agent] | type) == "object" and (.[$agent] | has($key)) then (.[$agent][$key] | tostring)
    elif (type == "object" and has($key)) then (.[$key] | tostring)
    else $default_val end
  ' "$CONFIG_FILE" 2>/dev/null) || value="$default"
  printf '%s\n' "$value"
}
config_int() {
  local value; value=$(config_value "$1" "$2") || value=""
  if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s\n' "$value"; else printf '%s\n' "$3"; fi
}
config_agent_enabled() { [[ "$(config_bool "$1" enabled true)" == true ]]; }
init_state() { mkdir -p "$STATE_DIR" 2>/dev/null || return 1; }
atomic_install() { mv -f "$1" "$2"; }
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then :; else
    local owner; owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      touch "$LOCK_DIR/rerun" 2>/dev/null || true
      return 1
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || return 1; mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"; printf '%s\n' "$$:$(date +%s)" >"$LOCK_DIR/identity"
}
cleanup() {
  local f; for f in "$STATE_DIR"/*.tmp "$STATE_DIR"/seen.*; do [[ -e "$f" ]] && rm -f "$f"; done
  [[ -f "$LOCK_DIR/pid" && "$(cat "$LOCK_DIR/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK_DIR"
}
readonly TIMER_PID_FILE="$STATE_DIR/timer.pid"
cancel_timer() {
  if [[ -f "$TIMER_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$TIMER_PID_FILE" 2>/dev/null || true)
    if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
      pkill -P "$old_pid" 2>/dev/null || true
      kill "$old_pid" 2>/dev/null || true
      wait "$old_pid" 2>/dev/null || true
    fi
    rm -f "$TIMER_PID_FILE"
  fi
}
schedule_wake() {
  local delay=${1:-}
  cancel_timer
  if [[ -n "$delay" && "$delay" =~ ^[0-9]+$ && "$delay" -gt 0 ]]; then
    local script="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/watch.sh"
    [[ -f "$script" ]] || return 0
    init_state || return 0
    (
      cd /
      sleep "$delay"
      bash "$script"
    ) >/dev/null 2>&1 &
    local new_pid=$!
    printf '%s\n' "$new_pid" >"$TIMER_PID_FILE"
    disown "$new_pid" 2>/dev/null || true
  fi
}
fmt_tokens() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1000000) printf "%.1fM", n / 1000000; else if (n >= 1000) printf "%.1fk", n / 1000; else printf "%d", n }'; }
fmt_clock() {
  local tz
  tz=$(config_str "" timezone "${HERDR_PLUGIN_TIMEZONE:-${TZ:-}}")
  if [[ -n "$tz" ]]; then
    TZ="$tz" date -d "@$1" +%H:%M 2>/dev/null || TZ="$tz" date -r "$1" +%H:%M 2>/dev/null
  else
    date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null
  fi
}
to_bold_digits() {
  local s=$1
  local map=("𝟬" "𝟭" "𝟮" "𝟯" "𝟰" "𝟱" "𝟲" "𝟳" "𝟴" "𝟵")
  local out="" i ch
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    if [[ "$ch" =~ [0-9] ]]; then
      out+="${map[ch]}"
    else
      out+="$ch"
    fi
  done
  printf '%s' "$out"
}
report_pane() {
  local pane=$1 agent=$2 token_val=$3 ttl_ms=${4:-15000}
  local status_val=${5:-} pct_val=${6:-} tokens_val=${7:-} state_val=${8:-}
  local details_val=${9:-} deadline_val=${10:-}
  local remaining_secs=${11:-} pct_num=${12:-}
  local cmd=("$HERDR_BIN" pane report-metadata "$pane" --source "$SOURCE" --agent "$agent" --token "cache=$token_val" --ttl-ms "$ttl_ms")
  cmd+=(--token "cache_status=$status_val")
  if [[ -n "$pct_val" ]]; then
    cmd+=(--token "cache_pct=$pct_val")
  else
    cmd+=(--clear-token "cache_pct")
  fi
  [[ -n "$tokens_val" ]] && cmd+=(--token "cache_tokens=$tokens_val")
  [[ -n "$state_val" ]] && cmd+=(--token "cache_state=$state_val")
  [[ -n "$details_val" ]] && cmd+=(--token "cache_details=$details_val")
  if [[ -n "$deadline_val" && "$deadline_val" =~ ^[0-9]+$ && "$deadline_val" -gt 0 ]]; then
    cmd+=(--token "cache_deadline=$deadline_val")
  else
    cmd+=(--clear-token "cache_deadline")
  fi
  if [[ -n "$remaining_secs" && "$remaining_secs" =~ ^[0-9]+$ && "$remaining_secs" -gt 0 ]]; then
    cmd+=(--token "cache_remaining_secs=$remaining_secs")
  else
    cmd+=(--clear-token "cache_remaining_secs")
  fi
  if [[ -n "$pct_num" && "$pct_num" =~ ^[0-9]+$ ]]; then
    cmd+=(--token "cache_pct_num=$pct_num")
  else
    cmd+=(--clear-token "cache_pct_num")
  fi
  local inject_mode
  inject_mode=$(config_str "$agent" "display_agent" "auto")
  local do_inject=false
  case "$inject_mode" in
    true|always) do_inject=true ;;
    false|never) do_inject=false ;;
    auto|*)
      local threshold
      threshold=$(config_int "$agent" "mobile_width_threshold" 64)
      local current_width="${HERDR_CURRENT_WIDTH:-}"
      if [[ -n "${TERMUX_VERSION:-}" ]]; then
        do_inject=true
      elif [[ -n "$current_width" && "$current_width" =~ ^[0-9]+$ ]] && (( current_width <= threshold )); then
        do_inject=true
      else
        do_inject=false
      fi
      ;;
  esac

  if [[ "$do_inject" == true && -n "$token_val" ]]; then
    cmd+=(--display-agent "$agent [$token_val]")
  else
    cmd+=(--clear-display-agent)
  fi
  "${cmd[@]}" >/dev/null 2>&1 || true
}
clear_pane() {
  "$HERDR_BIN" pane report-metadata "$1" --source "$SOURCE" --agent "${2:-codex}" \
    --clear-token cache --clear-token cache_status --clear-token cache_pct \
    --clear-token cache_tokens --clear-token cache_state --clear-token cache_details \
    --clear-token cache_deadline --clear-token cache_remaining_secs --clear-token cache_pct_num \
    --clear-display-agent \
    --ttl-ms 15000 >/dev/null 2>&1 || true
}
