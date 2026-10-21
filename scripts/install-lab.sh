#!/usr/bin/env bash
# Download the latest Cocut Lab (the tuning app) from GitHub, install it to /Applications, and
# make a `cocut-lab` command for Terminal and Claude Code.
# Usage: curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/install-lab.sh | bash
set -euo pipefail

REPO="mjcocat/cocut"
URL="https://github.com/${REPO}/releases/latest/download/CocutLab.zip"
DEST="/Applications/Cocut Lab.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading the latest Cocut Lab..."
curl -fL --progress-bar "$URL" -o "$TMP/CocutLab.zip"
ditto -x -k "$TMP/CocutLab.zip" "$TMP"

if pgrep -xq "Cocut Lab"; then
  osascript -e 'quit app "Cocut Lab"' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf "$DEST"
mv "$TMP/Cocut Lab.app" "$DEST"
# The build isn't notarized, so clear the download quarantine flag Gatekeeper would block on.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# The `cocut-lab` command: a small script that runs the app's command line.
WRAPPER='#!/usr/bin/env bash
exec "/Applications/Cocut Lab.app/Contents/MacOS/Cocut Lab" "$@"'
BIN=""
for dir in /opt/homebrew/bin /usr/local/bin; do
  if [ -d "$dir" ] && [ -w "$dir" ]; then BIN="$dir"; break; fi
done
if [ -z "$BIN" ]; then
  BIN="$HOME/.local/bin"
  mkdir -p "$BIN"
  if ! grep -qs 'Cocut Lab: cocut-lab' "$HOME/.zshrc"; then
    printf '\n# Cocut Lab: cocut-lab command\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"
    echo "Added ~/.local/bin to your PATH in ~/.zshrc (open a new Terminal window to use it)."
  fi
fi
printf '%s\n' "$WRAPPER" > "$BIN/cocut-lab"
chmod +x "$BIN/cocut-lab"

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Installed Cocut Lab ${VERSION} to ${DEST}"
echo "Command: ${BIN}/cocut-lab (try: cocut-lab status)"
