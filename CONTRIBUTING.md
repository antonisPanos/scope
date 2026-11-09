# Contributing to Scope

Scope is a native macOS file manager written in Swift (AppKit and SwiftUI).
This guide covers setting up, the safety rules, and how changes reach `main`.

## Setup

The app requires **macOS 27.2 or later**, **Xcode 27.2** (or a compatible newer
Xcode), and the **macOS 27.2 SDK or newer**. The standalone engine requires
macOS 15 or later and a Swift 6 toolchain.

```sh
git clone git@github.com:antonisPanos/scope.git
cd scope
make hooks      # commit-message hook and blame configuration
make build      # Scope Dev; ad-hoc signed without Config/Local.xcconfig
make test       # engine suites, one at a time
make app-test   # app tests hosted in Scope Dev
```

The CI-only bounded fault profile runs `python3 scripts/test-bounded.py` on a
disposable GitHub-hosted macOS runner. It refuses local execution; local use is
unsupported until an approved quota-backed environment is available. The
manifest selects a separate test target, and the runner confines its test process
to an owned scratch root, blocks child processes and system Trash, and uses
private fixtures. It watches the scratch tree at a 2 GiB allocated-byte threshold
and the fixture tree at 2 MiB and 128 entries, with build and test timeouts. These
polled thresholds can be exceeded between checks: they are not filesystem quotas.
The profile models failures; it cannot establish real filesystem, device or
power-loss behavior.

`make test` and the CI sanitizer job retain the full integration suite, including
mounted disposable test volumes. Run those only on an isolated CI/VM host with
sufficient space and cleanup controls, never on the owner's Mac.

Run `make` to see every target. Launch the result with:

```sh
open "build/DerivedData/Build/Products/Debug/Scope Dev.app"
```

A paid Apple account is not needed for local ad-hoc builds. For a stable local
Apple Development identity, run `make setup`, then replace `YOURTEAMID` in the
created, git-ignored `Config/Local.xcconfig` with your own team ID. Do that before
building: the placeholder is not a valid signing configuration. Keep credentials
and local team settings out of commits. To override an existing local signing
configuration for one build:

```sh
xcodebuild -project Scope.xcodeproj -scheme "Scope Dev" \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

## Safety first

Scope moves and deletes files, so development never changes real ones.

- Scope Dev, the build you run while working, reads anywhere but changes files only
  inside `~/ScopeScratch` (Go > Scratch Folder creates it). Every other change is refused.
- The production `Scope` build supports full file operations by default. Use `Scope Dev`
  for local development so changes stay inside `~/ScopeScratch`.
- Engine tests work in temporary folders and throwaway disk images (`TestVolume`), never
  in your home folder or your Trash.
- All file access goes through `FileEngine` in `Packages/ScopeEngine`, and every
  path passes `PathGuard` first. Writes use `checkWriteLocation`. Move to Trash
  uses the Trash when available. Both a no-Trash fallback and Delete Immediately
  require confirmation for each disk, naming every item, with Cancel as default.
  Permanent deletion cannot be undone.

[AGENTS.md](AGENTS.md) is the canonical project instruction file. Its safety
rules apply to everyone. Do not create a CodeGraph index automatically; consult
it first for code discovery only when `.codegraph/` already exists.

## Branches

`main` is always buildable. Every change goes through a short-lived branch and a pull request.

- Fetch `origin` and branch from the latest `origin/main`. Agent-created branches
  use `codex/`, for example `codex/search-date-filter` or `codex/docs-refresh`.
  Never commit directly to `main`.
- Keep a branch to one change, and open the PR early.
- PRs are **squash-merged**, so the PR title becomes the one commit on `main`.
- Releases are tags on `main` (`v0.2.0`); there are no release branches.

## Commit messages and PR titles

Scope uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): summary in lowercase, imperative mood
```

| Type | Use it for | Version bump |
| --- | --- | --- |
| `feat` | Something new for the user | minor |
| `fix` | A bug fix | patch |
| `perf` | Faster or lighter, same behaviour | patch |
| `refactor` | Code change with no behaviour change | none |
| `style` | Formatting only | none |
| `docs` | Documentation | none |
| `test` | Tests only | none |
| `build` | Xcode project, xcconfig, scripts, release tooling | none |
| `ci` | GitHub Actions | none |
| `chore` | Anything else | none |
| `revert` | Undoing an earlier commit | depends |

Add `!` after the type (`feat!:`) for a breaking change.

Scopes are optional and follow the code's areas: `engine`, `browser`, `sidebar`,
`search`, `preview`, `operations`, `commands`, `theme`, `system`, `release`, `ci`.

Examples:

```
feat(search): add a date added filter
fix(operations): cancel no longer hangs on network volumes
docs: add keyboard shortcuts to the user guide
```

The `commit-msg` hook (installed by `make hooks`) checks each commit locally, and
CI checks the PR title.

## Pull requests

- Fill in the template: what changed and how you tested it.
- CI checks engine tests normally and under Thread Sanitizer, the conventional PR
  title, and formatting/lint for changed Swift files. The app job builds both
  schemes and runs app tests only when its runner has the macOS 27.2 SDK; a green
  skipped build is not app validation. Build and test locally for app changes.
- Attach screenshots for anything visible. Use Scope Dev and disposable demo
  content. File-changing UI QA stays under `~/ScopeScratch`. Inspect images for
  personal paths and files before committing; see [screenshot provenance](docs/images/README.md).
- Use `make format` and `make lint` for Swift changes (`brew install swiftlint`
  provides SwiftLint). Documentation-only changes need link and render checks.
- Push the review branch and open a PR into `main`. Clean up only your own local
  demo fixtures, builds, services and temporary worktrees/branches once safely
  pushed; retain documentation assets and the remote PR branch.
