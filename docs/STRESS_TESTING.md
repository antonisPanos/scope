# Scope Dev stress-testing guide

Use the image-only Scope Dev launch to exercise file operations without giving
the app access to personal files through its managed file paths. The disposable
20 GB sparse APFS image has separate Source and Target volumes. Keep personal
files off both volumes.

## Before you start

- Use macOS 27.2 and Xcode 27.2, as required by the app build.
- Work from the repository root and leave at least 30 GiB free on the host
  before creating or attaching the image.
- Quit any running Scope Dev stress session before preparing or resetting
  fixtures. An ordinary Scope Dev session uses the separate ScopeScratch policy.

The image, identity record, fixture manifest and run artifacts live in the
ignored build/stress/ directory. Preparation prints the mounted paths and
volume UUIDs. Scope Dev checks both UUIDs, writable APFS mounts and the backing
image before opening a browser window; a failed check stops the stress launch.

## Prepare the image

~~~sh
make stress-prepare
~~~

This creates or attaches build/stress/ScopeStress.sparsebundle and seeds these
paths relative to the printed mounts:

- Source — ScopeStress/fixtures/wide: 100,000 empty files.
- Source — ScopeStress/fixtures/transfer: 10,000 small files and four 1 GiB files.
- Nested folders, conflict files, metadata, an archive, an internal link and
  an outside-target link.
- Target — ScopeStress/target: the destination for transfers.

For an existing image, preparation verifies its recorded volume UUIDs and
on-volume markers. It does not replace an image with different identities.
Use the printed mount paths rather than assuming that macOS reused an old
mount path.

## Run the automated suite

~~~sh
make stress-run
make stress-low-space
make stress-report
~~~

The first command builds Scope Dev, resets fixtures before each repetition,
and runs three repetitions. It checks the following outcomes using app hooks
and filesystem hashes:

| Case | Passing result |
| --- | --- |
| Outside sentinel | Navigation is refused and the outside file hash is unchanged. |
| Wide folder | 100,000 items appear within 45 seconds. |
| Duplicate and undo | One matching copy appears, undo removes it, and the runner cleans up its own trashed copy. |
| Pause, resume and cancel | The transfer reaches paused and running states, then ends cancelled after progress with no partial file. |
| Cross-volume copy | 10,000 small files and 4 GiB match the fixture manifest. |
| Cross-volume move | 10,000 files match on Target; Source retires only after completion. |
| Trash and put-back | The selected Target tree is trashed and restored with all 10,000 items. |

The low-space command fills only the verified image until about 1 GiB remains,
tries the 4 GiB copy, checks that the source stays intact and nothing incomplete
is published, and resets fixtures afterward.

Run the separate engine and app suites when validating a code change:

~~~sh
make test
make app-test
~~~

Engine tests cover forced detach, deterministic I/O faults and filesystem
variants that the main APFS image does not represent. App-hosted tests do not
write user files.

## Do the manual UI pass

Start from fresh fixtures, then launch the image-only app:

~~~sh
make stress-reset
make stress-open
~~~

The launcher prints a manual run ID. If you need hooks, compile the clients
with make devhook stress-status-client. Use only the printed Source and Target
mounts for file-changing actions.

1. **Check the gate.** Try the fixture's metadata/outside-link and the outside
   sentinel in build/stress/outside-sentinel.txt, plus an outside typed path,
   drag, preview and search result. Scope must refuse outside content. Recents,
   Tags and content search must stay inside the image; only its two volumes
   should appear in the stress sidebar. Go > Scratch Folder must be disabled.
2. **Browse and edit.** Open wide, sort and search it, and watch for any UI
   stall of one second or more. In Source, rename or move fixture items, create
   a folder, change a tag, compress archive/, extract archive/sample.zip and
   undo the changes. Compare the resulting tree with the fixture manifest,
   including link targets and the com.scope.stress xattr.
3. **Resolve conflicts.** Put a copy of Source/fixtures/conflicts in a Target
   folder, then copy it there again. Exercise merge, replace,
   replace-if-older, keep-both, skip and stop. Each result must match the
   selected choice; unrelated files must retain their hashes.
4. **Interrupt transfers.** Pause and resume a large transfer. On separate
   resets, cancel near the start, middle and end. Completed items must remain
   valid, unfinished items and .scope-partial- files must be absent, and each
   operation must reach a terminal state. Try Quit Now during a copy, reopen
   the image and inspect the destination before resetting.
5. **Check deletion.** Trash and put back image fixtures. Delete Immediately
   must name the disk and every selected item, default to Cancel, and leave
   items intact when cancelled. Confirm deletion only for disposable fixtures.

## Check archive failure near capacity

Quit Scope Dev, reset and fill the image, then reopen it:

~~~sh
make stress-reset
make stress-fill
make stress-open
~~~

Compress the 4 GiB transfer tree. The failure must identify its phase and
cause, preserve the source and publish no incomplete archive. Quit Scope Dev,
then remove the filler:

~~~sh
make stress-reset
~~~

## Read results and diagnose failures

Each automated repetition writes build/stress/runs/<run-id>/result.json,
samples.jsonl and unified.log. The low-space case writes the same files under
build/stress/low-space-runs/<run-id>/. The fixture hashes are in
build/stress/fixture-manifest.json.

- Start with result.json. A failed case records its expected and observed
  states, last operation, latest phase event and relevant log tail.
- Use samples.jsonl for periodic operation progress, process RSS and image
  free space. Compare the same machine and fixture across runs.
- Use unified.log to follow a run and operation ID through queueing,
  measurement, transfer, verification, publication and cleanup. Logs are
  aggregated by phase rather than emitted once per file.
- Run make stress-report after three passing repetitions. It compares median
  listing time, copy time, throughput and peak RSS with the ignored local
  baseline in build/stress/baseline.json. A regression over 25% is flagged
  for review; correctness failures stop the suite.

For an alert or unresponsive UI, the manual run ID can be passed to the
machine-readable hook client:

~~~sh
build/stress_status <run-id>
~~~

If hdiutil or diskutil appears stuck, look for a macOS authorization prompt
on screen. Do not kill system disk processes. If Scope Dev says it cannot
verify the image, quit it and run make stress-prepare to check the image and
recorded volume identities. Do not bypass the verification or substitute
another image.

## Finish

Quit Scope Dev before running make stress-reset. Reset verifies the image and
volume markers, then replaces only the two fixture directories. It does not
delete the image or broadly empty the volume Trash. The automated runner
removes only its own trashed fixture items after matching their recorded device
and inode. Keep run artifacts local when they contain fixture paths, and do
not commit captures containing personal content.

The gate covers Scope's managed browsing and file operations. macOS settings,
unified logs and runtime files still use their normal locations. This is an
application-level guard, not an App Sandbox.
