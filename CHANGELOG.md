# Changelog

## [Unreleased]
- Add experimental, display-only Herdr App support: a bundled mod runs the scanner through a herdr-core shim, including on Windows, and publishes the estimates as `shared("cache-hit")`. The user guide has a recipe for the Agents sidebar.
- Treat a canceled AGY background task as finished. One canceled task kept the cache warmer out of that session for the rest of its life.
- Read AGY 1.4 transcripts, which write uncached input and cache reads at the top level of `PLANNER_RESPONSE` steps and have no cache-write count. Without statusline data, such sessions showed no cache value.
- Keep LF line endings from a native Windows `jq` in Git Bash. Every raw value but the last ended in `\r`, so only one of several agents matched.
- Run the test suite under Bash 3.2 in CI, the version macOS still ships as `/bin/bash`.

## [0.1.26] - 2026-10-24
- Preserve Codex's last-request cache counters and timestamp after compaction. Context-only reports with zero request counters no longer erase cache reads or appear as a cache miss, including after a restart without saved state. The parser still accepts real requests with input tokens and zero cache reads.
- Use a one-hour Codex cache estimate. After that estimate elapses, keep the last-request counters and show unknown cache status instead of claiming eviction; cache misses do not shorten the estimate.
- Verify the downloaded helper from its executable header when `file` is unavailable, as in a default Termux, instead of failing the install. The format and architecture check stays as strict.

## [0.1.25] - 2026-10-10
- Fix stale Codex cache clocks after prompt rewind/edit creates another transcript with the same thread ID. Read Codex's current transcript pointer from its database instead of selecting the first matching file.
- Preserve Bash/jq-only compatibility by comparing valid usage timestamps across matching files. Python 3.6+ is recommended for exact branch selection; the fallback cannot distinguish a discarded branch with newer usage.
- Add regressions for duplicate transcripts, discarded branches, touched old files, and malformed or mismatched records; add Python 3.6 CI coverage alongside macOS, Linux and Windows Git Bash.

## [0.1.24] - 2026-10-10
- Make the Claude and OpenCode session-recovery tests compatible with Python 3.6, matching the supported runtime and GWDG installations. Runtime behavior is unchanged.

## [0.1.23] - 2026-10-10
- Support native Windows Herdr through Git Bash, with a Windows AMD64 helper binary and verified downloads.
- Recover Claude and OpenCode session identities when Herdr has no native session ID, including Windows paths and executable names.
- Keep late usage discovery working while retiring timers for expired caches, including write-only caches whose usage record disappears.
- Preserve native macOS Bash 3.2 compatibility when decoding empty pane paths; verify watcher behavior on macOS, Linux and Windows Git Bash.

## [0.1.22] - 2026-10-10
- Keep background refreshes running when a fired timer becomes the watcher process or its parent. This fixes stale expiry displays and restores scheduled cache-warmer checks.
- Test repeated background wake-ups and automatic hot-to-cold transitions without pane events.

## [0.1.21] - 2026-10-05
- Skip Claude warming while the latest reply is an API rejection such as a usage limit; the warm turn would be rejected too and queue into the user's next turn. Warming resumes after a successful reply. Transient `server_error` replies do not block.

## [0.1.20] - 2026-10-05
- Detect Claude background shells from Claude Code's own markers (`run_in_background`, `backgroundTaskId`, or its background notice), including commands moved to the background after a timeout. Foreground output that merely mentions background work no longer blocks warming.

## [0.1.19] - 2026-10-05
- Fix Claude warming being skipped permanently after any failed tool call, whose transcript `toolUseResult` is a string rather than an object.
- Clear Claude background shell tasks and background agents when their `<task-notification>` reports a final status; read shell task IDs from `backgroundTaskId`.

## [0.1.18] - 2026-10-04
- Recognize Codex `task_started` and `task_complete` lifecycle events so idle sessions can be warmed safely with current Codex transcript logs.

