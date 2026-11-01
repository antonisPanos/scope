#!/bin/bash
# Builds Scope Dev and puts it in ~/Applications, so Spotlight, Raycast and
# Launchpad find it like any other app. Run it again after pulling changes.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Scope.xcodeproj -scheme "Scope Dev" -derivedDataPath build/DerivedData build -quiet
mkdir -p "$HOME/Applications"
osascript -e 'quit app "Scope Dev"' 2>/dev/null || true
# Only ever replaces the Scope Dev app this script installed.
rm -rf "$HOME/Applications/Scope Dev.app"
cp -R "build/DerivedData/Build/Products/Debug/Scope Dev.app" "$HOME/Applications/"
mdimport "$HOME/Applications/Scope Dev.app" 2>/dev/null || true
echo "Installed ~/Applications/Scope Dev.app"
