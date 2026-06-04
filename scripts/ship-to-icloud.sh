#!/bin/zsh
# Build Agent Deck and drop a zipped .app into iCloud Drive so it can be pulled
# down and test-run on another Mac.
#
# Usage:
#   scripts/ship-to-icloud.sh            # Debug build (default, fast incremental)
#   scripts/ship-to-icloud.sh Release    # Release build
#
# The build is unsigned (CODE_SIGNING_ALLOWED=NO). On the other Mac, after
# unzipping, the app is quarantined — right-click → Open once, or run:
#   xattr -dr com.apple.quarantine "Agent Deck.app"
set -euo pipefail

SCHEME="agent-deck"
CONFIG="${1:-Debug}"
ICLOUD_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/AgentDeckBuilds"
BUILD_LOG="/tmp/agentdeck-ship-build.log"

mkdir -p "$ICLOUD_DIR"

echo "▸ Resolving build settings…"
TARGET_BUILD_DIR="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" \
  -showBuildSettings CODE_SIGNING_ALLOWED=NO 2>/dev/null \
  | awk -F' = ' '/ TARGET_BUILD_DIR = /{print $2; exit}')"

echo "▸ Building $SCHEME ($CONFIG)… (log: $BUILD_LOG)"
if ! xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" \
      CODE_SIGNING_ALLOWED=NO build > "$BUILD_LOG" 2>&1; then
  echo "✗ Build failed. Last lines:"
  tail -40 "$BUILD_LOG"
  exit 1
fi

APP="$TARGET_BUILD_DIR/Agent Deck.app"
if [ ! -d "$APP" ]; then
  echo "✗ Built app not found at: $APP"
  exit 1
fi

# Code-sign with Developer ID so the app opens on another Mac. An UNSIGNED app
# transferred via iCloud is quarantined and Gatekeeper reports it as "damaged"
# — a Developer ID signature avoids that (worst case: right-click → Open).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [ -n "$DEV_ID" ]; then
  echo "▸ Code-signing with: $DEV_ID"
  codesign --force --deep --options runtime --sign "$DEV_ID" "$APP" \
    && codesign --verify --deep --strict "$APP" \
    && echo "  ✓ signed & verified" \
    || { echo "✗ codesign failed"; exit 1; }
else
  echo "⚠ No Developer ID identity found — shipping UNSIGNED (will need: xattr -dr com.apple.quarantine)."
fi

# Notarize + staple so the app opens on a Mac WITHOUT admin rights (a signed but
# un-notarized app can't be overridden without admin). Requires a notarytool
# keychain profile passed via NOTARY_PROFILE (same one scripts/package-dmg.sh uses).
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (profile: $NOTARY_PROFILE) — uploads to Apple, ~2-5 min…"
  NOTARIZE_ZIP="$(mktemp -d)/AgentDeck-notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
  if xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
    xcrun stapler staple "$APP" && echo "  ✓ notarized & stapled"
  else
    echo "✗ Notarization failed (check the profile / submission log above)."; exit 1
  fi
else
  echo "⚠ NOTARY_PROFILE not set — signed but NOT notarized; won't open on a no-admin Mac."
fi

STAMP="$(date +%Y%m%d-%H%M)"
ZIP="$ICLOUD_DIR/AgentDeck-$CONFIG-$STAMP.zip"

echo "▸ Zipping → $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ""
echo "✓ Shipped to iCloud Drive:"
echo "    $ZIP"
echo ""
echo "On your work Mac (after iCloud syncs): unzip, then right-click Agent Deck.app → Open,"
echo "or:  xattr -dr com.apple.quarantine 'Agent Deck.app'"
