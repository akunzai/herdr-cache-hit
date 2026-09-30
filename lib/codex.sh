#!/usr/bin/env bash
codex_session_for_pane() {
  local pane=$1 cwd=$2 panes=$3 process script
  command -v python3 >/dev/null 2>&1 || return 1
  script="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/lib/codex_session.py"
  process=$("$HERDR_BIN" pane process-info --pane "$pane" 2>/dev/null) || return 1
  jq -c --argjson panes "$panes" '{process:.result.process_info, panes:$panes}' <<<"$process" |
    python3 "$script" "$SESSIONS_DIR" "$cwd" "$pane" 2>/dev/null
}

rollout_for_session() {
  local session_id=$1 path meta index_age now candidate
  [[ -d "$SESSIONS_DIR" && "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  # UUIDv7 fast path: Codex session IDs are UUIDv7, whose first 48 bits encode the
  # millisecond creation timestamp. Compute the exact YYYY/MM/DD directory directly
  # without scanning the directory tree or building indices. Checks UTC, local date,
  # and +/-1 day around midnight timezone boundaries.
  if [[ "${session_id:14:1}" == "7" && "${#session_id}" -eq 36 ]]; then
    local hex="${session_id:0:8}${session_id:9:4}"
    local sec=$(( 16#$hex / 1000 ))
    local d_utc d_loc d_prev d_next
    d_utc=$(date -u -r "$sec" +%Y/%m/%d 2>/dev/null || date -u -d "@$sec" +%Y/%m/%d 2>/dev/null)
    d_loc=$(date -r "$sec" +%Y/%m/%d 2>/dev/null || date -d "@$sec" +%Y/%m/%d 2>/dev/null)
    d_prev=$(date -u -r "$((sec - 86400))" +%Y/%m/%d 2>/dev/null || date -u -d "@$((sec - 86400))" +%Y/%m/%d 2>/dev/null)
    d_next=$(date -u -r "$((sec + 86400))" +%Y/%m/%d 2>/dev/null || date -u -d "@$((sec + 86400))" +%Y/%m/%d 2>/dev/null)
    for candidate in \
      "$SESSIONS_DIR/$d_utc"/*"$session_id"*.jsonl \
      "$SESSIONS_DIR/$d_loc"/*"$session_id"*.jsonl \
      "$SESSIONS_DIR/$d_next"/*"$session_id"*.jsonl \
      "$SESSIONS_DIR/$d_prev"/*"$session_id"*.jsonl; do
      if [[ -f "$candidate" ]]; then
        meta=$(head -n 100 "$candidate" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
        if [[ "$meta" == 1 ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
  fi

  # Fast path: check flat and recent date-partitioned paths first (avoids full tree scans on network filesystems)
  local d_now d_now_utc m_now
  d_now=$(date +%Y/%m/%d)
  d_now_utc=$(date -u +%Y/%m/%d)
  m_now=$(date +%Y/%m)
  for candidate in \
    "$SESSIONS_DIR"/*"$session_id"*.jsonl \
    "$SESSIONS_DIR/$d_now"/*"$session_id"*.jsonl \
    "$SESSIONS_DIR/$d_now_utc"/*"$session_id"*.jsonl \
    "$SESSIONS_DIR/$m_now"/*/*"$session_id"*.jsonl; do
    if [[ -f "$candidate" ]]; then
      meta=$(head -n 100 "$candidate" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
      if [[ "$meta" == 1 ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done

  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  now=$(date +%s)
  index_age=999999
  if [[ -f "$ROLLOUT_INDEX" ]]; then
    local mtime
    mtime=$(stat -c %Y "$ROLLOUT_INDEX" 2>/dev/null || stat -f %m "$ROLLOUT_INDEX" 2>/dev/null || printf 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    index_age=$((now - mtime))
  fi
  if (( index_age >= ROLLOUT_INDEX_TTL )); then
    local tmp; tmp=$(mktemp "${ROLLOUT_INDEX}.XXXXXX") || return 1
    find "$SESSIONS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null | while IFS= read -r -d '' path; do
      printf '%s\t%s\n' "$(basename "$path")" "$path"
    done >"$tmp"
    mv -f "$tmp" "$ROLLOUT_INDEX"
  fi
  while IFS=$'\t' read -r name path; do
    [[ "$name" == *"$session_id"* ]] || continue
    meta=$(head -n 100 "$path" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
    [[ "$meta" == 1 ]] && { printf '%s\n' "$path"; return 0; }
  done <"$ROLLOUT_INDEX"
  # The index is only an optimization. During an active session, a refresh can
  # race rollout creation; validate matching filenames directly before
  # declaring the native session unavailable.
  local matches
  matches=$(find "$SESSIONS_DIR" -type f -name "*$session_id*.jsonl" -print 2>/dev/null) || matches=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    meta=$(head -n 100 "$path" 2>/dev/null | jq -R -s --arg id "$session_id" '[splits("\n") | fromjson? | select(type == "object" and .type == "session_meta" and .payload.id == $id)] | length' 2>/dev/null) || continue
    [[ "$meta" == 1 ]] && { printf '%s\n' "$path"; return 0; }
  done <<<"$matches"
  return 1
}
parse_timestamp() {
  local value=${1%%.*}; value=${value%Z}
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$value" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}
latest_usage() {
  local path=$1 session_id=$2
  # Filter out content before JSON parsing, and keep constant-size state. Unlike
  # an arbitrary recent tail, this also finds usage during long tool-only turns.
  awk '/"type"[[:space:]]*:[[:space:]]*"(session_meta|turn_context|token_usage_record|token_count)"/' "$path" 2>/dev/null | jq -Rrn --arg id "$session_id" '
    def nonempty_string: type == "string" and length > 0;
    def token_count: if type == "number" then . >= 0 and floor == . else false end;
    reduce (inputs | fromjson? | select(type == "object" and (.payload | type) == "object")) as $row
      ({model:"codex", provider:"openai", latest:null};
       if $row.type == "session_meta" and $row.payload.id == $id then
         if ($row.payload.model_provider | nonempty_string) then .provider = $row.payload.model_provider else . end
       elif $row.type == "turn_context" then
         (if ($row.payload.model | nonempty_string) then .model = $row.payload.model else . end) |
         (if ($row.payload.model_provider | nonempty_string) then .provider = $row.payload.model_provider else . end)
       elif $row.type == "token_usage_record" or ($row.type == "event_msg" and $row.payload.type == "token_count") then
         (if $row.type == "token_usage_record" then $row.payload.usage
          elif ($row.payload.info | type) == "object" then $row.payload.info.last_token_usage
          else null end) as $usage |
         if ($usage | type) == "object" and
            ($row.payload.session_id == null or $row.payload.session_id == $id) and
            ($row.timestamp | type) == "string" and
            ($row.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
            ($usage.input_tokens | token_count) and ($usage.cached_input_tokens | token_count) then
           .latest = {ts:$row.timestamp, input:$usage.input_tokens, cached:$usage.cached_input_tokens,
             model:(if ($row.payload.model | nonempty_string) then $row.payload.model else .model end),
             provider:(if ($row.payload.model_provider | nonempty_string) then $row.payload.model_provider else .provider end)}
         else . end
       else . end) |
    .latest // empty | [.ts, .input, .cached, .model, .provider] | @tsv' 2>/dev/null
}
codex_usage() {
  local session_id=$1 path record ts input read model provider
  path=$(rollout_for_session "$session_id") || return 1
  record=$(latest_usage "$path" "$session_id") || return 1
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r ts input read model provider <<<"$record"
  [[ -n "$model" ]] || model=codex
  [[ -n "$provider" ]] || provider=openai
  printf 'codex\t%s\t%s\t%s\t%s\t0\t0\t0\t%s\t%s\t%s\n' "$session_id" "$ts" "$input" "$read" "$model" "$provider" "$path"
}
