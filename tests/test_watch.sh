#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cache-hit-test.XXXXXX")
trap 'cancel_timer; rm -rf "$TMP"' EXIT
export CODEX_SESSIONS_DIR="$TMP/sessions" HERDR_PLUGIN_STATE_DIR="$TMP/state" HODEX_SESSIONS_DIR="$TMP/unused"
export AGY_STATUSLINE_STATE_DIR="$TMP/agy-statusline"
export HERDR_PLUGIN_CONFIG_DIR="$TMP/config"
export HERDR_NO_TIMER=1
mkdir -p "$CODEX_SESSIONS_DIR/2026/09/06"
source "$ROOT/lib/core.sh"; source "$ROOT/lib/codex.sh"; source "$ROOT/lib/agy.sh"; source "$ROOT/lib/claude.sh"; source "$ROOT/lib/opencode.sh"; source "$ROOT/lib/cache.sh"
fail=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fail=1; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else printf 'not ok - %s\n' "$3"; fail=1; fi; }
assert_cmd() { if eval "$1" >/dev/null 2>&1; then ok "$2"; else not_ok "$2"; fi; }
pid_is_live() {
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') || return 1
  [[ -n "$stat" && "$stat" != Z* ]]
}
sid=aaa111; roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-$sid.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111","cwd":"/same"}}' 'not json' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500},"model":"m1","model_provider":"p1"}}' '{"type":"incomplete"}' >"$roll"
printf '%s\n' '{"type":"session_meta","payload":{"id":"wrong"}}' >"$TMP/rollout-bbb222.jsonl"
assert_eq "$(rollout_for_session "$sid")" "$roll" 'native ID selects exact rollout'
assert_eq "$(rollout_for_session bbb222 || true)" '' 'wrong rollout identity is rejected'

# UUIDv7 fast path test: historical session from May 2026 resolved without scanning
uuid7="019e0779-180e-7ec2-9d3c-e18de4536265"
mkdir -p "$CODEX_SESSIONS_DIR/2026/05/08"
roll7="$CODEX_SESSIONS_DIR/2026/05/08/rollout-$uuid7.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$uuid7\"}}" >"$roll7"
assert_eq "$(rollout_for_session "$uuid7")" "$roll7" 'UUIDv7 timestamp selects exact historical rollout'

assert_eq "$(latest_usage "$roll" "$sid")" $'2026-09-06T10:00:00Z\t1000\t500\tm1\tp1' 'malformed lines are ignored'

# Codex CLI token_count uses per-request counts, not cumulative session totals.
modern_roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-modern.jsonl"
cat >"$modern_roll" <<'JSONL'
{"type":"session_meta","payload":{"id":"modern","model_provider":"custom-provider"}}
{"type":"turn_context","payload":{"model":"gpt-current"}}
{"type":"event_msg","timestamp":"2026-09-06T10:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":90000},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400}}}}
{"type":"event_msg","timestamp":"2026-09-06T10:04:00Z","payload":{"type":"token_count","info":null,"rate_limits":{}}}
not json
{"type":"event_msg","payload":
JSONL
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:03:00Z\t1000\t400\tgpt-current\tcustom-provider' 'Codex token_count reads last usage and ignores quota-only and partial rows'
assert_eq "$(codex_usage modern | cut -f1-10)" $'codex\tmodern\t2026-09-06T10:03:00Z\t1000\t400\t0\t0\t0\tgpt-current\tcustom-provider' 'Codex adapter preserves model/provider column alignment'
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:05:00Z","payload":{"session_id":"modern","usage":{"input_tokens":2000,"cached_input_tokens":1600}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:05:00Z\t2000\t1600\tgpt-current\tcustom-provider' 'newer token_usage_record wins and inherits rollout metadata'
printf '%s\n' '{"type":"turn_context","payload":{"model":"next-model"}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern | cut -f4)" gpt-current 'later turn context does not relabel previous usage'
printf '%s\n' '{"type":"event_msg","timestamp":"2026-09-06T10:06:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3000,"cached_input_tokens":0}}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern)" $'2026-09-06T10:06:00Z\t3000\t0\tnext-model\tcustom-provider' 'newer token_count wins including a real zero-cache request'
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:07:00Z","payload":{"session_id":"other","usage":{"input_tokens":4000,"cached_input_tokens":3500}}}' '{"type":"event_msg","timestamp":"2026-09-06T10:08:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4000,"cached_input_tokens":-1}}}}' '{"type":"event_msg","timestamp":"2026-09-06T10:09:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":3500}}}}' >>"$modern_roll"
assert_eq "$(latest_usage "$modern_roll" modern | cut -f1-3)" $'2026-09-06T10:06:00Z\t3000\t0' 'foreign session, invalid counts, and cumulative-only rows are ignored'
bare_roll="$TMP/bare-codex.jsonl"
printf '%s\n' '{"type":"token_usage_record","timestamp":"2026-09-06T10:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":500}}}' >"$bare_roll"
assert_eq "$(latest_usage "$bare_roll" bare)" $'2026-09-06T10:00:00Z\t1000\t500\tcodex\topenai' 'missing model/provider use nonempty defaults before TSV parsing'
assert_eq "$(CODEX_HOME="$TMP/custom-home" env -u CODEX_SESSIONS_DIR -u HODEX_SESSIONS_DIR bash -c 'source "$1/lib/core.sh"; printf "%s" "$SESSIONS_DIR"' _ "$ROOT")" "$TMP/custom-home/sessions" 'Codex home overrides the default session directory'

if python3 - "$ROOT" "$TMP" <<'PY'
import json, os, pathlib, runpy, sys, time
module = runpy.run_path(str(pathlib.Path(sys.argv[1]) / 'lib/codex_session.py'))
resolve = module['resolve_session']
sessions = pathlib.Path(sys.argv[2]) / 'resolver-sessions'
sessions.mkdir()
started = time.time()
process = {'foreground_processes': [{'name': 'codex', 'argv': ['codex'], 'pid': os.getpid()}]}
def fixture(sid, created, **extra):
    payload = {'id': sid, 'cwd': '/same', 'timestamp': created, 'originator': 'codex-tui', 'source': 'vscode', **extra}
    path = sessions / f'rollout-{sid}.jsonl'
    path.write_text(json.dumps({'type': 'session_meta', 'payload': payload}) + '\n')
    return path
