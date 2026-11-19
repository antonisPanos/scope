# Releasing Scope

Releases are tags on `main` (`vX.Y.Z`). A new GitHub Release stays a draft until
its signed, notarized DMG and SHA-256 file have passed verification and been attached.
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
   and creates a draft GitHub Release with the changelog.
4. In the same workflow, **Build release DMG** checks out that exact tag and builds
   the Release configuration on GitHub's `xcode-27` runner with Xcode 27.2. It requires
   the macOS 27.2 SDK. It imports temporary Developer ID and notarization
   credentials, then verifies the app and embedded XPC service signatures,
   distribution entitlements, notarization ticket, disk image and checksum.
5. **Attach DMG to release** uploads `Scope-X.Y.Z.dmg` and `Scope-X.Y.Z.dmg.sha256`
   and updates the installation instructions. Publishing the draft is the final step.
   The app is never launched by this workflow.

The build job has read-only repository access and is the only job with Apple
credentials. Only the separate publishing job can write release assets; it
downloads that build's artifact by ID and verifies the checksum and source tag
again before uploading. If signing or notarization fails, the release remains a draft.

The release-please job starts the build through its outputs. A separate tag-push or
`release: published` workflow would not be triggered by release-please's default
`GITHUB_TOKEN`.

## Retry a failed release

In **Actions > Release PR > Run workflow**, select `main` and enter the existing
tag in **release_tag**. This builds that tag and replaces its DMG/checksum assets
without changing the version or creating another release. It works for drafts
left by a failed build and for already published releases.
Leaving the field empty keeps the usual release-please behavior.

The tag must be `vX.Y.Z`, have a GitHub Release, and belong to `main`'s
history. A moved tag is refused at publication if it no longer matches the built
source. The downloaded source ZIP/tar.gz files are GitHub's automatic archives;
the DMG is the installer.

## Build locally

`make dmg` builds a DMG for whatever is checked out, without uploading. Use it to try
the packaging. Builds that aren't on a tag are named `Scope-X.Y.Z-<commit>.dmg`.

`SCOPE_SIGNING_MODE=ad-hoc make dmg` explicitly chooses ad-hoc signing even
when a Developer ID certificate is available locally. The default `auto` mode
detects a Developer ID certificate and uses the `scope-notary` keychain profile.
For a release-quality local build, set `SCOPE_SIGNING_MODE=developer-id` and
`SCOPE_TEAM_ID` as well. The script fails before building if the identity or
notarization credentials are missing.

To attach assets locally from a clean checkout of a release tag, use `make release`.
Upload requires Developer ID signing and notarization, even in `auto` mode.
If the GitHub runner is unavailable, verify the uploaded assets and publish
the draft manually after updating its install notes.

Local packaging requires macOS 27.2+ and Xcode 27.2 with the macOS 27.2 SDK
(or a compatible newer toolchain). Ad-hoc packaging needs neither an Apple account
nor notarization credentials. Uploading also needs authenticated GitHub CLI access.

The script stamps `CFBundleVersion` with `git rev-list --count HEAD`, the commit
count of the checked-out source. For tagged releases this is the count through
that tag on `main`; use a full-history checkout. Ordinary local builds retain the
xcconfig build number (`1`).

## Signing modes

| Setup | Result | Opening it on another Mac |
| --- | --- | --- |
| `ad-hoc` for local testing | Ad-hoc app; unsigned DMG; no notarization | Requires per-app approval on another Mac |
| `auto` with a local Developer ID identity | Developer ID signed, notarized and stapled | Opens with the verified developer identity, even offline |
| `developer-id` in CI or locally | Requires the expected team, Developer ID identity and notarization credentials; fails closed | Opens with the verified developer identity, even offline |

Ad-hoc signing is a local code-integrity signature, not an Apple-verified developer
identity. It needs no paid membership. It does not remove Gatekeeper's first-launch
warning. Use [Apple's per-app approval instructions](https://support.apple.com/en-us/102445);
there is no need to disable Gatekeeper globally.

Existing ad-hoc release assets are not replaced automatically. The first
notarized installer will be the next version published through this pipeline.

## One-time setup for notarized releases

Developer ID signing and notarization require membership in the paid
[Apple Developer Program](https://developer.apple.com/programs/). See Apple's
[notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

1. **Developer ID certificate.** Confirm your membership is active and accept
   pending agreements. In Xcode, go to Settings > Accounts, select your team,
   then Manage Certificates > + > Developer ID Application. Export the identity
   and private key as a password-protected `.p12` through Manage Certificates.
   Keep a private backup outside the repository. Check the installed identity with:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notarization credentials.** In App Store Connect > Users and Access >
   Integrations > App Store Connect API, request API access if prompted. Create
   a **team** API key with the Developer role, download its `.p8` once, and
   record its key ID and issuer ID. Individual API keys cannot use `notarytool`.
   Keep the `.p8` outside the repository. For local builds, store a keychain
   profile under the name the script uses:

   ```sh
   xcrun notarytool store-credentials scope-notary \
     --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

   An app-specific password works too: `--apple-id you@example.com --team-id TEAMID --password <app-specific-password>`.

3. **GitHub Actions environment.** In the public repository's Settings >
   Environments, create `release-signing`. Restrict deployments to the `main`
   branch. Leave required reviewers off so the release can complete automatically.
   Add these environment secrets:

   | Secret | Value |
   | --- | --- |
   | `SCOPE_CERTIFICATE_P12_BASE64` | Base64 of the exported `.p12` |
   | `SCOPE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
   | `SCOPE_NOTARY_KEY_P8_BASE64` | Base64 of the team API key `.p8` |

   Add these environment variables: `SCOPE_TEAM_ID`, `SCOPE_NOTARY_KEY_ID`,
   and `SCOPE_NOTARY_ISSUER_ID`. Use `base64 -i "/path/to/file" | pbcopy` to
   copy each encoded file privately for pasting into its secret field, and
   clear the clipboard afterward. Never paste these values into a workflow,
   issue, pull request, chat or build log.

4. Run `SCOPE_SIGNING_MODE=developer-id SCOPE_TEAM_ID=YOURTEAMID make dmg`
   locally and confirm notarization is accepted. Then merge the pipeline PR;
   the next release PR is the first one that should publish a notarized DMG.

The stored credential profile stays in your keychain. CI uses a temporary
keychain and private `.p8` file that are removed at the end of the build job.
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
# Replace this example with the tag just published through the signed pipeline.
tag=v0.8.0
version="${tag#v}"
gh release view "$tag" --json url,assets
gh release download "$tag" --pattern "Scope-$version.dmg*" --dir /tmp/scope-release-check
cd /tmp/scope-release-check
shasum -a 256 -c "Scope-$version.dmg.sha256"
hdiutil verify "Scope-$version.dmg"
codesign --verify --strict "Scope-$version.dmg"
xcrun stapler validate "Scope-$version.dmg"
spctl --assess --type open --context context:primary-signature --verbose "Scope-$version.dmg"
```

The workflow additionally checks the app and XPC signatures and distribution
entitlements without launching Scope. If packaging fails, the draft stays
unpublished; use the retry procedure above.
