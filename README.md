# Scope

A personal file manager for macOS that sits beside Finder: tabs, dual split, a
preview pane, every classic view, a real operations queue and a search that
works, with Finder's keyboard shortcuts. Requires macOS 27.2 and Xcode 27.

Milestones done: M0 (project, file engine with its path guard, test disks, CI),
M1 (the browse window), M2 (views and preview), M3 (file operations) and M4
(split view and search), which completes the MVP list.

## What M4 adds

- Search (Cmd+F or the toolbar field) in the folder on screen and its
  subfolders, with Scope's own crawler instead of the Spotlight index:
  name contains, a pattern (`*.pdf`, `IMG_2026*`) or a regular expression.
  The filter bar adds hidden files, subfolders (on by default), inside
  packages, kind, size, date modified and tag. Results stream in as they're
  found; Stop or Escape ends the crawl at once. A Where column shows each
  result's folder. "Contents (Spotlight)" searches inside files instead.
- Split view (Shift+Cmd+S): two panes side by side, each with its own tabs
  (Cmd+T adds one on the focused side, Cmd+W closes it). Focus follows clicks,
  or Option+Cmd+Left/Right. Copy to Other Side (Ctrl+Cmd+C) and Move to Other
  Side (Ctrl+Cmd+M), or drag between the panes. The preview pane hides while
  split is on.

## What M3 adds

- Copy (Cmd+C) and Paste (Cmd+V), Move Item Here (Option+Cmd+V), Duplicate
  (Cmd+D), Rename (Return), New Folder (Shift+Cmd+N), Move to Trash
  (Cmd+Delete), Compress, Extract, Mount Disk Image, Eject (Cmd+E), Copy Path
  (Option+Cmd+C), all also in the right-click menu with Open With.
- Drag and drop between folders and from Finder: a move on the same disk, a
  copy across disks or with Option held.
- Undo (Cmd+Z) for every operation, including a cancelled one's finished part.
- When a name is taken: Keep Both, Replace (the old item goes to the Trash),
  Skip or Stop, with "Apply to all".
- The activity drawer (Option+Cmd+A or the toolbar ring) lists every
  operation with progress, speed, time running and left, Pause, Cancel, the
  queue with Start Now and reordering, and Undo for finished ones. The Dock
  icon shows a progress bar.
- Safety: nothing is overwritten or deleted. Copies are written under a hidden
  partial name and renamed into place; moves between disks verify every
  file's SHA-256 before the original goes to the Trash; archive entries with
  ../ or absolute paths, or that would write through a link, are skipped.
  Operations on the same disk run one at a time; held-down Cmd+Delete and
  Cmd+V don't repeat; items in a running operation can't be touched by another.

## What M2 adds

- Five views: Icons (Cmd+1), Details (Cmd+2), Columns (Cmd+3), Gallery
  (Cmd+4) and List (Cmd+5), from the View menu or the toolbar. The selection
  carries over when you switch.
- Icon grid that re-flows to the window width, with thumbnails from Quick
  Look. Size it with the slider in the status bar, Cmd+= and Cmd+-, or a pinch.
  Thumbnails held in memory are capped at 64 MB; Scope keeps no disk cache.
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
- Light and dark mode with Scope's palette.

In Scope Dev, places outside the test disks show dimmed and can't be opened,
and the status bar says "Scope Dev · test disks only".

## Layout

| Path | What it is |
| --- | --- |
| `Scope/` | The app (AppKit shell, SwiftUI where scale doesn't matter) |
| `Packages/ScopeEngine/` | The file engine: listing and file operations, all behind the path guard |
| `Config/` | Build settings and entitlements for each build |
| `scripts/testdisk.sh` | Builds and manages the throwaway test disks |
| `scripts/make-icons.swift` | Redraws the placeholder app icons |
| `scripts/devhook.swift` | Drives a running Scope Dev from the terminal (development only) |

## The three builds

| Scheme | App | Sandbox | Path guard | Use it for |
| --- | --- | --- | --- | --- |
| Scope Dev | Scope Dev (amber icon) | On, test disks only | Test disks only | All testing |
| Scope Dev (No Sandbox) | Scope Dev | Off | Test disks only | Mounting disk images (hdiutil can't run sandboxed) |
| Scope | Scope (teal icon) | Off | Read-only: every change is refused | The real app, after the MVP gate |

Development builds can only touch `/Volumes/ScopeTest`, `/Volumes/ScopeTest2`
and `/Volumes/ScopeTestCS`. The App Sandbox enforces that in the kernel, and
the engine's path guard enforces it again in Scope's own code, after
resolving symlinks, and logs a fault for every refusal.

The real Scope build can read anything but changes nothing: its engine
refuses every write until `SCOPE_ALLOW_WRITES` is added to
`Config/Scope.xcconfig`, which is a deliberate step for after the MVP gate.

## Getting started

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then put your team ID in it
scripts/testdisk.sh create                               # about 2 GB on disk, 15 seconds
open Scope.xcodeproj                                   # pick the "Scope Dev" scheme, press Cmd+R
```

Without `Config/Local.xcconfig` the app is signed ad hoc, which also runs, but
macOS then treats every build as a new app.

From the command line:

```bash
xcodebuild -project Scope.xcodeproj -scheme "Scope Dev" -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Scope Dev.app"
```

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
