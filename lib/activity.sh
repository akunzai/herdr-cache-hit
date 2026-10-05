#!/usr/bin/env bash

# Return a tri-state status. The warmer accepts only "idle"; missing or
# unfamiliar lifecycle data is deliberately treated as unknown.
codex_activity_status() {
  local session_id=$1 path status
  path=$(rollout_for_session "$session_id") || { printf 'unknown\n'; return 0; }
  status=$(jq -n -r -R '
    reduce inputs as $line
      ({seen:false,state:"unknown"};
       ($line | fromjson? // {}) as $row |
       if $row.type == "event_msg" then
         ($row.payload.type // "") as $event |
         if ($event == "turn_started" or $event == "task_started") then .seen=true | .state="busy"
         elif ($event == "turn_complete" or $event == "turn_aborted" or $event == "task_complete") then .seen=true | .state="idle"
         else . end
       else . end)
    | .state' "$path" 2>/dev/null) || status=unknown
  [[ "$status" == idle || "$status" == busy ]] || status=unknown
  printf '%s\n' "$status"
}

claude_activity_status() {
  local session_id=$1 cwd=${2:-} supplied=${3:-} path status
  path=$(claude_transcript_path "$session_id" "$cwd" "$supplied") || { printf 'unknown\n'; return 0; }
  # Background entries map a task ID to the tool_use_id that launched it.
  # Claude Code reports completion as a <task-notification> in queue,
  # queued-command, or plain user rows; tool results are never scanned for it.
  status=$(jq -n -r -R '
    def notification_texts:
      if .type == "queue-operation" then (.content | strings)
      elif .type == "attachment" and .attachment.type? == "queued_command" then (.attachment.prompt | strings)
      elif .type == "user" then
        (.message.content | if type == "string" then .
                            elif type == "array" then (.[]? | objects | select(.type == "text") | .text | strings)
                            else empty end)
      else empty end;
    def notifications:
      scan("<task-notification>[\\s\\S]*?</task-notification>") |
      {task: ((capture("<task-id>(?<v>[^<]+)</task-id>") | .v) // ""),
       tool: ((capture("<tool-use-id>(?<v>[^<]+)</tool-use-id>") | .v) // ""),
       status: ((capture("<status>(?<v>[^<]+)</status>") | .v) // "")};
    def finish_task($n):
      if ($n.status | test("^(completed|failed|killed|stopped|cancell?ed|error|timeout|timed_out)$")) then
        .background |= with_entries(select(.key != $n.task and .key != ("untracked:" + $n.tool) and .value != $n.tool))
      else . end;
    reduce inputs as $line
      ({seen:false,pending:{},background:{}};
       ($line | fromjson?) as $row |
       if ($row | type) != "object" then .
       else
         .seen=true |
         if $row.type == "assistant" then
           reduce ($row.message.content[]? | objects | select(.type == "tool_use" and (.id | type) == "string")) as $tool
             (. ; .pending[$tool.id] = {name:$tool.name,input:($tool.input // {})})
         elif $row.type == "user" then
           reduce ($row.message.content[]? | objects | select(.type == "tool_result" and (.tool_use_id | type) == "string")) as $result
             (. ;
              ($result.tool_use_id) as $id |
              (.pending[$id] // {}) as $call |
              (if ($result.content | type) == "string" then $result.content
               elif ($result.content | type) == "array" then [$result.content[]? | .text? // ""] | join("\n")
               elif ($result.content | type) == "object" then ($result.content | tojson)
               else "" end) as $text |
              (($result.task_id // $result.taskId //
                ($row.toolUseResult | objects | (.backgroundTaskId // .task_id // .taskId)) //
                (try ($text | capture("(?i)(?:task|process|background with)(?: id)?[: ]+(?<task>[A-Za-z0-9_.-]+)").task) catch "")) // "") as $task |
              .pending |= del(.[$id]) |
              # Only Claude Code'"'"'s own background markers count: command output
              # that merely mentions background work must not open a task.
              if (($call.name == "Bash" or $call.name == "PowerShell") and
                  (($call.input.run_in_background == true) or
                   ([$row.toolUseResult | objects | .backgroundTaskId | strings] | length > 0) or
                   ($text | test("^Command (running in|.*moved to the) background")))) then
                .background[if $task != "" then $task else ("untracked:" + $id) end] = $id
              elif (($call.name == "Agent" or $call.name == "Task") and $call.input.run_in_background == true) then
                .background[$id] = $id
              elif ($call.name == "BashOutput" or $call.name == "TaskOutput") then
                ($call.input.task_id // $call.input.id // "") as $task |
                if ($task != "" and ($text | test("(?i)(task|process).*(completed|finished|exited)|exit code|no such task")))
                then .background |= del(.[$task])
                else . end
              else . end)
         else . end |
         reduce ($row | notification_texts | notifications) as $n (. ; finish_task($n))
       end)
    | if (.pending | length) > 0 then "busy"
      elif (.background | length) > 0 then "unknown"
      elif .seen then "idle"
      else "unknown" end' "$path" 2>/dev/null) || status=unknown
  [[ "$status" == idle || "$status" == busy ]] || status=unknown
  printf '%s\n' "$status"
}

agy_activity_status() {
  local session_id=$1 supplied=${2:-} path status
  path=$(agy_transcript_path "$session_id" "$supplied") || { printf 'unknown\n'; return 0; }
  status=$(jq -s -r '
    ([ .[] | (.content // "") | split("\n") as $lines |
      range(0; ($lines | length)) as $i |
      select($lines[$i] | startswith("Task: ")) |
      select($lines[$i + 1] == "Status: RUNNING") |
      $lines[$i][6:]
    ]) as $running |
    ([ .[] | (.content // "") | split("Task id \"") | .[1] // empty | split("\" finished") | .[0] ]) as $finished |
    if (($running - $finished) | length) > 0 then "busy" else "idle" end
  ' "$path" 2>/dev/null) || status=unknown
  [[ "$status" == idle || "$status" == busy ]] || status=unknown
  printf '%s\n' "$status"
}

agent_activity_status() {
  local agent=$1 session_id=$2 cwd=${3:-} supplied=${4:-}
  case "$agent" in
    codex) codex_activity_status "$session_id" ;;
    claude) claude_activity_status "$session_id" "$cwd" "$supplied" ;;
    agy) agy_activity_status "$session_id" "$supplied" ;;
    *) printf 'unknown\n' ;;
  esac
}
