# Atlas

Atlas is a native macOS app for exploring iMessage history and optionally
connected Calendar events. Its SwiftUI interface and standalone Swift backend
are separate processes connected through a bearer-authenticated localhost API.
The backend owns read-only data access, local indexes, on-device models, MCP,
Codex conversations, and persisted chat history. Node.js is not used or
packaged.

Atlas can investigate relationships, recover details from old exchanges,
compare communication patterns over time, and build evidence-based personal
insights. It cannot send, edit, or delete messages or calendar events.

## Privacy

The Messages database, Calendar snapshot, search indexes, embeddings, tone
classifications, Atlas chats, and Codex credentials remain on the Mac. After
the onboarding disclosure is accepted, selected evidence for a question may be
sent to OpenAI through Codex. Atlas never uploads `chat.db` or attachment
contents.

Every prompt and MCP result passes through the same local outbound sanitizer.
It replaces detected phone numbers, email and postal addresses, precise
coordinates, IP addresses, financial and government identifiers, credentials,
verification codes, links, and attachment filenames with irreversible typed
redaction tokens. Names, dates, relevant prose, nicknames, company names, job
titles, and departments can still be sent when relevant. Automated redaction
is defense in depth rather than a guarantee, which onboarding discloses before
any Codex or MCP data route is enabled.

Calendar access is optional and read-only. Disconnecting it deletes Atlas's
private snapshot without modifying Calendar or its macOS permission.

## Architecture

```text
Atlas.app (SwiftUI UI process)
    |  bearer-authenticated HTTP on 127.0.0.1:47831
    v
atlas-backend (separate Swift child process inside the signed app bundle)
    +-- read-only Messages, Contacts, and Calendar snapshot access
    +-- SQLite FTS sidecar and native llama.cpp embeddings
    +-- local Core ML/ONNX tone classifier
    +-- Codex app-server with only Atlas MCP enabled
            +-- locally redacted, selected evidence sent to OpenAI
```

The random bearer token and identity key use owner-only files in
`~/Library/Application Support/Atlas`. Phone and email handles are converted
locally into keyed, randomized opaque person and conversation IDs and are never
returned by tools.

The UI owns the backend process, while a 15-second foreground lease gates every
expensive or remote operation. Closing Atlas terminates the backend and cancels
Codex turns, FTS indexing, embeddings, tone processing, suggestions, and insight
generation. Atlas uses its own Codex
home, so its threads do not appear in the Codex desktop app; deleting an Atlas
chat deletes its Codex thread too.

## Local processing

- The always-enabled SQLite FTS index processes Apple Messages read-only and
  preserves Apple attributed-body text through native decoding.
- Optional enhanced search downloads about 640 MB and embeds passages locally
  with Metal, newest first. It reports partial coverage explicitly.
- Tone analysis combines adjacent bubbles into speaker turns and short
  multi-speaker windows, then runs a three-way classifier locally. Core ML is
  preferred when bundled; verified ONNX inference is the native fallback.
- First insights wait for FTS and tone analysis to settle; embeddings do not
  block them.
- Embeddings pause on battery. Tone runs on battery except in Low Power Mode.
  Long work prevents idle sleep only while Atlas is open and conditions allow.

## MCP tools

- `database_info`
- `list_conversations`
- `list_people`
- `read_conversation`
- `search_messages`
- `search_context`
- `tone_analysis`
- `conversation_stats`
- `sample_conversation`
- `calendar_info`
- `search_calendar_events`
- `read_calendar_events`

All tools are read-only. Search limits reach 5,000 messages, conversation reads
reach 10,000 messages, and the model is instructed to choose breadth based on
the question.

## Requirements and install

- Apple silicon Mac running macOS 15 or newer
- Xcode Command Line Tools with Swift 6.1 or newer
- the official Codex CLI installed and logged in
- Full Disk Access for `Atlas.app`

```sh
git clone git@github.com:sacrosaunt/Atlas.git
cd Atlas
./scripts/install.sh
```

The installer builds the Swift backend and UI, copies the native llama and ONNX
runtimes, and ad-hoc signs `~/Applications/Atlas.app`. The app starts and
supervises the separate backend only while Atlas is open. Atlas prefers the
optional precompiled Core ML tone package at `assets/ToneClassifier.mlpackage`
and otherwise runs the verified downloaded tone model through ONNX Runtime.
Source builders can create the faster Core ML asset with
`scripts/convert-tone-coreml.py`.

Older installs can remove the retired Login Agent while preserving the app and local data:

```sh
./scripts/uninstall.sh
```

## Development

```sh
swift build
ATLAS_PORT=48731 .build/debug/AtlasBackend
```

The backend keeps the previous API and SQLite schemas, so existing Atlas chats,
Codex thread IDs, consent, Calendar snapshots, FTS data, embeddings, tone data,
and settings migrate in place without an export or rebuild.

## Layout

```text
assets/          App branding and production model assets
config/          App property list
scripts/         Install, uninstall, and model conversion tools
src/             SwiftUI interface and Calendar snapshot bridge
swift-backend/   Standalone Swift API, MCP, indexes, models, and Codex bridge
swift-backend-tests/  Native tests
```

Persistent state lives under `~/Library/Application Support/Atlas`. Logs are
written to `~/Library/Logs/Atlas.log` and `~/Library/Logs/Atlas.error.log`.
