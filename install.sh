#!/bin/bash
# Murmur installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mason50x/murmur/main/install.sh | bash
#
# Downloads the latest release from GitHub, checks its SHA-256 and that it's signed with
# Murmur's release certificate, installs it to /Applications (asking for your password only if
# that folder isn't writable), clears the download quarantine so macOS opens it, and launches it.
#
#   ... | bash -s -- --uninstall      remove Murmur, its models, history, settings and permissions
#   MURMUR_VERSION=1.0.0 ... | bash   install a specific release
set -euo pipefail

REPO="mason50x/murmur"
BUNDLE_ID="com.mason.murmur"
# SHA-1 of the self-signed "Murmur Release" certificate every release is signed with.
CERT_SHA1="3FBEE017D470E6A1C121D2CDEE9C8CFC4CD2B8A8"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; reset=$'\033[0m'
[[ -t 1 ]] || { bold=""; dim=""; red=""; reset=""; }
say() { printf '%s\n' "${bold}==>${reset} $*"; }
die() { printf '%s\n' "${red}error:${reset} $*" >&2; exit 1; }

existing_app() {
  for dir in /Applications "$HOME/Applications"; do
    [[ -d "$dir/Murmur.app" ]] && { echo "$dir/Murmur.app"; return; }
  done
  return 0
}

quit_murmur() {
  if pgrep -xq Murmur; then
    osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Murmur || return 0; sleep 0.3; done
    pkill -x Murmur || true
    sleep 0.5
  fi
}

# Runs a command, retrying with sudo if the target folder isn't writable.
as_needed() {
  local target=$1; shift
  if [[ -w "$target" ]]; then "$@"; else
    say "Administrator access needed to write to $target"
    sudo "$@" </dev/tty
  fi
}

uninstall() {
  say "Uninstalling Murmur"
  quit_murmur
  local app; app=$(existing_app)
  if [[ -n $app ]]; then
    as_needed "$(dirname "$app")" rm -rf "$app"
    echo "  removed $app"
  fi
  local support="$HOME/Library/Application Support"
  rm -rf "$support/Murmur" "$support/FluidAudio/Models/parakeet-unified-en-0.6b" "$support/FluidAudio/Models/phonon-2" \
    "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/Caches/Murmur" "$HOME/Library/HTTPStorages/Murmur" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
    "$HOME/Library/Logs/Murmur.log" "$HOME/Library/Logs/Murmur.old.log" "$HOME/Library/Logs/Murmur-last.wav"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "  removed speech models, history, logs, settings and permissions"
  say "Murmur is uninstalled."
}

[[ "${1:-}" == "--uninstall" ]] && { uninstall; exit 0; }
[[ $# -gt 0 ]] && die "unknown option: $1"

# --- Checks -------------------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "Murmur is a macOS app."
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]] || die "Murmur needs a Mac with Apple silicon (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || die "Murmur needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

if [[ -n "${MURMUR_VERSION:-}" ]]; then
  base="https://github.com/$REPO/releases/download/v${MURMUR_VERSION#v}"
else
  base="https://github.com/$REPO/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- Download & verify --------------------------------------------------------------------------
say "Downloading Murmur ${MURMUR_VERSION:+$MURMUR_VERSION }from github.com/$REPO"
curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$tmp/Murmur.zip" "$base/Murmur.zip" \
  || die "download failed"
curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "couldn't fetch checksums"
(cd "$tmp" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || die "checksum mismatch; the download is corrupt or was tampered with"

ditto -x -k "$tmp/Murmur.zip" "$tmp/unzipped"
app="$tmp/unzipped/Murmur.app"
[[ -d "$app" ]] || die "Murmur.app missing from the download"
codesign --verify --deep --strict "$app" 2>/dev/null || die "Murmur.app's code signature is invalid"
codesign --verify -R "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\"" "$app" 2>/dev/null \
  || die "Murmur.app isn't signed with Murmur's release certificate"
version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)
echo "  ${dim}verified Murmur $version (SHA-256 and code signature)${reset}"

# --- Install ------------------------------------------------------------------------------------
dest=$(existing_app)
if [[ -z $dest ]]; then
  dest=/Applications/Murmur.app
fi
say "Installing to $dest"
quit_murmur
dir=$(dirname "$dest")
as_needed "$dir" rm -rf "$dest"
as_needed "$dir" ditto "$app" "$dest"
# Murmur isn't notarized by Apple. Removing the quarantine flag lets it open without Gatekeeper's
# "unidentified developer" block; the checks above are what vouch for it instead.
as_needed "$dir" xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

say "Opening Murmur"
open "$dest"
cat <<EOF

  ${bold}Murmur $version is installed.${reset}
  The setup guide is opening: it picks a speech model for this Mac and asks for
  microphone and accessibility access. After that, hold the ${bold}right Option${reset} key to dictate.

  ${dim}Updates install from the menu bar icon. To uninstall:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --uninstall${reset}

EOF
