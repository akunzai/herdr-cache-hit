#!/usr/bin/env bash
# Experimental: a `herdr` stand-in for the Herdr App (GUI) backend.
#
# The plugin talks to Herdr through a small CLI surface (HERDR_BIN_PATH).
# This shim answers that surface from herdr-core (`hc`) and stores reported
# pane metadata as JSON files that the Herdr App mod reads.
#
#   HERDR_BIN_PATH=scripts/herdr-app-shim.sh HERDR_NO_TIMER=1 \
#     HERDR_CACHE_DISPLAY_ONLY=1 bash watch.sh
#
# Supported: api snapshot, pane list, pane process-info, pane report-metadata.
# Anything else fails: herdr-cache-view sorting stays inactive, and the cache
# warmer cannot type into a terminal (`agent prompt`) under Herdr App.
# HERDR_CACHE_DISPLAY_ONLY=1 makes the plugin skip warming altogether.
# Every pane reports as focused, so the warmer's focus guard also holds.
set -u
SHIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SHIM_DIR%/scripts}"
# The session resolvers call `$HERDR_BIN pane process-info`; route it here.
export HERDR_BIN_PATH="$SHIM_DIR/herdr-app-shim.sh"
# shellcheck source=lib/core.sh
. "$PLUGIN_DIR/lib/core.sh"
HC_BIN="${HC_BIN_PATH:-hc}"
META_DIR="$STATE_DIR/app-metadata"

# hc reports the agent's OSC 7501 app name; the plugin uses Herdr TUI's names.
# Terminals without a status report the foreground process name instead.
# shellcheck disable=SC2016 # jq program, not shell
AGENT_MAP='def plugin_agent: (ascii_downcase | split("/") | last) as $a |
  if $a == "claude-code" or $a == "claude" then "claude"
  elif $a == "codex" then "codex"
  elif $a == "antigravity" or $a == "agy" then "agy"
  elif $a == "opencode" then "opencode"
  else null end;'

