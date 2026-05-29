#!/usr/bin/env bash
# Build an unsigned DMG locally so you can iterate on the background fast.
#
# Usage:
#   ./scripts/dmg/preview.sh
#
# What it does:
#   1. Finds an existing Agent Deck.app (from /Applications, then Xcode
#      DerivedData, then a fresh Release build).
#   2. Runs create-dmg with the SAME flags release.yml uses, so layout
#      and background match production exactly.
#   3. Mounts the result and opens it in Finder.
#
# Skips: code signing, notarization, Sparkle EdDSA signing. Anything that
# costs minutes. This DMG is for VISUAL preview only — never ship it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
bold()  { printf '\033[1m%s\033[0m' "$1"; }

fail() { printf '%s %s\n' "$(red '✗')" "$1" >&2; exit 1; }
info() { printf '%s %s\n' "$(green '·')" "$1"; }

# --- 1. Locate or build an Agent Deck.app -----------------------------------

APP_PATH=""

# Candidate 1: installed copy from a previous DMG drop
if [ -d "/Applications/Agent Deck.app" ]; then
  APP_PATH="/Applications/Agent Deck.app"
  info "Using installed app at $APP_PATH"
fi

# Candidate 2: a Release product in DerivedData
if [ -z "$APP_PATH" ]; then
  CAND=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 \
         -path "*Build/Products/Release/Agent Deck.app" -type d 2>/dev/null \
         | head -1)
  if [ -n "$CAND" ]; then
    APP_PATH="$CAND"
    info "Using Release product at $APP_PATH"
  fi
fi

# Candidate 3: a Debug product in DerivedData
if [ -z "$APP_PATH" ]; then
  CAND=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 \
         -path "*Build/Products/Debug/Agent Deck.app" -type d 2>/dev/null \
         | head -1)
  if [ -n "$CAND" ]; then
    APP_PATH="$CAND"
    info "Using Debug product at $APP_PATH"
  fi
fi

# Candidate 4: do a quick unsigned Release build
if [ -z "$APP_PATH" ]; then
  info "No existing build found. Doing a fast unsigned Release build…"
  mkdir -p build/preview
  xcodebuild \
    -project agent-deck.xcodeproj \
    -scheme agent-deck \
    -configuration Release \
    -derivedDataPath build/preview/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    -quiet build
  APP_PATH="build/preview/DerivedData/Build/Products/Release/Agent Deck.app"
  [ -d "$APP_PATH" ] || fail "build succeeded but app not at $APP_PATH"
fi

# --- 2. Make sure dmgbuild is installed -------------------------------------

if ! python3 -m dmgbuild --help >/dev/null 2>&1; then
  fail "dmgbuild not installed. Run:  pip3 install --user dmgbuild"
fi

# --- 3. Build the DMG via dmgbuild ------------------------------------------

OUT_DIR="build/preview"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Agent-Deck-preview.dmg"
rm -f "$DMG"

# Timestamped volume name — Finder caches window state per-volume-name,
# so iterating with a constant name (e.g. "Agent Deck (preview)") makes
# Finder reuse a stale window size and ignore the fresh .DS_Store we
# write. A new name every run guarantees Finder opens cold and honours
# the bounds dmgbuild baked in.
PREVIEW_VOLUME="Agent Deck (preview $(date +%s))"

info "Running dmgbuild…"
python3 -m dmgbuild \
  -s scripts/dmg/dmg-config.py \
  -D "app=$APP_PATH" \
  -D background=scripts/dmg/background.png \
  "$PREVIEW_VOLUME" \
  "$DMG"

# --- 4. Mount and open ------------------------------------------------------

info "Mounting and opening in Finder…"
if [ -d "/Volumes/$PREVIEW_VOLUME" ]; then
  hdiutil detach "/Volumes/$PREVIEW_VOLUME" -quiet || true
fi
hdiutil attach "$DMG" -quiet
open "/Volumes/$PREVIEW_VOLUME"

printf '\n%s preview DMG at %s\n' "$(green '✓')" "$(bold "$DMG")"
printf '   Eject the mounted volume when done.\n'
