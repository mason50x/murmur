#!/bin/zsh
# Optional, for local development: creates a self-signed "Murmur Development" code-signing
# certificate in your login keychain. scripts/build.sh signs with it, so macOS keeps Murmur's
# Microphone and Accessibility grants across rebuilds (ad hoc signatures change every build).
#
# This is not the release certificate. Release keys live only in 1Password; see
# scripts/release-keys.sh.
set -euo pipefail

NAME="Murmur Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  print "✓ \"$NAME\" already exists"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
export P12_PASSWORD=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/id.p12" -passout env:P12_PASSWORD -name "$NAME"
security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
print "✓ Created \"$NAME\" in your login keychain; scripts/build.sh will sign with it"
