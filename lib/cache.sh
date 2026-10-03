#!/usr/bin/env bash
reset_pane_cache() {
  local path tmp
  path=$(state_path "$1")
  [[ -s "$path" ]] || return 0
  tmp=$(mktemp "$STATE_DIR/state.XXXXXX") || return 1
  if jq '.active = null | .last_known = null' "$path" >"$tmp" 2>/dev/null; then
    atomic_install "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}
valid_state() { jq -e 'type == "object" and ((.active == null) or ((.active | type) == "object" and ([.active.agent,.active.session_id,.active.model,.active.provider,.active.signature] | all(type == "string")) and (.active.hit_at | type == "number") and (.active.deadline | type == "number")))' "$1" >/dev/null 2>&1; }
load_state() {
  local path=$1 tmp
  if [[ ! -s "$path" ]] || ! valid_state "$path"; then
    tmp=$(mktemp "$STATE_DIR/state.XXXXXX") || return 1; printf '%s\n' '{"active":null,"last_known":null,"observations":[]}' >"$tmp"; atomic_install "$tmp" "$path"
  fi
}
model_key() {
  local provider=${1:-unknown} model=${2:-default}
  [[ -n "$provider" ]] || provider=unknown
  [[ -n "$model" ]] || model=default
  printf '%s:%s' "$provider" "$model"
}
get_learned_ttl() {
  local provider=$1 model=$2 floor=$3 ceiling=${4:-$CEILING_SECONDS} allow_below_floor=${5:-false} key ttl
  key=$(model_key "$provider" "$model")
  [[ -s "$OBSERVATIONS_FILE" ]] || { printf '%s\n' "$floor"; return 0; }
  ttl=$(jq -r \
    --arg key "$key" \
    --argjson floor "$floor" \
    --argjson ceiling "$ceiling" \
    --argjson allow_below_floor "$allow_below_floor" '
    (.[$key] // []) as $raw |
    ($raw | map(select(type == "number" and . >= 60 and . <= $ceiling))) as $obs |
    if ($obs | length) >= (if $allow_below_floor then 3 else 2 end) then
      ($obs | sort) as $s |
      (if ($s | length) >= 5 then
        (($s | length) * 0.1 | floor) as $trim |
        $s[$trim : (($s | length) - $trim)]
       else $s end) as $inliers |
      (($inliers | add) / ($inliers | length) | floor) as $avg |
      (if $allow_below_floor then [$floor, $avg] | min else [$floor, $avg] | max end) | [., $ceiling] | min
    else
      $floor
    end' "$OBSERVATIONS_FILE" 2>/dev/null) || ttl="$floor"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$floor"
  printf '%s\n' "$ttl"
}
record_observation() {
  local provider=$1 model=$2 seconds=$3 max_sec=${4:-$CEILING_SECONDS} key tmp
  [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 60 && "$seconds" -le "$max_sec" ]] || return 0
  key=$(model_key "$provider" "$model")
  tmp=$(mktemp "$STATE_DIR/obs.XXXXXX") || return 1
  if [[ -s "$OBSERVATIONS_FILE" ]] && jq -e 'type == "object"' "$OBSERVATIONS_FILE" >/dev/null 2>&1; then
    jq --arg key "$key" --argjson sec "$seconds" '
      .[$key] = (((.[$key] // []) + [$sec]) | .[-25:])
    ' "$OBSERVATIONS_FILE" >"$tmp" 2>/dev/null && atomic_install "$tmp" "$OBSERVATIONS_FILE"
  else
    jq -n --arg key "$key" --argjson sec "$seconds" '
      { ($key): [$sec] }
    ' >"$tmp" 2>/dev/null && atomic_install "$tmp" "$OBSERVATIONS_FILE"
  fi
  rm -f "$tmp"
}
record_warmed_observation() {
  local agent=$1 session_id=$2 provider=$3 model=$4 seconds=$5 max_sec=$6 marker
  marker=$(warm_marker_path "$agent" "$session_id")
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 0
  fi
  record_observation "$provider" "$model" "$seconds" "$max_sec"
}
update_pane() {
  local pane=$1 agent session_id cwd supplied record state now record_epoch ttl_floor
  if [[ $# -eq 2 ]]; then agent=codex; session_id=$2; cwd=""; supplied=""; else agent=$2; session_id=$3; cwd=${4:-}; supplied=${5:-}; fi
  config_agent_enabled "$agent" || { clear_pane "$pane" "$agent"; return 0; }
  case "$agent" in
    codex) record=$(codex_usage "$session_id" 2>/dev/null) ;;
    agy) record=$(agy_usage "$session_id" "$supplied" 2>/dev/null) ;;
    claude) record=$(claude_usage "$session_id" "$cwd" "$supplied" 2>/dev/null) ;;
    opencode) record=$(opencode_usage "$session_id" "$cwd" "$supplied" 2>/dev/null) ;;
    *) clear_pane "$pane" "$agent"; return 0 ;;
  esac
  state=$(state_path "$pane"); load_state "$state" || return 1; now=${now:-$(date +%s)}
  local prev_hit_at prev_deadline prev_sig prev_active prev_sid
  prev_active=$(jq -r 'if .active != null then "true" else "false" end' "$state" 2>/dev/null || printf "false")
  prev_hit_at=$(jq -r '.active.hit_at // 0' "$state" 2>/dev/null || printf 0)
  prev_deadline=$(jq -r '.active.deadline // 0' "$state" 2>/dev/null || printf 0)
  prev_sig=$(jq -r '.active.signature // ""' "$state" 2>/dev/null || printf "")
  prev_sid=$(jq -r '.active.session_id // ""' "$state" 2>/dev/null || printf "")
  local last_known_sid last_known_read
  last_known_sid=$(jq -r '.last_known.session_id // ""' "$state" 2>/dev/null || printf "")
  last_known_read=$(jq -r '.last_known.read // 0' "$state" 2>/dev/null || printf 0)

  if [[ -z "$record" ]]; then
    if [[ "$prev_active" == "true" && "$prev_sid" == "$session_id" && "$prev_deadline" =~ ^[0-9]+$ && "$prev_deadline" -gt "$now" ]]; then
      input=$(jq -r '.active.input // 0' "$state" 2>/dev/null || printf 0)
      read=$(jq -r '.active.read // 0' "$state" 2>/dev/null || printf 0)
      write=$(jq -r '.active.write // 0' "$state" 2>/dev/null || printf 0)
      write5m=$(jq -r '.active.write5m // 0' "$state" 2>/dev/null || printf 0)
      write1h=$(jq -r '.active.write1h // 0' "$state" 2>/dev/null || printf 0)
      model=$(jq -r '.active.model // ""' "$state" 2>/dev/null || printf "")
      provider=$(jq -r '.active.provider // ""' "$state" 2>/dev/null || printf "")
    elif [[ "$prev_active" == "true" && "$prev_sid" == "$session_id" ]]; then
      if [[ ("$agent" == codex || "$agent" == agy) && "$prev_deadline" =~ ^[0-9]+$ && "$prev_deadline" -le "$now" ]]; then
        rm -f "$(warm_marker_path "$agent" "$session_id")"
      fi
      input=$(jq -r '.active.input // 0' "$state" 2>/dev/null || printf 0)
      read=$(jq -r '.active.read // 0' "$state" 2>/dev/null || printf 0)
      write=$(jq -r '.active.write // 0' "$state" 2>/dev/null || printf 0)
      write5m=$(jq -r '.active.write5m // 0' "$state" 2>/dev/null || printf 0)
      write1h=$(jq -r '.active.write1h // 0' "$state" 2>/dev/null || printf 0)
      model=$(jq -r '.active.model // ""' "$state" 2>/dev/null || printf "")
      provider=$(jq -r '.active.provider // ""' "$state" 2>/dev/null || printf "")
      jq --arg agent "$agent" --arg sid "$session_id" --arg model "$model" --arg provider "$provider" \
        --argjson input "$input" --argjson read "$read" --argjson write "$write" \
        --argjson write5m "$write5m" --argjson write1h "$write1h" '
        .active = null |
        .last_known = {agent:$agent, session_id:$sid, model:$model, provider:$provider, input:$input, read:$read, write:$write, write5m:$write5m, write1h:$write1h}
      ' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
    elif [[ "$last_known_sid" == "$session_id" && "$last_known_read" =~ ^[0-9]+$ && "$last_known_read" -gt 0 ]]; then
      input=$(jq -r '.last_known.input // 0' "$state" 2>/dev/null || printf 0)
      read=$(jq -r '.last_known.read // 0' "$state" 2>/dev/null || printf 0)
      write=$(jq -r '.last_known.write // 0' "$state" 2>/dev/null || printf 0)
      write5m=$(jq -r '.last_known.write5m // 0' "$state" 2>/dev/null || printf 0)
      write1h=$(jq -r '.last_known.write1h // 0' "$state" 2>/dev/null || printf 0)
      model=$(jq -r '.last_known.model // ""' "$state" 2>/dev/null || printf "")
      provider=$(jq -r '.last_known.provider // ""' "$state" 2>/dev/null || printf "")
    else
      # Different session or no previous state: clear any stale cached state
      if [[ "$prev_active" == "true" || -n "$last_known_sid" ]]; then
        jq '.active = null | .last_known = null' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
      fi
      if [[ "$agent" == agy ]]; then
        local cold_sym; cold_sym=$(config_str "$agent" cold_symbol "❄")
        report_pane "$pane" "$agent" "$cold_sym" "$DISPLAY_TTL_MS" "$cold_sym" "" "" "cold" || true
      else
        clear_pane "$pane" "$agent"
      fi
      return 0
    fi
  else
    local rec_agent rec_sid ts write5m write1h source_path source_deadline
    IFS=$'\t' read -r rec_agent rec_sid ts input read write write5m write1h model provider source_path source_deadline <<<"$record"
    : "$source_path"
    [[ "$rec_agent" == "$agent" && "$rec_sid" == "$session_id" ]] || { clear_pane "$pane" "$agent"; return 0; }
    record_epoch=$(parse_timestamp "$ts") || { clear_pane "$pane" "$agent"; return 0; }
    local signature; signature="$agent|$session_id|$model|$provider|$input|$read|$write|$write5m|$write1h"
    ttl_floor=$FLOOR_SECONDS
    local ttl_max
    ttl_max=$(config_int "$agent" ttl_ceiling "$CEILING_SECONDS")
    if [[ "$agent" == claude ]]; then
      if [[ "$write1h" -gt 0 ]]; then ttl_floor=3600; ttl_max=3600
      elif [[ "$write5m" -gt 0 ]]; then ttl_floor=300; ttl_max=300
      else ttl_floor=3600; ttl_max=3600
      fi
    elif [[ "$agent" == opencode ]]; then
      if [[ "$provider" == "kiconnect" ]]; then ttl_floor=2900; ttl_max=3600
      else ttl_floor=$FLOOR_SECONDS; ttl_max=3600
      fi
    fi

    if [[ "$read" -eq 0 && "$write" -eq 0 ]]; then
      if [[ "$prev_active" == "true" && "$prev_sid" == "$session_id" && "$prev_deadline" =~ ^[0-9]+$ && "$prev_deadline" -gt "$now" ]]; then
        # Preserve active cache state across intermediate zero-token reports
        input=$(jq -r '.active.input // 0' "$state" 2>/dev/null || printf 0)
        read=$(jq -r '.active.read // 0' "$state" 2>/dev/null || printf 0)
        write=$(jq -r '.active.write // 0' "$state" 2>/dev/null || printf 0)
        write5m=$(jq -r '.active.write5m // 0' "$state" 2>/dev/null || printf 0)
        write1h=$(jq -r '.active.write1h // 0' "$state" 2>/dev/null || printf 0)
        model=$(jq -r '.active.model // ""' "$state" 2>/dev/null || printf "")
        provider=$(jq -r '.active.provider // ""' "$state" 2>/dev/null || printf "")
      else
        # True cold drop: if we were previously active in the same session, record the survival duration before going cold
        if [[ "$prev_active" == "true" && "$prev_sid" == "$session_id" && "$prev_hit_at" =~ ^[0-9]+$ && "$prev_hit_at" -gt 0 ]]; then
          local delta=$((record_epoch - prev_hit_at))
          if (( delta >= 60 && delta <= ttl_max )); then
            record_warmed_observation "$agent" "$session_id" "$provider" "$model" "$delta" "$ttl_max"
          fi
        fi
        if [[ "$prev_active" == "true" && "$prev_sid" == "$session_id" ]]; then
          input=$(jq -r '.active.input // 0' "$state" 2>/dev/null || printf 0)
          read=$(jq -r '.active.read // 0' "$state" 2>/dev/null || printf 0)
          write=$(jq -r '.active.write // 0' "$state" 2>/dev/null || printf 0)
          write5m=$(jq -r '.active.write5m // 0' "$state" 2>/dev/null || printf 0)
          write1h=$(jq -r '.active.write1h // 0' "$state" 2>/dev/null || printf 0)
          model=$(jq -r '.active.model // ""' "$state" 2>/dev/null || printf "")
          provider=$(jq -r '.active.provider // ""' "$state" 2>/dev/null || printf "")
          jq --arg agent "$agent" --arg sid "$session_id" --arg model "$model" --arg provider "$provider" \
            --argjson input "$input" --argjson read "$read" --argjson write "$write" \
            --argjson write5m "$write5m" --argjson write1h "$write1h" '
            .active = null |
            .last_known = {agent:$agent, session_id:$sid, model:$model, provider:$provider, input:$input, read:$read, write:$write, write5m:$write5m, write1h:$write1h}
          ' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
        elif [[ "$last_known_sid" == "$session_id" && "$last_known_read" =~ ^[0-9]+$ && "$last_known_read" -gt 0 ]]; then
          input=$(jq -r '.last_known.input // 0' "$state" 2>/dev/null || printf 0)
          read=$(jq -r '.last_known.read // 0' "$state" 2>/dev/null || printf 0)
          write=$(jq -r '.last_known.write // 0' "$state" 2>/dev/null || printf 0)
          write5m=$(jq -r '.last_known.write5m // 0' "$state" 2>/dev/null || printf 0)
          write1h=$(jq -r '.last_known.write1h // 0' "$state" 2>/dev/null || printf 0)
          model=$(jq -r '.last_known.model // ""' "$state" 2>/dev/null || printf "")
          provider=$(jq -r '.last_known.provider // ""' "$state" 2>/dev/null || printf "")
        else
          jq '.active = null' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
        fi
      fi
    else
      # Cache hit or write
      if [[ "$signature" != "$prev_sig" ]]; then
        # Surprise hit: prompt arrived after the expected deadline but still hit the cache in the same session!
        if [[ "$read" -gt 0 && "$prev_sid" == "$session_id" && "$prev_hit_at" =~ ^[0-9]+$ && "$prev_hit_at" -gt 0 && "$prev_deadline" =~ ^[0-9]+$ && "$prev_deadline" -gt "$prev_hit_at" ]]; then
          local delta=$((record_epoch - prev_hit_at))
          local prev_ttl=$((prev_deadline - prev_hit_at))
          if (( delta > prev_ttl && delta >= 60 && delta <= ttl_max )); then
            record_warmed_observation "$agent" "$session_id" "$provider" "$model" "$delta" "$ttl_max"
          fi
        fi
        local ttl
        if [[ "$agent" == codex ]]; then
          # Use the documented 30m baseline. Only shorten it after at least three
          # recorded survival observations below 30m; longer intervals never extend it.
          ttl=$(get_learned_ttl "$provider" "$model" "$ttl_floor" "$ttl_max" true)
        else
          ttl=$(get_learned_ttl "$provider" "$model" "$ttl_floor" "$ttl_max")
        fi
        local new_deadline=$((record_epoch + ttl))
        jq --arg sig "$signature" --arg agent "$agent" --arg sid "$session_id" --arg model "$model" --arg provider "$provider" \
          --argjson at "$record_epoch" --argjson deadline "$new_deadline" \
          --argjson input "$input" --argjson read "$read" --argjson write "$write" \
          --argjson write5m "$write5m" --argjson write1h "$write1h" '
          .active = {agent:$agent, session_id:$sid, model:$model, provider:$provider, signature:$sig, hit_at:$at, deadline:$deadline, input:$input, read:$read, write:$write, write5m:$write5m, write1h:$write1h} |
          .last_known = {agent:$agent, session_id:$sid, model:$model, provider:$provider, input:$input, read:$read, write:$write, write5m:$write5m, write1h:$write1h}
        ' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
      fi
  fi
  if [[ "$agent" == agy && "$source_deadline" =~ ^[0-9]+$ && "$source_deadline" -gt 0 ]]; then
      jq --arg agent "$agent" --arg sid "$session_id" --argjson deadline "$source_deadline" 'if .active != null and .active.agent == $agent and .active.session_id == $sid then .active.deadline=$deadline else . end' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
    fi
  fi
  # Rebase existing Codex state after a policy change without extending the
  # cache lifetime: keep the original hit time and apply the new model estimate.
  local rebase_codex_state=false codex_max
  if [[ -z "$record" ]]; then
    if [[ "$prev_active" == true && "$prev_sid" == "$session_id" && "$prev_deadline" =~ ^[0-9]+$ && "$prev_deadline" -gt "$now" ]]; then
      rebase_codex_state=true
    fi
  elif [[ "$prev_active" == true && "$prev_sid" == "$session_id" && "$prev_sig" == "${signature:-}" ]]; then
    rebase_codex_state=true
  fi
  if [[ "$agent" == codex && "$rebase_codex_state" == true ]]; then
    local codex_ttl codex_floor prev_ttl rebased_deadline
    codex_floor=$FLOOR_SECONDS
    codex_max=$(config_int codex ttl_ceiling "$CEILING_SECONDS")
    codex_ttl=$(get_learned_ttl "$provider" "$model" "$codex_floor" "$codex_max" true)
    prev_ttl=$((prev_deadline - prev_hit_at))
    rebased_deadline=$((prev_hit_at + codex_ttl))
    if (( prev_ttl > codex_ttl )); then
      jq --argjson deadline "$rebased_deadline" '.active.deadline = $deadline' "$state" >"$state.tmp" 2>/dev/null && atomic_install "$state.tmp" "$state"
    fi
  fi
  local deadline pct total
  deadline=$(jq -r '.active.deadline // 0' "$state" 2>/dev/null || printf 0)
  if [[ "$deadline" =~ ^[0-9]+$ && "$deadline" -gt "$now" ]]; then
    ACTIVE_CACHE_COUNT=$(( ${ACTIVE_CACHE_COUNT:-0} + 1 ))
  fi
  local show_deadline show_read show_write show_percentage show_model bold_time read_text write_text model_text deadline_text
  local default_show_pct=true
  [[ "$agent" == agy || "$agent" == claude ]] && default_show_pct=false
  show_deadline=$(config_bool "$agent" show_deadline true)
  show_read=$(config_bool "$agent" show_read_tokens true)
  show_write=$(config_bool "$agent" show_write_tokens false)
  show_percentage=$(config_bool "$agent" show_percentage "$default_show_pct")
  show_model=$(config_bool "$agent" show_model false)
  bold_time=$(config_bool "$agent" bold_time true)
  read_text=""; write_text=""
  [[ "$show_read" == true ]] && read_text="⇣$(fmt_tokens "$read")"
  [[ "$show_write" == true ]] && write_text="⇡$(fmt_tokens "$write")"
  model_text=""; [[ "$show_model" == true && -n "$model" ]] && model_text="$model"

  local hot_sym expiring_sym cold_sym expiring_secs bold_secs remaining symbol
  hot_sym=$(config_str "$agent" hot_symbol "")
  expiring_sym=$(config_str "$agent" expiring_symbol "⏰")
  cold_sym=$(config_str "$agent" cold_symbol "❄")
  expiring_secs=$(config_int "$agent" expiring_threshold_seconds 300)
  bold_secs=$(config_int "$agent" bold_threshold_seconds "$expiring_secs")
  remaining=$((deadline - now))
  if (( remaining <= expiring_secs )); then
    symbol="$expiring_sym"
  else
    symbol="$hot_sym"
  fi

  deadline_text=""
  if [[ "$show_deadline" == true && "$deadline" =~ ^[0-9]+$ && "$deadline" -gt "$now" ]]; then
    local raw_clock; raw_clock=$(fmt_clock "$deadline")
    if [[ "$bold_time" == true ]] && (( remaining <= bold_secs )); then
      deadline_text="~$(to_bold_digits "$raw_clock")"
    else
      deadline_text="~$raw_clock"
    fi
  fi

  local pane_wake=0
  local t_high=$expiring_secs t_low=$bold_secs
  if (( bold_secs > expiring_secs )); then
    t_high=$bold_secs
    t_low=$expiring_secs
  fi
  if (( remaining > t_high )); then
    pane_wake=$((remaining - t_high))
  elif (( remaining > t_low && t_low > 0 )); then
    pane_wake=$((remaining - t_low))
  elif (( remaining > 0 )); then
    pane_wake=$remaining
  fi

  local state_name status_text tokens_text full_text ttl_ms
  if [[ "$agent" == codex ]]; then
    pct=0; [[ "$input" -gt 0 ]] && pct=$((read*100/input)); [[ "$pct" -gt 100 ]] && pct=100
    local pct_text; pct_text=""; [[ "$show_percentage" == true ]] && pct_text="${pct}%"
    tokens_text="$read_text"

    if [[ "$read" -gt 0 && -n "$deadline_text" ]]; then
      if (( remaining <= expiring_secs )); then state_name="expiring"; else state_name="hot"; fi
      status_text="${symbol}${deadline_text}"
      ttl_ms=$DISPLAY_TTL_MS
      if (( pane_wake > 0 )); then
        if [[ -z "${EARLIEST_WAKE:-}" ]] || (( pane_wake < EARLIEST_WAKE )); then
          EARLIEST_WAKE=$pane_wake
        fi
      fi
    else
      state_name="cold"
      status_text="$cold_sym"
      pct_text=""
      ttl_ms=$DISPLAY_TTL_MS
    fi
    local parts=()
    [[ -n "$status_text" ]] && parts+=("$status_text")
    [[ -n "$pct_text" ]] && parts+=("$pct_text")
    [[ -n "$tokens_text" ]] && parts+=("$tokens_text")
    [[ -n "$model_text" ]] && parts+=("$model_text")
    full_text="${parts[*]:-}"
    local details_text; details_text="${pct_text}${pct_text:+${tokens_text:+ }}${tokens_text}"
    local active_deadline="" active_remaining="" active_pct_num=""
    if [[ "$state_name" != "cold" && "$deadline" =~ ^[0-9]+$ && "$deadline" -gt "$now" ]]; then
      active_deadline="$deadline"
      (( remaining > 0 )) && active_remaining="$remaining"
      active_pct_num="$pct"
    fi
    report_pane "$pane" "$agent" "$full_text" "$ttl_ms" "$status_text" "$pct_text" "$tokens_text" "$state_name" "$details_text" "$active_deadline" "$active_remaining" "$active_pct_num" || true
  else
    total=$((input + read + write)); pct=0; [[ "$total" -gt 0 ]] && pct=$((read*100/total)); [[ "$pct" -gt 100 ]] && pct=100
    pct_text=""; [[ "$show_percentage" == true ]] && pct_text="${pct}%"
    tokens_text="${read_text}${write_text:+ $write_text}"

    if [[ "$total" -gt 0 && -n "$deadline_text" ]]; then
      if (( remaining <= expiring_secs )); then state_name="expiring"; else state_name="hot"; fi
      status_text="${symbol}${deadline_text}"
      ttl_ms=$DISPLAY_TTL_MS
      if (( pane_wake > 0 )); then
        if [[ -z "${EARLIEST_WAKE:-}" ]] || (( pane_wake < EARLIEST_WAKE )); then
          EARLIEST_WAKE=$pane_wake
        fi
      fi
    else
      state_name="cold"
      status_text="$cold_sym"
      pct_text=""
      ttl_ms=$DISPLAY_TTL_MS
    fi
    local parts=()
    [[ -n "$status_text" ]] && parts+=("$status_text")
    [[ -n "$pct_text" ]] && parts+=("$pct_text")
    [[ -n "$tokens_text" ]] && parts+=("$tokens_text")
    [[ -n "$model_text" ]] && parts+=("$model_text")
    full_text="${parts[*]:-}"
    local details_text; details_text="${pct_text}${pct_text:+${tokens_text:+ }}${tokens_text}"
    local active_deadline="" active_remaining="" active_pct_num=""
    if [[ "$state_name" != "cold" && "$deadline" =~ ^[0-9]+$ && "$deadline" -gt "$now" ]]; then
      active_deadline="$deadline"
      (( remaining > 0 )) && active_remaining="$remaining"
      active_pct_num="$pct"
    fi
    report_pane "$pane" "$agent" "$full_text" "$ttl_ms" "$status_text" "$pct_text" "$tokens_text" "$state_name" "$details_text" "$active_deadline" "$active_remaining" "$active_pct_num" || true
  fi
}
maybe_warm_agent() {
  local agent=$1 pane=$2 session_id=$3 state deadline now remaining margin max_count count
  [[ "$agent" == codex || "$agent" == agy ]] || return 0
  [[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 0

  state=$(state_path "$pane")
  [[ -s "$state" ]] || return 0
  [[ "$(jq -r '.active.session_id // ""' "$state" 2>/dev/null)" == "$session_id" ]] || return 0
  deadline=$(jq -r '.active.deadline // 0' "$state" 2>/dev/null) || return 0
  [[ "$deadline" =~ ^[0-9]+$ && "$deadline" -gt 0 ]] || return 0
  now=${now:-$(date +%s)}
  remaining=$((deadline - now))
  (( remaining > 0 )) || return 0
  margin=$(config_int "$agent" cache_warmer_margin_seconds 300)
  (( margin >= 30 && margin <= 600 )) || margin=300
  (( remaining <= margin )) || return 0
  warmer_enabled_for_session "$agent" "$session_id" || return 0

  # Herdr's AGY state can say done while an AGY-managed background task is
  # still running. The transcript provides the task lifecycle signal.
  if [[ "$agent" == agy ]]; then
    agy_has_running_background_task "$session_id"
    [[ $? -eq 0 ]] && return 0
  fi

  max_count=$(config_int "$agent" cache_warmer_max_per_session 0)
  (( max_count == 0 || (max_count >= 1 && max_count <= 3) )) || max_count=0
  local count_path marker_path epoch_path epoch hit_at
  count_path=$(warm_count_path "$agent" "$session_id")
  marker_path=$(warm_marker_path "$agent" "$session_id")
  epoch_path=$(warm_epoch_path "$agent" "$session_id")
  hit_at=$(jq -r '.active.hit_at // 0' "$state" 2>/dev/null)
  epoch="$hit_at:$deadline"
  [[ "$(cat "$epoch_path" 2>/dev/null)" != "$epoch" ]] || return 0
  count=$(cat "$count_path" 2>/dev/null || printf 0)
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( max_count == 0 || count < max_count )) || return 0

  # Check current identity, idle state, and focus immediately before touching the PTY.
  local snapshot still_safe screen last_prompt
  snapshot=$("$HERDR_BIN" api snapshot 2>/dev/null) || return 0
  still_safe=$(jq -r --arg pane "$pane" --arg agent "$agent" --arg sid "$session_id" '
    [.result.snapshot.panes[]? | select(.pane_id == $pane and .agent == $agent and .agent_session.kind == "id" and .agent_session.value == $sid)] as $p |
    if ($p | length) == 1 then (($p[0].agent_status == "idle" or $p[0].agent_status == "done") and $p[0].focused == false) else false end
  ' <<<"$snapshot" 2>/dev/null) || return 0
  [[ "$still_safe" == true ]] || return 0
  screen=$("$HERDR_BIN" agent read "$pane" --source recent --lines 12 2>/dev/null) || return 0
  case "$agent" in
    codex)
      last_prompt=$(printf '%s\n' "$screen" | sed -n '/›/p' | tail -n 1 | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ "$last_prompt" == '› Ask Codex to do anything' ]] || return 0
      ;;
    agy)
      last_prompt=$(printf '%s\n' "$screen" | sed -n -E '/^[[:space:]]*>/p' | tail -n 1 | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ "$last_prompt" == '>' ]] || return 0
      ;;
  esac

  # Mark before submission so a timeout cannot cause a duplicate queued prompt.
  printf '%s\n' "$((count + 1))" >"$count_path.tmp" || return 0
  atomic_install "$count_path.tmp" "$count_path" || return 0
  : >"$marker_path" || return 0
  printf '%s\n' "$epoch" >"$epoch_path.tmp" || return 0
  atomic_install "$epoch_path.tmp" "$epoch_path" || return 0
  local prompt='Cache warm check only: do not use tools or inspect or change anything. Reply with exactly: cache warm.'
  "$HERDR_BIN" agent prompt "$pane" "$prompt" --wait --timeout 120000 >/dev/null 2>&1 || true
}
maybe_warm_codex() { maybe_warm_agent codex "$1" "$2"; }
maybe_warm_agy() { maybe_warm_agent agy "$1" "$2"; }