## [0.1.17] - 2026-10-04
### Added
- Add an optional per-session warmer duration in hours; `0` keeps the default unlimited behavior.
- Add independent opt-ins to warm a focused pane or a pane with an existing prompt draft; both remain off by default.
### Changed
- Require transcript lifecycle evidence that Codex, Claude, and AGY are idle before warming; unknown activity state skips the attempt.
- Detect unfinished delegated tasks in AGY transcripts even when Herdr reports the foreground turn as done.

## [0.1.16] - 2026-10-03
- Clarify the command-palette distinction between per-agent settings and global mode; remove the default global-warming shortcut from Mac and GWDG configs.

## [0.1.15] - 2026-10-03
- Add per-session and global cache-warmer actions to Herdr's plugin action list and command palette.
- Resolve the command-palette session target from the active workspace only when exactly one identified agent session is present.

## [0.1.14] - 2026-10-03
- Route active Claude panes through the cache warmer. Fix ShellCheck and watcher-test failures that had been blocking CI.

## [0.1.13] - 2026-10-03
- Add opt-in Claude Code cache warming with session/global toggles, a visible armed marker, and a 60-second default margin. Claude warming requires a tracked 5-minute or 1-hour cache lifetime and skips unknown lifetimes.

## [0.1.12] - 2026-10-03
- Set AGY's default cache warmer margin to 60 seconds before expiration; Codex stays at 300 seconds. Both remain configurable.

## [0.1.11] - 2026-10-03
- Prevent duplicate warmer prompts within the same unchanged cache window.
- Skip AGY warming while its transcript shows an unfinished delegated background task, even when Herdr reports the foreground turn as done.

## [0.1.10] - 2026-10-03
### Added
- Add optional Codex and AGY cache warming with per-session and global toggles, visible status markers, and quiet Herdr notifications.
- Continue warming opted-in sessions indefinitely by default; allow a finite per-session attempt limit through configuration.
### Changed
- Exclude survival observations affected by synthetic warmer turns.

## [0.1.9] - 2026-10-03
### Fixed
- Rebase persisted Codex cache deadlines during startup even when usage data is temporarily unavailable.

## [0.1.8] - 2026-10-03
### Changed
- Use a 30-minute baseline for Codex cache countdowns; only shorten it after at least three lower survival observations for the same provider/model, and do not extend it from longer observations.
- Rebase persisted active Codex countdowns to the new policy while preserving the original cache-hit time.

## [0.1.7] - 2026-09-30
### Fixed
- Recover explicitly resumed Codex sessions when `--no-daemon` appears before the `resume` subcommand.

## [0.1.6] - 2026-09-30
### Fixed
- Recover Codex cache metadata when Herdr has no native session ID, using foreground process information with guards against same-directory panes, subagents, and ambiguous roots.
- Read Codex `event_msg/token_count` per-request usage alongside `token_usage_record`, and recover model/provider metadata from the rollout.
- Respect `CODEX_HOME` and preserve empty snapshot columns when parsing pane records.
- Refresh cold Codex panes every 15 seconds so the first cache hit appears without a focus change.

## [0.1.4] - 2026-09-11
### Fixed
- **Claude Streaming Parser Optimization**: Replaced `tail -n 500 | jq -R -s` with an $O(1)$ streaming reverse reader (`rev_lines | jq -Rrn 'first(inputs | fromjson? ...)'`) to prevent multi-second parser bottlenecks on large JSONL transcripts and networked filesystems (such as HPC Lustre/VAST).
- **Graceful Partial-Line Handling**: Added newline padding and `fromjson?` protection to safely ignore in-flight, unclosed JSON lines during active Claude Code generation.
- **Lock Contention Elimination**: Prevents long-running `jq` processes from holding the plugin lock and dropping interactive `pane.focused` UI click events.

## [0.1.3] - 2026-09-11
### Fixed
- **Mobile Layout Compatibility**: Injected the formatted cache string into the pane's `--display-agent` metadata to ensure prompt-cache statistics remain visible when Herdr dynamically collapses into its hardcoded mobile layout (e.g., on narrow terminal windows or Termux). Herdr's mobile layout ignores custom `config.toml` rows and custom `agent.view.set` sorting rules, rendering `{pane_title} · {status} · {agent}`. This fix ensures the cache hit data is preserved within the `{agent}` slot.