fresh = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started))
old = '2026-01-01T00:00:00Z'
fixture('root', fresh)
fixture('child', fresh, parent_thread_id='root', source={'subagent': {}}, thread_source='subagent')
assert resolve(sessions, '/same', 'p1', process, [], started) == 'root'
print('ok - missing native ID resolves a fresh root and excludes subagents')
fixture('collision', fresh)
assert resolve(sessions, '/same', 'p1', process, [], started) is None
print('ok - simultaneous same-directory roots are ambiguous')
resume = {'foreground_processes': [{'name': 'codex', 'argv': ['codex', 'resume', 'root', '--yolo']}]}
assert resolve(sessions, '/same', 'p1', resume, [{'agent': 'codex', 'pane_id': 'p2', 'cwd': '/same'}], started) == 'root'
print('ok - explicit resume ID disambiguates same-directory panes')
fixture('root', old)
fixture('collision', old)
claimed = [{'agent': 'codex', 'pane_id': 'p2', 'cwd': '/other', 'agent_session': {'kind': 'id', 'value': 'collision'}}]
assert resolve(sessions, '/same', 'p1', process, claimed, started) == 'root'
print('ok - unique active cwd fallback excludes sessions assigned to other panes')
assert resolve(sessions, '/same', 'p1', process, [], started) is None
print('ok - multiple active roots refuse a newest-file guess')
assert resolve(sessions, '/same', 'p1', process, claimed + [{'agent': 'codex', 'pane_id': 'p3', 'cwd': '/same'}], started) is None
print('ok - cwd fallback refuses multiple live panes in the same directory')
assert resolve(sessions, '/same', 'p1', {'foreground_processes': []}, claimed, started) is None
print('ok - missing Codex foreground process cannot select a historical session')
assert resolve(sessions, '/same', 'p1', process, claimed, None) is None
print('ok - missing process launch time cannot select a historical session')
fixture('root', fresh)
resumed = fixture('collision', old)
with resumed.open('a') as handle:
    handle.write(json.dumps({'type': 'token_usage_record', 'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started + 1)), 'payload': {'usage': {'input_tokens': 1000, 'cached_input_tokens': 400}}}) + '\n')
assert resolve(sessions, '/same', 'p1', process, [], started) == 'collision'
print('ok - interactive resume selects the used root instead of an empty bootstrap thread')
other = fixture('other-active', old)
for path, total_in, total_out in [(resumed, 98901000, 241030), (other, 41000, 1800)]:
    with path.open('a') as handle:
        handle.write(json.dumps({'type': 'token_usage_record', 'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started + 1)), 'payload': {'usage': {'input_tokens': 1000, 'cached_input_tokens': 400}, 'thread_token_usage': {'input_tokens': total_in, 'output_tokens': total_out}}}) + '\n')
title_panes = [{'pane_id': 'p1', 'agent': 'codex', 'cwd': '/same', 'terminal_title_stripped': 'Working | Context 78% used | 98.9M in | 241K out | GPT-current'}]
assert resolve(sessions, '/same', 'p1', process, title_panes, started) == 'collision'
print('ok - pane title totals disambiguate multiple active root rollouts')
with other.open('a') as handle:
    handle.write(json.dumps({'type': 'event_msg', 'timestamp': fresh, 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 98902000, 'output_tokens': 241000}}}}) + '\n')
assert resolve(sessions, '/same', 'p1', process, title_panes, started) is None
print('ok - indistinguishable rounded title totals remain ambiguous')
assert abs(module['process_started'](os.getpid()) - started) < 5
print('ok - process start time is read from the local process table')
PY
then :; else not_ok 'Codex missing-session resolver fixtures'; fi

assert_eq "$(fmt_tokens 0)" 0 'zero formatting'; assert_eq "$(fmt_tokens 10000)" 10.0k 'thousands formatting'; assert_eq "$(fmt_tokens 2000000)" 2.0M 'millions formatting'
init_state; report_pane() { :; }; clear_pane() { :; }
update_pane paneA "$sid"; d1=$(jq -r .active.deadline "$(state_path paneA)"); update_pane paneA "$sid"; d2=$(jq -r .active.deadline "$(state_path paneA)")
assert_eq "$d1" "$d2" 'cached records do not extend deadline'
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"codex":{"enabled":false}}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(config_bool codex enabled true)" false 'per-agent enabled setting is read'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:01:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m1","model_provider":"p1"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active == null' \"$(state_path paneA)\"" 'cold transition sets active null'
assert_cmd "jq -e '.\"p1:m1\" | length == 1' \"$OBSERVATIONS_FILE\"" 'cold transition records observation in shared observations.json'

# Switch to m2/p2 at 10:02:00Z (hit_at = 10:02:00Z, deadline = 10:32:00Z, ttl = 1800)
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:02:00Z","payload":{"usage":{"input_tokens":1,"cached_input_tokens":1},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"; assert_cmd "jq -e '.active.model == \"m2\" and .active.provider == \"p2\"' \"$(state_path paneA)\"" 'model/provider are isolated'

# Surprise hit past deadline: prompt at 10:47:00Z (45 min = 2700s > 1800s deadline) with cache read hits
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | (length == 1 and .[0] == 2700)' \"$OBSERVATIONS_FILE\"" 'surprise hit past deadline records survival observation'

# Cross-pane sharing: paneB with same model/provider reads from shared observations
record_observation p2 m2 3300
learned=$(get_learned_ttl p2 m2 1800)
assert_eq "$learned" 3000 'shared observations compute learned TTL across panes'

# Prefix shift guardrail: cold drop within 20s does not add to observations
printf '%s\n' '{"type":"session_meta","payload":{"id":"aaa111"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T10:47:20Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":0},"model":"m2","model_provider":"p2"}}' >"$roll"
update_pane paneA "$sid"
assert_cmd "jq -e '.\"p2:m2\" | length == 2' \"$OBSERVATIONS_FILE\"" 'prefix shift under 60s is ignored by observation guardrail'

printf '%s\n' corrupt >"$(state_path paneB)"; update_pane paneB "$sid"; assert_cmd "jq -e . \"$(state_path paneB)\"" 'corrupt state is rebuilt'

# AGY and Claude adapter fixtures exercise native IDs, recent-tail parsing, and
# independent read/write counters without involving either CLI's status command.
agy_root="$TMP/agy"; claude_root="$TMP/claude"; export AGY_HOME="$agy_root" CLAUDE_CONFIG_DIR="$claude_root"
mkdir -p "$agy_root/antigravity/brain/agy-1/.system_generated/logs" "$claude_root/projects/-same"
agy_file="$agy_root/antigravity/brain/agy-1/.system_generated/logs/transcript.jsonl"
printf '%s\n' '{"conversation_id":"wrong","created_at":"2026-09-06T10:00:00Z","context_window":{"current_usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}},"model":"bad"}' 'partial' '{"conversationId":"agy-1","created_at":"2026-09-06T10:01:00Z","context_window":{"current_usage":{"input_tokens":12000,"cache_read_input_tokens":48900,"cache_creation_input_tokens":3000}},"model":"Gemini 3.8 Flash"}' >"$agy_file"
assert_eq "$(agy_usage agy-1 | cut -f1-10)" $'agy\tagy-1\t2026-09-06T10:01:00Z\t12000\t48900\t3000\t0\t0\tGemini 3.8 Flash\tantigravity' 'AGY transcript maps read/write fields and rejects mismatched IDs'
assert_eq "$(agy_usage missing || true)" '' 'missing AGY transcript is unavailable'
agy_cli_root="$TMP/agy-cli"; mkdir -p "$agy_cli_root/brain/agy-cli-1/.system_generated/logs"; export AGY_CLI_HOME="$agy_cli_root"
printf '%s\n' '{"conversation_id":"agy-cli-1","created_at":"2026-09-06T10:03:00Z","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}},"model":"Gemini CLI"}' >"$agy_cli_root/brain/agy-cli-1/.system_generated/logs/transcript.jsonl"
assert_eq "$(agy_transcript_path agy-cli-1)" "$agy_cli_root/brain/agy-cli-1/.system_generated/logs/transcript.jsonl" 'AGY native CLI transcript path is discovered'
claude_file="$claude_root/projects/-same/claude-1.jsonl"
printf '%s\n' '{"sessionId":"claude-1","timestamp":"2026-09-06T10:02:00Z","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":400,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":25}},"model":"claude-sonnet"}}' >"$claude_file"
assert_eq "$(claude_usage claude-1 /same | cut -f1-10)" $'claude\tclaude-1\t2026-09-06T10:02:00Z\t1000\t400\t75\t50\t25\tclaude-sonnet\tanthropic' 'Claude transcript maps cache lifetime creation counters'
now=$(date +%s)
mkdir -p "$AGY_STATUSLINE_STATE_DIR"
jq -n --argjson now "$now" '{session_id:"agy-1",observed_at:$now,input_tokens:900,cache_read_tokens:800,cache_creation_tokens:100,model:"Gemini live",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-1.json"
jq -n --argjson now "$now" '{session_id:"agy-2",observed_at:$now,input_tokens:700,cache_read_tokens:0,cache_creation_tokens:600,model:"Gemini second",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-2.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t900\t800\t100\t0\t0\tGemini live\tantigravity' 'AGY live statusline sidecar takes precedence'
assert_eq "$(agy_usage agy-2 | cut -f1,2,4-10)" $'agy\tagy-2\t700\t0\t600\t0\t0\tGemini second\tantigravity' 'parallel AGY sidecars remain session-isolated'
jq --argjson now "$now" '.observed_at = ($now - 180)' "$AGY_STATUSLINE_STATE_DIR/agy-1.json" >"$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" && mv "$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" "$AGY_STATUSLINE_STATE_DIR/agy-1.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t900\t800\t100\t0\t0\tGemini live\tantigravity' 'AGY hot sidecar survives statusline silence until deadline'
jq -n --argjson now "$now" '{session_id:"agy-1",observed_at:($now-180),input_tokens:900,cache_read_tokens:800,cache_creation_tokens:100,model:"Gemini live",provider:"antigravity",deadline:($now+300)}' >"$AGY_STATUSLINE_STATE_DIR/agy-1.json"
update_pane paneAGY agy agy-1 /same; assert_cmd "jq -e '.active.agent == \"agy\" and .active.session_id == \"agy-1\" and .active.deadline == ($now + 300)' \"$(state_path paneAGY)\"" 'AGY state is isolated by agent and native ID and deadline'
jq --argjson now "$now" '.deadline = ($now - 1)' "$AGY_STATUSLINE_STATE_DIR/agy-1.json" >"$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" && mv "$AGY_STATUSLINE_STATE_DIR/agy-1.tmp" "$AGY_STATUSLINE_STATE_DIR/agy-1.json"
assert_eq "$(agy_usage agy-1 | cut -f1,2,4-10)" $'agy\tagy-1\t12000\t48900\t3000\t0\t0\tGemini 3.8 Flash\tantigravity' 'expired AGY sidecar falls back to transcript data'
update_pane paneClaude claude claude-1 /same; assert_cmd "jq -e '.active.agent == \"claude\" and .active.provider == \"anthropic\"' \"$(state_path paneClaude)\"" 'Claude state is isolated by agent and provider'
mkdir "$STATE_DIR/watcher.lock"; printf '%s\n' 999999 >"$STATE_DIR/watcher.lock/pid"; assert_cmd 'acquire_lock' 'stale lock is recoverable'; cleanup
if command -v python3 >/dev/null 2>&1; then
  py=$(python3 - "$roll" <<'PY'
import json,sys
last=''
for line in open(sys.argv[1]):
 try: o=json.loads(line)
 except json.JSONDecodeError: continue
 if o.get('type')=='token_usage_record':
  u=o.get('payload',{}).get('usage',{})
  if isinstance(u.get('input_tokens'),int) and isinstance(u.get('cached_input_tokens'),int): last='\t'.join([o.get('timestamp',''),str(u['input_tokens']),str(u['cached_input_tokens']),o.get('payload',{}).get('model',''),o.get('payload',{}).get('model_provider','')])
print(last)
PY
); assert_eq "$py" "$(latest_usage "$roll" "$sid")" 'Bash and Python fixture outputs agree'; fi

if command -v python3 >/dev/null 2>&1; then
  opencode_db="$TMP/opencode.db"
  export OPENCODE_DB_PATH="$opencode_db"
  python3 -c "
import sqlite3
con = sqlite3.connect('$opencode_db')
cur = con.cursor()
cur.execute('CREATE TABLE session (id text PRIMARY KEY, directory text, time_created integer, time_updated integer, model text, tokens_input integer, tokens_cache_read integer, tokens_cache_write integer)')
cur.execute('CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, time_updated integer, data text)')
cur.execute('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?, ?)', ('oc-1', '/same', 1000, 2000, '{\"id\":\"m1\",\"providerID\":\"p1\"}', 10, 20, 5))
cur.execute('INSERT INTO message VALUES (?, ?, ?, ?, ?)', ('m1', 'oc-1', 1000, 2000, '{\"role\":\"assistant\",\"tokens\":{\"input\":15,\"cache\":{\"read\":45,\"write\":10}},\"modelID\":\"gpt-5\",\"providerID\":\"kiconnect\",\"time\":{\"completed\":1788784328200}}'))
con.commit()
con.close()
"
  assert_eq "$(opencode_usage oc-1 | cut -f1,2,4-10)" $'opencode\toc-1\t15\t45\t10\t0\t0\tgpt-5\tkiconnect' 'OpenCode message maps tokens, model, and provider'
  special_db="$TMP/opencode#query?percent%.db"
  cp "$opencode_db" "$special_db"
  assert_eq "$(opencode_usage oc-1 '' "$special_db" | cut -f1,2,4-10)" $'opencode\toc-1\t15\t45\t10\t0\t0\tgpt-5\tkiconnect' 'OpenCode reads database paths containing #, ?, and %'
  update_pane paneOC opencode oc-1 /same
  assert_cmd "jq -e '.active.agent == \"opencode\" and .active.session_id == \"oc-1\" and .active.model == \"gpt-5\"' \"$(state_path paneOC)\"" 'OpenCode pane state is recorded'

  # Test OpenCode with live WAL mode and genuinely uncheckpointed committed row
  wal_fifo="$TMP/wal_sync"
  mkfifo "$wal_fifo"
  python3 -c "
import sqlite3
con = sqlite3.connect('$opencode_db')
con.execute('PRAGMA journal_mode=WAL;')
cur = con.cursor()
cur.execute('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?, ?)', ('oc-wal', '/wal', 2000, 3000, '{\"id\":\"m-wal\",\"providerID\":\"p-wal\"}', 50, 100, 20))
cur.execute('INSERT INTO message VALUES (?, ?, ?, ?, ?)', ('m-wal-1', 'oc-wal', 2000, 3000, '{\"role\":\"assistant\",\"tokens\":{\"input\":30,\"cache\":{\"read\":90,\"write\":25}},\"modelID\":\"claude-3-7\",\"providerID\":\"anthropic\",\"time\":{\"completed\":1788784330000}}'))
con.commit()
# Signal commit is done, then block until reader signals us to close
open('$wal_fifo', 'w').write('ready\n')
open('$wal_fifo', 'r').read()
con.close()
" &
  wal_pid=$!
  # Wait for writer to signal commit is done (blocks until FIFO is written)
  read -r _ < "$wal_fifo"
  # Assert WAL file exists (writer still holds connection)
  assert_cmd "[[ -f '${opencode_db}-wal' ]]" 'WAL file exists while writer holds connection'
  assert_eq "$(opencode_usage oc-wal | cut -f1,2,4-10)" $'opencode\toc-wal\t30\t90\t25\t0\t0\tclaude-3-7\tanthropic' 'OpenCode reads committed rows from live WAL database'
  # Release writer
  echo "done" > "$wal_fifo"
  wait "$wal_pid" 2>/dev/null || true
  rm -f "$wal_fifo"
fi

fake="$TMP/fake-herdr"; reports="$TMP/watcher-reports"; panes="$TMP/panes.json"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$1 $2" == "pane list" ]]; then cat "$FAKE_PANES"; elif [[ "$1 $2" == "pane process-info" ]]; then cat "${FAKE_PROCESS_INFO:-/dev/null}"; else printf "%s\n" "$*" >>"$FAKE_REPORTS"; fi' >"$fake"; chmod +x "$fake"
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}},{"pane_id":"p2","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"bbb222"}},{"pane_id":"p3","agent":"agy","cwd":"/same","agent_session":{"kind":"id","value":"agy-missing"}},{"pane_id":"p4","agent":"opencode","cwd":"/same","agent_session":{"kind":"id","value":"oc-1"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p1.*cache=' \"$reports\"" 'watcher reports native session pane'
assert_cmd "grep -q 'p1.*cache_status=' \"$reports\"" 'watcher reports granular cache_status'
assert_cmd "grep -q 'p1.*clear-token cache_pct' \"$reports\"" 'cold watcher clears formatted cache percentage'
assert_cmd "grep -q 'p1.*clear-token cache_pct_num' \"$reports\"" 'cold watcher clears numeric cache percentage'
assert_cmd "grep -q 'p1.*cache_tokens=' \"$reports\"" 'watcher reports granular cache_tokens'
assert_cmd "grep -q 'p1.*clear-token cache_deadline' \"$reports\"" 'watcher clears cache_deadline on cold pane'
assert_cmd "grep -q 'p1.*clear-token cache_remaining_secs' \"$reports\"" 'watcher clears cache_remaining_secs on cold pane'
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'missing rollout clears second pane'
assert_cmd "grep -q 'p2.*clear-token cache_deadline' \"$reports\"" 'missing rollout clears cache_deadline'
assert_cmd "grep -q 'p2.*clear-token cache_pct_num' \"$reports\"" 'missing rollout clears numeric percentage'
assert_cmd "grep -q 'p3.*cache_state=cold' \"$reports\"" 'missing AGY usage reports cold'
assert_cmd "grep -q 'p3.*clear-token cache_deadline' \"$reports\"" 'missing AGY usage clears cache_deadline'
assert_cmd "grep -q 'p4.*agent opencode.*cache=' \"$reports\"" 'watcher reports OpenCode session pane'
FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" bash -c \
  'source "$1/lib/core.sh"; report_pane paneNumeric codex "~12:00 80% ⇣800" 15000 "~12:00" "80%" "⇣800" hot "80% ⇣800" 2000000000 240 80' _ "$ROOT"
assert_cmd "grep -q 'paneNumeric.*cache_pct=80%' \"$reports\" && grep -q 'paneNumeric.*cache_remaining_secs=240' \"$reports\" && grep -q 'paneNumeric.*cache_pct_num=80' \"$reports\"" 'hot watcher reports formatted and numeric cache metadata'
printf '%s\n' '{"result":{"panes":[{"pane_id":"p1","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"aaa111"}}]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$reports" HERDR_BIN_PATH="$fake" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'p2.*clear-token cache' \"$reports\"" 'closed pane is cleared'

# A missing native session ID must survive empty TSV fields and keep polling
# before the first token_count arrives, rather than waiting for a focus event.
recovery_process="$TMP/recovery-process.json"
recovery_reports="$TMP/recovery-reports"
recovery_wakes="$TMP/recovery-wakes"
recovery_roll="$CODEX_SESSIONS_DIR/2026/09/06/rollout-recovery.jsonl"
printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"name":"codex","argv":["codex","resume","recovery"],"pid":1}]}}}' >"$recovery_process"
printf '%s\n' '{"result":{"panes":[{"pane_id":"pRecovery","agent":"codex","cwd":"/same","agent_session":null}]}}' >"$panes"
printf '%s\n' '{"type":"session_meta","payload":{"id":"recovery","model_provider":"openai"}}' >"$recovery_roll"
FAKE_PANES="$panes" FAKE_PROCESS_INFO="$recovery_process" FAKE_REPORTS="$recovery_reports" FAKE_WAKE_FILE="$recovery_wakes" HERDR_BIN_PATH="$fake" HERDR_NO_TIMER='' bash -c \
  'source "$1/watch.sh"; schedule_wake() { printf "%s\n" "$1" >"$FAKE_WAKE_FILE"; }; cancel_timer() { printf "cancel\n" >"$FAKE_WAKE_FILE"; }; watch_main' _ "$ROOT"
