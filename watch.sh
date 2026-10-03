#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
PLUGIN_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/core.sh
. "$PLUGIN_DIR/lib/core.sh"
# shellcheck source=lib/codex.sh
. "$PLUGIN_DIR/lib/codex.sh"
# shellcheck source=lib/agy.sh
. "$PLUGIN_DIR/lib/agy.sh"
# shellcheck source=lib/claude.sh
. "$PLUGIN_DIR/lib/claude.sh"
# shellcheck source=lib/opencode.sh
. "$PLUGIN_DIR/lib/opencode.sh"
# shellcheck source=lib/cache.sh
. "$PLUGIN_DIR/lib/cache.sh"

watch_main() {
  require_runtime || return 1
  init_state || return 1
  acquire_lock || return 0
  trap cleanup EXIT
  trap 'exit 0' HUP INT TERM
  while true; do
    rm -f "$LOCK_DIR/rerun" 2>/dev/null || true
    local pane_json pane_id agent session_kind session_id cwd session_path pane current rows delay min_width codex_panes codex_rescans
    if pane_json=$("$HERDR_BIN" api snapshot 2>/dev/null) && [[ -n "$pane_json" ]] && jq -e '.result.snapshot.panes | type == "array"' >/dev/null 2>&1 <<<"$pane_json"; then
      min_width=$(jq -r '[.result.snapshot.layouts[]?.area?.width // empty] | min // ""' <<<"$pane_json" 2>/dev/null) || min_width=""
      rows=$(jq -r '.result.snapshot.panes[]? | select(.agent == "codex" or .agent == "agy" or .agent == "claude" or .agent == "opencode") | [.pane_id, .agent, .agent_session.kind, .agent_session.value, (.cwd // .foreground_cwd), (.agent_session.path // .agent_session.agent_session_path)] | map(if . == null or . == "" then "-" else . end) | @tsv' <<<"$pane_json" 2>/dev/null) || rows=""
    elif pane_json=$("$HERDR_BIN" pane list 2>/dev/null) && [[ -n "$pane_json" ]] && jq -e '.result.panes | type == "array"' >/dev/null 2>&1 <<<"$pane_json"; then
      min_width=""
      rows=$(jq -r '.result.panes[]? | select(.agent == "codex" or .agent == "agy" or .agent == "claude" or .agent == "opencode") | [.pane_id, .agent, .agent_session.kind, .agent_session.value, (.cwd // .foreground_cwd), (.agent_session.path // .agent_session.agent_session_path)] | map(if . == null or . == "" then "-" else . end) | @tsv' <<<"$pane_json" 2>/dev/null) || rows=""
    else
      return 1
    fi
    codex_panes=$(jq -c '[((.result.snapshot.panes // .result.panes)[]?) | select(.agent == "codex")]' <<<"$pane_json") || codex_panes='[]'
    codex_rescans=0
    export HERDR_CURRENT_WIDTH="${HERDR_CURRENT_WIDTH:-$min_width}"
    current=$(mktemp "$STATE_DIR/seen.XXXXXX") || return 1
    EARLIEST_WAKE=""
    ACTIVE_CACHE_COUNT=0
    while IFS=$'\t' read -r pane_id agent session_kind session_id cwd session_path; do
      [[ -n "$pane_id" ]] || continue
      [[ "$session_kind" == - ]] && session_kind=""
      [[ "$session_id" == - ]] && session_id=""
      [[ "$cwd" == - ]] && cwd=""
      [[ "$session_path" == - ]] && session_path=""
      printf '%s\n' "$pane_id" >>"$current"
      if [[ "$agent" == codex ]] && config_agent_enabled codex; then
        codex_rescans=$((codex_rescans + 1))
        if [[ "$session_kind" != id || -z "$session_id" ]]; then
          session_id=$(codex_session_for_pane "$pane_id" "$cwd" "$codex_panes") || session_id=""
          [[ -n "$session_id" ]] && session_kind=id
        fi
      fi
      if [[ "$session_kind" != "id" || -z "$session_id" ]]; then
        reset_pane_cache "$pane_id" || true
        clear_pane "$pane_id" "$agent"
        continue
      fi
      update_pane "$pane_id" "$agent" "$session_id" "$cwd" "$session_path"
      if [[ ("$agent" == codex || "$agent" == agy || "$agent" == claude) ]] && (( ACTIVE_CACHE_COUNT > 0 )); then
        maybe_warm_agent "$agent" "$pane_id" "$session_id"
      fi
    done <<<"$rows"
    if [[ -s "$SEEN_FILE" ]]; then while IFS= read -r pane; do
      if ! grep -Fqx "$pane" "$current"; then
        reset_pane_cache "$pane" || true
        clear_pane "$pane"
      fi
    done <"$SEEN_FILE"; fi
    atomic_install "$current" "$SEEN_FILE"
    rm -f "$current"
    if [[ -z "${HERDR_NO_TIMER:-}" ]]; then
      if delay=$(next_wake_delay "$((ACTIVE_CACHE_COUNT + codex_rescans))" "$EARLIEST_WAKE"); then
        schedule_wake "$delay"
      else
        cancel_timer
      fi
    fi
    [[ -f "$LOCK_DIR/rerun" ]] || break
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then watch_main "$@"; fi
