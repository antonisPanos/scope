# Scope architecture

Scope is a native macOS app: an AppKit shell, with SwiftUI where scale doesn't matter, on top of
a file engine in its own Swift package. Nothing touches the disk except through the engine.

## Layout

| Path | What it is |
| --- | --- |
| `Scope/` | The app (AppKit shell, SwiftUI where scale doesn't matter) |
| `Packages/ScopeEngine/` | The file engine: listing and file operations, all behind the path guard |
| `Config/` | Build settings and entitlements for each build |
| `scripts/make-icons.swift` | Redraws the app icons |
| `scripts/devhook.swift` | Drives a running Scope Dev from the terminal (development only) |

| App folder | What's in it |
| --- | --- |
| `Scope/App` | App delegate, settings, build identity, dev hooks |
| `Scope/Browser` | The window, the browser model, the views, the path bar |
| `Scope/Sidebar` | Favorites, locations, disk images, tags |
| `Scope/Commands` | One command list that feeds the menus and the Cmd+K palette |
| `Scope/Operations` | `OperationsController` and the activity drawer |
| `Scope/Search` | Search and its filter bar |
| `Scope/Preview` | The preview pane |
| `Scope/System` | System integrations: notifications, keeping the Mac awake during jobs |
| `Scope/Theme` | Scope's palette, light and dark |

## The engine and its path guard

- `FileEngine` in `Packages/ScopeEngine` does all listing and every file change, off the main thread.
- Every path passes `PathGuard` first, after symlinks are resolved. Write operations call
  `checkWriteLocation`, and each refusal is logged as a fault.
- `OperationCenter` runs copies, moves, trash, compress and extract as jobs you can pause and
  cancel. The app reaches it through `OperationsController`. Jobs on the same disk run one at a time.
- Copies are written under a hidden `.scope-partial-` name and renamed into place. Nothing is
  overwritten, and deletes always go to the Trash. A disk with no Trash is the one exception: the
  engine asks the app (`confirmPermanentDeletion`), which names the disk and every item, and only
  a yes removes them, through open folders that never follow a link (`PermanentDelete.swift`).

The engine targets macOS 15 so its tests run on GitHub's hosted runners; the app needs macOS 27.2.

## The two builds

| Scheme | App | Sandbox | Path guard | Use it for |
| --- | --- | --- | --- | --- |
| Scope Dev | Scope Dev (amber squares) | Off | Reads anywhere, changes only `~/ScopeScratch` | All testing |
| Scope | Scope (white squares) | Off | Full file operations with normal macOS permissions | Production |

Neither build runs in the App Sandbox: a file manager has to reach every
folder, and mounting disk images (hdiutil) can't run sandboxed. The engine's
path guard does the limiting, in Scope's own code, after resolving symlinks,
and logs a fault for every refusal.

Scope Dev may read anything, but it changes files only inside `~/ScopeScratch`
(`PathGuard.writesOnlyUnder`). The folder itself can't be renamed, moved or
trashed; Go > Scratch Folder creates it.

Production Scope enables `SCOPE_ALLOW_WRITES` in `Config/Scope.xcconfig` by
default. File operations still go through the engine's path guard and macOS
permissions. File-changing development and QA use Scope Dev or disposable
engine fixtures.

## Tests

```bash
cd Packages/ScopeEngine && swift test
```

In Xcode, choose the ScopeEngine scheme and press Cmd+U. Engine tests run in
fresh temporary folders with a path guard limited to that folder, never on real
files. Tests with disk side effects (Trash, moves between disks, FAT volumes,
the 100,000-file speed checks) mount a small sparse disk image of their own
(`TestVolume`) in the temporary folder and detach and delete it afterwards, so
they never use your real Trash. CI runs them on every push.
