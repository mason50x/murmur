# Sourced by the other scripts: makes sure the pinned Sparkle release is downloaded and verified,
# then sets SPARKLE_FRAMEWORK and SPARKLE_BIN (sign_update, generate_keys).
# To update Sparkle, change both lines below; the checksum is the one in Sparkle's own Package.swift
# for that tag (https://github.com/sparkle-project/Sparkle/blob/<tag>/Package.swift).
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959

SPARKLE_DIR=.build/sparkle/$SPARKLE_VERSION
if [[ ! -f $SPARKLE_DIR/.verified ]]; then
  rm -rf "$SPARKLE_DIR"
  mkdir -p "$SPARKLE_DIR"
  curl -fsSL --proto '=https' -o "$SPARKLE_DIR/sparkle.zip" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
  if [[ $(shasum -a 256 "$SPARKLE_DIR/sparkle.zip" | cut -d' ' -f1) != "$SPARKLE_SHA256" ]]; then
    rm -rf "$SPARKLE_DIR"
    print -u2 "error: Sparkle $SPARKLE_VERSION download doesn't match its pinned SHA-256"
    exit 1
  fi
  ditto -x -k "$SPARKLE_DIR/sparkle.zip" "$SPARKLE_DIR"
  rm "$SPARKLE_DIR/sparkle.zip"
  touch "$SPARKLE_DIR/.verified"
fi
SPARKLE_FRAMEWORK=$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_BIN=$SPARKLE_DIR/bin
