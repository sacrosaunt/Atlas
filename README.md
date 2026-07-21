# Atlas

Atlas is a native macOS app for asking questions about the iMessage history and
optionally connected Calendar events on your Mac. It combines read-only local connectors, fast local indexes,
on-device tone and semantic models, and Codex reasoning in one private desktop
interface.

Atlas can help explore a relationship, recover a detail from an old exchange,
compare communication patterns over time, or build evidence-based personal
insights. It cannot send, edit, or delete iMessages.

## Privacy model

Atlas is local-first, not fully on-device. The Messages database, private Calendar snapshot, attachment
contents, search indexes, embeddings, tone classifications, Atlas chat history,
and Codex credentials stay on the Mac. When you ask a question, selected text
and metadata retrieved for that question are sent to OpenAI for reasoning. When
Calendar is connected, matching event titles, dates, locations, notes, and
calendar names may also be sent for calendar-related questions.

Before any prompt or MCP result leaves the local service, Atlas applies the same
outbound sanitizer. Detected values are replaced with irreversible typed tokens
such as `[redacted: email address]`; values are not hashed or encoded into those
tokens.

Atlas currently filters:

- phone numbers and email addresses;
- street and postal addresses;
- precise coordinates and IP addresses;
- payment cards, bank identifiers, and common government identifiers;
- passwords, verification codes, and common API or bearer-token formats;
- links, including their paths, query parameters, and fragments;
- attachment filenames, which are reduced to `[attachment]` plus a normalized
  extension while retaining the MIME type.

Typed tokens are used instead of deletion because they preserve sentence
structure and tell the model that evidence is intentionally absent. MCP results
also include aggregate redaction counts and categories, never the removed
values.

Names, dates, relationship-relevant prose, contact nicknames, company names,
job titles, and departments may still be sent when relevant. Automated
redaction is defense in depth, not a guarantee that every identifying detail or
unusual secret will be detected. Onboarding presents this limitation before
any Messages data can be exposed to Codex or sent to OpenAI. The service stores
the current disclosure approval locally and returns an error from every Codex
and MCP data route until that approval exists.

Atlas never uploads the `chat.db` database file or attachment contents.
Calendar access is optional and read-only. Disconnecting it in Settings deletes
Atlas's private local event snapshot without changing events or macOS permission settings.

## Architecture

```text
Atlas.app (SwiftUI)
        |
        +-- read-only EventKit access and private Calendar snapshot
        |
        | bearer-authenticated localhost API
        v
Atlas background service (Node, launchd)
        |
        +-- read-only Apple Messages and Contacts databases
        +-- local SQLite full-text and vector sidecars
        +-- local Core ML tone classifier
        +-- Codex app-server in a dedicated Atlas home
                |
                +-- read-only Atlas MCP tools
                +-- selected, locally redacted evidence sent to OpenAI
```

The service binds only to `127.0.0.1:47831`. App and MCP routes use a random
local bearer token stored with owner-only permissions. The Codex runtime is
started with approval policy `never`, a read-only sandbox, network access off
for tools, and shell, browser, app, image, and multi-agent capabilities
disabled. Only the Atlas MCP is enabled.

The Login Agent remains available so Atlas can reconnect quickly, but it is
CPU-idle without an Atlas window. The app renews a short foreground lease while
its window exists. Closing Atlas expires that lease, aborts in-flight analysis,
and pauses full-text indexing, embeddings, tone processing, automatic insights,
suggestions, and chats until Atlas is opened again.

Atlas uses a dedicated Codex home at
`~/Library/Application Support/Atlas/CodexHome`, so its resumable threads do not
appear in the Codex desktop app. Deleting an Atlas conversation also deletes
its corresponding Codex thread.

## Local processing

### Full-text search

Atlas builds a private SQLite FTS sidecar while the app is open and Messages
access is available. It processes the archive locally and never modifies
Apple's `chat.db`. Literal message searches use this sidecar and fall back to a
read-only database scan only while initial indexing is incomplete.

### Tone analysis

Onboarding installs a verified local sentiment model. Atlas combines adjacent
bubbles into coherent speaker turns and short multi-speaker windows, then
stores negative, neutral, and positive measurements locally. MCP access exposes
only scoped aggregates through `tone_analysis`; representative messages must be
retrieved separately when the model needs qualitative evidence.

