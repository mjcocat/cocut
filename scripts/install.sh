#!/usr/bin/env bash
# Download the latest Cocut release from GitHub and install it to /Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install.sh | bash
set -euo pipefail

REPO="mjcocat/cocut"
URL="https://github.com/${REPO}/releases/latest/download/Cocut.zip"
DEST="/Applications/Cocut.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading the latest Cocut release..."
curl -fL --progress-bar "$URL" -o "$TMP/Cocut.zip"
ditto -x -k "$TMP/Cocut.zip" "$TMP"

if pgrep -xq "Cocut"; then
  echo "Quitting the running copy..."
  osascript -e 'quit app "Cocut"' >/dev/null 2>&1 || true
  sleep 2
  pkill -x "Cocut" 2>/dev/null || true
  sleep 0.5
fi

rm -rf "$DEST"
mv "$TMP/Cocut.app" "$DEST"
# The build isn't notarized, so clear the download quarantine flag Gatekeeper would block on.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Installed Cocut ${VERSION} to ${DEST}"
open "$DEST"
