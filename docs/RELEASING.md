# Releasing Scope

Releases are tags on `main` (`v0.2.0`), each with a DMG attached to its GitHub Release.
Versions come from the conventional commits, so nobody picks a number by hand.

## How a release happens

1. Work lands on `main` through squash-merged PRs with conventional titles.
2. release-please keeps a PR open called `chore(main): release X.Y.Z`. It bumps
   `MARKETING_VERSION` in `Config/Base.xcconfig` and adds the new section to `CHANGELOG.md`.
   `feat` bumps the minor version, `fix` and `perf` the patch. While Scope is 0.x,
   breaking changes bump the minor.
3. Merge that PR when you want a release. GitHub Actions tags `vX.Y.Z` and creates the
   GitHub Release with the changelog.
4. On your Mac, from an up-to-date, clean `main`:

   ```sh
   git checkout main && git pull
   make release
   ```

   This fetches the tag, builds the Release configuration, makes `Scope-X.Y.Z.dmg`,
   signs and notarizes it when you're set up for that (below), and attaches the DMG and
   its SHA-256 to the GitHub Release.

`make dmg` builds a DMG for whatever is checked out, without uploading. Use it to try
the packaging. Builds that aren't on a tag are named `Scope-X.Y.Z-<commit>.dmg`.

The DMG is built on your Mac because GitHub's runners don't have the macOS 27.2 SDK
yet. Once they do, the same script can run in a workflow when a tag is pushed.

The build number (`CFBundleVersion`) is the number of commits on `main`, so it always goes up.

## Signing: what you get at each stage

| Setup | Result | Opening it on another Mac |
| --- | --- | --- |
| Nothing (today) | Ad-hoc signed DMG | Right-click Scope.app > Open the first time, or `xattr -dr com.apple.quarantine /Applications/Scope.app` |
| Developer ID certificate | Signed DMG and app | Gatekeeper checks online and may still warn |
| Certificate and notarization profile | Signed, notarized and stapled | Opens normally, even offline |

`scripts/release.sh` detects which one applies, so nothing in the repo changes when you upgrade.

## One-time setup for notarized releases

You need the paid [Apple Developer Program](https://developer.apple.com/programs/) ($99 a year).

1. **Developer ID certificate.** In Xcode, go to Settings > Accounts, select your team,
   then Manage Certificates > + > Developer ID Application. The certificate goes into
   your login keychain. Check it with:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notarization credentials.** Create an App Store Connect API key (App Store Connect >
   Users and Access > Integrations > App Store Connect API, with the Developer role), and
   download the `.p8` file. Then store it in your keychain under the profile name the
   script uses:

   ```sh
   xcrun notarytool store-credentials scope-notary \
     --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

   An app-specific password works too: `--apple-id you@example.com --team-id TEAMID --password <app-specific-password>`.

3. Run `make dmg` and look for "Notarizing" and "accepted" in the output.

The credentials stay in your keychain. Nothing goes into the repo, and CI doesn't need them yet.

## Production file operations

Production releases enable `SCOPE_ALLOW_WRITES` in `Config/Scope.xcconfig` by
default and support full file operations with normal macOS permissions. The
release script prints whether the resulting build allows changes.

Use Scope Dev for file-changing QA, inside `~/ScopeScratch`, and disposable
fixtures for engine tests. Build production for release validation without
using personal files as test data.