assert_eq "$(cat "$recovery_wakes")" 15 'Codex pane with no usage schedules a 15-second refresh'
recovery_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "{\"type\":\"event_msg\",\"timestamp\":\"$recovery_ts\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":400}}}}" >>"$recovery_roll"
FAKE_PANES="$panes" FAKE_PROCESS_INFO="$recovery_process" FAKE_REPORTS="$recovery_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "grep -q 'pRecovery.*cache_pct=40%' \"$recovery_reports\"" 'missing native ID publishes first token_count cache hit'
assert_cmd "jq -e '.active.session_id == \"recovery\" and .active.read == 400' \"$(state_path pRecovery)\"" 'missing native ID watcher keeps counters attached to the resolved session'
printf '%s\n' '{"result":{"panes":[]}}' >"$panes"
FAKE_PANES="$panes" FAKE_REPORTS="$recovery_reports" FAKE_WAKE_FILE="$recovery_wakes" HERDR_BIN_PATH="$fake" HERDR_NO_TIMER='' bash -c \
  'source "$1/watch.sh"; schedule_wake() { printf "%s\n" "$1" >"$FAKE_WAKE_FILE"; }; cancel_timer() { printf "cancel\n" >"$FAKE_WAKE_FILE"; }; watch_main' _ "$ROOT"
