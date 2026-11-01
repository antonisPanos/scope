# Pandora: notes for Claude

Personal macOS file manager. The owner doesn't write Swift; Claude writes all the code.
The scoping doc (goals, milestones M0 to M4, test plan) is at https://claude.ai/artifact/AwuXcqF6wVVC3vtkijEZ8K.

## Safety rules (never relax these)

- All file system access goes through `FileEngine` in `Packages/PandoraEngine`, and every
  path passes `PathGuard` first. Development builds (`PANDORA_DEV`) restrict it to the
  test disks in `BuildIdentity.testDiskRoots`.
- The release build uses `PathGuard.readOnly` until `PANDORA_ALLOW_WRITES` is set in
  `Config/Pandora.xcconfig`. Only the owner decides to set it, after the MVP gate.
- Engine write operations must call `checkWriteLocation`, never only `checkLocation`.
- Tests that need real disk side effects (Trash) run on `/Volumes/PandoraTest` only and
  skip when it isn't mounted. Never let a test touch the user's real Trash or home.
- Never run Pandora Dev, tests or scripts against real user files. Engine tests use temp
  folders with a restricted guard; manual testing uses `/Volumes/PandoraTest*` only.
- The main thread never touches disk. Copies write under `.pandora-partial-` names and
  rename into place; never overwrite; delete always means Trash.
- Keep the test disk list in sync in three places: `BuildIdentity.testDiskRoots`,
  `Config/PandoraDev.entitlements`, `scripts/testdisk.sh`.

## Build and test

- Engine tests: `cd Packages/PandoraEngine && swift test` (Swift Testing).
- App: `xcodebuild -project Pandora.xcodeproj -scheme "Pandora Dev" -derivedDataPath build/DerivedData build`.
- Schemes: `Pandora Dev` (sandboxed), `Pandora Dev (No Sandbox)` (for disk image mounting), `Pandora` (release).
- The Xcode project is hand-written (objectVersion 77, synchronized folder `Pandora/`), so new
  files in `Pandora/` are picked up automatically. Build settings live in `Config/*.xcconfig`.
- `Config/Local.xcconfig` (git-ignored) sets the signing team.
- Screen capture and accessibility are not granted to the terminal. To check the app,
  run Pandora Dev and drive it with `scripts/devhook.swift` (compile it once:
  `swiftc -O -o build/devhook scripts/devhook.swift`): commands, typed paths, sidebar picks,
  `state` (logged) and `snapshot:<name>` (a PNG of the window). Snapshots from the sandboxed
  build land in its container, which the terminal can't read; use the "Pandora Dev (No
  Sandbox)" build for snapshots. Read results with
  `/usr/bin/log show --last 30s --predicate 'subsystem == "com.antonispanos.pandora"'`.
  Snapshots don't render the sidebar (vibrancy); check it through `state`.
- Don't launch the release "Pandora" build: it would read the user's real home folder.
- App layout: `Pandora/Browser` (window, model, list, path bar), `Pandora/Sidebar`,
  `Pandora/Commands` (one command list feeds the menus and the Cmd+K palette), `Pandora/Theme`.
- Every file operation goes through `OperationCenter` (engine) via `OperationsController` (app).
  Operation tests mount throwaway sparse bundles with hdiutil (`TestVolume`); never run them
  against the startup disk, whose Trash is the user's.
- If `hdiutil`/`diskutil image attach` hangs, it is usually waiting on a macOS authorization
  prompt on the user's screen: ask them to look for one. Don't kill system processes.
- Recents and Tags come from Spotlight. `scripts/testdisk.sh` turns on indexing for the test
  disks and imports the fixture folders; if they look empty, run `mdimport /Volumes/PandoraTest/attributes/tagged`.
- GitHub's runners top out at macOS 26, so CI runs the engine tests (engine targets macOS 15)
  and skips the app build until a runner has the macOS 27.2 SDK.
