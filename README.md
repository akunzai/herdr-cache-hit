# Herdr Agent Cache Hit & Expiration Plugin (`cache-hit`)

[![CI](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml/badge.svg)](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Website and live showcase](https://www.ekotov.pro/herdr-cache-hit/)

A high-efficiency plugin for [Herdr](https://github.com/herdrdev/herdr) that provides real-time prompt-cache HUD metrics, dynamic expiration countdowns, and declarative cache-deadline agent sorting.

Supports **Codex CLI**, **AGY** ([Antigravity CLI](docs/AGY_INTEGRATION.md)), **Claude Code**, and **OpenCode**.

[![Herdr terminal sidebar showing alarm, active, and cold prompt-cache states sorted by expiry](https://www.ekotov.pro/herdr-cache-hit/assets/herdr-expiry-agents.webp)](https://www.ekotov.pro/herdr-cache-hit/)

---

## Features

- **Live Prompt-Cache HUD**: Real-time cache hit ratios, read/cached token metrics, and estimated expiration countdowns directly in Herdr's sidebar.
- **Urgency Transitions**: Automatic visual transitions from healthy state (`~15:44`) to urgent alarm warning (`⏰~𝟭𝟱:𝟰𝟰`) using mathematical Unicode bold digits when nearing expiration (configurable threshold, default ≤5m).
- **Declarative Agent Sorting**: Sort active agent panes by prompt-cache expiration deadline (`cache_deadline asc`), keeping expiring agents at the top. Toggle effortlessly with a single keybinding (`prefix+s`).
- **Bounded Rescans**: Event hooks update immediately. While any cache is active or an enabled Codex pane is present, one lightweight wake timer rescans every 15 seconds (or sooner for an expiration transition). Codex's first cache hit can appear even when the pane started with no cache or native session ID.
- **Experimental Cache Warmer**: An opt-in warmer can submit a short ordinary turn when a Codex, AGY, or Claude pane is idle, unfocused, and showing an empty prompt. It is disabled by default and continues while opted in; a finite per-session cap is configurable. AGY warming also waits for delegated background tasks to finish and sends at most once per unchanged cache window.
- **Warmer Toggle**: Warming is off by default; opt in per Codex, AGY, or Claude session with Herdr's `prefix+u`. The command palette distinguishes **Toggle per-agent cache warming** from **Switch between global and per-agent warming**. Global mode ON includes all supported sessions; switching it OFF returns to saved individual settings and does not turn those settings off. There is no default global-warming shortcut; users can add one in Herdr config if desired. The session palette action refuses if multiple identified sessions make its target ambiguous. A configurable `↻` before the countdown marks an armed session.
- **Privacy-First**: Cache telemetry is read locally. When the experimental warmer is enabled, its short prompt is submitted like a normal user turn and is stored in that agent session.

---

## Prerequisites & Compatibility

- **Operating Systems**: **macOS** and **Linux** (native). On **Windows**, use **WSL2** (Windows Subsystem for Linux). Native Windows (PowerShell / Command Prompt) is not supported as Herdr and its plugin hooks run in a POSIX shell environment.
- **Dependencies**:
  - `jq` (**Required**): Core JSON parser for state and token metadata (`brew install jq` or `sudo apt install jq`).
  - `bash` (**Required**): Standard on Linux (4.0+) and macOS (native bash 3.2 works; Homebrew bash 4.0+ is also supported).
  - `python3` 3.6+ (**Optional**): Needed for **OpenCode**, view sorting, and Codex session recovery when Herdr has no native session ID. Codex panes with a native session ID and Claude Code need only Bash and jq.
  - `Go` 1.24+ (**Optional**): Only needed if building the AGY SQLite helper from source instead of downloading the precompiled release binary.

---

## Quick Start

### 1. Install Plugin

Install directly with Herdr:

```bash
herdr plugin install e-kotov/herdr-cache-hit
```

Herdr will automatically clone the repository and run the build step to download and checksum-verify the precompiled helper binary for your platform.

<details>
<summary>Manual / Development Install</summary>

```bash
git clone https://github.com/e-kotov/herdr-cache-hit.git
cd herdr-cache-hit

# Download precompiled helper binary (or compile locally with ./scripts/build-agy-usage.sh)
./scripts/download-helpers.sh

# Link to Herdr
herdr plugin unlink cache-hit 2>/dev/null || true
herdr plugin link .
herdr plugin list
```

</details>

### 2. Configure Herdr Sidebar

Add dynamic styling rules to `~/.config/herdr/config.toml` so Herdr colors expiring caches in bold warning tones:

```toml
[ui.sidebar.agents]
rows = [
  [{ token = "state_icon", bold = true, dim = false }, { token = "agent", fg = "#241835", bold = true, dim = false }],
  [
    { token = "$cache", fg = "#64748b", bold = false, dim = true, rules = [
      { starts_with = "⏰", bold = true, dim = false, fg = "#7f1d1d" },
      { starts_with = "⚠️", bold = true, dim = false, fg = "#b45309" },
      { starts_with = "↻~", bold = false, dim = false, fg = "#713f78" },
      { starts_with = "~", bold = false, dim = false, fg = "#713f78" },
      { starts_with = "♨️", bold = false, dim = false, fg = "#713f78" }
    ] }
  ],
  [{ token = "workspace", fg = "#4c4669", bold = false, dim = false }, { token = "tab", fg = "#4c4669", bold = false, dim = false }]
]
```

If you customize `cache_warmer_symbol`, add a matching `starts_with` rule before
the generic `~` rule to preserve the active-cache color.

### 3. Add 2-Way Expiration Sorting Keybinding

Enable toggling between expiration sorting and native sorting via `prefix+s` in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "s"
command = ["bash", "-c", "herdr-cache-view toggle"]

[keys]
settings = "S" # Remap settings to prefix+S (shift+s)
```

Reload Herdr configuration:
```bash
herdr server reload-config
```

---

## Token Reference

The plugin emits the following pane tokens:

- **`$cache`**: Unified token string without middle dots (e.g. `~11:41 99% ⇣95.4k` when healthy, `⏰~𝟭𝟭:𝟰𝟭 99% ⇣95.4k` when expiring, or `❄ ⇣95.4k` when cold). Percentages are omitted after expiration because they describe the last request rather than the usable cache.
- **`$cache_status`**: Expiration clock with optional symbol prefix (e.g. `~11:41` or `⏰~𝟭𝟭:𝟰𝟭`).
- **`$cache_pct`**: Cache hit percentage (`99%`).
- **`$cache_pct_num`**: Raw integer hit percentage for native numeric rules (`99`; cleared when cold).
- **`$cache_remaining_secs`**: Seconds until estimated expiration (`240`; cleared when cold).
- **`$cache_tokens`**: Read and write token counters (`⇣95.4k`).
- **`$cache_state`**: State identifier (`hot`, `expiring`, or `cold`).
- **`cache_deadline`**: Epoch timestamp used for declarative sorting.

---

## Configuration & Documentation

For detailed information on configuring symbols, thresholds, timezones, per-agent overrides, custom declarative views, and troubleshooting, see the **[User Guide & Configuration Manual](USERGUIDE.md)**.

A ready-to-use template is available in [`config.example.json`](config.example.json).

---

## Verification & Testing

Run the test suite and static analysis:

```bash
bash -n watch.sh
shellcheck watch.sh lib/*.sh bin/herdr-cache-view scripts/*.sh
bash tests/test_watch.sh
go test -v ./cmd/agy-usage
```

---

## License

[MIT](LICENSE) © 2026 Egor Kotov