assert_eq "$(cat "$recovery_wakes")" cancel 'closing all Codex panes cancels cold refreshes'

# Configurable symbols and expiring threshold tests
init_state
now=$(date +%s)
last_reported=""
last_deadline=""
last_pct=""
last_remaining=""
last_pct_num=""
report_pane() { last_reported="$3"; last_pct="${6:-}"; last_deadline="${10:-}"; last_remaining="${11:-}"; last_pct_num="${12:-}"; }
sig="codex|s1|m|p|1000|800|0|0|0"
codex_usage() { printf 'codex\ts1\t%s\t1000\t800\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# Active pane survives transient missing record until deadline
jq -n --arg sig "agy|agy-survive|m|p|1000|800|0|0|0" --argjson now "$now" '{active:{agent:"agy",session_id:"agy-survive",model:"m",provider:"p",signature:$sig,hit_at:($now-60),deadline:($now+240),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' >"$(state_path paneSurvive)"
update_pane paneSurvive agy agy-survive
assert_cmd '[[ "$(jq -r .active.read "$(state_path paneSurvive)")" == "800" && "$last_reported" == *"800"* ]]' 'active pane preserves token counters on transient missing record'

# Active pane survives transient zero-cache record before deadline without wiping to 0% ⇣0
agy_usage() { printf 'agy\tagy-survive\t%s\t500\t0\t0\t0\t0\tm\tp\t/fake\t0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
update_pane paneSurvive agy agy-survive
assert_cmd '[[ "$(jq -r .active.read "$(state_path paneSurvive)")" == "800" && "$last_reported" == *"800"* && "$last_reported" != *"0% ⇣0"* ]]' 'active pane survives transient zero-cache record without wiping'

# Cold transition retains last known token counters instead of dropping to 0% ⇣0
now_expired=$((now + 300))
now=$now_expired update_pane paneSurvive agy agy-survive
assert_cmd '[[ -z "$last_deadline" && "$last_reported" == *"800"* && "$last_reported" != *"0% ⇣0"* ]]' 'cold transition retains token counters instead of dropping to 0% ⇣0'
assert_eq "$last_reported" "❄ ⇣800" 'default cold cache places snowflake immediately before retained token count'
assert_eq "$last_pct" "" 'shared cold formatter clears formatted percentage'
assert_eq "$last_pct_num" "" 'shared cold formatter clears numeric percentage'
assert_eq "$last_remaining" "" 'shared cold formatter clears remaining seconds'

# Subsequent watch pass while pane remains cold still retains token count
now_subsequent=$((now_expired + 30))
now=$now_subsequent update_pane paneSurvive agy agy-survive
assert_eq "$last_reported" "❄ ⇣800" 'subsequent cold watch pass retains token count instead of reverting to bare snowflake'

# Replacement session in same pane clears old session retained tokens
unset -f agy_usage
now=$((now_subsequent + 10)) update_pane paneSurvive agy agy-new-session
assert_eq "$last_reported" "❄" 'new session without cache starts with bare cold symbol without leaking previous session tokens'
assert_cmd '[[ "$(jq -r ".last_known" "$(state_path paneSurvive)")" == "null" ]]' 'replacement session clears old last_known state'

# Percentage-enabled agents also suppress percentages while cold.
codex_usage() { printf 'codex\tsess-cold\t%s\t1000\t0\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
jq -n --argjson now "$now" '{active:{agent:"codex",session_id:"sess-cold",model:"m",provider:"p",signature:"old",hit_at:($now-60),deadline:($now-1),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' >"$(state_path paneColdCodex)"
now=$now update_pane paneColdCodex codex sess-cold
assert_eq "$last_reported" "❄ ⇣800" 'Codex cold cache suppresses percentage and keeps retained token count'
assert_eq "$last_pct" "" 'Codex cold formatter clears formatted percentage'
assert_eq "$last_pct_num" "" 'Codex cold formatter clears numeric percentage'
assert_eq "$last_remaining" "" 'Codex cold formatter clears remaining seconds'
codex_usage() { printf 'codex\ts1\t%s\t1000\t800\t0\t0\t0\tm\tp\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }

# 1. Hot state: deadline 10 minutes ahead (> 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_eq "$last_deadline" "$((now+600))" 'active pane passes deadline to report_pane'
if (( last_remaining >= 599 && last_remaining <= 600 )); then ok 'active pane passes remaining seconds to report_pane'; else not_ok 'active pane passes remaining seconds to report_pane'; fi
assert_eq "$last_pct_num" "80" 'active pane passes numeric percentage to report_pane'
assert_cmd "[[ \"$last_reported\" == '~'* && \"$last_reported\" != *'♨️'* ]]" 'hot cache displays clean clock without emoji by default'
assert_cmd "[[ \"$last_reported\" =~ ~[0-9]{2}:[0-9]{2} ]]" 'hot cache clock remains non-bold before threshold (>5m)'

# 2. Expiring state: deadline 4 minutes ahead (<= 300s)
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1560),deadline:($now+240)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'⏰'* ]]" 'expiring cache under 5m displays ⏰ by default'
assert_cmd "[[ \"$last_reported\" =~ (𝟬|𝟭|𝟮|𝟯|𝟰|𝟱|𝟲|𝟳|𝟴|𝟵) ]]" 'expiring cache clock converts to bold digits under threshold (<=5m)'

# 3. Custom config override: custom hot, expiring symbols, and custom bold threshold
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
printf '%s\n' '{"hot_symbol":"🔥","expiring_symbol":"⚡","expiring_threshold_seconds":60,"bold_threshold_seconds":60}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'🔥'* ]]" 'custom hot symbol and threshold are respected'
assert_cmd "[[ \"$last_reported\" =~ [0-9]{2}:[0-9]{2} ]]" 'clock stays non-bold when above custom bold threshold'
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:($now-1770),deadline:($now+30)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'⚡'* ]]" 'custom expiring symbol is respected'
assert_cmd "[[ \"$last_reported\" =~ (𝟬|𝟭|𝟮|𝟯|𝟰|𝟱|𝟲|𝟳|𝟴|𝟵) ]]" 'clock becomes bold when under custom bold threshold'

