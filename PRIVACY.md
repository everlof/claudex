# Privacy

Claudex is a local macOS menu-bar app.

## Data read locally

- Claude config-directory names, to identify local account slots.
- Names and filesystem entry types for candidate Claude Science data roots, solely to
  exclude that separate application's data directory from account discovery and restore
  a Claudex-owned status-line integration created by older versions. Science credentials,
  projects, conversations, and artifacts are never read.
- An opt-in Claude Code status-line cache containing only five-hour/weekly usage,
  reset timestamps, last-changed/last-limits-seen times, and Claude Code version.
- When **Active Claude refresh (Experimental)** is explicitly enabled, the
  `.credentials.json` file inside each discovered Claude config directory. Its current
  access token and subscription label are held only inside the fetch operation.
- When the user additionally selects a Claude account slot and clicks **Authorize
  Keychain & Refresh**, the `Claude Code-credentials` Keychain item. The current access
  token is held only in memory for the app run. No startup, timer, menu-open, or ordinary
  refresh path requests secret Keychain data. Non-secret item metadata may be inspected
  during that explicit action to select the newest candidate.
- Codex login metadata and tokens from local `CODEX_HOME` directories.
- Codex usage endpoint responses needed to render rate-limit state.
- Rate-limit observations and inferred reset events used by **Limit history**, described
  below. Collection begins with this version and uses only already-observed usage data.
- Optional local `ccusage` output for historical usage charts.
- Frontmost Terminal/iTerm tab tty plus the matching local process's provider,
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, and working directory, when macOS grants Apple
  Events access. These are used only to match the active account and preserve the
  project directory for an explicit handoff. A validated non-conventional config
  directory observed on a live CLI process is retained in memory for the current app
  process so that account can appear in the popover; it is not persisted.
- Codex.app's local `account_id` when Codex is frontmost. Claude.app is recognized
  only as Claude; Claudex does not inspect its account configuration.
- When the user explicitly enables **Activity Map (Beta)**: supported Claude Code
  and Codex lifecycle hooks send event JSON to the signed local helper. The helper
  retains only provider, tool name/category, observed time/outcome, project-folder
  name, repository-relative file paths exposed by supported file tools, permission
  requests, and hashed account/session/turn/agent/project identifiers.

## Network use

By default Claudex makes no Claude/Anthropic request; Claude usage is delivered by the
user's normal Claude Code session to a local helper. If **Active Claude refresh
(Experimental)** is explicitly enabled and either a current credentials file exists or
the user has authorized the Keychain item for an account, Claudex calls Anthropic's
read-only `https://api.anthropic.com/api/oauth/usage` endpoint. Claudex also calls Codex's
read-only usage endpoints. It does not operate a MJUKIS or Everlof server and does not
upload usage data to MJUKIS.

Usage history invokes only an already-installed `ccusage` executable. Claudex never
runs `npx` or a package manager to download or update that third-party tool.

## Secrets

By default Claudex never reads Claude Keychain items. In the optional active mode, only
the explicit **Authorize Keychain & Refresh** action may request Claude Code's credential
item from macOS. Because the item is one JSON value, Claudex necessarily receives its raw
bytes before parsing; it extracts only the current access token, expiry, and subscription
label. It does not extract, retain, or use the refresh-token field, refresh credentials,
or write the item. A Keychain-derived access token is kept only in memory for the current
app run and may be reused by active background usage refreshes. Disabling the mode clears
it immediately. Claude and Codex access tokens are not written to logs, history,
diagnostics, or the UI model.

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

### Limit history

Claudex automatically keeps the rate-limit values it already receives so they can be
plotted over time. Each sample contains only observation time, provider, local account
slot ID/label, limit-window ID/label, normalized usage fraction, reset timestamp, window
length, and source kind (passive Claude, active Claude file, active Claude Keychain, or
Codex API). An inferred
reset event contains those local account/window labels, the adjacent observation times,
old and new reset timestamps, capacity restored, elapsed fraction, above-linear fraction,
and estimated seconds early.

Limit history does not contain credentials, tokens, config paths, prompts, responses,
transcripts, session IDs, token/cost records, or raw provider payloads. It is stored in
owner-only daily JSONL files under
`~/Library/Application Support/Claudex/LimitHistory/`. Each daily file is capped at
8 MiB, at most 250,000 records are loaded, and files older than 180 days are removed.
**Settings → Limit history… → Delete local limit history** removes the files immediately.

Reset detection requires both a sharp usage drop and an advance in the provider's reset
timestamp. The exact reset may have happened between the last pre-reset and first
post-reset observation, so the displayed and notified time gain is an estimate based on
the first observation that revealed it. Notifications are local macOS notifications.

### Activity Map beta

Activity Map is off by default. Its review screen lists every retained and excluded
field before **Enable Activity Map** changes any provider configuration. Enabling adds
one stable command hook to each discovered account's supported lifecycle events.
Existing hook groups and handlers are preserved. Codex requires the user to review and
trust a new command-hook definition in `/hooks`; Claudex keeps the command stable across
normal app upgrades so its definition does not routinely change.

The helper parses provider hook input in memory and discards raw input immediately.
It never writes prompts, responses, reasoning, file contents, shell commands, tool
arguments, tool output, credentials, full working-directory paths, transcript paths,
or raw provider session/turn/agent identifiers. Absolute paths outside the observed
working directory are discarded. MCP and shell arguments are never inspected for
resources. File paths are retained only when a supported file tool provides an
explicit in-project path or an `apply_patch` header names it.

Sanitized events are kept in owner-only daily JSONL files under
`~/Library/Application Support/Claudex/Activity/`. Each daily file is capped at 1 MiB;
the UI reads at most 2,500 recent events and removes event files older than seven days.
The graph therefore represents **observed supported activity**, not a guarantee that
every filesystem or network effect was captured.

Pausing removes only Claudex's exact hook handlers and retains the local graph history.
**Delete local history** explicitly removes the event files. Owner-only installation
metadata retains provider/configuration paths and the exact Claudex hook command so the
app can remove its entries later; it is never included in diagnostics or uploaded.

## Diagnostics

Diagnostics are generated locally and previewed in full. Nothing is uploaded or copied
until the user explicitly selects **Copy report**. Its allowlist contains the generation
time, app version and binary SHA-256, macOS version, schema/helper health, aggregate provider
account counts, ordinal account states/window kinds, and an active Codex backoff duration.
The report excludes credentials, identity, config paths, working directories, sessions,
transcripts, Activity Map events, file paths, tool names, and content.

## Analytics

Claudex does not include product analytics, crash reporting, or tracking.
