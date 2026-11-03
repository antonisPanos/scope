# Releasing Scope

Releases are tags on `main` (`v0.2.0`), each with a DMG attached to its GitHub Release.
Versions come from the conventional commits, so nobody picks a number by hand.

## How a release happens

1. Work lands on `main` through squash-merged PRs with conventional titles.
2. release-please keeps a PR open called `chore(main): release X.Y.Z`. It bumps
   `MARKETING_VERSION` in `Config/Base.xcconfig` and adds the new section to `CHANGELOG.md`.
   `feat` bumps the minor version, `fix` and `perf` the patch. While Scope is 0.x,
   breaking changes bump the minor.
3. Merge that PR when you want a release. The **Release PR** workflow tags `vX.Y.Z`
   and creates the GitHub Release with the changelog.
4. In the same workflow, **Build release DMG** checks out that exact tag and builds
   the Release configuration on GitHub's `xcode-27` runner with Xcode 27.2. It verifies
   the app's ad-hoc signature, distribution entitlements, disk image and checksum.
5. **Attach DMG to release** uploads `Scope-X.Y.Z.dmg` and `Scope-X.Y.Z.dmg.sha256`
   and adds installation/signing information to the release notes. The app is never
   launched. No Apple account, certificate or additional GitHub secret is needed.

The build job has read-only repository access. Only the separate publishing job can
write release assets; it downloads that build's artifact by ID and verifies the
checksum and source tag again before uploading.

The release-please job starts the build through its outputs. A separate tag-push or
`release: published` workflow would not be triggered by release-please's default
`GITHUB_TOKEN`.

## Retry or backfill an existing release

In **Actions > Release PR > Run workflow**, select `main` and enter the published
tag (for example `v0.2.0`) in **release_tag**. This builds that tag and replaces its
DMG/checksum assets without changing the version or creating another release.
Leaving the field empty keeps the usual release-please behavior.

The tag must be `vX.Y.Z`, have a published GitHub Release, and belong to `main`'s
history. A moved tag is refused at publication if it no longer matches the built
source. The downloaded source ZIP/tar.gz files are GitHub's automatic archives;
the DMG is the installer.

## Build locally

`make dmg` builds a DMG for whatever is checked out, without uploading. Use it to try
the packaging. Builds that aren't on a tag are named `Scope-X.Y.Z-<commit>.dmg`.

`SCOPE_SIGNING_MODE=ad-hoc make dmg` explicitly chooses free ad-hoc signing even
when a Developer ID certificate is available locally. The default `auto` mode
detects a Developer ID certificate and notarization profile as described below.

To publish locally from a clean checkout of a release tag, use `make release`.
This remains available if the GitHub runner is unavailable.

The build number (`CFBundleVersion`) is the number of commits on `main`, so it always goes up.

## Signing: what you get at each stage

| Setup | Result | Opening it on another Mac |
| --- | --- | --- |
| Nothing (today, including CI) | App signed ad hoc, without a verified publisher identity or notarization | After the first launch is blocked, System Settings > Privacy & Security > Open Anyway for Scope |
| Developer ID certificate | Signed DMG and app | Gatekeeper checks online and may still warn |
| Certificate and notarization profile | Signed, notarized and stapled | Opens normally, even offline |

Ad-hoc signing is a local code-integrity signature, not an Apple-verified developer
identity. It needs no paid membership. It does not remove Gatekeeper's first-launch
warning. Use [Apple's per-app approval instructions](https://support.apple.com/en-us/102445);
there is no need to disable Gatekeeper globally.

`scripts/release.sh` detects which setup applies to local builds. CI deliberately
uses ad-hoc signing until Developer ID credentials and notarization are configured
for the hosted runner; adding a certificate to your Mac does not change CI.

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