# 4. Arbitrary user text/emoji/empty symbols
printf '%s\n' '{"hot_symbol":"[HOT]","expiring_symbol":"","cold_symbol":"🧊"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
jq -n --arg sig "$sig" --argjson now "$now" '{active:{agent:"codex",session_id:"s1",model:"m",provider:"p",signature:$sig,hit_at:$now,deadline:($now+600)},observations:[]}' >"$(state_path paneSym)"
update_pane paneSym codex s1
assert_cmd "[[ \"$last_reported\" == *'[HOT]'* ]]" 'arbitrary text or emoji symbols are allowed'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"

# TTL ceiling guardrail tests
# 1. Observations exceeding ceiling (e.g. 44005s from multi-hour idle) are rejected
record_observation pCeil mCeil 44005 3600
assert_cmd "! jq -e 'has(\"pCeil:mCeil\")' \"$OBSERVATIONS_FILE\"" 'observations exceeding ceiling are rejected by record_observation'

# 2. Corrupted or legacy observations exceeding ceiling in observations.json are filtered by get_learned_ttl
jq '.["pCeil:mCeil"] = [44005, 3000, 3200]' "$OBSERVATIONS_FILE" >"$OBSERVATIONS_FILE.tmp" && mv "$OBSERVATIONS_FILE.tmp" "$OBSERVATIONS_FILE"
learned_clamped=$(get_learned_ttl pCeil mCeil 1800 3600)
assert_eq "$learned_clamped" 3100 'get_learned_ttl filters out legacy observations exceeding ceiling'

# 3. Session isolation: surprise hit does NOT record across different session IDs in the same pane
roll_s2="$CODEX_SESSIONS_DIR/2026/09/06/rollout-s2.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"s2"}}' '{"type":"token_usage_record","timestamp":"2026-09-06T15:00:00Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":800},"model":"mIso","model_provider":"pIso"}}' >"$roll_s2"
jq -n --arg sig "codex|s1|mIso|pIso|1000|800|0|0|0" '{active:{agent:"codex",session_id:"s1",model:"mIso",provider:"pIso",signature:$sig,hit_at:1788690000,deadline:1788691800},observations:[]}' >"$(state_path paneIso)"
update_pane paneIso codex s2
assert_cmd "! jq -e 'has(\"pIso:mIso\")' \"$OBSERVATIONS_FILE\"" 'different session ID does not record surprise hit across sessions'

# 4. Timezone override in fmt_clock
clock_epoch=1788858000 # 2026-09-08 09:00:00 UTC
HERDR_PLUGIN_TIMEZONE="UTC" assert_eq "$(HERDR_PLUGIN_TIMEZONE="UTC" fmt_clock "$clock_epoch")" "09:00" 'fmt_clock formats in UTC with HERDR_PLUGIN_TIMEZONE'
HERDR_PLUGIN_TIMEZONE="Europe/Berlin" assert_eq "$(HERDR_PLUGIN_TIMEZONE="Europe/Berlin" fmt_clock "$clock_epoch")" "11:00" 'fmt_clock formats in CEST (+2) with HERDR_PLUGIN_TIMEZONE'
printf '%s\n' '{"timezone":"UTC"}' >"$HERDR_PLUGIN_CONFIG_DIR/config.json"
assert_eq "$(fmt_clock "$clock_epoch")" "09:00" 'fmt_clock respects timezone from config.json'
assert_eq "$(to_bold_digits "09:00")" "𝟬𝟵:𝟬𝟬" 'to_bold_digits converts ascii numbers to mathematical sans-serif bold glyphs'
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.json"
# 5. Timer scheduling and cancellation
schedule_wake 100
assert_cmd "[[ -s \"$TIMER_PID_FILE\" ]]" 'schedule_wake records timer PID'
tpid=$(cat "$TIMER_PID_FILE")
assert_cmd "pid_is_live \"$tpid\"" 'scheduled timer process is running'
schedule_wake 100
replacement_tpid=$(cat "$TIMER_PID_FILE")
assert_cmd "[[ \"$tpid\" != \"$replacement_tpid\" ]] && ! pid_is_live \"$tpid\" && pid_is_live \"$replacement_tpid\"" 'rescheduling retains at most one live timer'
cancel_timer
assert_cmd "[[ ! -f \"$TIMER_PID_FILE\" ]]" 'cancel_timer removes PID file'
assert_cmd "! pid_is_live \"$replacement_tpid\"" 'cancel_timer stops the scheduled process'
# 6. Declarative view sort mode cycling and persistence
source "$ROOT/lib/view.sh"
last_rpc_method=""
last_rpc_params=""
herdr_view_rpc() { last_rpc_method="$1"; last_rpc_params="$2"; }

