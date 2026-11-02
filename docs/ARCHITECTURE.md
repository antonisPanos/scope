# Scope architecture

Scope is a native macOS app: an AppKit shell, with SwiftUI where scale doesn't matter, on top of
a file engine in its own Swift package. Nothing touches the disk except through the engine.

## Layout

| Path | What it is |
| --- | --- |
| `Scope/` | The app (AppKit shell, SwiftUI where scale doesn't matter) |
| `Packages/ScopeEngine/` | The file engine: listing and file operations, all behind the path guard |
| `Config/` | Build settings and entitlements for each build |
| `scripts/testdisk.sh` | Builds and manages the throwaway test disks |
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

## The three builds

| Scheme | App | Sandbox | Path guard | Use it for |
| --- | --- | --- | --- | --- |
| Scope Dev | Scope Dev (amber squares) | On, test disks only | Test disks only | All testing |
| Scope Dev (No Sandbox) | Scope Dev | Off | Test disks only | Mounting disk images (hdiutil can't run sandboxed) |
| Scope | Scope (white squares) | Off | Read-only: every change is refused | The real app, after the MVP gate |

Development builds can only touch `/Volumes/ScopeTest`, `/Volumes/ScopeTest2`
and `/Volumes/ScopeTestCS`. The App Sandbox enforces that in the kernel, and
the engine's path guard enforces it again in Scope's own code, after
resolving symlinks, and logs a fault for every refusal.

The real Scope build can read anything but changes nothing: its engine
refuses every write until `SCOPE_ALLOW_WRITES` is added to
`Config/Scope.xcconfig`, which is a deliberate step for after the MVP gate.

## Tests

```bash
cd Packages/ScopeEngine && swift test
```

In Xcode, choose the ScopeEngine scheme and press Cmd+U. Engine tests run in
fresh temporary folders with a path guard limited to that folder, never on real
files. The Trash test needs a disk of its own, so it runs in a scratch folder on
the test disk when that is mounted and is skipped otherwise; it never uses your
real Trash. CI runs them on every push.

## Test disks

`scripts/testdisk.sh` makes three growable APFS images in `~/ScopeTestDisks`
and mounts them:

- `/Volumes/ScopeTest`: up to 5 GB, with fixtures for Unicode names, symlinks
  and aliases, packages, attributes and flags, large files, a folder of 100,000
  files, archives (including malicious ones) and small disk images. See its README.txt.
- `/Volumes/ScopeTest2`: a small second disk for moves between disks.
- `/Volumes/ScopeTestCS`: a small case-sensitive disk for name clashes.

`reset` rebuilds them from scratch, `eject` and `mount` do what they say,
`status` shows what exists, and `destroy` deletes the images.
