# Scope user guide

Everything Scope does, grouped by area, with its keyboard shortcuts. Scope follows
Finder's shortcuts wherever Finder has one.

## Windows, tabs and the sidebar

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

Scope Dev reads anywhere but changes files only in `~/ScopeScratch` (Go >
Scratch Folder), and its status bar says so.

## Views and preview

- Five views: Icons (Cmd+1), Details (Cmd+2), Columns (Cmd+3), Gallery
  (Cmd+4) and List (Cmd+5), from the View menu or the toolbar. The selection
  carries over when you switch.
- Icon grid that re-flows to the window width, with thumbnails from Quick
  Look. Size it with the slider in the status bar, Cmd+= and Cmd+-, or a pinch.
  Thumbnails held in memory are capped at 64 MB; Scope keeps no disk cache.
- Gallery: a large preview of the selected item over a strip of thumbnails.
- Finder color tags appear as colored dots in every view, on folder icons
  and thumbnails in Icons and Gallery, and beside filenames in the other
  views. Changes refresh without losing the selection or open columns.
  Examples: [light appearance](images/color-tags-light.png),
  [dark appearance](images/color-tags-dark.png), and [Columns](images/color-tags-columns.png).
- Preview pane on the right in every view (Shift+Cmd+P): a Quick Look preview
  plus size, dates, last opened, tags, where, and for images their dimensions
  and camera, for audio and video their length, for folders their item count.
- Quick Look on Space or Cmd+Y; arrow keys in the panel move the selection.

## File operations

- Copy (Cmd+C) and Paste (Cmd+V), Move Item Here (Option+Cmd+V), Duplicate
  (Cmd+D), Rename (Return), New Folder (Shift+Cmd+N), Move to Trash
  (Cmd+Delete), Compress, Extract, Mount Disk Image, Eject (Cmd+E), Copy Path
  (Option+Cmd+C), all also in the right-click menu with Open With.
- Drag and drop between folders and from Finder: a move on the same disk, a
  copy across disks or with Option held.
- Undo (Cmd+Z) for every operation, including a cancelled one's finished part.
- Archives preserve resource forks, FinderInfo, tags, other ordinary extended
  attributes, permissions and modification dates using standard AppleDouble
  records. ZIPs interoperate with Finder/ditto; non-Mac tools may show `__MACOSX`
  or `._` sidecars. Metadata is limited to 64 MB per item; exceeding it fails
  without publishing an archive. Compression refuses custom ACLs or file flags
  it cannot preserve. Ownership and creation dates are not retained, so use a
  backup tool when those matter. Download quarantine comes from the archive's
  provenance, never untrusted metadata stored inside it. Repacking a downloaded
  file also marks the new archive as quarantined.
- When a name is taken: Keep Both, Replace (the old item goes to the Trash),
  Skip or Stop, with "Apply to all".
- The activity drawer (Option+Cmd+A or the toolbar ring) lists every
  operation with progress, speed, time running and left, Pause, Cancel, the
  queue with Start Now and reordering, and Undo for finished ones. The Dock
  icon shows a progress bar.
- Some disks, such as certain network shares, have no Trash. Deleting there
  asks first, naming the disk and every item; Cancel is the default, and only
  Delete Permanently removes them. Items on other disks still go to the Trash.
- Safety: nothing is overwritten, and nothing is deleted without asking. Copies are written under a hidden
  partial name and renamed into place; moves between disks verify every
  file's SHA-256 before the original goes to the Trash; archive entries with
  ../ or absolute paths, or that would write through a link, are skipped.
  Operations on the same disk run one at a time; held-down Cmd+Delete and
  Cmd+V don't repeat; items in a running operation can't be touched by another.

## Split view and search

- Search (Cmd+F or the toolbar field) in the folder on screen and its
  subfolders, with Scope's own crawler instead of the Spotlight index:
  name contains, a pattern (`*.pdf`, `IMG_2026*`) or a regular expression.
  The filter bar adds hidden files, subfolders (on by default), inside
  packages, kind, size, date modified and tag. Results stream in as they're
  found; Stop or Escape ends the crawl at once. A Where column shows each
  result's folder. "Contents (Spotlight)" searches inside files instead.
- Split view (Shift+Cmd+S, the toolbar button, or "Open in Split View" on a
  folder's right-click menu): two panes side by side, each with its own tabs
  (Cmd+T adds one on the focused side, Cmd+W closes it). Focus follows clicks,
  or Option+Cmd+Left/Right. Copy to Other Side (Ctrl+Cmd+C) and Move to Other
  Side (Ctrl+Cmd+M), or drag between the panes. The preview pane and the path
  bar hide while split is on; Cmd+L opens the command palette with the path
  to edit instead.
