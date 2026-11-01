# Contributing to Scope

Scope is a native macOS file manager written in Swift (AppKit and SwiftUI).
This guide covers setting up, the safety rules, and how changes reach `main`.

## Setup

You need macOS 27.2 and Xcode 27.

```sh
git clone git@github.com:antonisPanos/scope.git
cd scope
make setup      # git hooks, and Config/Local.xcconfig for your signing team
make testdisk   # the throwaway test disks Scope Dev works on
make build      # builds Scope Dev
make test       # engine tests
```

Run `make` to see every target.

## Safety first

Scope moves and deletes files, so development never touches real ones.

- Scope Dev, the build you run while working, can only reach the test disks
  (`/Volumes/ScopeTest`, `ScopeTest2`, `ScopeTestCS`). Everything else is dimmed.
- Don't launch the release `Scope` build while developing: it reads your real home folder.
- All file access goes through `FileEngine` in `Packages/ScopeEngine`, and every
  path passes `PathGuard` first. Deletes always go to the Trash.

`CLAUDE.md` lists the full set of rules; they apply to everyone, not only Claude.

## Branches

`main` is always buildable. Every change goes through a short-lived branch and a pull request.

- Branch from the latest `main`: `feat/search-date-filter`, `fix/cancel-hang`, `docs/readme`.
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
- CI must be green: engine tests, and the app build once GitHub's runners have the macOS 27.2 SDK.
- Attach screenshots for anything visible. Take them in Scope Dev on the test disks.
