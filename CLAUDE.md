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
- Screen capture and accessibility are not granted to the terminal; verify app behaviour
  through `os.Logger` output (`/usr/bin/log show --predicate 'subsystem == "com.antonispanos.pandora"'`).
- GitHub's runners top out at macOS 26, so CI runs the engine tests (engine targets macOS 15)
  and skips the app build until a runner has the macOS 27.2 SDK.
