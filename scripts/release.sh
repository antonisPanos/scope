#!/bin/bash
# Builds Scope.app (Release), packs it into a DMG, and signs and notarizes it
# when the Apple credentials are set up. It never launches the app.
#
#   scripts/release.sh            build a DMG for the current commit into build/release
#   scripts/release.sh --upload   also attach it to the GitHub Release of the tag at HEAD
#
# Signing is picked automatically:
#   - A "Developer ID Application" certificate in the keychain: signed with it,
#     notarized with the notarytool profile "scope-notary" (override with
#     SCOPE_NOTARY_PROFILE) and stapled. Without the profile it is signed only.
#   - No certificate: ad-hoc signed. Opens on your own Macs after
#     right-click > Open, or after clearing the quarantine flag.
# One-time setup is in docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=false
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=true ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

NOTARY_PROFILE="${SCOPE_NOTARY_PROFILE:-scope-notary}"
OUT="build/release"
DERIVED="build/ReleaseDerivedData"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# Version: the vX.Y.Z tag at HEAD, otherwise the xcconfig version marked as a snapshot.
base_version="$(sed -nE 's/^MARKETING_VERSION = ([0-9.]+).*/\1/p' Config/Base.xcconfig)"
tag="$(git describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "$tag" ]; then
  version="${tag#v}"
  [ "$version" = "$base_version" ] || fail "tag $tag doesn't match MARKETING_VERSION $base_version in Config/Base.xcconfig"
else
  version="$base_version"
  $UPLOAD && fail "--upload needs a vX.Y.Z tag at HEAD (merge the release PR, then git pull --tags)"
fi
build_number="$(git rev-list --count HEAD)"
commit="$(git rev-parse --short HEAD)"
if [ -z "$tag" ]; then dmg_version="$version-$commit"; else dmg_version="$version"; fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  $UPLOAD && fail "the working tree has changes; release from a clean checkout"
  echo "warning: the working tree has uncommitted changes; this DMG is for testing only" >&2
fi

# Signing identity.
identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -n 1)"
if [ -n "$identity" ]; then
  team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$identity")"
  sign_mode="developer-id"
  sign_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  sign_mode="ad-hoc"
  sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

step "Scope $version (build $build_number, $commit), signing: $sign_mode"

step "Building the Release configuration"
rm -rf "$DERIVED" "$OUT"
mkdir -p "$OUT"
xcodebuild -project Scope.xcodeproj -scheme Scope -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  "${sign_settings[@]}" \
  clean build -quiet
app="$DERIVED/Build/Products/Release/Scope.app"
[ -d "$app" ] || fail "the build didn't produce $app"

step "Checking the app"
codesign --verify --deep --strict --verbose=1 "$app"
# Inspect signed code, not just the source entitlements: Xcode can inject
# debugging entitlements during a normal build, including into XPC services.
scripts/check-release-entitlements.sh "$app"
plist="$app/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$version" ] || fail "wrong version in Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" = "$build_number" ] || fail "wrong build number in Info.plist"
if [ "$sign_mode" = "developer-id" ]; then
  codesign -dv "$app" 2>&1 | grep -q 'flags=.*runtime' || fail "hardened runtime is off; notarization would reject it"
fi
if xcodebuild -project Scope.xcodeproj -scheme Scope -configuration Release -showBuildSettings 2>/dev/null \
  | grep -E '^\s*SWIFT_ACTIVE_COMPILATION_CONDITIONS = ' | grep -q SCOPE_ALLOW_WRITES; then
  echo "note: this build can change files (SCOPE_ALLOW_WRITES is set)"
else
  echo "note: this build is read-only (SCOPE_ALLOW_WRITES is not set)"
fi

step "Making the DMG"
dmg="$OUT/Scope-$dmg_version.dmg"
staging="$OUT/dmg-root"
mkdir -p "$staging"
ditto "$app" "$staging/Scope.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Scope $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" -quiet
rm -rf "$staging"

if [ "$sign_mode" = "developer-id" ]; then
  codesign --sign "$identity" --timestamp "$dmg"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    step "Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    step "Checking Gatekeeper"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  else
    echo "warning: no notarytool profile \"$NOTARY_PROFILE\"; the DMG is signed but not notarized" >&2
  fi
fi

(cd "$OUT" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

if $UPLOAD; then
  step "Uploading to the GitHub Release $tag"
  gh release view "$tag" >/dev/null || fail "no GitHub Release for $tag yet; merge the release PR first"
  gh release upload "$tag" "$dmg" "$dmg.sha256" --clobber
fi

step "Done"
echo "$dmg"
cat "$dmg.sha256"
