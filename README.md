<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Scope app icon">
</p>

<h1 align="center">Scope</h1>

<p align="center">
  <strong>A native file manager for macOS, built to sit beside Finder.</strong><br>
  Five views, tabs, dual panes, streaming search and a file operations queue.
</p>

<p align="center">
  <a href="https://github.com/antonisPanos/scope/actions/workflows/ci.yml"><img src="https://github.com/antonisPanos/scope/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/antonisPanos/scope/releases/latest"><img src="https://img.shields.io/github/v/release/antonisPanos/scope?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-27.2%2B-blue" alt="macOS 27.2 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/split-view-dark.png">
  <img src="docs/images/split-view.png" alt="Scope with a fictional design project in Details on the left and tagged coastal artwork in Icons on the right">
</picture>
</p>

## Browse, compare and organize

- **Five views:** Icons, Details, Columns, Gallery and List (`Cmd+1` through `Cmd+5`).
  List fills compact columns from top to bottom and scrolls horizontally;
  Details supports sortable columns and expandable folders.
- **Tabs and dual panes:** keep places open, compare two folders, and copy or move
  the selection to the other side (`Ctrl+Cmd+C` / `Ctrl+Cmd+M`).
- **Finder color tags:** see tags on folders, thumbnails and filenames; apply them
  from the context menu. Metadata changes refresh without losing your place.
- **Preview and navigation:** Quick Look, an optional details pane, an editable path
  bar, Back/Forward history and a command palette (`Cmd+K`).
- **Search:** stream results from the current folder and its subfolders using a
  name, glob or regular expression. Filter by kind, size, modification date and
  tag, or use Contents (Spotlight) for indexed file contents.
- **File operations:** copy, move, duplicate, rename, create folders, compress to ZIP,
  extract archives, and mount or eject disk images. The activity drawer shows job
  status, progress, pause/cancel controls and queued work. Undo is available for
  supported file changes, including completed steps of a cancelled job.

The [user guide](docs/USER_GUIDE.md) covers the views, shortcuts, settings and operation limits.

## A closer look

| | |
| --- | --- |
| <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/browser-icons-dark.png"><img src="docs/images/browser-icons.png" alt="Icons view showing six original coastal illustrations with Finder color tags"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/details-dark.png"><img src="docs/images/details.png" alt="Details view with tagged project folders and expanded artwork"></picture> |
| **Icons:** resizable thumbnails and color tags | **Details:** sortable metadata and expandable folders |
| <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/search-dark.png"><img src="docs/images/search.png" alt="A glob search for JPG artwork across a fictional studio project"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/activity-dark.png"><img src="docs/images/activity.png" alt="Scope Dev activity drawer after compressing disposable coastal artwork, with Undo available"></picture> |
| **Search:** patterns and filters across subfolders | **Activity:** inspect jobs and undo supported changes |

[Gallery, Columns and List screenshots](docs/USER_GUIDE.md#views-and-preview) show the other views.
All captures use the actual app with an original, disposable demo project; see
[screenshot provenance](docs/images/README.md).

## Care with your files

- Copies are staged under hidden `.scope-partial-` names and published when complete.
  Replace puts the previous item in the Trash rather than overwriting its contents.
- Moves between disks verify file contents with SHA-256 before trashing the originals.
- **Move to Trash** uses the Trash when available. A disk without Trash requires
  confirmation before permanent deletion. **Delete Immediately** (`Option+Cmd+Delete`)
  also requires confirmation for each disk, naming every item. Permanent deletion has no Undo.
- Archive extraction rejects unsafe paths and links. Archive codecs run in a separate
  sandboxed service; the engine validates entries and controls file access.
- File I/O runs off the main thread. Jobs support cancellation and clean up unfinished copies.

## Install

Download the DMG from the [latest release](https://github.com/antonisPanos/scope/releases/latest),
open it, and drag **Scope** to **Applications**. The app requires **macOS 27.2 or later**.
The engine's lower macOS target does not make the app compatible with macOS 15.

Releases currently use an **ad-hoc signed app, without notarization or an Apple-verified
publisher identity**. After macOS blocks first launch, use **System Settings > Privacy
& Security > Open Anyway** for Scope. See [Apple's per-app instructions](https://support.apple.com/en-us/102445).
The release includes a matching `.dmg.sha256` file to verify the download:

```sh
# In the folder containing both downloaded files; substitute your version.
shasum -a 256 -c Scope-0.3.0.dmg.sha256
```

Scope is early 0.x software. Production Scope supports full file operations with
normal macOS permissions. Scope Dev restricts file changes to `~/ScopeScratch`.

The [Back/Forward validation fix (#139)](https://github.com/antonisPanos/scope/pull/139)
and [compact horizontal List layout (#140)](https://github.com/antonisPanos/scope/pull/140)
merged into `main` after v0.3.0 for the v0.4.0 release.
The screenshots show that merged source; v0.3.0 has the earlier vertical List.
Check the [release notes](https://github.com/antonisPanos/scope/releases) for the installer version.

## Build from source

Use **macOS 27.2+** and **Xcode 27.2** (or a compatible newer Xcode) with the
**macOS 27.2 SDK or newer**. Local ad-hoc builds do not require a paid Apple account.

```sh
git clone https://github.com/antonisPanos/scope.git
cd scope
make hooks
make build      # Scope Dev; changes files only inside ~/ScopeScratch
make test       # standalone engine tests, one suite at a time
make app-test   # app tests hosted in Scope Dev
open "build/DerivedData/Build/Products/Debug/Scope Dev.app"
```

Without `Config/Local.xcconfig`, builds sign ad hoc. `make setup` additionally creates
that optional file for Apple Development signing; replace its `YOURTEAMID` placeholder
before building. See [Contributing](CONTRIBUTING.md) for signing overrides and workflow.
Run `make` for all tasks, including `make install-dev` and local DMG packaging.

## Project

- [User guide](docs/USER_GUIDE.md)
- [Architecture and safety boundaries](docs/ARCHITECTURE.md)
- [Project instructions for agents](AGENTS.md)
- [Changelog](CHANGELOG.md)
- [Release process](docs/RELEASING.md)
- [Report a bug or suggest a feature](https://github.com/antonisPanos/scope/issues/new/choose)