rm -f "$SORT_STATE_FILE"
assert_eq "$(get_sort_mode)" "native" 'default sort mode is native'
set_sort_mode "expiry"
assert_eq "$(get_sort_mode)" "expiry" 'set_sort_mode updates sort_mode.json'
assert_eq "$last_rpc_method" "agent.view.set" 'set_sort_mode expiry issues agent.view.set'
if [[ "$last_rpc_params" == *'"label": "expiry"'* ]]; then ok 'set_sort_mode expiry passes expiry label'; else not_ok 'set_sort_mode expiry passes expiry label'; fi

# Toggle tests: expiry <-> native
toggle_sort_mode >/dev/null
assert_eq "$(get_sort_mode)" "native" 'toggle from expiry yields native'
assert_eq "$last_rpc_method" "agent.view.clear" 'native mode clears agent view'

toggle_sort_mode >/dev/null
assert_eq "$(get_sort_mode)" "expiry" 'toggle from native yields expiry'
assert_eq "$last_rpc_method" "agent.view.set" 'expiry mode issues agent.view.set'
if [[ "$last_rpc_params" == *'"label": "expiry"'* ]]; then ok 'expiry mode passes expiry label'; else not_ok 'expiry mode passes expiry label'; fi

# 7. AGY statusline capture wrapper tests
cap_dir="$TMP/agy-capture-test"
export AGY_STATUSLINE_STATE_DIR="$cap_dir"
mkdir -p "$cap_dir"

# Valid payload
valid_payload='{"conversation_id":"cap-safe-1","model":{"display_name":"Gemini 3.8 Flash"},"context_window":{"current_usage":{"input_tokens":1000,"cache_read_input_tokens":400,"cache_creation_input_tokens":200}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$valid_payload" >/dev/null
assert_cmd "[[ -s \"$cap_dir/cap-safe-1.json\" ]]" 'statusline wrapper creates state for valid payload'
assert_cmd "jq -e '.input_tokens == 1000 and .cache_read_tokens == 400 and .cache_creation_tokens == 200' \"$cap_dir/cap-safe-1.json\"" 'statusline wrapper stores correct token counters'

# Command injection payload attempt
rm -f "$TMP/injected_marker"
inject_payload='{"conversation_id":"cap-inject","model":"Gemini","context_window":{"current_usage":{"input_tokens":"100; touch '"$TMP"'/injected_marker;","cache_read_input_tokens":50,"cache_creation_input_tokens":10}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$inject_payload" >/dev/null 2>&1 || true
assert_cmd "[[ ! -f \"$TMP/injected_marker\" ]]" 'statusline wrapper prevents command injection from token counters'
assert_cmd "[[ ! -e \"$cap_dir/cap-inject.json\" ]]" 'statusline wrapper rejects a non-numeric counter'
negative_payload='{"conversation_id":"cap-negative","model":"Gemini","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":-1,"cache_creation_input_tokens":2}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$negative_payload" >/dev/null 2>&1 || true
assert_cmd "[[ ! -e \"$cap_dir/cap-negative.json\" ]]" 'statusline wrapper rejects a negative counter'
fraction_payload='{"conversation_id":"cap-fraction","model":"Gemini","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":1.5,"cache_creation_input_tokens":2}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$fraction_payload" >/dev/null 2>&1 || true
assert_cmd "[[ ! -e \"$cap_dir/cap-fraction.json\" ]]" 'statusline wrapper rejects a fractional counter'

# Pass-through to real statusline
real_statusline="$TMP/fake_real_statusline.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "PASSED:%s" "$(< /dev/stdin)"' >"$real_statusline"
chmod +x "$real_statusline"
out=$(AGY_STATUSLINE_SCRIPT="$real_statusline" bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"HELLO_PAYLOAD")
assert_eq "$out" "PASSED:HELLO_PAYLOAD" 'statusline wrapper passes through to original script'

# Empty model strings survive structured parsing; an empty session creates no sidecar.
empty_model_payload='{"conversation_id":"cap-empty-model","model":"","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$empty_model_payload" >/dev/null
assert_cmd "jq -e '.session_id == \"cap-empty-model\" and .model == \"\"' \"$cap_dir/cap-empty-model.json\"" 'statusline wrapper preserves an empty model string'
before_empty_session=$(find "$cap_dir" -type f | wc -l | tr -d ' ')
empty_session_payload='{"conversation_id":"","model":"Gemini","context_window":{"current_usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0}}}'
bash "$ROOT/scripts/agy-statusline-capture.sh" <<<"$empty_session_payload" >/dev/null
after_empty_session=$(find "$cap_dir" -type f | wc -l | tr -d ' ')
assert_eq "$after_empty_session" "$before_empty_session" 'statusline wrapper preserves and rejects an empty session identity'

# Installer preserves existing statuslines, is idempotent, and fails closed.
install_dir="$TMP/agy-install-regular"
mkdir -p "$install_dir"
printf '%s\n' 'ORIGINAL_STATUSLINE' >"$install_dir/statusline.sh"
AGY_CLI_CONFIG_DIR="$install_dir" bash "$ROOT/scripts/install-agy-statusline.sh" "$ROOT" >/dev/null
assert_cmd "[[ -L \"$install_dir/statusline.sh\" ]] && grep -qx ORIGINAL_STATUSLINE \"$install_dir/statusline.real.sh\"" 'installer preserves a regular statusline as statusline.real.sh'
AGY_CLI_CONFIG_DIR="$install_dir" bash "$ROOT/scripts/install-agy-statusline.sh" "$ROOT" >/dev/null
assert_cmd "[[ -L \"$install_dir/statusline.sh\" ]] && grep -qx ORIGINAL_STATUSLINE \"$install_dir/statusline.real.sh\"" 'installer reinstall is idempotent'
if AGY_CLI_CONFIG_DIR="$TMP/relative-install" bash "$ROOT/scripts/install-agy-statusline.sh" relative/path >/dev/null 2>&1; then
  not_ok 'installer rejects a relative clone path'
else
  ok 'installer rejects a relative clone path'
fi

install_symlink_dir="$TMP/agy-install-symlink"
mkdir -p "$install_symlink_dir"
printf '%s\n' 'LINK_TARGET' >"$install_symlink_dir/original.sh"
ln -s "$install_symlink_dir/original.sh" "$install_symlink_dir/statusline.sh"
AGY_CLI_CONFIG_DIR="$install_symlink_dir" bash "$ROOT/scripts/install-agy-statusline.sh" "$ROOT" >/dev/null
preserved_target=$(readlink "$install_symlink_dir/statusline.real.sh")
assert_cmd "[[ -L \"$install_symlink_dir/statusline.real.sh\" && \"$preserved_target\" == \"$install_symlink_dir/original.sh\" ]]" 'installer preserves an existing statusline symlink'

