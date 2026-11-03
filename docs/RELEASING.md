# Releasing Scope

Releases are tags on `main` (`vX.Y.Z`). The GitHub Release is created first;
its DMG and SHA-256 file arrive after the packaging/publishing jobs succeed.
Versions come from the conventional commits, so nobody picks a number by hand.

## How a release happens

1. Work lands on `main` through squash-merged PRs with conventional titles.
2. release-please keeps a PR open called `chore(main): release X.Y.Z`. It bumps
   `MARKETING_VERSION` in both `Config/Base.xcconfig` and
   `Config/ScopeArchiveService.xcconfig`, updates `.release-please-manifest.json`,
   and adds the new section to `CHANGELOG.md`.
   `feat` bumps the minor version, `fix` and `perf` the patch. While Scope is 0.x,
   breaking changes bump the minor.
3. Merge that PR when you want a release. The **Release PR** workflow tags `vX.Y.Z`
   and creates the GitHub Release with the changelog.
4. In the same workflow, **Build release DMG** checks out that exact tag and builds
   the Release configuration on GitHub's `xcode-27` runner with Xcode 27.2. It requires
   the macOS 27.2 SDK and verifies
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

Local packaging requires macOS 27.2+ and Xcode 27.2 with the macOS 27.2 SDK
(or a compatible newer toolchain). Ad-hoc packaging needs neither an Apple account
nor notarization credentials. Uploading also needs authenticated GitHub CLI access.

The script stamps `CFBundleVersion` with `git rev-list --count HEAD`, the commit
count of the checked-out source. For tagged releases this is the count through
that tag on `main`; use a full-history checkout. Ordinary local builds retain the
xcconfig build number (`1`).

## Signing: what you get at each stage

| Setup | Result | Opening it on another Mac |
| --- | --- | --- |
| No Developer ID credentials (current CI mode) | App signed ad hoc; DMG container unsigned; no verified publisher identity or notarization | After the first launch is blocked, System Settings > Privacy & Security > Open Anyway for Scope |
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

Developer ID signing and notarization require membership in the paid
[Apple Developer Program](https://developer.apple.com/programs/). See Apple's
[notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

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

The stored credential profile stays in your keychain; keep the downloaded `.p8`
private and outside the repository too. CI currently uses neither.
`SCOPE_NOTARY_PROFILE` overrides the default `scope-notary` profile name.

## Production file operations

Production releases enable `SCOPE_ALLOW_WRITES` in `Config/Scope.xcconfig` by
default and support full file operations with normal macOS permissions. The
release script prints whether the resulting build allows changes.

Use Scope Dev for file-changing QA, inside `~/ScopeScratch`, and disposable
fixtures for engine tests. Build production for release validation without
using personal files as test data.

## Verify completion

A tag or release page alone does not prove an installer exists. Wait for all
**Release PR** jobs, including **Attach DMG to release**, to succeed, then confirm
both assets are attached and validate them:

```sh
# Example version; use the tag just published.
gh release view v0.4.0 --json url,assets
gh release download v0.4.0 --pattern 'Scope-0.4.0.dmg*' --dir /tmp/scope-release-check
cd /tmp/scope-release-check
shasum -a 256 -c Scope-0.4.0.dmg.sha256
hdiutil verify Scope-0.4.0.dmg
```

The workflow additionally checks signatures and distribution entitlements without
launching Scope. If packaging fails after the release page appears, use the retry
procedure above. Do not announce an installer until its assets are verified.
