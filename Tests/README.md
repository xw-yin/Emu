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

The existing macOS build workflow runs both offline JavaScript checks and native
server checks before building the app. No game files are required; native checks
create and remove their own temporary directory.

## Changes under test

- Native save snapshot is installed before each main-document navigation. The
  original document's pending saves are drained on reload before the next snapshot.
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

Open the affected game, reach the title, load an existing PC save, make a new save,
reload the page, then exit/reopen and load it again. Repeat with an MV and an MZ
game. Confirm the log names the storage bridge before engine startup. If startup
takes more than 15 seconds, inspect the diagnostic line for the active scene,
missing database files, pending images, and font states.

The current Windows workspace cannot compile or execute WebKit/Network.framework.
The JavaScript tests and upstream MV integration were run locally; the macOS checks
are provided for the next build and must not be represented as already passed.
