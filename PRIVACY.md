# Privacy

Claudex is a local macOS menu-bar app.

## Data read locally

- Claude config-directory names, to identify local account slots.
- An opt-in Claude Code status-line cache containing only five-hour/weekly usage,
  reset timestamps, last-changed/last-limits-seen times, and Claude Code version.
- When **Direct Claude refresh (Experimental)** is explicitly enabled, the
  `.credentials.json` file inside each discovered Claude config directory. Its current
  access token and subscription label are held only inside the fetch operation.
- Codex login metadata and tokens from local `CODEX_HOME` directories.
- Codex usage endpoint responses needed to render rate-limit state.
- Optional local `ccusage` output for historical usage charts.
- Frontmost Terminal/iTerm tab tty plus the matching local process's provider,
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, and working directory, when macOS grants Apple
  Events access. These are used only to match the active account and preserve the
  project directory for an explicit handoff. A validated non-conventional config
  directory observed on a live CLI process is retained in memory for the current app
  process so that account can appear in the popover; it is not persisted.
- Codex.app's local `account_id` when Codex is frontmost. Claude.app is recognized
  only as Claude; Claudex does not inspect its account configuration.

## Network use

By default Claudex makes no Claude/Anthropic request; Claude usage is delivered by the
user's normal Claude Code session to a local helper. If **Direct Claude refresh
(Experimental)** is explicitly enabled and a current credentials file exists, Claudex
calls Anthropic's read-only `https://api.anthropic.com/api/oauth/usage` endpoint. Claudex
also calls Codex's read-only usage endpoints. It does not operate a MJUKIS or Everlof
server and does not upload usage data to MJUKIS.

Usage history invokes only an already-installed `ccusage` executable. Claudex never
runs `npx` or a package manager to download or update that third-party tool.

## Secrets

Claudex never reads Claude Keychain items. The optional direct mode reads only the access
token and expiry metadata from a config slot's `.credentials.json`; it never reads or uses
the refresh token, refreshes credentials, or changes the file. Claude and Codex access
tokens remain inside the fetch layer and are not written to logs, history, diagnostics,
or the UI model.

Claude Code's raw status-line payload is never stored. The helper allowlists the four
usage/reset values, last-changed/last-limits-seen times, and Claude Code version; it
discards credentials, prompts, responses, working directories, session IDs, and
transcript paths. An additional health heartbeat contains only received time,
last-limits-seen time, Claude Code version, and a boolean indicating whether rate-limit
fields were present.

Connecting a Claude slot also creates owner-only restoration metadata containing the
config-directory path and exact original `statusLine` object, plus a forwarding copy of
an existing command. Those values are required to chain and later restore the user's
configuration. An original command may itself contain paths or secrets chosen by the
user. Restoration metadata is never included in diagnostics or uploaded.

## Diagnostics

Diagnostics are generated locally and previewed in full. Nothing is uploaded or copied
until the user explicitly selects **Copy report**. Its allowlist contains the generation
time, app version and binary SHA-256, macOS version, schema/helper health, aggregate provider
account counts, ordinal account states/window kinds, and an active Codex backoff duration.
The report excludes credentials, identity, config paths, working directories, sessions,
transcripts, and content.

## Analytics

Claudex does not include product analytics, crash reporting, or tracking.
