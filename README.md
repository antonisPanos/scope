# Pandora

A personal file manager for macOS that sits beside Finder: tabs, dual split, a
preview pane, every classic view, a real operations queue and a search that
works, with Finder's keyboard shortcuts. Requires macOS 27.2 and Xcode 27.

This is milestone M0: the project, the file engine with its path guard, the
test disks and CI. There is no browser window yet; Pandora Dev opens a status
window that shows the build type and lists the test disk.

## Layout

| Path | What it is |
| --- | --- |
| `Pandora/` | The app (AppKit shell, SwiftUI where scale doesn't matter) |
| `Packages/PandoraEngine/` | The file engine: listing and file operations, all behind the path guard |
| `Config/` | Build settings and entitlements for each build |
| `scripts/testdisk.sh` | Builds and manages the throwaway test disks |
| `scripts/make-icons.swift` | Redraws the placeholder app icons |

## The three builds

| Scheme | App | Sandbox | Path guard | Use it for |
| --- | --- | --- | --- | --- |
| Pandora Dev | Pandora Dev (amber icon) | On, test disks only | Test disks only | All testing |
| Pandora Dev (No Sandbox) | Pandora Dev | Off | Test disks only | Mounting disk images (hdiutil can't run sandboxed) |
| Pandora | Pandora (teal icon) | Off | Read-only: every change is refused | The real app, after the MVP gate |

Development builds can only touch `/Volumes/PandoraTest`, `/Volumes/PandoraTest2`
and `/Volumes/PandoraTestCS`. The App Sandbox enforces that in the kernel, and
the engine's path guard enforces it again in Pandora's own code, after
resolving symlinks, and logs a fault for every refusal.

The real Pandora build can read anything but changes nothing: its engine
refuses every write until `PANDORA_ALLOW_WRITES` is added to
`Config/Pandora.xcconfig`, which is a deliberate step for after the MVP gate.

## Getting started

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then put your team ID in it
scripts/testdisk.sh create                               # about 2 GB on disk, 15 seconds
open Pandora.xcodeproj                                   # pick the "Pandora Dev" scheme, press Cmd+R
```

Without `Config/Local.xcconfig` the app is signed ad hoc, which also runs, but
macOS then treats every build as a new app.

From the command line:

```bash
xcodebuild -project Pandora.xcodeproj -scheme "Pandora Dev" -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Pandora Dev.app"
```

## Tests

```bash
cd Packages/PandoraEngine && swift test
```

In Xcode, choose the PandoraEngine scheme and press Cmd+U. Engine tests run in
fresh temporary folders with a path guard limited to that folder, never on real
files. The Trash test needs a disk of its own, so it runs in a scratch folder on
the test disk when that is mounted and is skipped otherwise; it never uses your
real Trash. CI runs them on every push.

## Test disks

`scripts/testdisk.sh` makes three growable APFS images in `~/PandoraTestDisks`
and mounts them:

- `/Volumes/PandoraTest`: up to 5 GB, with fixtures for Unicode names, symlinks
  and aliases, packages, attributes and flags, large files, a folder of 100,000
  files, archives (including malicious ones) and small disk images. See its README.txt.
- `/Volumes/PandoraTest2`: a small second disk for moves between disks.
- `/Volumes/PandoraTestCS`: a small case-sensitive disk for name clashes.

`reset` rebuilds them from scratch, `eject` and `mount` do what they say,
`status` shows what exists, and `destroy` deletes the images.
