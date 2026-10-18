#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate for CI builds and store it
# as GitHub Actions secrets. Every CI build is then signed with the same identity, so macOS
# keeps Cocut's Screen Recording permission across updates instead of asking again.
#
# Requires the GitHub CLI, signed in:  brew install gh && gh auth login
# Usage: curl -fsSL https://raw.githubusercontent.com/mjcocat/cocut/main/scripts/setup-signing.sh | bash
set -euo pipefail

REPO="mjcocat/cocut"
NAME="Cocut Self-Signed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh, then gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }

if gh secret list -R "$REPO" | grep -q '^COCUT_CERT_P12'; then
  read -r -p "A signing certificate is already set up. Replace it? Cocut will ask for Screen Recording permission once more. [y/N] " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0
fi

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

PASSWORD="$(openssl rand -hex 16)"
# Legacy encryption so the runner's `security import` can read it.
openssl pkcs12 -export -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/cert.p12" -passout "pass:$PASSWORD" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -legacy -name "$NAME" \
       -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/cert.p12" -passout "pass:$PASSWORD"

base64 < "$WORK/cert.p12" | tr -d '\n' | gh secret set COCUT_CERT_P12 -R "$REPO"
printf '%s' "$PASSWORD" | gh secret set COCUT_CERT_PASSWORD -R "$REPO"

echo "Done. The next CI build will be signed as \"$NAME\"."
echo "After installing that build, grant Screen Recording one last time; later updates keep it."