install_backup_dir="$TMP/agy-install-backup"
mkdir -p "$install_backup_dir"
printf '%s\n' 'CURRENT' >"$install_backup_dir/statusline.sh"
printf '%s\n' 'BACKUP' >"$install_backup_dir/statusline.real.sh"
if AGY_CLI_CONFIG_DIR="$install_backup_dir" bash "$ROOT/scripts/install-agy-statusline.sh" "$ROOT" >/dev/null 2>&1; then
  not_ok 'installer refuses an existing backup'
else
  ok 'installer refuses an existing backup'
fi
assert_cmd "grep -qx CURRENT \"$install_backup_dir/statusline.sh\" && grep -qx BACKUP \"$install_backup_dir/statusline.real.sh\"" 'backup refusal leaves both files unchanged'

# 8. Stale cache regression: session A -> session B in same focused pane
init_state
now=$(date +%s)
last_reported="" last_deadline=""
report_pane() { last_reported="$3"; last_deadline="${10:-}"; }
clear_pane() { last_reported="CLEARED"; last_deadline=""; }

# Session A has hot cache state in paneRestart
sig_a="codex|sess-A|m1|p1|1000|800|0|0|0"
jq -n --arg sig "$sig_a" --argjson now "$now" \
  '{active:{agent:"codex",session_id:"sess-A",model:"m1",provider:"p1",signature:$sig,hit_at:($now-60),deadline:($now+240),input:1000,read:800,write:0,write5m:0,write1h:0},observations:[]}' \
  >"$(state_path paneRestart)"

# Session B starts — same pane, same agent, different session_id, no usage yet
codex_usage() { return 1; }
update_pane paneRestart codex sess-B
assert_cmd '[[ "$(jq -r ".active" "$(state_path paneRestart)")" == "null" ]]' \
  'stale cache: session A state cleared when session B has no usage'

