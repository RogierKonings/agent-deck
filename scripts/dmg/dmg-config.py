# dmgbuild config for the Agent Deck installer DMG.
#
# Usage:
#   python3 -m dmgbuild -s scripts/dmg/dmg-config.py \
#                       -D app=/path/to/Agent\ Deck.app \
#                       -D background=scripts/dmg/background.png \
#                       "Agent Deck" output.dmg
#
# `app` and `background` are passed in via -D so the same config works
# for preview builds, release CI, and ad-hoc local runs.
#
# Unlike create-dmg, dmgbuild writes the .DS_Store binary plist directly
# without driving Finder over AppleScript. Window bounds, chrome state,
# and icon positions all come from the values here — no Finder quirks,
# no first-mount caching issues, deterministic across runs and machines.

import os.path

# ── External inputs (-D var=value on the command line) ───────────────────────
application = defines.get("app", "Agent Deck.app")
background_image = defines.get("background", "scripts/dmg/background.png")
appname = os.path.basename(application)

# ── DMG container ────────────────────────────────────────────────────────────
format = "UDZO"          # compressed read-only (same as `hdiutil ... -format UDZO`)
filesystem = "HFS+"
size = None              # autosize

# ── Contents ─────────────────────────────────────────────────────────────────
files = [application]
symlinks = {"Applications": "/Applications"}

# ── View / window ────────────────────────────────────────────────────────────
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Window rectangle: ((x, y), (width, height)) of the CONTENT area.
# dmgbuild handles the title bar offset automatically — these are the
# dimensions of the visible content area, exactly matching our 800x400
# background art.
window_rect = ((200, 120), (800, 400))

# Background image. Both 1x and 2x variants are auto-picked up if a file
# named `*@2x.*` exists alongside.
background = background_image

# Icon view options.
icon_size = 96
text_size = 14
grid_offset = (0, 0)
grid_spacing = 100.0
icon_locations = {
    appname:        (180, 160),
    "Applications": (620, 160),
}

# Hide noise (HFS+ metadata, Trashes, etc.) from the rendered view.
include_icon_view_settings = "auto"
include_list_view_settings = "auto"
