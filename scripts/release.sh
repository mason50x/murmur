#!/bin/zsh
# Ships everything on main since the last release:
#
#   scripts/release.sh [patch|minor|major|X.Y.Z] [--yes] [--dry-run]
#
# Production releases run this in GitHub Actions: `make release` starts the Release workflow.
#
#  1. Picks the version: the last vX.Y.Z tag bumped by patch (default), minor or major, or the
#     exact version given. The very first release uses the version in Resources/Info.plist.
#  2. Release notes: CHANGELOG.md's "## Unreleased" section becomes "## X.Y.Z — date". If there
#     isn't one, every commit subject since the last release becomes a bullet (subjects starting
#     with "internal:" or "chore:" are left out). Bumps Info.plist, commits "Release X.Y.Z",
#     and pushes main.
#  3. Loads the signing keys into a throwaway keychain (from GitHub secrets when it runs in the
#     Release workflow, else from 1Password), checks they're the ones installed copies trust,
#     builds and signs Murmur.app, zips it, and signs the zip and the appcast feed.
#  4. Publishes the GitHub release (Murmur.zip, appcast.xml, SHA256SUMS), which creates the
#     vX.Y.Z tag.
#     Installed copies find it within a day through
#     https://github.com/mason50x/murmur/releases/latest/download/appcast.xml
#
# --dry-run does steps 1 and 3 into dist/ without committing, pushing or publishing.
# Safe to rerun after a failure: it picks up the release commit it already made.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=mason50x/murmur
OP_ITEM=${MURMUR_OP_ITEM:-"op://Private/Murmur Release Signing"}
die() { print -u2 "error: $*"; exit 1; }

BUMP=patch
YES=0
DRY=0
for arg in "$@"; do
  case $arg in
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    patch|minor|major|<->.<->.<->) BUMP=$arg ;;
    *) die "usage: scripts/release.sh [patch|minor|major|X.Y.Z] [--yes] [--dry-run]" ;;
  esac
done

# Keys come from GitHub Actions secrets in CI (.github/workflows/release.yml), else from 1Password.
CI_KEYS=0
[[ -n ${MURMUR_RELEASE_P12:-} ]] && CI_KEYS=1
(( CI_KEYS )) || command -v op >/dev/null || die "install the 1Password CLI: brew install --cask 1password-cli"
command -v gh >/dev/null || die "install the GitHub CLI: brew install gh"
source scripts/sparkle.sh

# --- 1. Version ---------------------------------------------------------------------------------
if (( ! DRY )); then
  [[ -z $(git status --porcelain) ]] || die "commit or stash your changes first"
  [[ $(git branch --show-current) == main ]] || die "release from main"
  git fetch -q --tags origin main
  git merge-base --is-ancestor origin/main HEAD || die "main is behind origin; pull first"
fi
LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
if [[ $BUMP == *.*.* ]]; then
  VERSION=$BUMP
elif [[ -z $LAST || $(git log -1 --format=%s) == "Release $PLIST_VERSION" ]]; then
  VERSION=$PLIST_VERSION  # first release, or a rerun after a failed publish
else
  parts=(${(s:.:)${LAST#v}})
  case $BUMP in
    major) VERSION="$((parts[1] + 1)).0.0" ;;
    minor) VERSION="${parts[1]}.$((parts[2] + 1)).0" ;;
    patch) VERSION="${parts[1]}.${parts[2]}.$((parts[3] + 1))" ;;
  esac
fi
TAG=v$VERSION
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG is already released"
[[ -z $LAST || $(git rev-list --count "$LAST..HEAD") -gt 0 ]] || die "nothing has changed since $LAST"
print "Releasing Murmur $VERSION${LAST:+ (everything since $LAST)}"

# --- 2. Release notes and release commit --------------------------------------------------------
section() {
  awk -v v="$1" '$0 ~ "^## \\[?" v "\\]?([ ]|$)" { f = 1; next } /^## / { f = 0 } f' CHANGELOG.md \
    | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}
