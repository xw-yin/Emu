# Startup and save regression checks

Run the JavaScript checks with Node 20+:

```sh
node --test Tests/game-runtime.test.cjs Tests/game-audio.test.cjs
```

These execute the shipped runtime and the audio script extracted from
`GameWebView.swift`. The storage contract tests use small engine doubles; they do
not simulate WebKit or replace an iOS device test. The optional integration check
uses unmodified upstream MV managers and real LZString when `EMU_MV_SOURCE_DIR`
points to a directory containing `StorageManager.js`, `DataManager.js`,
`ConfigManager.js`, and `lz-string.js` (LZString 1.4.4 was checked locally).

On macOS, exercise the actual HTTP server, filesystem, snapshot, session isolation,
script installation, and byte ranges:

```sh
swiftc -parse-as-library Services/LocalGameServer.swift Services/EmuScriptAssets.swift Tests/LocalGameServerChecks.swift -o /tmp/emu-server-checks
/tmp/emu-server-checks
```

On a logged-in macOS desktop, check synchronous startup reads through real WebKit,
backup/restore, and durable disk writeback (the codec is an identity test double):

```sh
swiftc -parse-as-library Services/LocalGameServer.swift Services/EmuScriptAssets.swift Tests/GameWebKitChecks.swift -o /tmp/emu-webkit-checks
/tmp/emu-webkit-checks
```

The existing macOS build workflow runs both offline JavaScript checks and native
server checks before building the app. No game files are required; native checks
create and remove their own temporary directory.

External games now import their original saves once into Application Support /
GameSaves / game UUID. Native checks cover import, independent writes/HTTP reads,
restart persistence and deletion without reimport. Original external saves remain
untouched. File-provider resources are read through NSFileCoordinator; actual iOS
provider permissions and cloud materialization still require device verification.

## Changes under test

- Native save metadata is installed before each main-document navigation. The
  original document's pending saves are drained on reload before the next snapshot.
- Small MV saves are prepared natively before navigation (256 KiB per file,
  1 MiB total, prioritizing config/global/plugin data). No asynchronous preload
  races engine startup. Larger/uncached MV saves still use synchronous loopback
  HTTP; MZ remains asynchronous. Provider asset preparation runs on four workers
  independently of the network/save queue, so a slow asset cannot block all saves.
  Cached strings use an 8 MiB UTF-16 estimate with LRU eviction.
  Pending MV writes stay pinned until durable writeback; a large pending write can
  temporarily exceed the limit. Orphan-index checks retain validation results,
  not full save strings. Evicted saves and backups remain readable.
- External save import runs on the server queue, one file at a time. Cancelled
  preparations cannot start a listener. The persistent WebKit store keeps failed
  write journals available across closing/reopening the game.
- The local server appends an installation call to standard `rpg_managers.js` and
  `rmmz_managers.js`, so hooks run before plugins/main can read configuration.
  DOM/load observers cover later definitions; custom bundled engines still need
  their own compatibility verification.
- MV reads stay synchronous; writes first enter a per-game localStorage journal,
  then flush to disk in file order. Failed writes remain available for recovery
  on reopening the same origin. MZ saves resolve only after the disk write succeeds.
- MV's older browser-only saves are imported when their game title and global ID
  match; existing disk files win. MZ retains its original game-scoped IndexedDB
  fallback and key initialization. Original browser data is not bulk-deleted.
- MV directory-scoped saves with a missing index or outdated title/global ID get
  an in-memory index view after validating all ten standard save-content fields.
  Opening Continue does not rewrite the imported files. Invalid/orphan fragments
  are not promoted to save slots; plugin index fields and normal eligibility
  checks are preserved. Disabled Continue and load failures emit explicit errors.
- Missing resources, invalid saves, and plugin errors are reported rather than
  replaced with empty scripts/maps or bypassed readiness checks.
- No compatibility code globally replaces map geometry or swallows save extraction
  exceptions. Plugins depending on NW.js or modified save formats may still require
  explicit adapters based on their actual source.

## Device checks still required

The virtual keyboard checks cover quick taps sampled on the next engine update,
holds, cancellation, modifiers and the registered letter/digit/function keys.
On device, also check simultaneous direction + action, sliding between directions,
background/resume, hiding controls and opening the key editor while holding a key.
Use the toolbar log button after startup: select/copy a line, copy all, and toggle
follow-latest while new logs arrive. Startup logs (up to 2,000 entries) are retained
separately from the rolling 2,000 runtime entries for the current game session.
Toggle keep-awake, background the app, and exit to confirm idle-timer restoration.

Open the affected game, reach the title, load an existing PC save, make a new save,
reload the page, then exit/reopen and load it again. Repeat with an MV and an MZ
game. Confirm the log names the storage bridge before engine startup. If startup
takes more than 15 seconds, inspect the diagnostic line for the active scene,
missing database files, pending images, and font states.

The optional upstream MV integration requires EMU_MV_SOURCE_DIR; without it those
checks are skipped. Offline checks do not establish crash recovery on a real iOS
device or compatibility with every game/plugin.

## Performance regression checks

```sh
swiftc -parse-as-library Services/GameLogManager.swift Tests/GameLogChecks.swift -o /tmp/emu-log-checks
/tmp/emu-log-checks
swiftc -parse-as-library Models/Game.swift Services/GameLibraryManager.swift Tests/GameLibraryChecks.swift -o /tmp/emu-library-checks
/tmp/emu-library-checks
```

Server checks also verify byte-exact responses spanning multiple 64 KiB sends,
range/HEAD/empty-file framing, conditional static-resource caching, changed-file
invalidation and session isolation. Saves remain `no-store`. Static assets require
ETag revalidation because different games reuse the same loopback origin.
Library checks cover persistent IDs, unchanged refreshes and stale removal scans.
Log checks cover one publication per batch, concurrent producers and reset isolation.
Runtime checks verify 100 ms startup / 1 s post-readiness compatibility checks,
pause/visibility suspension, resumed installation and late plugin replacements.
Thumbnail loading uses coordinated ImageIO downsampling on a serial worker with a
24 MiB cache budget; external file-provider permissions still need device coverage.

On an Apple Silicon Mac with a booted simulator, exercise the production thumbnail
loader (replace the UDID with the booted device):

```sh
EMU_SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -parse-as-library -sdk "$EMU_SIM_SDK" -target arm64-apple-ios18.0-simulator Models/Game.swift Services/HapticManager.swift Views/Library/GameCardView.swift Tests/CoverThumbnailChecks.swift -o /tmp/emu-thumbnail-checks
xcrun simctl spawn SIMULATOR_UDID /tmp/emu-thumbnail-checks
```

This checks decode dimensions, reuse, changed-file invalidation and a missing
cover. A 4096×2160 fixture decodes to 512×270 (552,960 pixel-storage bytes),
without retaining a full-sized decoded cover in the card cache. This is a
thumbnail allocation check, not an app-wide memory or frame-rate measurement.

Startup timeout checks cover plugin string-key case normalization, native small
save reads with synchronous HTTP deliberately disabled, and a held file-provider
coordination lock while another request reads a save. The 1 MiB startup snapshot
and 256 KiB file caps are verified separately from the 8 MiB runtime LRU cache.
