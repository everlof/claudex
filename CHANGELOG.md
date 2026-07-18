# Changelog

All notable changes to Claudex will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic
versioning for public releases.

## [Unreleased]

### Added
- An opt-in **Active Claude refresh (Experimental)** mode modeled after CodexBar. It can
  use a current credential file or an account-specific, explicitly authorized Keychain
  access token held only in memory. It never refreshes or rewrites credentials and falls
  back to the passive local feed when active refresh is unavailable.
- An opt-in **Activity Map (Beta)** window visualizes observed Claude and Codex
  conversations as conversation → tool → repository-relative file graphs.
- Reversible provider hooks feed a content-free, owner-only seven-day activity
  spool; the review screen shows the complete retention and exclusion policy
  before enabling collection.
- A local **Limit history** window retains 180 days of Claude and Codex rate-limit
  observations, plots actual usage against linear pace, and measures capacity restored,
  above-pace headroom, and time gained when a provider resets a window early.
- One-time local notifications report qualifying early resets and their measured gain.
- Settings can reveal the exact running Claudex application bundle in Finder, making it
  easier to inspect or add the correct signed build to macOS permission controls.

### Changed
- Claude's passive feed now tracks last-limits-seen separately from last-value-change
  time, so unchanged but healthy usage stays fresh.
- Validated `CLAUDE_CONFIG_DIR` and `CODEX_HOME` paths observed on a frontmost CLI can
  join the popover even when they do not use Claudex's conventional directory names.
- Public GitHub release flow now updates mjukis.dev release metadata by default.
- The signed local bridge can now sanitize provider hook events without retaining
  prompts, responses, reasoning, commands, tool arguments/output, credentials,
  full working-directory paths, transcript paths, or raw provider identifiers.
- Development builds now sign correctly with an Apple Development identity on
  Bash 3 as well as the public Developer ID release path.

### Fixed
- Claude Science's application data root is no longer presented as a separate Claude
  account. Any exact Claudex-managed status-line change there is restored first, and
  legacy pseudo-account samples are hidden from Limit History.
- A status-line event that temporarily omits Claude rate limits no longer erases the
  last successful usage snapshot; the card remains visible with a stale indicator.
- One expired Claude window no longer invalidates another window that is still current.

## [1.1.0] - 2026-07-12

### Added
- Opt-in Claude Code local usage feed with reversible per-profile setup, existing
  status-line chaining, stale-data indicators, and safe disconnect behavior.
- Preview-before-copy diagnostics with an explicit privacy allowlist.
- A normalized all-account portfolio and same-provider handoff suggestions when
  an active account is under rate-limit pressure.
- Frontmost Claude/Codex session detection for Terminal, iTerm2, and supported
  desktop-app state, with provider-aware menu-bar fallback behavior.
- Configurable menu-bar subjects/styles and reset notifications.
- Usage-history chart backed by `ccusage`, with compact panel summary and a
  breakout window; the optional tool must already be installed and is never
  downloaded automatically.
- Launch-at-login control in the app settings menu.
- App icon asset and bundle icon packaging.
- Release, privacy, and website publication documentation.
- Universal direct-download release packaging and GitHub release asset upload
  script.
- Unit and black-box coverage for formatting, aggregation, backoff, handoff,
  local-cache validation, helper deployment/forwarding, and reversible setup.
- Developer ID signing, Apple notarization/stapling, and Gatekeeper verification
  for public direct-download releases.

### Changed
- Claude usage no longer reads Keychain credentials or polls Anthropic's undocumented
  OAuth usage/profile endpoints; Codex remains network-backed.
- Existing Claude accounts must use **Review & Connect…** once after upgrading and send
  one Claude response so the new local feed can produce its first snapshot.
- Codex refreshes honor server `Retry-After` backoff while keeping a previous safe
  snapshot visible.
- Chart and menu rendering are split to reduce unnecessary per-second menu
  refreshes.

### Fixed
- Chart x-axis and tooltip overflow handling.

## [1.0.2] - 2026-07-07

### Fixed
- Hardened the Homebrew build path by supporting ad-hoc signing in sandboxed
  builds.

## [1.0.1] - 2026-07-07

### Fixed
- Disabled SwiftPM sandboxing for Homebrew builds.
- Corrected stale install documentation.

## [1.0.0] - 2026-07-07

### Added
- Initial open-source release of the Claudex menu-bar app.
