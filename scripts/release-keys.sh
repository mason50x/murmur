#!/bin/zsh
# Murmur's two release keys live in one 1Password item, and nowhere else:
#   - "Murmur Release": a self-signed code-signing certificate (.p12 + its password). A stable
#     signature keeps users' Microphone/Accessibility grants across updates.
#   - A Sparkle Ed25519 key. Installed copies only accept updates signed with it.
# scripts/release.sh reads them at release time (1Password asks you to approve) into a throwaway
# keychain that's deleted afterwards. Losing this item means losing the ability to ship updates,
# so it's stored in 1Password, which syncs and backs it up.
#
#   scripts/release-keys.sh create   one time: generate both keys straight into 1Password
#   scripts/release-keys.sh check    confirm the item is readable and matches the app's pins
#   scripts/release-keys.sh github   copy them into the GitHub "production" environment's secrets,
#                                    which the Release workflow signs with
#
# MURMUR_OP_ITEM overrides the item (default "op://Private/Murmur Release Signing").
set -euo pipefail
cd "$(dirname "$0")/.."

OP_ITEM=${MURMUR_OP_ITEM:-"op://Private/Murmur Release Signing"}
OP_VAULT=${${OP_ITEM#op://}%%/*}
OP_TITLE=${OP_ITEM##*/}
die() { print -u2 "error: $*"; exit 1; }
command -v op >/dev/null || die "install the 1Password CLI: brew install --cask 1password-cli"

pinned_cert() { sed -n 's/^CERT_SHA1="\(.*\)"$/\1/p' install.sh; }
pinned_edkey() { /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist; }

case ${1:-} in
create)
  op item get "$OP_TITLE" --vault "$OP_VAULT" >/dev/null 2>&1 && die "\"$OP_TITLE\" already exists in $OP_VAULT"
  tmp=$(mktemp -d)
  chmod 700 "$tmp"
  trap 'rm -rf "$tmp"' EXIT

  # Code-signing certificate, valid 20 years.
  /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=Murmur Release" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  export P12_PASSWORD=$(/usr/bin/openssl rand -hex 24)
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "Murmur Release" \
    -out "$tmp/certificate.p12" -passout env:P12_PASSWORD
  rm "$tmp/key.pem"
  sha1=$(/usr/bin/openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)

  # Sparkle Ed25519 key: the base64 seed is what Sparkle's tools call the private key.
  keys=$(swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey()
print(k.rawRepresentation.base64EncodedString()); print(k.publicKey.rawRepresentation.base64EncodedString())')
  sparkle_private=${keys%%$'\n'*}
  sparkle_public=${keys##*$'\n'}

  # Secrets go to op on stdin as a JSON template, never as command-line arguments.
  SPARKLE_PRIVATE=$sparkle_private SPARKLE_PUBLIC=$sparkle_public SHA1=$sha1 TITLE=$OP_TITLE \
    python3 -I -c '
import json, os
sections = {"sparkle": "Sparkle", "codesigning": "Code signing"}
field = lambda id, kind, value, section: {"id": id, "label": id, "type": kind, "value": value,
                                          "section": {"id": section, "label": sections[section]}}
print(json.dumps({
  "title": os.environ["TITLE"],
  "category": "SECURE_NOTE",
  "tags": ["murmur", "code-signing"],
  "sections": [{"id": id, "label": label} for id, label in sections.items()],
  "notesPlain": "Release keys for github.com/mason50x/murmur, read by scripts/release.sh.\n\n"
    "Both are trusted by every installed copy of Murmur. Do not rotate them casually: a new "
    "certificate makes macOS forget users’ permissions, and a new Sparkle key stops existing "
    "installs from accepting updates.",
  "fields": [
    field("sparkle_private_key", "CONCEALED", os.environ["SPARKLE_PRIVATE"], "sparkle"),
    field("sparkle_public_key", "STRING", os.environ["SPARKLE_PUBLIC"], "sparkle"),
    field("p12_password", "CONCEALED", os.environ["P12_PASSWORD"], "codesigning"),
    field("certificate_sha1", "STRING", os.environ["SHA1"], "codesigning"),
  ],
}))' | op item create --vault "$OP_VAULT" --format json >/dev/null
  op item edit "$OP_TITLE" --vault "$OP_VAULT" "Code signing.certificate_p12[file]=$tmp/certificate.p12" >/dev/null
  unset P12_PASSWORD

  print "✓ Stored \"$OP_TITLE\" in 1Password ($OP_VAULT)"
  print "  Certificate SHA-1:  $sha1   → CERT_SHA1 in install.sh, SECURITY.md"
  print "  Sparkle public key: $sparkle_public   → SUPublicEDKey in Resources/Info.plist, SECURITY.md"
  ;;
check)
  sha1=$(op read "$OP_ITEM/certificate_sha1")
  public=$(op read "$OP_ITEM/sparkle_public_key")
  [[ $sha1 == $(pinned_cert) ]] || die "certificate SHA-1 in 1Password ($sha1) doesn't match install.sh"
  [[ $public == $(pinned_edkey) ]] || die "Sparkle public key in 1Password doesn't match Info.plist"
  tmp=$(mktemp -d)
  chmod 700 "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  op read --out-file "$tmp/certificate.p12" "$OP_ITEM/certificate_p12" >/dev/null
  P12_PASSWORD=$(op read "$OP_ITEM/p12_password") /usr/bin/openssl pkcs12 -in "$tmp/certificate.p12" \
    -passin env:P12_PASSWORD -nokeys -clcerts 2>/dev/null | /usr/bin/openssl x509 -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d : | grep -qx "$sha1" || die "the .p12 doesn't hold the pinned certificate"
  # Sign with the private key, verify with the public key pinned in Info.plist.
  print -n "1Password check" > "$tmp/probe"
  source scripts/sparkle.sh
  sig=$(op read "$OP_ITEM/sparkle_private_key" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$tmp/probe")
  PUB=$public SIG=$sig FILE=$tmp/probe swift -e 'import CryptoKit; import Foundation
let e = ProcessInfo.processInfo.environment
let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: e["PUB"]!)!)
let ok = key.isValidSignature(Data(base64Encoded: e["SIG"]!)!, for: try! Data(contentsOf: URL(fileURLWithPath: e["FILE"]!)))
exit(ok ? 0 : 1)' || die "the Sparkle private key doesn't match SUPublicEDKey"
  print "✓ Release keys in 1Password are readable and match the app (cert $sha1)"
  ;;
github)
  REPO=mason50x/murmur
  command -v gh >/dev/null || die "install the GitHub CLI: brew install gh"
  "$0" check
  # Only main may use the environment; its secrets aren't visible to other branches or forks.
  gh api -X PUT "repos/$REPO/environments/production" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
  gh api "repos/$REPO/environments/production/deployment-branch-policies" --jq '.branch_policies[].name' \
    | grep -qx main || gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  # Values go straight from 1Password to GitHub through pipes: never printed, never on disk.
  op read -n "$OP_ITEM/certificate_p12" | base64 | gh secret set MURMUR_RELEASE_P12 --repo "$REPO" --env production
  op read -n "$OP_ITEM/p12_password" | gh secret set MURMUR_RELEASE_P12_PASSWORD --repo "$REPO" --env production
  op read -n "$OP_ITEM/sparkle_private_key" | gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" --env production
  print "✓ Release keys are in the production environment of github.com/$REPO"
  ;;
*)
  die "usage: scripts/release-keys.sh create|check|github"
  ;;
esac
