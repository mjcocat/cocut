#!/usr/bin/env bash
# Download the latest Highlight Creator release from GitHub and install it to /Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install.sh | bash
set -euo pipefail

REPO="mjcocat/cocut"
DEST="/Applications/Highlight Creator.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Finding the latest release of $REPO…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*HighlightCreator.zip"' \
  | head -1 | cut -d'"' -f4)"

if [[ -z "$URL" ]]; then
  echo "No release found. Push a tag like v0.1.0 to create one." >&2
  exit 1
fi

echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/HighlightCreator.zip"
ditto -x -k "$TMP/HighlightCreator.zip" "$TMP"

if pgrep -xq "Highlight Creator"; then
  echo "Quitting the running copy…"
  osascript -e 'quit app "Highlight Creator"' || true
  sleep 1
fi

rm -rf "$DEST"
mv "$TMP/Highlight Creator.app" "$DEST"
# The build isn't notarized, so clear the download quarantine flag Gatekeeper would block on.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed: $DEST"
open "$DEST"