# `hc get`, with the agent filled in where herdr-core reports no foreground
# process (Windows): pid, argv and folder come from the process itself.
# Claude also records its cwd and session id per pid.
hc_info() {
  local info pid fg root sess
  info=$("$HC_BIN" get "$1" --json 2>/dev/null) || return 1
  if [[ "$(jq -r '.foreground == null and (.pid | type) == "number"' <<<"$info")" == true ]] &&
     fg=$(python3 "$PLUGIN_DIR/lib/win_foreground.py" "$(jq -r '.pid' <<<"$info")" 2>/dev/null); then
    pid=$(jq -r '.pid' <<<"$fg")
    root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
    sess=null
    if [[ "$(jq -r '.name' <<<"$fg")" == claude && -f "$root/sessions/$pid.json" ]]; then
      sess=$(jq -c --argjson pid "$pid" 'select(.pid == $pid) | {cwd, sessionId}' "$root/sessions/$pid.json" 2>/dev/null) || sess=null
      [[ -n "$sess" ]] || sess=null
    fi
    info=$(jq -c --argjson fg "$fg" --argjson sess "$sess" '.foreground = {pid: $fg.pid, name: $fg.name,
      argv: ($fg.argv // [$fg.name]), cwd: ($sess.cwd // $fg.cwd // null)} | .claude_session = ($sess.sessionId // "")' <<<"$info")
  fi
  printf '%s\n' "$info"
}

hc_terminals() {
  # Local terminals only: session recovery reads local processes and files.
  # `hc ls` reports the shell's folder; `hc get` adds the agent's own folder.
  # A failed `hc ls` must fail the call, not read as "no terminals": the
  # watcher would clear every pane's record.
  local list addrs addr out=()
  list=$("$HC_BIN" ls --json 2>/dev/null) || return 1
  jq -e '.terminals | type == "array"' >/dev/null 2>&1 <<<"$list" || return 1
  addrs=$(jq -r "$AGENT_MAP"'
    .terminals[] | select(.state == "live" and (.address | contains("/") | not))
    | select((.agent // "" | plugin_agent) != null) | .address' <<<"$list") || return 1
  local info pid sid
  for addr in $addrs; do
    info=$(hc_info "$addr") || continue
    # Herdr TUI reports AGY's session id natively; here, take it from the
    # one conversation database the AGY process holds open.
    sid=""
    if [[ "$(jq -r "$AGENT_MAP"'(.status.app // .foreground.name // "") | plugin_agent' <<<"$info")" == agy ]]; then
      pid=$(jq -r '.foreground.pid // empty' <<<"$info")
      [[ "$pid" =~ ^[0-9]+$ ]] && sid=$(agy_open_session "$pid")
    fi
    [[ -n "$sid" ]] || sid=$(jq -r '.claude_session // ""' <<<"$info")
    out+=("$(jq -c --arg sid "$sid" '. + {known_session: $sid}' <<<"$info")")
  done
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -cs "$AGENT_MAP"'
    [.[] | select(type == "object") | ((.status.app // .foreground.name // "") | plugin_agent) as $agent | select($agent != null)
     | {pane_id: .address, agent: $agent, agent_status: (.status.state // null),
        cwd: (.foreground.cwd // .cwd // null), foreground_cwd: (.foreground.cwd // .cwd // null),
        terminal_title: (.title // ""), focused: true,
        agent_session: (if .known_session != "" then {kind: "id", value: .known_session} else null end)}]'
}

# Prints the session id only when the process holds exactly one session open.
# AGY keeps brain/<uuid>/ open while idle and conversations/<uuid>.db only
# around turns; both use the session id.
agy_open_session() {
  local pid=$1 files ids
  if [[ -d "/proc/$pid/fd" ]]; then
    files=$(for f in /proc/"$pid"/fd/*; do readlink "$f" 2>/dev/null; done)
  elif command -v lsof >/dev/null 2>&1; then
    files=$(lsof -Fn -p "$pid" 2>/dev/null | sed -n 's/^n//p')
  else
    agy_log_session "$pid"
    return 0
  fi
  ids=$(printf '%s\n' "$files" | sed -nE 's#.*/(brain/([0-9a-fA-F-]{36})|conversations/([0-9a-fA-F-]{36})\.db)$#\2\3#p' | sort -u)
  [[ -n "$ids" && $(printf '%s\n' "$ids" | wc -l) -eq 1 ]] && printf '%s' "$ids"
  return 0
}

# Windows has neither /proc nor lsof. AGY writes one log per process, starting
# with its pid, and names each conversation it creates or opens as active.
# Newest log first, so a reused pid finds the live process's log.
agy_log_session() {
  local pid=$1 dir i
  dir="${AGY_CLI_HOME:-${AGY_HOME:-${GEMINI_HOME:-$HOME/.gemini}}/antigravity-cli}/log"
  # cli-YYYYMMDD_HHMMSS.log: name order is time order.
  local -a logs=("$dir"/cli-*.log)
  for ((i = ${#logs[@]} - 1; i >= 0 && i >= ${#logs[@]} - 20; i--)); do
    local log=${logs[i]}
    if [[ ! -f "$log" ]] || ! head -n 1 "$log" | grep -q "process with pid $pid$"; then continue; fi
    grep -oE '(Created conversation|found conversation) [0-9a-fA-F-]{36}( \(active=true\)|$| \(backend)' "$log" |
      tail -n 1 | grep -oE '[0-9a-fA-F-]{36}'
    return 0
  done
}

snapshot() {
  local panes
  panes=$(hc_terminals) || return 1
  [[ -n "$panes" ]] || return 1
  jq -c '{result: {snapshot: {panes: .}}}' <<<"$panes"
}

pane_list() {
  local panes
  panes=$(hc_terminals) || return 1
  [[ -n "$panes" ]] || return 1
  jq -c '{result: {panes: .}}' <<<"$panes"
}

process_info() {
  local pane=""
  while (($#)); do
    case "$1" in
      --pane) pane=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$pane" ]] || return 1
  hc_info "$pane" | jq -ce '
    select(.foreground.pid != null)
    | {result: {process_info: {foreground_processes: [{pid: .foreground.pid, name: (.foreground.name // ""),
        argv0: (.foreground.argv[0] // ""), argv: (.foreground.argv // []), cwd: (.foreground.cwd // null)}]}}}'
}

report_metadata() {
  local pane=${1:-}; shift || true
  [[ "$pane" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
  local agent="" ttl_ms=15000 display=null file tmp
  local -a set_args=() clear_args=()
  while (($#)); do
    case "$1" in
      --agent) agent=${2:-}; shift 2 ;;
      --ttl-ms) ttl_ms=${2:-15000}; shift 2 ;;
      --token) set_args+=("${2:-}"); shift 2 ;;
      --clear-token) clear_args+=("${2:-}"); shift 2 ;;
      --display-agent) display=$(jq -Rn --arg v "${2:-}" '$v'); shift 2 ;;
      --source) shift 2 ;;
      --clear-display-agent) shift ;;
      *) shift ;;
    esac
  done
  [[ "$ttl_ms" =~ ^[0-9]+$ ]] || ttl_ms=15000
  mkdir -p "$META_DIR" || return 1
  file="$META_DIR/${pane//\//_}.json"
  tmp=$(mktemp "$META_DIR/.tmp.XXXXXX") || return 1
  # Tokens persist between reports until cleared, matching Herdr's metadata merge.
  # Values go in as arguments: native Windows jq cannot open <(...) paths.
  local prev
  prev=$(jq -c . "$file" 2>/dev/null) || prev=null
  [[ -n "$prev" ]] || prev=null
  jq -n --arg pane "$pane" --arg agent "$agent" --argjson ttl "$ttl_ms" --argjson display "$display" \
    --argjson now "$(($(date +%s) * 1000))" --argjson prev "$prev" \
    --arg set "$(printf '%s\n' "${set_args[@]+"${set_args[@]}"}")" \
    --arg clear "$(printf '%s\n' "${clear_args[@]+"${clear_args[@]}"}")" '
    ($set | split("\n") | map(select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.*)$"))) as $sets |
    ($clear | split("\n") | map(select(length > 0))) as $clears |
    (($prev.tokens // {}) + ($sets | from_entries)) as $t |
    {pane: $pane, agent: $agent, updated_ms: $now, expires_ms: ($now + $ttl),
     display_agent: $display, tokens: ($t | with_entries(select(.key as $k | $clears | index($k) | not)))}
  ' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

case "${1:-} ${2:-}" in
  "api snapshot") snapshot ;;
  "pane list") pane_list ;;
  "pane process-info") shift 2; process_info "$@" ;;
  "pane report-metadata") shift 2; report_metadata "$@" ;;
  *) echo "herdr-app-shim: unsupported: $*" >&2; exit 1 ;;
esac