# Session B produces its first usage
codex_usage() { printf 'codex\tsess-B\t%s\t500\t300\t0\t0\t0\tm2\tp2\t/same\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
update_pane paneRestart codex sess-B
assert_cmd '[[ "$(jq -r ".active.session_id" "$(state_path paneRestart)")" == "sess-B" ]]' \
  'stale cache: session B metrics appear after first usage'
assert_cmd '[[ "$(jq -r ".active.read" "$(state_path paneRestart)")" == "300" ]]' \
  'stale cache: session B counters are correct'
unset -f codex_usage

# 9. Complete same-pane restart through watch_main. Timer lifecycle is tested
# above in-process so child reaping is deterministic on both Linux and macOS.
restart_reports="$TMP/restart-reports"
restart_panes="$TMP/restart-panes.json"
restart_a="$CODEX_SESSIONS_DIR/2026/09/06/rollout-restart-A.jsonl"
restart_b="$CODEX_SESSIONS_DIR/2026/09/06/rollout-restart-B.jsonl"
restart_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' '{"type":"session_meta","payload":{"id":"restart-A","cwd":"/same"}}' "{\"type\":\"token_usage_record\",\"timestamp\":\"$restart_ts\",\"payload\":{\"usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800},\"model\":\"model-A\",\"model_provider\":\"provider-A\"}}" >"$restart_a"
rm -f "$ROLLOUT_INDEX"
printf '%s\n' '{"result":{"panes":[{"pane_id":"paneRestartWatch","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"restart-A"}}]}}' >"$restart_panes"
FAKE_PANES="$restart_panes" FAKE_REPORTS="$restart_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"

printf '%s\n' '{"result":{"panes":[{"pane_id":"paneRestartWatch","agent":"codex","cwd":"/same","agent_session":null}]}}' >"$restart_panes"
FAKE_PANES="$restart_panes" FAKE_REPORTS="$restart_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "jq -e '.active == null' \"$(state_path paneRestartWatch)\"" 'watch_main clears session A state when identity disappears'

printf '%s\n' '{"result":{"panes":[{"pane_id":"paneRestartWatch","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"restart-B"}}]}}' >"$restart_panes"
FAKE_PANES="$restart_panes" FAKE_REPORTS="$restart_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "jq -e '.active == null' \"$(state_path paneRestartWatch)\"" 'watch_main keeps replacement session cold before its first record'

printf '%s\n' '{"type":"session_meta","payload":{"id":"restart-B","cwd":"/same"}}' "{\"type\":\"token_usage_record\",\"timestamp\":\"$restart_ts\",\"payload\":{\"usage\":{\"input_tokens\":500,\"cached_input_tokens\":300},\"model\":\"model-B\",\"model_provider\":\"provider-B\"}}" >"$restart_b"
rm -f "$ROLLOUT_INDEX"
FAKE_PANES="$restart_panes" FAKE_REPORTS="$restart_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "jq -e '.active.session_id == \"restart-B\" and .active.read == 300 and .active.model == \"model-B\"' \"$(state_path paneRestartWatch)\"" 'watch_main displays only session B data after its first record'
assert_eq "$(next_wake_delay 1 '')" "15" 'active cache rescan delay is capped at 15 seconds'
assert_eq "$(next_wake_delay 1 5)" "5" 'expiration transition preempts the 15-second rescan interval'
assert_eq "$(next_wake_delay 0 5 || true)" "" 'cold caches request no wake delay'
printf '%s\n' '{"result":{"panes":[{"pane_id":"paneRestartWatch","agent":"codex","cwd":"/same","agent_session":null}]}}' >"$restart_panes"
FAKE_PANES="$restart_panes" FAKE_REPORTS="$restart_reports" HERDR_BIN_PATH="$fake" bash "$ROOT/watch.sh"
assert_cmd "jq -e '.active == null' \"$(state_path paneRestartWatch)\"" 'watch_main leaves the pane cold after session B disappears'

# 10. Download helper validation and replacement tests.
dummy_bin_dir="$TMP/dummy_bin"
download_dir="$TMP/downloads"
fake_tools="$TMP/fake-download-tools"
mkdir -p "$dummy_bin_dir" "$download_dir" "$fake_tools"
dl_name="agy-usage-darwin-arm64"
dummy_file="$dummy_bin_dir/$dl_name"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 1 ;; esac' >"$fake_tools/uname"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'url=""; out=""; while [[ $# -gt 0 ]]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done; src="$FAKE_DOWNLOADS/${url##*/}"; [[ -f "$src" ]] || exit 22; cp "$src" "$out"' >"$fake_tools/curl"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == -b ]] || exit 1; printf "%s\n" "$FAKE_FILE_TYPE"' >"$fake_tools/file"
chmod +x "$fake_tools/uname" "$fake_tools/curl" "$fake_tools/file"

run_download_failure() {
  local label=$1
  printf '%s\n' 'EXISTING_HELPER' >"$dummy_file"
  if PATH="$fake_tools:$PATH" FAKE_DOWNLOADS="$download_dir" FAKE_FILE_TYPE="$FAKE_FILE_TYPE" HERDR_CACHE_BIN_DIR="$dummy_bin_dir" HERDR_CACHE_HELPER_VERSION="0.1.0" bash "$ROOT/scripts/download-helpers.sh" >/dev/null 2>&1; then
    not_ok "$label"
  else
    ok "$label"
  fi
  assert_eq "$(<"$dummy_file")" "EXISTING_HELPER" "$label preserves the old helper"
  assert_cmd "! find \"$dummy_bin_dir\" -maxdepth 1 -name '.*.tmp.*' -o -name '.checksums.tmp.*' | grep -q ." "$label cleans temporary downloads"
}

printf '%s\n' 'NEW_HELPER' >"$download_dir/$dl_name"
FAKE_FILE_TYPE='Mach-O 64-bit executable arm64'
rm -f "$download_dir/checksums.txt"
run_download_failure 'missing checksums fail closed'
printf '%s\n' "bad $dl_name" >"$download_dir/checksums.txt"
run_download_failure 'malformed checksum entry fails closed'
good_sum=$(shasum -a 256 "$download_dir/$dl_name" | awk '{print $1}')
printf '%s  %s\n%s  %s\n' "$good_sum" "$dl_name" "$good_sum" "$dl_name" >"$download_dir/checksums.txt"
run_download_failure 'duplicate checksum entries fail closed'
printf '%064d  %s\n' 0 "$dl_name" >"$download_dir/checksums.txt"
run_download_failure 'checksum mismatch fails closed'
printf '%s  %s\n' "$good_sum" "$dl_name" >"$download_dir/checksums.txt"
FAKE_FILE_TYPE='HTML document, ASCII text'
run_download_failure 'wrong executable format fails closed'
FAKE_FILE_TYPE='Mach-O 64-bit executable x86_64'
run_download_failure 'wrong executable architecture fails closed'

FAKE_FILE_TYPE='Mach-O 64-bit executable arm64'
printf '%s\n' 'EXISTING_HELPER' >"$dummy_file"
if PATH="$fake_tools:$PATH" FAKE_DOWNLOADS="$download_dir" FAKE_FILE_TYPE="$FAKE_FILE_TYPE" HERDR_CACHE_BIN_DIR="$dummy_bin_dir" HERDR_CACHE_HELPER_VERSION="0.1.0" bash "$ROOT/scripts/download-helpers.sh" >/dev/null 2>&1; then
  ok 'verified helper replaces the old binary'
else
  not_ok 'verified helper replaces the old binary'
fi
assert_eq "$(<"$dummy_file")" "NEW_HELPER" 'successful verified replacement installs downloaded helper'
assert_cmd "[[ -x \"$dummy_file\" ]]" 'successful verified replacement is executable'
assert_cmd "! find \"$dummy_bin_dir\" -maxdepth 1 -name '.*.tmp.*' -o -name '.checksums.tmp.*' | grep -q ." 'successful replacement cleans temporary downloads'

# 11. Auto-adaptive display-agent and mobile layout detection
da_reports="$TMP/display-agent-reports"
da_config_dir="$TMP/da-config"
mkdir -p "$da_config_dir"

# Default auto mode on desktop (width > 64) clears display agent
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=120 bash -c \
  'source "$1/lib/core.sh"; report_pane pDesktop codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pDesktop.*--clear-display-agent' \"$da_reports\"" 'auto mode on desktop clears display-agent'
assert_cmd "! grep -q 'pDesktop.*--display-agent' \"$da_reports\"" 'auto mode on desktop does not inject display-agent'

# Default auto mode on mobile width (<= 64) injects display agent
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=50 bash -c \
  'source "$1/lib/core.sh"; report_pane pMobile codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pMobile.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'auto mode on mobile width injects display-agent'

# Termux environment injects display agent regardless of width
rm -f "$da_reports"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_CURRENT_WIDTH=120 TERMUX_VERSION="0.118.0" bash -c \
  'source "$1/lib/core.sh"; report_pane pTermux codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pTermux.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'auto mode under Termux injects display-agent'

# Config override: display_agent = "never" forces clear on mobile
rm -f "$da_reports"
printf '{"display_agent":"never"}\n' >"$da_config_dir/config.json"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$da_config_dir" HERDR_CURRENT_WIDTH=50 bash -c \
  'source "$1/lib/core.sh"; report_pane pNever codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pNever.*--clear-display-agent' \"$da_reports\"" 'display_agent=never suppresses display-agent on mobile'

# Config override: display_agent = "always" forces injection on desktop
rm -f "$da_reports"
printf '{"display_agent":"always"}\n' >"$da_config_dir/config.json"
FAKE_REPORTS="$da_reports" HERDR_BIN_PATH="$fake" HERDR_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$da_config_dir" HERDR_CURRENT_WIDTH=120 bash -c \
  'source "$1/lib/core.sh"; report_pane pAlways codex "❄ ⇣500" 15000' _ "$ROOT"
assert_cmd "grep -q 'pAlways.*--display-agent codex \[❄ ⇣500\]' \"$da_reports\"" 'display_agent=always injects display-agent on desktop'

# Snapshot layout area width detection via watch.sh
fake_snapshot="$TMP/fake-herdr-snapshot"
snapshot_panes="$TMP/snapshot-panes.json"
snapshot_reports="$TMP/snapshot-reports"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$1 $2" == "api snapshot" ]]; then cat "$FAKE_SNAPSHOT"; elif [[ "$1 $2" == "pane list" ]]; then cat "$FAKE_PANES"; else printf "%s\n" "$*" >>"$FAKE_REPORTS"; fi' >"$fake_snapshot"; chmod +x "$fake_snapshot"

# Wide layout snapshot clears display-agent
printf '{"result":{"snapshot":{"panes":[{"pane_id":"pSnapWide","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"sWide"}}],"layouts":[{"area":{"width":120,"height":40}}]}}}\n' >"$snapshot_panes"
printf '{"type":"session_meta","payload":{"id":"sWide","cwd":"/same"}}' >"$CODEX_SESSIONS_DIR/2026/09/06/rollout-sWide.jsonl"
rm -f "$snapshot_reports" "$ROLLOUT_INDEX"
FAKE_SNAPSHOT="$snapshot_panes" FAKE_REPORTS="$snapshot_reports" HERDR_BIN_PATH="$fake_snapshot" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'pSnapWide.*--clear-display-agent' \"$snapshot_reports\"" 'watch.sh detects wide snapshot layout and clears display-agent'

# Narrow layout snapshot injects display-agent
printf '{"result":{"snapshot":{"panes":[{"pane_id":"pSnapNarrow","agent":"codex","cwd":"/same","agent_session":{"kind":"id","value":"sNarrow"}}],"layouts":[{"area":{"width":50,"height":40}}]}}}\n' >"$snapshot_panes"
ts_narrow=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n%s\n' '{"type":"session_meta","payload":{"id":"sNarrow","cwd":"/same"}}' "{\"type\":\"token_usage_record\",\"timestamp\":\"$ts_narrow\",\"payload\":{\"usage\":{\"input_tokens\":1000,\"cached_input_tokens\":500},\"model\":\"m\",\"model_provider\":\"p\"}}" >"$CODEX_SESSIONS_DIR/2026/09/06/rollout-sNarrow.jsonl"
rm -f "$snapshot_reports" "$ROLLOUT_INDEX"
FAKE_SNAPSHOT="$snapshot_panes" FAKE_REPORTS="$snapshot_reports" HERDR_BIN_PATH="$fake_snapshot" WATCH_ONCE=1 bash "$ROOT/watch.sh"
assert_cmd "grep -q 'pSnapNarrow.*--display-agent codex' \"$snapshot_reports\"" 'watch.sh detects narrow snapshot layout and injects display-agent'

# Trailing rerun flag on lock contention
rerun_lock_dir="$STATE_DIR/watcher.lock"
rm -rf "$rerun_lock_dir"
mkdir -p "$rerun_lock_dir"
printf '%s\n' "$$" >"$rerun_lock_dir/pid"
assert_cmd "! acquire_lock" 'acquire_lock returns 1 when lock is held by live process'
assert_cmd "[[ -f \"$rerun_lock_dir/rerun\" ]]" 'contended acquire_lock touches rerun flag'
rm -rf "$rerun_lock_dir"

exit "$fail"
