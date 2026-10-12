#!/bin/zsh
# Builds and signs build/Murmur.app (Apple silicon, hardened runtime).
#   scripts/package.sh [--dev] [--version 1.2.3] [--build 42]
# --dev compiles in the murmur:// debug hooks (never use it for releases).
# Signs with $MURMUR_SIGN_IDENTITY (from $MURMUR_KEYCHAIN if set; scripts/release.sh does this
# with the release certificate), else the local "Murmur Development" certificate from
# scripts/setup-signing.sh, else ad hoc (fine for a try; permissions reset every build).
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=0
VERSION=""
BUILD=""
while (( $# )); do
  case $1 in
    --dev) DEV=1 ;;
    --version) VERSION=$2; shift ;;
    --build) BUILD=$2; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

source scripts/sparkle.sh

FLAGS=(-c release --arch arm64)
(( DEV )) && FLAGS+=(-Xswiftc -DMURMUR_DEBUG_HOOKS)
swift build $FLAGS
BIN=$(swift build $FLAGS --show-bin-path)

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns

APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# Murmur isn't sandboxed, so Sparkle's XPC services aren't used.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

PLIST="$APP/Contents/Info.plist"
[[ -n $VERSION ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n $BUILD ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

IDENTITY=${MURMUR_SIGN_IDENTITY:-}
if [[ -z $IDENTITY ]]; then
  IDENTITY=$(security find-certificate -c "Murmur Development" -Z 2>/dev/null | awk '/SHA-1/ {print $3}' | head -1 || true)
fi
if [[ -z $IDENTITY ]]; then
  echo "warning: no signing identity; signing ad hoc (run scripts/setup-signing.sh)" >&2
  IDENTITY=-
fi

KEYCHAIN_ARGS=()
[[ -n ${MURMUR_KEYCHAIN:-} ]] && KEYCHAIN_ARGS=(--keychain "$MURMUR_KEYCHAIN")
sign() {
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" $KEYCHAIN_ARGS "$@" 2>&1 \
    | { grep -v "replacing existing signature" || true; }
  (( ${pipestatus[1]} == 0 )) || exit 1
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/Murmur.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Packaged $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"
