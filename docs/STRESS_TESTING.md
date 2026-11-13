# Stress testing Scope Dev

The stress launch uses one **20 GB sparse APFS image** containing the separate
`ScopeStressSource` and `ScopeStressTarget` volumes. Both are disposable. The image,
identity record, fixtures and run reports live under git-ignored `build/stress/`.
The image grows as data is written; provisioning checks for at least 30 GiB of
host free space. Do not put personal files on these volumes.

## Prepare and run

```sh
make stress-prepare  # create or attach, verify volume UUIDs, seed fixtures
make stress-run      # build Scope Dev and run three automated repetitions
make stress-low-space # fill near capacity, verify copy refusal, reset fixtures
make stress-report   # compare median times with the recorded baseline
make stress-reset    # restore fixtures after Scope Dev has quit
make stress-open     # launch image-only Scope Dev for the manual pass
```

`stress-prepare` never overwrites an existing image or silently adopts volumes
whose UUIDs changed. A partial first-time seed can be retried. `stress-reset`
checks the image path, both UUIDs and on-volume markers, refuses an active stress
app, and removes only its fixture directories. It never deletes the image.
The runner removes only its own trashed duplicate and retired source after
matching their recorded device and inode on the verified image volume, so
repeat runs do not fill the image's Trash.
If `hdiutil` or `diskutil` pauses, check for a macOS authorization prompt;
do not kill a system disk process.

The launcher passes the image path and both UUIDs to Scope Dev. Before any
browser window opens, the engine verifies that the two writable mounted volumes
are backed by that image. The path guard then pins their mount identities. The
app refuses the launch if either volume is missing, replaced or detached. The
ordinary Scope Dev scratch-folder mode and app-hosted tests are unchanged.
The gate covers Scope's managed browsing, search, preview and file operations;
macOS app settings, unified logs and runtime files still use their normal
locations. This is an application-level guard, not an App Sandbox.

## Automated cases

`make stress-run` records each repetition in `build/stress/runs/<run-id>/`.
The runner targets hooks to its own run ID, samples operation state, memory and
image free space, captures unified logs, and writes a `result.json` with expected
and observed results. Failed cases also include the last operation, phase event
and relevant log tail. The cases fail on any mismatch:

| Case | Acceptance |
| --- | --- |
| Outside sentinel | Navigation is refused and the sentinel SHA-256 is unchanged. |
| Large folder | 100,000 entries appear within 45 seconds; engine performance tests retain their own tighter limits. |
| Duplicate and undo | Exactly one identical copy appears and undo removes it. |
| Pause, resume and cancel copy | A large cross-volume copy reaches paused and running states, then cancellation is requested after measured progress; the job ends cancelled with no `.scope-partial-` entry. |
| Cross-volume copy | 10,000 small files and 4 GiB of large files land on Target; counts and large-file SHA-256 values match the fixture manifest. |
| Cross-volume move | The 10,000-file folder reaches Target and the Source item is retired only after completion. |
| Trash and put-back | Only the selected Target tree is trashed; undo restores all 10,000 entries. |

Three passing repetitions establish the first local median baseline for listing
and copy time, copy throughput and peak process memory. Later reports flag
median regressions greater than 25% for review on the same machine and fixture.
Correctness failures stop the suite; performance flags are diagnostic, since
fixed throughput thresholds do not transfer across hardware. Capture an
Instruments Hangs trace if the UI stalls for one second or more.
`make stress-low-space` records its own run under `build/stress/low-space-runs/`:
the 4 GiB copy must fail with a free-space cause, leave the source hashes intact,
and publish no destination or partial file. It resets fixtures afterward.

## Manual UI and failure pass

Run these with only Scope Dev stress mode open. Start from a fresh
`make stress-reset`, then `make stress-open` and use only the two `ScopeStress`
volumes. The manual launcher assigns a distinct run ID.

1. Try a typed path outside the image, an outside symlink, a favorite, Recents,
   Tags, content search, preview and drag from outside. No outside content
   should open or change. Only the two image volumes should be offered in the
   stress sidebar; Go > Scratch Folder should be disabled.
2. In Source, rename and move several fixture items, create a folder, change a
   tag, compress `archive/`, extract `archive/sample.zip`, then undo each change.
   Compare item counts, hashes, symlink targets and the `com.scope.stress` xattr.
3. Copy `conflicts/` to a Target folder with existing names. Exercise merge,
   replace, replace-if-older, keep-both, skip and stop. The chosen result must
   match the displayed decision; unrelated files must keep their hashes.
4. Pause and resume a large transfer. Cancel near the start, middle and end on
   separate resets. Completed items must be valid; no incomplete destination
   or partial name may remain. Try Quit Now while a copy runs and reopen the
   image; inspect activity and the destination before resetting.
5. Trash and put back image files. For Delete Immediately, verify the dialog
   names the disk and every selected item, Cancel is the default, and Cancel
   leaves the items unchanged. Confirm deletion only for disposable fixtures.
6. Run `make stress-low-space` for the automated near-full copy case. For the
   archive case, run `make stress-reset`, then `make stress-fill` to leave
   roughly 1 GiB free. Launch stress mode, attempt to compress the 4 GiB
   transfer tree, and inspect the failure phase and cause. The source must
   remain intact and no incomplete archive may be published. Run
   `make stress-reset` afterward to remove the filler.

The automated engine suites use separate throwaway images for forced detach,
filesystem variants and injected read/write faults. Run them with `make test`;
the app-hosted tests use `make app-test` and never write files.

## Diagnostics

`StressOperations` unified-log events carry run and operation IDs, state,
duration, counts, bytes and error codes. `StressPhases` records measurement,
transfer, verification, publication, source retirement and partial cleanup.
Signposts cover folder listing, copy, transfer, publication and whole-operation
time. The development-only `stress-status` hook returns JSON snapshots to the
runner. Logs avoid per-file events in the large fixtures; failure text stays
private in the unified log. Keep run artifacts local if they contain fixture
paths, and never commit screenshots of personal content.
