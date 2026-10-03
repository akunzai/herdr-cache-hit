#!/usr/bin/env bash

agy_transcript_path() {
  local session_id=$1 supplied=${2:-} root path
  if [[ -n "$supplied" && -f "$supplied" ]]; then printf '%s\n' "$supplied"; return 0; fi
  root=${AGY_HOME:-${GEMINI_HOME:-$HOME/.gemini}}
  for path in \
    "$root/antigravity/brain/$session_id/.system_generated/logs/transcript.jsonl" \
    "${AGY_CLI_HOME:-$root/antigravity-cli}/brain/$session_id/.system_generated/logs/transcript.jsonl"; do
    if [[ -f "$path" ]]; then printf '%s\n' "$path"; return 0; fi
  done
  return 1
}

# AGY can report its foreground turn as done while a delegated background task
# is still running. The transcript records RUNNING checks and a later system
# message when each task finishes; keep the warmer out until those match.
agy_has_running_background_task() {
  local session_id=$1 transcript_path
  transcript_path=$(agy_transcript_path "$session_id") || return 1
  local result
  result=$(jq -s '
    ([ .[] | (.content // "") | split("\n") as $lines |
      range(0; ($lines | length)) as $i |
      select($lines[$i] | startswith("Task: ")) |
      select($lines[$i + 1] == "Status: RUNNING") |
      $lines[$i][6:]
    ]) as $running |
    ([ .[] | (.content // "") | split("Task id \"") | .[1] // empty | split("\" finished") | .[0] ]) as $finished |
    (($running - $finished) | length) > 0
  ' "$transcript_path" 2>/dev/null) || return 1
  [[ "$result" == true ]] && return 0
  return 1
}

agy_usage_helper() {
  local os arch name plugin_dir
  plugin_dir=${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
  os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
  arch=$(uname -m 2>/dev/null) || return 1
  case "$os:$arch" in
    darwin:arm64) name=agy-usage-darwin-arm64 ;;
    darwin:x86_64) name=agy-usage-darwin-amd64 ;;
    linux:x86_64) name=agy-usage-linux-amd64 ;;
    linux:aarch64|linux:arm64) name=agy-usage-linux-arm64 ;;
    mingw*:x86_64|msys*:x86_64) name=agy-usage-windows-amd64.exe ;;
    *) return 1 ;;
  esac
  [[ -x "$plugin_dir/bin/$name" ]] || return 1
  printf '%s\n' "$plugin_dir/bin/$name"
}

agy_native_db_path() {
  local session_id=$1 root path
  root=${AGY_HOME:-${GEMINI_HOME:-$HOME/.gemini}}
  for path in \
    "${AGY_CLI_HOME:-$root/antigravity-cli}/conversations/$session_id.db" \
    "$root/antigravity-cli/conversations/$session_id.db" \
    "$root/antigravity/conversations/$session_id.db"; do
    if [[ -f "$path" ]]; then printf '%s\n' "$path"; return 0; fi
  done
  return 1
}

