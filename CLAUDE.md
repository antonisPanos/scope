# Scope: notes for Claude

The app is called Scope. It was called Pandora while it was being scoped, so the scoping doc
and early history still use that name.

Personal macOS file manager. The owner doesn't write Swift; Claude writes all the code.
The scoping doc (goals, milestones M0 to M4, test plan) is at https://claude.ai/artifact/AwuXcqF6wVVC3vtkijEZ8K.

## Branches and commits

- `main` is the trunk. Branch from the latest `origin/main`, open a PR into `main`, and
  never commit to `main` directly. PRs are squash-merged.
- Commit messages and PR titles are Conventional Commits (`feat(search): add a date filter`).
  Types, scopes and examples are in `CONTRIBUTING.md`. Run `make hooks` in a fresh clone.
- `claude/project-thread-neh6mq` is the pre-`main` history, kept for reference. `main` starts
  from a squash of it at 95d4a50; don't merge that branch into `main`.

## Safety rules (never relax these)

- All file system access goes through `FileEngine` in `Packages/ScopeEngine`, and every
  path passes `PathGuard` first. Development builds (`SCOPE_DEV`) restrict it to the
  test disks in `BuildIdentity.testDiskRoots`.
- The release build uses `PathGuard.readOnly` until `SCOPE_ALLOW_WRITES` is set in
  `Config/Scope.xcconfig`. Only the owner decides to set it, after the MVP gate.
- Engine write operations must call `checkWriteLocation`, never only `checkLocation`.
- Tests that need real disk side effects (Trash) run on `/Volumes/ScopeTest` only and
  skip when it isn't mounted. Never let a test touch the user's real Trash or home.
- Never run Scope Dev, tests or scripts against real user files. Engine tests use temp
  folders with a restricted guard; manual testing uses `/Volumes/ScopeTest*` only.
- The main thread never touches disk. Copies write under `.scope-partial-` names and
  rename into place; never overwrite; delete always means Trash. The one exception
  (owner's decision on #45): on a disk with no Trash, after the user confirms a dialog
  that names the disk and every item, with Cancel as the default and no "apply to all".
- Keep the test disk list in sync in three places: `BuildIdentity.testDiskRoots`,
  `Config/ScopeDev.entitlements`, `scripts/testdisk.sh`.

## Build and test

- Engine tests: `cd Packages/ScopeEngine && swift test --no-parallel` (Swift Testing), or `make test`.
  Suites run one at a time: test helpers block pool threads, and parallel suites starve each
  other's timing checks.
- App: `xcodebuild -project Scope.xcodeproj -scheme "Scope Dev" -derivedDataPath build/DerivedData build`.
- App tests: `make app-test` runs `ScopeTests/` (Swift Testing) hosted in Scope Dev, so they run
  sandboxed and guarded. Scope Dev opens no window when it hosts tests (`AppDelegate.isHostingTests`).
  New files in `ScopeTests/` are picked up automatically, like `Scope/`.
- Schemes: `Scope Dev` (sandboxed), `Scope Dev (No Sandbox)` (for disk image mounting), `Scope` (release).
- The Xcode project is hand-written (objectVersion 77, synchronized folder `Scope/`), so new
  files in `Scope/` are picked up automatically. Build settings live in `Config/*.xcconfig`.
- `Config/Local.xcconfig` (git-ignored) sets the signing team.
- Screen capture and accessibility are not granted to the terminal. To check the app,
  run Scope Dev and drive it with `scripts/devhook.swift` (compile it once:
  `swiftc -O -o build/devhook scripts/devhook.swift`): commands, typed paths, sidebar picks,
  `state` (logged) and `snapshot:<name>` (a PNG of the window). Snapshots from the sandboxed
  build land in its container, which the terminal can't read; use the "Scope Dev (No
  Sandbox)" build for snapshots. Read results with
  `/usr/bin/log show --last 30s --predicate 'subsystem == "com.antonispanos.scope"'`.
  Snapshots don't render the sidebar (vibrancy); check it through `state`.
- Don't launch the release "Scope" build: it would read the user's real home folder.
- App layout: `Scope/Browser` (window, model, list, path bar), `Scope/Sidebar`,
  `Scope/Commands` (one command list feeds the menus and the Cmd+K palette), `Scope/Theme`.
- Every file operation goes through `OperationCenter` (engine) via `OperationsController` (app).
  Operation tests mount throwaway sparse bundles with hdiutil (`TestVolume`); never run them
  against the startup disk, whose Trash is the user's.
- If `hdiutil`/`diskutil image attach` hangs, it is usually waiting on a macOS authorization
  prompt on the user's screen: ask them to look for one. Don't kill system processes.
- Recents and Tags come from Spotlight. `scripts/testdisk.sh` turns on indexing for the test
  disks and imports the fixture folders; if they look empty, run `mdimport /Volumes/ScopeTest/attributes/tagged`.
- GitHub's runners top out at macOS 26, so CI runs the engine tests (engine targets macOS 15)
  and skips the app build until a runner has the macOS 27.2 SDK.
