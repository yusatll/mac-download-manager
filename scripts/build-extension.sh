#!/bin/sh
# Assembles the extension for both targets (spec §12 "make extension"):
#   Extension/dist/macdm-chrome/    → "Load unpacked" in Chrome/Brave/Edge/Vivaldi + zip source
#   SafariExtension/Resources/    → resources embedded in the Safari app extension
set -eu
cd "$(dirname "$0")/.."

CHROME_DIST=Extension/dist/macdm-chrome
SAFARI_RES=SafariExtension/Resources

rm -rf "$CHROME_DIST" "$SAFARI_RES"
mkdir -p "$CHROME_DIST/lib" "$CHROME_DIST/popup" "$CHROME_DIST/icons" "$SAFARI_RES"

# Shared sources. hdm.js lives in lib/ so manifest paths (lib/hdm.js) and
# importScripts('lib/hdm.js') resolve in every context.
cp Extension/src/lib/hdm.js "$CHROME_DIST/lib/"
cp Extension/src/background.js Extension/src/content.js Extension/src/page-hook.js "$CHROME_DIST/"
cp Extension/src/popup/popup.html Extension/src/popup/popup.css Extension/src/popup/popup.js "$CHROME_DIST/popup/"
cp Extension/icons/*.png "$CHROME_DIST/icons/"
cp Extension/manifest.chrome.json "$CHROME_DIST/manifest.json"

# Safari: same JS, its own manifest, no downloads/webRequest permissions
cp Extension/src/lib/hdm.js "$SAFARI_RES/lib/" 2>/dev/null || { mkdir -p "$SAFARI_RES/lib"; cp Extension/src/lib/hdm.js "$SAFARI_RES/lib/"; }
cp Extension/src/background.js Extension/src/content.js Extension/src/page-hook.js "$SAFARI_RES/"
mkdir -p "$SAFARI_RES/popup" "$SAFARI_RES/icons"
cp Extension/src/popup/popup.html Extension/src/popup/popup.css Extension/src/popup/popup.js "$SAFARI_RES/popup/"
cp Extension/icons/*.png "$SAFARI_RES/icons/"
cp Extension/manifest.safari.json "$SAFARI_RES/manifest.json"

# The Chrome package for distribution
cd Extension/dist
zip -qr macdm-chrome.zip macdm-chrome
cd ../..

echo "extension built: $CHROME_DIST, Extension/dist/macdm-chrome.zip, $SAFARI_RES"