CHANGELOG_BEFORE=$(cat CHANGELOG.md)
if [[ -z $(section "$VERSION") ]]; then
  HEADING="## $VERSION — $(date +%Y-%m-%d)"
  if [[ -n $(section Unreleased) ]]; then
    sed -i '' -E "s/^## \\[?Unreleased\\]?.*/$HEADING/" CHANGELOG.md
  else
    COMMITS=$(git log --no-merges --format=%s ${LAST:+$LAST..}HEAD \
      | grep -viE '^(internal|chore)(\(|:)|^Release [0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^/- /' || true)
    HEADING=$HEADING NOTES=${COMMITS:-"- Fixes and improvements."} python3 -I -c '
import os, re
text = open("CHANGELOG.md").read()
text = re.sub(r"^## \[?Unreleased\]?[^\n]*\n+", "", text, flags=re.M)
section = os.environ["HEADING"] + "\n\n" + os.environ["NOTES"] + "\n\n"
first = re.search(r"^## ", text, re.M)
text = text[:first.start()] + section + text[first.start():] if first else text.rstrip() + "\n\n" + section
open("CHANGELOG.md", "w").write(text)'
  fi
fi
NOTES=$(section "$VERSION")
if (( DRY )); then
  print -r -- "$CHANGELOG_BEFORE" > CHANGELOG.md
else
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
  if [[ -n $(git status --porcelain) ]]; then
    git add CHANGELOG.md Resources/Info.plist
    git commit -q -m "Release $VERSION"
  fi
fi

# --- 3. Sign ------------------------------------------------------------------------------------
WORK=$(mktemp -d)
chmod 700 "$WORK"
KEYCHAIN=$WORK/release.keychain-db
SEARCH_LIST=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
cleanup() {
  security list-keychains -d user -s "${SEARCH_LIST[@]}" 2>/dev/null || true
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
if (( CI_KEYS )); then
  print -r -- "$MURMUR_RELEASE_P12" | base64 -d > "$WORK/release.p12"
  export P12_PASSWORD=$MURMUR_RELEASE_P12_PASSWORD
  sparkle_key() { print -r -- "$SPARKLE_PRIVATE_KEY"; }
else
  print "Reading release keys from 1Password (approve the prompt if one appears)…"
  op whoami >/dev/null 2>&1 || op vault list >/dev/null || die "1Password didn't authorize the CLI"
  op read --out-file "$WORK/release.p12" "$OP_ITEM/certificate_p12" >/dev/null
  export P12_PASSWORD=$(op read "$OP_ITEM/p12_password")
  sparkle_key() { op read "$OP_ITEM/sparkle_private_key"; }
fi
sign_with_sparkle() { sparkle_key | "$SPARKLE_BIN/sign_update" --ed-key-file - "$@"; }

# The keys must be the ones installed copies trust: the certificate pinned in install.sh and the
# Sparkle key matching SUPublicEDKey.
IDENTITY=$(/usr/bin/openssl pkcs12 -in "$WORK/release.p12" -passin env:P12_PASSWORD -nokeys -clcerts 2>/dev/null \
  | /usr/bin/openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
[[ $IDENTITY == $(sed -n 's/^CERT_SHA1="\(.*\)"$/\1/p' install.sh) ]] \
  || die "the release certificate doesn't match CERT_SHA1 in install.sh"
print -n "murmur release key check" > "$WORK/probe"
PUB=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist) SIG=$(sign_with_sparkle -p "$WORK/probe") \
  FILE=$WORK/probe swift -e 'import CryptoKit; import Foundation
let e = ProcessInfo.processInfo.environment
let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: e["PUB"]!)!)
exit(key.isValidSignature(Data(base64Encoded: e["SIG"]!)!, for: try! Data(contentsOf: URL(fileURLWithPath: e["FILE"]!))) ? 0 : 1)' \
  || die "the Sparkle key doesn't match SUPublicEDKey in Info.plist"

