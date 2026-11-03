# Scope: project instructions

The app is called Scope. It was called Pandora while it was being scoped, so the scoping doc
and early history still use that name.

Personal macOS file manager. The owner doesn't write Swift; coding agents implement and maintain the code.
The historical scoping doc (goals, milestones M0 to M4, test plan) is at
https://claude.ai/artifact/AwuXcqF6wVVC3vtkijEZ8K (may require the owner's account).
Use the current source and repository docs for present behavior and requirements.

## Branches and commits

- Use `codex/` for agent-created branches (for example `codex/docs-refresh`).
- `main` is the trunk. Branch from the latest `origin/main`, open a PR into `main`, and
  never commit to `main` directly. PRs are squash-merged.
- Commit messages and PR titles are Conventional Commits (`feat(search): add a date filter`).
  Types, scopes and examples are in `CONTRIBUTING.md`. Run `make hooks` in a fresh clone.
- `claude/project-thread-neh6mq` is the pre-`main` history, kept for reference. `main` starts
  from a squash of it at 95d4a50; don't merge that branch into `main`.

## Safety rules (never relax these)

- All file system access goes through `FileEngine` in `Packages/ScopeEngine`, and every
  path passes `PathGuard` first. Neither build runs in the App Sandbox.
- Development builds (`SCOPE_DEV`, "Scope Dev") use `PathGuard.writesOnlyUnder`: they read
  anywhere but change files only inside `~/ScopeScratch` (`BuildIdentity.scratchFolder`).
- Production builds (`Scope`) enable `SCOPE_ALLOW_WRITES` by default and use normal
  macOS file permissions (owner's decision, 2026-11-02). Development restrictions belong
  in `Scope Dev`; file-changing QA must still use scratch folders or disposable fixtures.
- Engine write operations must call `checkWriteLocation`, never only `checkLocation`.
- Engine tests use temp folders with a restricted guard, and throwaway disk images
  (`TestVolume`) for anything with disk side effects (Trash, moves between disks). Never let
  a test touch the user's real Trash, home or files. App tests never write files.
- Scope Dev and Scope may be launched over Remote Control to check a change. They read the
  user's real files, so only browse and look; anything that changes files happens in
  `~/ScopeScratch` only, and only in Scope Dev.
- The main thread never touches disk. Copies write under `.scope-partial-` names and
  rename into place; never overwrite; delete always means Trash. Two exceptions, both
  only after the user confirms a dialog that names the disk and every item, with Cancel
  as the default and no "apply to all": a disk with no Trash (owner's decision on #45),
  and Delete Immediately (⌥⌘⌫, owner's request 2026-11-02), which asks once per disk
  before anything is removed.

## Build and test

- Engine tests: `cd Packages/ScopeEngine && swift test --no-parallel` (Swift Testing), or `make test`.
  Suites run one at a time: test helpers block pool threads, and parallel suites starve each
  other's timing checks.
- App: `xcodebuild -project Scope.xcodeproj -scheme "Scope Dev" -derivedDataPath build/DerivedData build`.
- App tests: `make app-test` runs `ScopeTests/` (Swift Testing) hosted in Scope Dev, so they run
  guarded. Scope Dev opens no window when it hosts tests (`AppDelegate.isHostingTests`).
  New files in `ScopeTests/` are picked up automatically, like `Scope/`.
- Schemes: `Scope Dev` (development, writes only in `~/ScopeScratch`) and `Scope` (release).
- The Xcode project is hand-written (objectVersion 77, synchronized folder `Scope/`), so new
  files in `Scope/` are picked up automatically. Build settings live in `Config/*.xcconfig`.
- The app requires macOS 27.2 and Xcode 27.2 with the macOS 27.2 SDK. The standalone engine targets macOS 15 and Swift 6.
- `Config/Local.xcconfig` (git-ignored) optionally sets a local signing team. Without it, builds use ad-hoc signing; do not leave the `YOURTEAMID` placeholder from `make setup`. See `CONTRIBUTING.md`.
- Screen capture and accessibility are not granted to the terminal. To check the app,
  run Scope Dev and drive it with `scripts/devhook.swift` (compile it once:
  `swiftc -O -o build/devhook scripts/devhook.swift`): commands, typed paths, sidebar picks,
  `state` (logged) and `snapshot:<name>` (a PNG of the window). Read results with
  `/usr/bin/log show --last 30s --predicate 'subsystem == "com.antonispanos.scope"'`.
  Snapshots may omit vibrancy and remote Quick Look content; check the actual app too.
  While remote control shares the window, `snapshot` may select a system sharing child window.
  Never commit captures containing personal paths or content; use disposable demo fixtures.
  Retain intentional documentation images, then clean up only owned fixtures, builds and temporary worktrees/branches after pushing.
- App layout: `Scope/Browser` (window, model, list, path bar), `Scope/Sidebar`,
  `Scope/Commands` (one command list feeds the menus and the Cmd+K palette), `Scope/Theme`.
- Archive decoding and encoding run in `ScopeArchiveService/`, an embedded XPC service with
  no user-file or network entitlements (`Config/ScopeArchiveService.entitlements`; keep its grants empty; retain only `com.apple.security.app-sandbox = true`).
  Extraction receives only an open read-only archive; the engine checks and writes every entry.
  Compression receives bounded entry descriptions and source bytes, and returns bounded encoded
  bytes with backpressure. The engine owns source traversal, metadata, output size/space limits,
  staging and final publication. Never pass compression source paths or writable output handles
  to the service, or fall back to the in-process codec when an XPC connection fails.
- Every file operation goes through `OperationCenter` (engine) via `OperationsController` (app).
  Operation tests mount throwaway sparse bundles with hdiutil (`TestVolume`); never run them
  against the startup disk, whose Trash is the user's.
- If `hdiutil`/`diskutil image attach` hangs, it is usually waiting on a macOS authorization
  prompt on the user's screen: ask them to look for one. Don't kill system processes.
- Recents and Tags come from Spotlight, over the whole computer.
- Engine CI uses macOS 26 (engine targets macOS 15). The release workflow uses `xcode-27`
  with Xcode 27.2 to build and publish ad-hoc signed DMGs without launching the app.
  The existing app CI job on macOS 26 skips its build when the 27.2 SDK is unavailable.

<!-- CODEGRAPH_START -->
## CodeGraph

Use CodeGraph before grep/find or reading files to locate or understand code **only if**
a `.codegraph/` directory exists at the repository root. Use the `codegraph_explore` MCP
tool, or `codegraph explore "<symbol names or question>"`; name a file or symbol for
current line-numbered source. If `.codegraph/` is absent, skip CodeGraph entirely.
Do not create an index automatically; indexing is the owner's decision.
<!-- CODEGRAPH_END -->
