# Changelog

## [0.1.12] - 2026-10-03
- Set AGY's default cache warmer margin to 60 seconds before expiration; Codex stays at 300 seconds. Both remain configurable.

## [0.1.11] - 2026-10-03
- Prevent duplicate warmer prompts within the same unchanged cache window.
- Skip AGY warming while its transcript shows an unfinished delegated background task, even when Herdr reports the foreground turn as done.

## [Unreleased]

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