agy_native_usage() {
  local session_id=$1 helper db json
  helper=$(agy_usage_helper) || return 1
  db=$(agy_native_db_path "$session_id") || return 1
  json=$($helper "$db" "$session_id") || return 1
  jq -e --arg sid "$session_id" '
    type == "object" and
    (.timestamp|type) == "string" and (.timestamp|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
    ([.input_tokens,.cache_read_tokens,.cache_creation_tokens]|all(type == "number" and . >= 0 and floor == .)) and
    (.model|type) == "string" and (.provider|type) == "string" and .provider != ""
  ' <<<"$json" >/dev/null || return 1
  printf '%s\n' "$json"
}

agy_statusline_state_path() {
  local session_id=$1 root key
  key=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')
  [[ -n "$key" ]] || return 1
  if [[ -n "${AGY_STATUSLINE_STATE_DIR:-}" ]]; then
    printf '%s/%s.json\n' "$AGY_STATUSLINE_STATE_DIR" "$key"
    return 0
  fi
  for root in "$HOME/.cache/herdr-cache-plugin/agy-statusline" "$HOME/.cache/herdr-codex-cache/agy-statusline"; do
    if [[ -s "$root/$key.json" ]]; then
      printf '%s/%s.json\n' "$root" "$key"
      return 0
    fi
  done
  printf '%s/%s.json\n' "$HOME/.cache/herdr-cache-plugin/agy-statusline" "$key"
}

agy_statusline_usage() {
  local session_id=$1 path now json observed deadline
  path=$(agy_statusline_state_path "$session_id") || return 1
  [[ -s "$path" ]] || return 1
  now=$(date +%s)
  json=$(jq -e --arg sid "$session_id" --argjson now "$now" '
    select(type == "object" and .session_id == $sid and
    (.observed_at | type) == "number" and (.observed_at | floor) == .observed_at and
    (.observed_at <= $now + 5) and
    ([.input_tokens,.cache_read_tokens,.cache_creation_tokens]|all(type == "number" and . >= 0 and floor == .)) and
    ([.cache_read_tokens,.cache_creation_tokens]|any(. > 0)) and
    (.model | type) == "string" and (.provider | type) == "string" and .provider != "" and
    (.deadline | type) == "number" and .deadline == (.deadline | floor) and
    (.deadline == 0 or .deadline >= $now) and
    ((.deadline > $now) or ($now - .observed_at <= 300)))
  ' "$path") || return 1
  observed=$(jq -r .observed_at <<<"$json")
  deadline=$(jq -r .deadline <<<"$json")
  [[ "$deadline" -eq 0 || "$deadline" -ge "$observed" ]] || return 1
  printf '%s\n' "$json"
}

agy_latest_usage() {
  local path=$1 session_id=$2
  tail -n 500 "$path" 2>/dev/null | jq -R -s -r --arg sid "$session_id" '
    [splits("\n") | fromjson? | select(type == "object")] |
    [ .[] |
      (.conversation_id // .conversationId // .session_id // .sessionId // .conversation.id // null) as $embedded |
      select($embedded == null or $embedded == $sid) |
      (.context_window.current_usage // .current_usage // .usage // .message.usage // {}) as $u |
      {ts:(.timestamp // .created_at // .createdAt // .message.timestamp // ""),
       input:($u.input_tokens // null), read:($u.cache_read_input_tokens // null),
       write5m:((($u.cache_creation // {}).ephemeral_5m_input_tokens) // 0),
       write1h:((($u.cache_creation // {}).ephemeral_1h_input_tokens) // 0),
       write:($u.cache_creation_input_tokens // (((($u.cache_creation // {}).ephemeral_5m_input_tokens) // 0) + ((($u.cache_creation // {}).ephemeral_1h_input_tokens) // 0)) // null), model:(.model // .message.model // ""),
       provider:(.provider // .model_provider // .message.provider // ""), source:""} |
      select((.ts|type)=="string" and (.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))) |
      select((.input|type)=="number" and .input >= 0 and (.input|floor)==.input) |
      select((.read|type)=="number" and .read >= 0 and (.read|floor)==.read) |
      select((.write|type)=="number" and .write >= 0 and (.write|floor)==.write) |
      select((.model|type)=="string" and (.provider|type)=="string") ] | last // empty |
    [.ts,.input,.read,.write,.write5m,.write1h,.model,.provider] | @tsv' 2>/dev/null
}

agy_usage() {
  local session_id=$1 supplied=${2:-} path record ts input read write model provider native live
  if live=$(agy_statusline_usage "$session_id" 2>/dev/null); then
    ts=$(date -u -r "$(jq -r .observed_at <<<"$live")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(jq -r .observed_at <<<"$live")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    input=$(jq -r .input_tokens <<<"$live")
    read=$(jq -r .cache_read_tokens <<<"$live")
    write=$(jq -r .cache_creation_tokens <<<"$live")
    model=$(jq -r .model <<<"$live")
    provider=$(jq -r .provider <<<"$live")
    [[ -n "$ts" ]] || return 1
    printf 'agy\t%s\t%s\t%s\t%s\t%s\t0\t0\t%s\t%s\t%s\t%s\n' "$session_id" "$ts" "$input" "$read" "$write" "$model" "$provider" "$(agy_statusline_state_path "$session_id")" "$(jq -r .deadline <<<"$live")"
    return 0
  fi
  if native=$(agy_native_usage "$session_id" 2>/dev/null); then
    ts=$(jq -r .timestamp <<<"$native")
    input=$(jq -r .input_tokens <<<"$native")
    read=$(jq -r .cache_read_tokens <<<"$native")
    write=$(jq -r .cache_creation_tokens <<<"$native")
    model=$(jq -r .model <<<"$native")
    provider=$(jq -r .provider <<<"$native")
    printf 'agy\t%s\t%s\t%s\t%s\t%s\t0\t0\t%s\t%s\t%s\t0\n' "$session_id" "$ts" "$input" "$read" "$write" "$model" "$provider" "$(agy_native_db_path "$session_id")"
    return 0
  fi
  if path=$(agy_transcript_path "$session_id" "$supplied") && record=$(agy_latest_usage "$path" "$session_id") && [[ -n "$record" ]]; then
    IFS=$'\t' read -r ts input read write write5m write1h model provider <<<"$record"
    [[ -n "$provider" ]] || provider=antigravity
    printf 'agy\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$session_id" "$ts" "$input" "$read" "$write" "$write5m" "$write1h" "$model" "$provider" "$path"
    return 0
  fi
  path=$(agy_statusline_state_path "$session_id") || return 1
  if [[ -s "$path" ]] && live=$(jq -e --arg sid "$session_id" 'select(type == "object" and .session_id == $sid and ([.input_tokens,.cache_read_tokens,.cache_creation_tokens]|all(type == "number" and . >= 0 and floor == .)) and ([.cache_read_tokens,.cache_creation_tokens]|any(. > 0)))' "$path" 2>/dev/null); then
    ts=$(date -u -r "$(jq -r .observed_at <<<"$live")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(jq -r .observed_at <<<"$live")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    input=$(jq -r .input_tokens <<<"$live")
    read=$(jq -r .cache_read_tokens <<<"$live")
    write=$(jq -r .cache_creation_tokens <<<"$live")
    model=$(jq -r .model <<<"$live")
    provider=$(jq -r .provider <<<"$live")
    [[ -n "$ts" ]] || return 1
    printf 'agy\t%s\t%s\t%s\t%s\t%s\t0\t0\t%s\t%s\t%s\t%s\n' "$session_id" "$ts" "$input" "$read" "$write" "$model" "$provider" "$path" "$(jq -r '.deadline // 0' <<<"$live")"
    return 0
  fi
  return 1
}
