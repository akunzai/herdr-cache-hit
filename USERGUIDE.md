# User Guide & Configuration Manual

This guide covers full configuration, token customization, sidebar styling, and declarative view sorting for the **cache-hit** Herdr plugin.

---

## Table of Contents

1. [Architecture & How It Works](#architecture--how-it-works)
2. [Configuration Reference](#configuration-reference)
3. [Token Reference](#token-reference)
4. [Sidebar Styling & Color Rules](#sidebar-styling--color-rules)
5. [Agent Sorting & Keybindings](#agent-sorting--keybindings)
6. [Agent Adapters & Data Sources](#agent-adapters--data-sources)
7. [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)

---

## Architecture & How It Works

`cache-hit` is an event-driven metadata scanner for [Herdr](https://github.com/herdrdev/herdr).
- **No Background Daemon**: Herdr events start `watch.sh`; no persistent scanner process is required.
- **Single Refresh Timer**: While at least one cache is active or an enabled Codex pane is present, one lightweight sleep process wakes at the earlier of 15 seconds or the next expiration display transition. Cold Codex panes continue refreshing so their first cache hit is detected. With no active caches and no enabled Codex panes, no periodic scan is scheduled.
- **Privacy**: Content is processed locally only as necessary to extract usage metadata and is not intentionally extracted, retained, logged, or transmitted. Only token usage counters, session identifiers, model names, and provider identifiers are tracked.

---

## Configuration Reference

Configuration is stored in `config.json` inside the plugin's configuration directory:

```bash
herdr plugin config-dir cache-hit
```

If `config.json` does not exist, safe built-in defaults are used. Changes to `config.json` take effect on the very next Herdr scan without needing a server restart.

### Global Settings

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `hot_symbol` | string | `""` | Symbol or emoji prepended to the countdown clock when the cache is active and healthy (> `expiring_threshold_seconds`). E.g. `"♨️"` or `""`. |
| `expiring_symbol` | string | `"⏰"` | Symbol or emoji prepended when remaining cache lifetime is less than or equal to `expiring_threshold_seconds`. E.g. `"⏰"` or `"⚠️"`. |
| `cold_symbol` | string | `"❄"` | Symbol shown immediately before retained token counts when the cache has expired. Set `""` to hide it. |
| `cache_warmer_symbol` | string | `"↻"` | Symbol placed immediately before the countdown for an armed Codex, AGY, or Claude session. Set `""` to hide the indicator. |
| `expiring_threshold_seconds`| integer | `300` | Warning threshold in seconds (default 5 minutes). At or below this, the warning symbol appears. |
| `bold_time` | boolean | `true` | When `true`, converts countdown clock digits into Unicode mathematical sans-serif bold characters (`𝟬-𝟵`) for visual punch. |
| `bold_threshold_seconds` | integer | `300` | Countdown threshold in seconds under which clock digits turn bold. Keeps healthy caches sleek and non-bold, turning bold only when expiring. |
| `timezone` | string | `""` | IANA timezone name (e.g. `"Europe/Berlin"`, `"America/New_York"`). When empty, respects `HERDR_PLUGIN_TIMEZONE` or the local system timezone. |
| `display_agent` | string | `"auto"` | Controls injection of cache stats into Herdr's `--display-agent` metadata (`"auto"`, `"always"`, or `"never"`). In `"auto"` mode, stats are injected only when terminal width $\le$ `mobile_width_threshold` or under Termux, keeping desktop multi-row sidebars clean and free of duplicate badges. |
| `mobile_width_threshold` | integer | `64` | Terminal column width at or below which Herdr collapses into single-line mobile layout. |

### Per-Agent Settings

Supported agent keys: `agy` (Antigravity CLI), `claude` (Claude Code), `codex` (Codex CLI), `opencode` (OpenCode).

```json
{
  "codex": {
    "enabled": true,
    "cache_warmer_sessions": [],
    "cache_warmer_margin_seconds": 300,
    "cache_warmer_max_per_session": 0,
    "show_deadline": true,
    "show_read_tokens": true,
    "show_write_tokens": false,
    "show_percentage": true,
    "show_model": false,
    "ttl_ceiling": 3600
  },
  "agy": {
    "enabled": true,
    "cache_warmer_sessions": [],
    "cache_warmer_margin_seconds": 60,
    "cache_warmer_max_per_session": 0,
    "show_deadline": true,
    "show_read_tokens": true,
    "show_write_tokens": false,
    "show_percentage": false,
    "show_model": false,
    "ttl_ceiling": 3600
  },
  "claude": {
    "enabled": true,
    "cache_warmer_sessions": [],
    "cache_warmer_margin_seconds": 60,
    "cache_warmer_max_per_session": 0,
    "show_deadline": true,
    "show_read_tokens": true,
    "show_write_tokens": false,
    "show_percentage": false,
    "show_model": false,
    "ttl_ceiling": 3600
  }
}
```

| Field | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | boolean | `true` | Enable cache tracking for this agent. Set `false` to clear this agent's cache token. |
| `cache_warmer_sessions` | array of session IDs | `[]` | Codex, AGY, and Claude. Sessions explicitly armed with `prefix+u`; each eligible session may receive a short normal turn near the current countdown deadline. The experimental turn is appended to the conversation. |
| `cache_warmer_global_enabled` | boolean | `false` | When true, all Codex, AGY, and Claude sessions are armed, including sessions opened later. The command palette item “Switch between global and per-agent warming” toggles this mode; turning it off returns to saved per-session settings and does not turn those settings off. No global shortcut is bound by default. |
| `cache_warmer_global_excluded_sessions` | object of agent to session ID arrays | `{}` | Per-session exclusions while global mode is on. `prefix+u` toggles the focused session in or out of the global set. |
| `cache_warmer_margin_seconds` | integer | Codex `300`, AGY and Claude `60` | Attempt a warm turn when the displayed cache countdown reaches this many seconds; accepted range is 30–600 seconds. Claude warming requires cache lifetime evidence from a 5-minute or 1-hour cache write. |
| `cache_warmer_max_per_session` | integer | `0` | Codex, AGY, and Claude. `0` allows indefinite warming while the session is opted in; set 1–3 to cap warm-turn attempts per session. |
| `show_deadline` | boolean | `true` | Include the estimated expiration countdown time (`~15:44`). |
| `show_read_tokens` | boolean | `true` | Include read/cached tokens counter (e.g. `⇣95.4k`). |
| `show_write_tokens`| boolean | `false` | Include cache-creation tokens counter (e.g. `⇡12.3k`). |
| `show_percentage` | boolean | Agent-dependent | Show cache hit percentage (`99%`). Defaults `true` for Codex/OpenCode, `false` for AGY/Claude. |
| `show_model` | boolean | `false` | Include model name in the token string. |
| `ttl_ceiling` | integer | `3600` | Hard upper bound in seconds on learned prompt-cache survival time. |

For Codex, the countdown starts from a 30-minute baseline, matching OpenAI's
current documented default. The plugin shortens that estimate only after at
least three recorded survival observations below 30 minutes for the same provider
and model. Longer observations do not extend the Codex countdown. The countdown
is still an estimate: cache misses can also result from a changed prompt prefix
or routing, so it is not a guarantee of cache eviction time.

The experimental warmer is off by default. When enabled, it sends a normal
user turn through Herdr; this adds a short prompt and response to the agent
conversation and incurs that agent's normal usage. Before submission it
rechecks the session, requires an idle or done status and an unfocused pane, and
checks that the prompt is visibly empty (`Ask Codex to do anything` for Codex;
a standalone `>` prompt for AGY; an empty `❯` prompt for Claude). Claude cache
warming follows the lifetime indicated by recorded 5-minute or 1-hour cache
writes and uses a 60-second default margin. Working parents, including parents waiting on
subagents, are skipped. Warmed intervals are excluded from survival observations.
The status and empty-prompt checks are best effort and cannot make PTY submission
atomic with a user switching focus or typing, so start with a disposable session.

With the configured prefix (`Ctrl+B`), toggle warming for the focused Codex, AGY, or Claude
session with `u`.
Toggle global warming for all supported warmer sessions, including sessions opened later,
with `Shift+U`. While global mode is on, `u` excludes or restores only the focused
session. Turning global mode off restores the saved per-session settings. The active cache display gains the
configured `cache_warmer_symbol` (default `↻`) immediately before the countdown
when that session is armed. A warm turn is sent only if the pane is idle, unfocused,
and its prompt editor is empty when the estimated deadline nears. Each toggle
also shows a quiet Herdr notification describing the resulting setting.

---

## Token Reference

The plugin emits the following pane tokens to Herdr:

| Token | Description | Example Output |
| :--- | :--- | :--- |
| **`$cache`** | **Unified string** combining status, countdown, percentage, and token counts without middle-dot separators. Cold output omits the last-request percentage. | Hot: `~15:44 99% ⇣95.4k`<br>Expiring: `⏰~𝟭𝟱:𝟰𝟰 99% ⇣95.4k`<br>Cold: `❄ ⇣95.4k` |
| **`$cache_status`** | Status symbol and countdown clock. | `~15:44`, `⏰~𝟭𝟱:𝟰𝟰`, or `❄` when cold |
| **`$cache_pct`** | Formatted cache hit percentage; cleared when cold. | `99%` |
| **`$cache_pct_num`** | Raw integer hit percentage for numeric comparisons; cleared when cold. | `99` |
| **`$cache_remaining_secs`** | Seconds remaining until expiration; cleared when cold. | `240` |
| **`$cache_tokens`** | Just the read/write token counters. | `⇣95.4k` |
| **`$cache_state`** | Lifecycle state identifier. | `hot`, `expiring`, or `cold` |
| **`cache_deadline`**| Unix epoch integer timestamp of expiration. | `1788877732` (cleared when cold) |

---

## Sidebar Styling & Color Rules

Herdr's sidebar configuration (`~/.config/herdr/config.toml`) controls how tokens are rendered. Using conditional `rules` on `$cache` allows dynamic color transitions:

```toml
[ui.sidebar.agents]
rows = [
  [
    { token = "state_icon", bold = true, dim = false },
    { token = "agent", fg = "#241835", bold = true, dim = false }
  ],
  [
    { token = "$cache", fg = "#64748b", bold = false, dim = true, rules = [
      { starts_with = "⏰", bold = true, dim = false, fg = "#7f1d1d" }, # Urgent red
      { starts_with = "⚠️", bold = true, dim = false, fg = "#b45309" }, # Warning amber
      { starts_with = "↻~", bold = false, dim = false, fg = "#713f78" }, # Armed active cache
      { starts_with = "~", bold = false, dim = false, fg = "#713f78" },  # Active magenta
      { starts_with = "♨️", bold = false, dim = false, fg = "#713f78" }  # Active hot
    ] }
  ],
  [
    { token = "workspace", fg = "#4c4669", bold = false, dim = false },
    { token = "tab", fg = "#4c4669", bold = false, dim = false }
  ]
]
```

---

## Agent Sorting & Keybindings

The plugin includes `bin/herdr-cache-view`, a declarative view manager that interfaces with Herdr's JSON-RPC socket API (`agent.view.set` and `agent.view.clear`).

### View Modes
1. **`expiry`**: Sorts active sessions with live prompt caches by earliest expiration deadline first (`cache_deadline asc`), keeping expiring sessions at the top. Cold sessions fall back cleanly to Herdr priority mode (`attention desc`, `state_change_seq desc`).
2. **`native`**: Herdr's default interactive sort mode.

### CLI Usage

```bash
# Toggle between expiry sorting and native sorting
herdr-cache-view toggle

# Explicitly set view
herdr-cache-view set expiry
herdr-cache-view set native

# Check current active mode
herdr-cache-view get

# Restore saved mode (run on startup)
herdr-cache-view restore
```

### Herdr Keybinding Integration

Add a keybinding in `~/.config/herdr/config.toml` to toggle cache sorting with `prefix+s`:

```toml
[[keys.command]]
key = "s"
command = ["bash", "-c", "herdr-cache-view toggle"]

# Remap Herdr settings to prefix+S (shift+s)
[keys]
settings = "S"
```

The active mode is saved in `sort_mode.json` and automatically restored whenever Herdr boots via the plugin's `[[startup]]` hook.

---

## Agent Adapters & Data Sources

| Agent | Extraction Method | Required Helper / Dependencies |
| :--- | :--- | :--- |
| **Codex CLI** | Rollout inspection from `${CODEX_HOME:-~/.codex}/sessions` | `bash` + `jq`; `python3` 3.6+ for missing-session recovery |
| **Claude Code** | Project transcript analysis (`~/.claude/projects/`) | None (pure `bash` + `jq`) |
| **OpenCode** | SQLite database (`~/.local/share/opencode/opencode.db`) | `python3` |
| **AGY / Antigravity CLI** | Multi-tier fallback (Statusline → Go helper → Transcript) | Optional Go helper (`agy-usage-*`) or statusline hook |

### Codex Session Recovery

The adapter supports both `token_usage_record.payload.usage` and
`event_msg.payload.info.last_token_usage` (`token_count`). It uses per-request
cache counts, ignores quota-only events, and reads model/provider metadata from
the preceding turn context and session metadata. `CODEX_SESSIONS_DIR` takes
precedence over `HODEX_SESSIONS_DIR`, then `CODEX_HOME`.

When Herdr has no native Codex session ID, the optional Python helper inspects
`pane process-info`. An explicit `codex resume <id>` selects that session.
Otherwise, a unique root rollout matching the process launch time and exact
directory is selected. When several roots are active, cumulative input/output
counters in the pane's terminal title can identify a unique matching rollout.
These totals are used only for session identification, never for the cache-hit
percentage. Interactive resume can fall back to a unique root with usage since
process launch in that directory only when no other Codex pane shares it; an
empty bootstrap thread is excluded when a resumed thread has real usage. Subagents and sessions
already assigned to other panes are excluded. Ambiguous matches leave the cache
blank rather than display another session's counters. This publishes only cache
metadata; it does not change Herdr's native session identity.

The fallback was informed by [herdr-agent-usage](https://github.com/senna-lang/herdr-agent-usage)'s
Codex adapter, with additional guards for same-directory panes and subagents.

### AGY / Antigravity CLI Architecture

Because AGY CLI transcripts do not serialize token metrics to disk, the plugin uses a 3-tier fallback strategy:
1. **Tier 1 — Live Statusline Sidecar (Fastest)**: The supplied `scripts/agy-statusline-capture.sh` wrapper writes real-time prompt cache stats to `~/.cache/herdr-cache-plugin/agy-statusline/<sid>.json` without SQLite parsing.
2. **Tier 2 — Go SQLite Helper (`agy-usage-*`)**: If the statusline sidecar is absent, the plugin invokes the compiled helper to extract token metrics directly from AGY's internal SQLite database (`~/.gemini/antigravity-cli/conversations/<sid>.db`). Precompiled binaries are provided for macOS and Linux.
3. **Tier 3 — Transcript Fallback**: If neither is available, it attempts to read `transcript.jsonl` (used by AGY Web IDE).

> [!NOTE]
> **If you don't use AGY CLI:**
> You do **not** need the Go helper or any statusline scripts. Codex, Claude Code, and OpenCode work completely out of the box with standard system tools (`bash`, `jq`, and optionally `python3`).

For installation instructions for the tested wrapper, see the **[Antigravity CLI (AGY) Integration Guide](docs/AGY_INTEGRATION.md)**.

---

## Troubleshooting & Diagnostics

### Inspect Live Tokens
Run `herdr pane list` to view the tokens currently assigned to each pane:
```bash
herdr pane list | jq '.result.panes[] | {agent, tokens}'
```

### Inspect Observations
Survival observations are stored in:
```bash
cat "${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/cache-hit/observations.json"
```

### Verify Scripts & Tests
```bash
bash -n watch.sh
shellcheck watch.sh lib/*.sh bin/herdr-cache-view scripts/*.sh
bash tests/test_watch.sh
```
