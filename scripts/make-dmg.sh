#!/bin/sh
# Builds a Release MacDM.app and packs it into a DMG (spec §13, unsigned until
# Developer ID signing/notarization is configured — README explains the first-run step).
set -eu
cd "$(dirname "$0")/.."

CONFIGURATION=Release
APP="MacDM.app"
BUILT="build/Build/Products/Release/${APP}"
OUT="dist"

rm -rf "build/${CONFIGURATION}" "${OUT}/MacDM.dmg"
mkdir -p "${OUT}"

xcodebuild -project HizDownloadManager.xcodeproj -scheme HizDownloadManager \
  -configuration "${CONFIGURATION}" -derivedDataPath build -quiet build

# Applications symlink + dragged-icon layout, like most Mac DMGs.
STAGING="$(mktemp -d)/dmg"
mkdir -p "${STAGING}"
cp -R "${BUILT}" "${STAGING}/${APP}"
ln -s /Applications "${STAGING}/Applications"

hdiutil create -volname "MacDM" -srcfolder "${STAGING}" -ov -format UDZO \
  "${OUT}/MacDM.dmg" -quiet

echo "built ${OUT}/MacDM.dmg"
hdiutil imageinfo "${OUT}/MacDM.dmg" | grep -E "Format:|Size Information" || true