The production classifier uses a fixed-shape FP16 Core ML package with
length-bucketed batches. Tone processing runs on battery unless Low Power Mode
is enabled, and it pauses under serious thermal pressure. Its ETA appears after
a 30-second warm-up and refreshes once per minute. Closing Atlas pauses tone
processing.

### Enhanced semantic search

Enhanced search is an optional download of approximately 640 MB. It embeds
message passages locally using Metal, newest first, and combines vector and
keyword retrieval. Partial results report a coverage frontier so an absent
semantic match is not misrepresented as archive-wide evidence.

Semantic optimization pauses on battery, in Low Power Mode, or under serious
thermal pressure. On external power, Atlas prevents idle system sleep while
long-running optimization is active; the display may still sleep.
Closing Atlas releases the sleep assertion and pauses optimization.

### First insights

Atlas waits for the full-text index and local tone analysis to settle before it
creates the first insight document. A tone-model failure is treated as an
explicitly unavailable signal rather than blocking Atlas indefinitely.
Embeddings do not block first insights and can continue improving semantic
coverage afterward.

When the first insight document is ready, Atlas shows a one-time in-app banner
or, when it is behind another app, a privacy-safe macOS notification. The
notification contains no names, excerpts, or findings and opens **Insights
About You** when selected. Notification permission is requested only after the
first insight generation has begun.

## MCP tools

- `database_info`: archive record counts without message text.
- `list_conversations`: recent chats with opaque conversation and person IDs.
- `list_people`: contact resolution using names and safe profile metadata.
- `read_conversation`: date-bounded or paginated reads of up to 10,000 messages.
- `search_messages`: literal search across archive, person, conversation, date,
  and direction scopes.
- `search_context`: optional hybrid semantic and keyword passage retrieval.
- `tone_analysis`: local tone aggregates by archive, conversation, people, date,
  direction, and timeline bucket.
- `conversation_stats`: longitudinal sent and received activity counts.
- `sample_conversation`: evenly spaced bounded samples for hypothesis discovery.
- `calendar_info`: optional Calendar connection, date coverage, and opaque calendar IDs.
- `search_calendar_events`: bounded event search across titles, dates, locations, and notes.
- `read_calendar_events`: full cached details for selected opaque event IDs.

Phone numbers and email handles are represented internally by keyed, stable,
opaque IDs. The underlying identifiers are never returned by MCP tools.

## Requirements

- Apple silicon Mac running macOS 14 or newer.
- Node.js 22.5 or newer. The installer prefers Node 24 when managed by NVM.
- The official Codex CLI installed and logged in.
- Full Disk Access for the Node executable so the background service can open
  the Messages and Contacts databases read-only.

Grant Full Disk Access in:

```text
System Settings > Privacy & Security > Full Disk Access
```

Onboarding displays the exact Node executable used by the Login Agent. After
granting it Full Disk Access, use **Restart & Recheck** in Atlas; restarting the
window alone does not restart the separate background process. Codex is
resolved dynamically from `CODEX_CLI_PATH`, the service `PATH`, the active Node
bin, and common Homebrew, NVM, Volta, npm, asdf, and mise locations.

## Install

```sh
cd ~/Atlas
./scripts/install.sh
```

The installer builds the native app and Core ML helper, ad-hoc signs the app,
installs it at `~/Applications/Atlas.app`, and registers the
`com.sacrosaunt.atlas` Login Agent.

To remove only the background Login Agent while preserving the app and all
local data:

```sh
./scripts/uninstall.sh
```

## Development

Install dependencies and run the service directly:

```sh
npm install
npm start
```

Run syntax checks and tests with the same Node runtime used by the service:

```sh
npm run check
npm test
```

Core ML conversion and repeatable performance tools live under `scripts/`:

- `convert-tone-coreml.py`
- `benchmark-tone.js`
- `benchmark-embeddings.js`

Generated dependencies, Python environments, compiled binaries, local models,
SQLite databases, and user data are excluded from Git.

## Project layout

```text
assets/     App icon and brand assets
config/     App and launchd property lists
public/     Legacy web assets retained for development reference
scripts/    Installation, migration, conversion, and benchmark utilities
src/        SwiftUI app, Node service, MCP, indexes, and native model runners
```

All persistent Atlas state is stored under
`~/Library/Application Support/Atlas`. Logs are written to
`~/Library/Logs/Atlas.log` and `~/Library/Logs/Atlas.error.log`.
