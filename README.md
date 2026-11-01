# Pandora

A personal file manager for macOS that sits beside Finder: tabs, dual split, a
preview pane, every classic view, a real operations queue and a search that
works, with Finder's keyboard shortcuts. Requires macOS 27.2 and Xcode 27.

Milestones done: M0 (project, file engine with its path guard, test disks, CI),
M1 (the browse window) and M2 (views and preview). File operations such as
copy and move arrive in M3.

## What M2 adds

- Five views: Icons (Cmd+1), Details (Cmd+2), Columns (Cmd+3), Gallery
  (Cmd+4) and List (Cmd+5), from the View menu or the toolbar. The selection
  carries over when you switch.
- Icon grid that re-flows to the window width, with thumbnails from Quick
  Look. Size it with the slider in the status bar, Cmd+= and Cmd+-, or a pinch.
  Thumbnails held in memory are capped at 64 MB; Pandora keeps no disk cache.
- Gallery: a large preview of the selected item over a strip of thumbnails.
- Preview pane on the right in every view (Shift+Cmd+P): a Quick Look preview
  plus size, dates, last opened, tags, where, and for images their dimensions
  and camera, for audio and video their length, for folders their item count.
- Quick Look on Space or Cmd+Y; arrow keys in the panel move the selection.

## What M1 does

- Tabs: macOS window tabs. Cmd+T opens a tab, Cmd+N a window, and tabs can be
  dragged out or merged like in any Mac app.
- Sidebar: Favorites (Recents, Applications, Desktop, Documents, Downloads,
  Home, and folders you add with Ctrl+Cmd+T), Locations, Disk Images with the
  file each came from and an Eject button, and Tags.
- Path bar: click a part to go there, or click the empty space (or press Cmd+L
  or Shift+Cmd+G) and type a path: absolute, relative, `~`, or pasted.
- Views: Details (Cmd+2, columns you can sort, resize, reorder and show or hide
  from the header's menu, folders that expand in place) and List (Cmd+5).
- Command palette: Cmd+K finds any command or place, or goes to a typed path.
- Finder shortcuts: Cmd+[ and Cmd+] for back and forward, Cmd+Up and Cmd+Down
  for out and in, Shift+Cmd+. for hidden files, Ctrl+Option+Cmd+1 to 7 to sort,
  Shift+Cmd+H/D/O/A/F and Option+Cmd+L for standard places, Cmd+E to eject.
- Live updates: a folder on screen refreshes when its contents change.
- Light and dark mode with Pandora's palette.

In Pandora Dev, places outside the test disks show dimmed and can't be opened,
and the status bar says "Pandora Dev · test disks only".

## Layout

| Path | What it is |
| --- | --- |
| `Pandora/` | The app (AppKit shell, SwiftUI where scale doesn't matter) |
| `Packages/PandoraEngine/` | The file engine: listing and file operations, all behind the path guard |
| `Config/` | Build settings and entitlements for each build |
| `scripts/testdisk.sh` | Builds and manages the throwaway test disks |
| `scripts/make-icons.swift` | Redraws the placeholder app icons |
| `scripts/devhook.swift` | Drives a running Pandora Dev from the terminal (development only) |

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