KEYCHAIN_PASSWORD=$(/usr/bin/openssl rand -hex 24)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 900 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/release.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
rm "$WORK/release.p12"
unset P12_PASSWORD
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign only finds identities in keychains on the search list (on CI runners, at least).
security list-keychains -d user -s "$KEYCHAIN" "${SEARCH_LIST[@]}"

BUILD=$(git rev-list --count HEAD)
MURMUR_SIGN_IDENTITY=$IDENTITY MURMUR_KEYCHAIN=$KEYCHAIN scripts/package.sh --version "$VERSION" --build "$BUILD"
codesign --verify -R "=identifier \"com.mason.murmur\" and certificate leaf = H\"$IDENTITY\"" build/Murmur.app \
  || die "Murmur.app isn't signed with the pinned release certificate"

DIST=dist/$VERSION
rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent build/Murmur.app "$DIST/Murmur.zip"
ENCLOSURE_SIG=$(sign_with_sparkle "$DIST/Murmur.zip")
[[ $ENCLOSURE_SIG == *edSignature* ]] || die "sign_update failed: $ENCLOSURE_SIG"

NOTES_HTML=$(print -r -- "$NOTES" | python3 -I -c '
import html, re, sys
out, in_list = [], False
for line in sys.stdin.read().splitlines():
    line = line.rstrip()
    item = re.match(r"^[-*] (.*)", line)
    text = html.escape(item.group(1) if item else line)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    if item and not in_list: out.append("<ul>"); in_list = True
    if not item and in_list: out.append("</ul>"); in_list = False
    if item: out.append("<li>" + text + "</li>")
    elif line.startswith("### "): out.append("<h3>" + html.escape(line[4:]) + "</h3>")
    elif line: out.append("<p>" + text + "</p>")
if in_list: out.append("</ul>")
print("\n".join(out))')

cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Murmur</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Murmur $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Murmur.zip" type="application/octet-stream" $ENCLOSURE_SIG/>
    </item>
  </channel>
</rss>
XML
sign_with_sparkle "$DIST/appcast.xml" >/dev/null
sign_with_sparkle --verify "$DIST/appcast.xml" >/dev/null || die "appcast signature didn't verify"
(cd "$DIST" && shasum -a 256 Murmur.zip > SHA256SUMS)

print "\nMurmur $VERSION (build $BUILD)"
print "  $(cat "$DIST/SHA256SUMS")"
print -- "$NOTES" | sed 's/^/  /'
if (( DRY )); then
  print "Dry run: artifacts are in $DIST; nothing was committed or published."
  exit 0
fi

# --- 4. Publish ---------------------------------------------------------------------------------
if (( ! YES )); then
  read -q "?Publish Murmur $VERSION to github.com/$REPO? [y/N] " || { print "\nStopped; artifacts are in $DIST"; exit 1; }
  print
fi
git push -q origin main
# An interrupted earlier attempt can leave a draft behind; drafts aren't published, so replace it.
if [[ $(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null) == true ]]; then
  gh release delete "$TAG" --repo "$REPO" --yes
fi
# Published releases and v* tags are immutable, so everything is attached to a draft first, and
# the tag is only created, on this exact commit, when the draft is published.
gh release create "$TAG" "$DIST/Murmur.zip" "$DIST/appcast.xml" "$DIST/SHA256SUMS" \
  --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Murmur $VERSION" --draft --notes "$NOTES

### Install

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash
\`\`\`

Already have Murmur? It updates itself, or choose **Check for Updates…** from the menu bar icon.

<sub>SHA-256 \`$(cut -d' ' -f1 "$DIST/SHA256SUMS")\` · Murmur.zip</sub>" >/dev/null
gh release edit "$TAG" --repo "$REPO" --draft=false --latest >/dev/null
print "Published https://github.com/$REPO/releases/tag/$TAG"
