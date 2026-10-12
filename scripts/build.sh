#!/bin/zsh
# `make`: builds a development copy (with the murmur:// debug hooks), installs it over your
# existing Murmur (/Applications or ~/Applications), and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { print -u2 "error: $*"; exit 1; }
[[ $(uname -m) == arm64 ]] || die "Murmur builds on Apple silicon Macs only"
(( ${$(sw_vers -productVersion)%%.*} >= 26 )) || die "Murmur needs macOS 26 or later to build"
command -v swift >/dev/null || die "install the Xcode Command Line Tools: xcode-select --install"
swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p')
[[ $(printf '%s\n' 6.2 "$swift_version" | sort -V | head -1) == 6.2 ]] \
  || die "Murmur needs Swift 6.2 or later (found ${swift_version:-none}); update the Command Line Tools"

# A local signing certificate keeps macOS's Microphone/Accessibility grants across rebuilds.
if [[ -z ${MURMUR_SIGN_IDENTITY:-} ]] && ! security find-certificate -c "Murmur Development" >/dev/null 2>&1; then
  scripts/setup-signing.sh
fi

scripts/package.sh --dev

DEST=/Applications/Murmur.app
[[ -d $DEST ]] || DEST="$HOME/Applications/Murmur.app"
pkill -x Murmur 2>/dev/null && sleep 0.5 || true
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto build/Murmur.app "$DEST"
open "$DEST"
print "Installed and opened $DEST"
