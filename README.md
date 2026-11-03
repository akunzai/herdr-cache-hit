# Herdr Agent Cache Hit & Expiration Plugin (`cache-hit`)

[![CI](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml/badge.svg)](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml)
[![Total release downloads](https://img.shields.io/github/downloads/e-kotov/herdr-cache-hit/total?label=release%20downloads)](https://github.com/e-kotov/herdr-cache-hit/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Website and live showcase](https://www.ekotov.pro/herdr-cache-hit/)

[Documentation](https://www.ekotov.pro/herdr-cache-hit/documentation.html)

[Changelog](https://www.ekotov.pro/herdr-cache-hit/changelog.html)

A high-efficiency plugin for [Herdr](https://github.com/herdrdev/herdr) that provides real-time prompt-cache HUD metrics, dynamic expiration countdowns, and declarative cache-deadline agent sorting.

The same project also includes an experimental, display-only mod for [Herdr App](https://github.com/herdrdev/herdr-app) ([website](https://herdr.dev/)). Both use one shared scanner; the desktop mod has its own installation and configuration, and does not warm caches or control agent sorting.

Supports **Codex CLI**, **AGY** ([Antigravity CLI](docs/AGY_INTEGRATION.md)), **Claude Code**, and **OpenCode**.

## Latest release: v0.2.0

[v0.2.0](https://github.com/e-kotov/herdr-cache-hit/releases/tag/v0.2.0) adds experimental Herdr App desktop support, contributed by [@akunzai](https://github.com/akunzai) in [#15](https://github.com/e-kotov/herdr-cache-hit/pull/15), plus AGY 1.4 token parsing, canceled-task handling, Windows line-ending fixes, and Bash 3.2 CI coverage. The existing TUI plugin continues to provide cache display, sorting and opt-in warming.

Python 3.6+ is recommended for exact Codex transcript selection. [Read the full changelog](CHANGELOG.md).

[![Herdr terminal sidebar showing alarm, active, and cold prompt-cache states sorted by expiry](https://www.ekotov.pro/herdr-cache-hit/assets/herdr-expiry-agents.webp)](https://www.ekotov.pro/herdr-cache-hit/)

The screenshot shows the Herdr TUI. For desktop setup, see [Herdr App (Experimental)](USERGUIDE.md#herdr-app-experimental).

---

## Features

- **Live Prompt-Cache HUD**: Real-time cache hit ratios, read/cached token metrics, and estimated expiration countdowns directly in Herdr's sidebar.
- **Urgency Transitions**: Automatic visual transitions from healthy state (`~15:44`) to urgent alarm warning (`⏰~𝟭𝟱:𝟰𝟰`) using mathematical Unicode bold digits when nearing expiration (configurable threshold, default ≤5m).
- **Declarative Agent Sorting**: Sort active agent panes by prompt-cache expiration deadline (`cache_deadline asc`), keeping expiring agents at the top. Toggle effortlessly with a single keybinding (`prefix+s`).
- **Bounded Rescans**: Event hooks update immediately. While any cache is active, an enabled Codex pane is present, or an enabled agent pane is awaiting its first usage record, one lightweight wake timer rescans every 15 seconds (or sooner for an expiration transition). Session recovery and late usage can appear without a focus event; expired caches alone do not keep the timer running.
- **Experimental Cache Warmer**: An opt-in warmer can submit a short ordinary turn for Codex, AGY, or Claude. By default it requires the pane to be unfocused, the prompt editor to be empty, and the harness activity signal to confirm idle. Two separate config switches can allow focused panes or nonempty prompt editors; both are off by default. Unknown activity state always skips warming. AGY warming also checks its transcript for outstanding delegated tasks and sends at most once per unchanged cache window.
- **Optional Warmup Duration**: Warming continues indefinitely by default. Configure `cache_warmer_duration_hours` at the root or per-agent level to stop each session after that many hours from its first warmer attempt.
- **Warmer Toggle**: Warming is off by default; opt in per Codex, AGY, or Claude session with Herdr's `prefix+u`. The command palette distinguishes **Toggle per-agent cache warming** from **Switch between global and per-agent warming**. Global mode ON includes all supported sessions; switching it OFF returns to saved individual settings and does not turn those settings off. There is no default global-warming shortcut; users can add one in Herdr config if desired. The session palette action refuses if multiple identified sessions make its target ambiguous. A configurable `↻` before the countdown marks an armed session.
- **Privacy-First**: Cache telemetry is read locally. When the experimental warmer is enabled, its short prompt is submitted like a normal user turn and is stored in that agent session.

When `cache_warmer_allow_nonempty_prompt` is enabled, Herdr sends the warm prompt through the pane's terminal input and presses Enter. Existing draft text may therefore be submitted together with the warm prompt. Enable this only if that behavior is acceptable.

---

## Prerequisites & Compatibility

- **Operating Systems**: **macOS** and **Linux** (native). On **Windows**, native Herdr requires Git for Windows (`sh.exe` and Bash) on `PATH` for plugin commands; WSL2 remains an option.
- **Dependencies**:
  - `jq` (**Required**): Core JSON parser for state and token metadata (`brew install jq`, `sudo apt install jq`, or `scoop install jq` on Windows). It must be on the `PATH` seen by Git Bash.
  - `bash` (**Required**): Standard on Linux (4.0+) and macOS (native bash 3.2 works; Homebrew bash 4.0+ is also supported). On Windows, install Git for Windows and make sure its `sh.exe` is on the Windows `PATH`. The plugin enters through `sh`, which then starts Git Bash even when the WSL `bash.exe` alias appears earlier on `PATH`.
  - `python3` 3.6+ (**Optional**): Needed for **OpenCode**, view sorting, and Codex or Claude session recovery when Herdr has no native session ID. Also recommended for Codex: it reads the current transcript pointer after prompt rewind/edit. Without Python or an available Codex database, native Codex panes use Bash and jq to select the matching file with the latest usage timestamp; that fallback cannot distinguish a discarded branch with newer usage.
  - `Go` 1.24+ (**Optional**): Only needed if building the AGY SQLite helper from source instead of downloading the precompiled release binary.

---

## Quick Start

The steps below are for the **Herdr TUI**. For the desktop app, use the separate [Herdr App installation instructions](USERGUIDE.md#herdr-app-experimental).

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

- **`$cache`**: Unified token string without middle dots (e.g. `~11:41 99% ⇣95.4k` when healthy, `⏰~𝟭𝟭:𝟰𝟭 99% ⇣95.4k` when expiring, or `❄ ⇣95.4k` when cold). Codex uses a one-hour baseline estimate; after it passes, `? 99% ⇣95.4k` retains the last-request counters with unknown current cache status.
- **`$cache_status`**: Expiration clock with optional symbol prefix (e.g. `~11:41` or `⏰~𝟭𝟭:𝟰𝟭`).
- **`$cache_pct`**: Cache hit percentage (`99%`).
- **`$cache_pct_num`**: Raw integer hit percentage for native numeric rules (`99`; cleared when cold).
- **`$cache_remaining_secs`**: Seconds until estimated expiration (`240`; cleared when cold).
- **`$cache_tokens`**: Read and write token counters (`⇣95.4k`).
- **`$cache_state`**: State identifier (`hot`, `expiring`, `unknown`, or `cold`).
- **`cache_deadline`**: Epoch timestamp used for declarative sorting.

---

## Configuration & Documentation

For detailed information on configuring symbols, thresholds, timezones, per-agent overrides, custom declarative views, and troubleshooting, see the **[User Guide & Configuration Manual](USERGUIDE.md)**.

A ready-to-use template is available in [`config.example.json`](config.example.json).

[Herdr App](https://github.com/herdrdev/herdr-app) ([website](https://herdr.dev/)) is supported experimentally and display-only through a bundled mod; see [Herdr App (Experimental)](USERGUIDE.md#herdr-app-experimental). Desktop support is community-maintained on a best-effort basis.

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

## Contributors

- [Egor Kotov](https://github.com/e-kotov) — project maintainer.
- [@akunzai](https://github.com/akunzai) — Herdr App desktop integration, AGY compatibility, Windows fixes and Bash 3.2 CI coverage (including [#15](https://github.com/e-kotov/herdr-cache-hit/pull/15)).

See all [GitHub contributors](https://github.com/e-kotov/herdr-cache-hit/graphs/contributors).

## License

[MIT](LICENSE) © 2026 Egor Kotov
