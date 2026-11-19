#!/bin/bash
# Builds Scope.app (Release), packs it into a DMG, and optionally signs and
# notarizes it. It never launches the app.
#
#   scripts/release.sh            build a DMG for the current commit into build/release
#   scripts/release.sh --upload   also attach it to the GitHub Release of the tag at HEAD
#
# SCOPE_SIGNING_MODE=developer-id requires SCOPE_TEAM_ID and either a notarytool
# keychain profile or SCOPE_NOTARY_KEY_PATH, SCOPE_NOTARY_KEY_ID, and
# SCOPE_NOTARY_ISSUER_ID. It fails if signing or notarization cannot complete.
# The default auto mode uses a local Developer ID identity when available;
# ad-hoc explicitly builds an unsigned-for-distribution local DMG.
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

dmg_python="$PWD/build/dmg-venv/bin/python3"
[ -x "$dmg_python" ] || fail "run scripts/dmg/setup.sh with Python 3.12 before packaging"
"$dmg_python" -c 'import dmgbuild, ds_store, mac_alias; from importlib.metadata import version; assert version("dmgbuild") == "2.0.0"' \
  || fail "packaging tools are unavailable; run scripts/dmg/setup.sh"

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

sign_mode="${SCOPE_SIGNING_MODE:-auto}"
case "$sign_mode" in
  auto|ad-hoc|developer-id) ;;
  *) fail "SCOPE_SIGNING_MODE must be auto, ad-hoc, or developer-id" ;;
esac

identity=""
if [ "$sign_mode" != "ad-hoc" ]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' || true)"
  if [ "$sign_mode" = "developer-id" ]; then
    [[ "${SCOPE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail "SCOPE_TEAM_ID must be a 10-character Apple Developer Team ID"
    identity="$(printf '%s\n' "$identities" | grep -F "(${SCOPE_TEAM_ID})" | head -n 1 || true)"
    [ -n "$identity" ] || fail "no valid Developer ID Application identity for team $SCOPE_TEAM_ID"
  else
    identity="$(printf '%s\n' "$identities" | head -n 1)"
  fi
fi
if [ -n "$identity" ]; then
  team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$identity")"
  [ -n "$team" ] || fail "could not determine the Developer ID team"
  sign_mode="developer-id"
  sign_settings=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team" "OTHER_CODE_SIGN_FLAGS=--timestamp")
else
  sign_mode="ad-hoc"
  sign_settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

notary_args=()
if [ "$sign_mode" = "developer-id" ]; then
  if [ -n "${SCOPE_NOTARY_KEY_PATH:-}${SCOPE_NOTARY_KEY_ID:-}${SCOPE_NOTARY_ISSUER_ID:-}" ]; then
    [ -n "${SCOPE_NOTARY_KEY_PATH:-}" ] || fail "SCOPE_NOTARY_KEY_PATH is required with API key credentials"
    [ -f "$SCOPE_NOTARY_KEY_PATH" ] || fail "SCOPE_NOTARY_KEY_PATH is not a file"
    [ -n "${SCOPE_NOTARY_KEY_ID:-}" ] || fail "SCOPE_NOTARY_KEY_ID is required"
    [ -n "${SCOPE_NOTARY_ISSUER_ID:-}" ] || fail "SCOPE_NOTARY_ISSUER_ID is required"
    notary_args=(--key "$SCOPE_NOTARY_KEY_PATH" --key-id "$SCOPE_NOTARY_KEY_ID" --issuer "$SCOPE_NOTARY_ISSUER_ID")
  else
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
  fi
  xcrun notarytool history "${notary_args[@]}" >/dev/null || fail "notarization credentials are unavailable"
fi
$UPLOAD && [ "$sign_mode" != "developer-id" ] && fail "upload requires a Developer ID signed, notarized DMG"

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
  service="$app/Contents/XPCServices/ScopeArchiveService.xpc"
  [ -d "$service" ] || fail "the embedded archive service is missing"
  for signed in "$app" "$service"; do
    codesign --verify --strict --verbose=1 "$signed"
    signature="$(codesign -dv --verbose=4 "$signed" 2>&1)"
    grep -Fqx "TeamIdentifier=$team" <<<"$signature" || fail "wrong signing team for $signed"
    grep -q '^Authority=Developer ID Application:' <<<"$signature" || fail "not Developer ID signed: $signed"
    grep -q '^Timestamp=' <<<"$signature" || fail "secure timestamp is missing: $signed"
    grep -q 'flags=.*runtime' <<<"$signature" || fail "hardened runtime is off: $signed"
  done
fi
if xcodebuild -project Scope.xcodeproj -scheme Scope -configuration Release -showBuildSettings 2>/dev/null \
  | grep -E '^\s*SWIFT_ACTIVE_COMPILATION_CONDITIONS = ' | grep -q SCOPE_ALLOW_WRITES; then
  echo "note: this build can change files (SCOPE_ALLOW_WRITES is set)"
else
  echo "note: this build is read-only (SCOPE_ALLOW_WRITES is not set)"
fi

step "Making the DMG"
dmg="$OUT/Scope-$dmg_version.dmg"
"$dmg_python" scripts/dmg/package.py "$app" "Scope $version" "$dmg"

if [ "$sign_mode" = "developer-id" ]; then
  codesign --sign "$identity" --timestamp "$dmg"
  codesign --verify --strict "$dmg"
  step "Notarizing (this can take up to an hour)"
  notary_response="$(mktemp -t scope-notary-response)"
  trap 'rm -f "$notary_response"' EXIT
  if ! xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --output-format json > "$notary_response"; then
    submission_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$notary_response" 2>/dev/null || true)"
    [ -z "$submission_id" ] || xcrun notarytool log "$submission_id" "${notary_args[@]}" || true
    fail "notarization submission failed"
  fi
  status="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$notary_response")"
  submission_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$notary_response")"
  if [ "$status" != "Accepted" ]; then
    [ -z "$submission_id" ] || xcrun notarytool log "$submission_id" "${notary_args[@]}" || true
    fail "notarization status: ${status:-unknown}"
  fi
  echo "notarization accepted: $submission_id"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  step "Checking Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
  codesign --verify --strict "$dmg"
fi

# Verify the actual final deliverable, after stapling and before checksumming.
"$dmg_python" scripts/dmg/verify.py "$dmg" "$app" "Scope $version"
(cd "$OUT" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")

if $UPLOAD; then
  step "Uploading to the GitHub Release $tag"
  gh release view "$tag" >/dev/null || fail "no GitHub Release for $tag yet; merge the release PR first"
  gh release upload "$tag" "$dmg" "$dmg.sha256" --clobber
fi

step "Done"
echo "$dmg"
cat "$dmg.sha256"
