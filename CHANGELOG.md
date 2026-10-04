# Changelog

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

## [Unreleased]

## [0.1.17] - 2026-10-04
### Added
- Add an optional per-session warmer duration in hours; `0` keeps the default unlimited behavior.
- Add independent opt-ins to warm a focused pane or a pane with an existing prompt draft; both remain off by default.
### Changed
- Require transcript lifecycle evidence that Codex, Claude, and AGY are idle before warming; unknown activity state skips the attempt.
- Detect unfinished delegated tasks in AGY transcripts even when Herdr reports the foreground turn as done.

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
