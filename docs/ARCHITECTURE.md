# Scope architecture

Scope is a native AppKit browser, with SwiftUI for smaller interfaces, above a
separate Swift package for user-file access. [AGENTS.md](../AGENTS.md) contains the
canonical project and safety instructions.

## Layout

| Path | Responsibility |
| --- | --- |
| `Scope/App` | App lifecycle, settings, build identity and development hooks |
| `Scope/Browser` | Window, panes/tabs, shared folder stores, models, five views and path bar |
| `Scope/Sidebar` | Favorites, Spotlight Recents/Tags, volumes and disk images |
| `Scope/Commands` | One command registry feeds menus and the command palette |
| `Scope/Operations` | `OperationsController`, conflict/failure dialogs and activity UI |
| `Scope/Search` | Search settings and filter UI |
| `Scope/Preview` | Quick Look, metadata, Get Info and thumbnail support |
| `Scope/System` | Notifications and keeping the Mac awake during jobs |
| `Scope/Theme` | Light/dark palette |
| `Packages/ScopeEngine` | Listings, path validation, search, metadata and file-operation scheduling/execution |
| `ScopeArchiveService` | Embedded, sandboxed XPC archive decoding/encoding service |
| `Config` | Build settings, Info.plist inputs and entitlements |
| `ScopeTests` | Swift Testing app tests hosted in Scope Dev |
| `scripts/devhook.swift` | Development-only control client for a running Scope Dev |
| `scripts/make-icons.swift` | Regenerates Icon Composer assets and the README icon |
| `scripts/release.sh` | Build, verify, package and optionally upload a release DMG |

The browser uses virtualized AppKit views for large listings. Icons, Gallery and
compact List reuse collection-browser infrastructure; List fills columns vertically
and scrolls horizontally. Details uses an outline view for metadata and expanded
folders. Columns navigates folder levels. Folder stores share listings and change
notifications between tabs; view changes retain selection.

## Engine and path guard

- `FileEngine` performs user-file access off the main thread, using dedicated I/O
  threads for blocking work. Every path passes `PathGuard`. Writes use
  `checkWriteLocation`, rather than only the read/location check.
- The guard resolves parent paths, checks symlinks according to the operation,
  fails closed and logs refusals. It protects system folders, the user's home and
  standard folders, volume roots and development scratch roots from removal or relocation.
- The app starts jobs through `OperationsController` and the engine's `OperationCenter`.
  Jobs sharing a disk serialize, with busy-path protection, pause/cancel support,
  progress snapshots, queued work and bounded undo records.
- Copies stage under `.scope-partial-` names and publish after completion. Replace
  trashes the existing item rather than overwriting its contents. Cross-disk moves
  verify copied bytes before trashing the originals.
- Move to Trash uses the Trash where available. Both a no-Trash fallback and
  explicit Delete Immediately require confirmation naming the disk and every item,
  Cancel as default and no Apply to all. The engine revalidates identities before
  permanent deletion and traverses through checked descriptors without following
  links. Permanent deletion is not undoable.

## Archive isolation

Production and development embed `ScopeArchiveService.xpc`. Its only entitlement
is `com.apple.security.app-sandbox = true`: it has no user-file or network grants.
Extraction receives an already-open read-only archive descriptor; the engine
validates entry paths/links, limits sizes and free space, stages output, applies
trusted quarantine provenance and publishes the result. Every entry is created and
reopened through descriptors from the pinned staging folder, one component at a
time without following links, and published only into the archive's pinned folder.
Metadata is applied as it arrives; only sidecars waiting for their file are held,
within a fixed budget, as are the few fields needed to set final modes and dates.

Compression receives bounded entry descriptions and source bytes with backpressure.
The engine owns traversal, metadata checks, space/output budgets, staging and final
publication. Source paths and writable output handles never cross into the service.
An XPC failure does not fall back to in-process decoding or encoding in the app.

## Build identities

| Scheme | App | App Sandbox | Path guard | Purpose |
| --- | --- | --- | --- | --- |
| Scope Dev | Scope Dev, amber icon | Off | Reads anywhere, changes only `~/ScopeScratch` | Development and file-changing UI QA |
| Scope | Scope, white icon | Off | Full operations with normal macOS permissions | Production; read-only UI inspection during development |

Neither **app** uses the App Sandbox; the embedded archive service does. Scope Dev
uses `PathGuard.writesOnlyUnder`. **Go > Scratch Folder** creates the allowed root,
which cannot itself be moved, renamed or trashed. Production enables
`SCOPE_ALLOW_WRITES` in `Config/Scope.xcconfig`. All development file changes still
use Scope Dev in scratch folders, or disposable engine fixtures.

The app and XPC service target **macOS 27.2** and use Swift 6. The standalone engine
targets **macOS 15**, which allows engine tests on older runners. A synchronized
Xcode folder includes new files in `Scope/` and `ScopeTests/` automatically; build
settings are in `Config/*.xcconfig`. Local signing guidance is in
[Contributing](../CONTRIBUTING.md#setup).

## Tests and CI

From the repository root:

```sh
make test       # cd Packages/ScopeEngine && swift test --no-parallel
make app-test   # ScopeTests hosted in Scope Dev; requires the app SDK
```

Engine suites run one at a time because blocking helpers can starve timing checks
when suites compete. Tests use restricted guards and fresh temporary folders.
Trash, cross-disk and filesystem tests use owned throwaway sparse disk images
(`TestVolume`) rather than the real startup disk or user's Trash. App tests never
write files; their Scope Dev host opens no browser window.

CI runs normal engine tests and Thread Sanitizer on `macos-26`. Its app job checks
for the macOS 27.2 SDK, then builds both schemes and runs app tests when available;
otherwise that build is skipped. Lint checks changed Swift files and a separate
check validates Conventional Commit PR titles. Release packaging uses `xcode-27`
with Xcode 27.2 and never launches the app. See [Releasing](RELEASING.md).
