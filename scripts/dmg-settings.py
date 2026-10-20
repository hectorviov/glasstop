# dmgbuild settings for the Glasstop disk image (used by scripts/make-dmg.sh).
# Coordinates are Finder's (top-left origin) and must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]                 # path to Glasstop.app
background = defines["background"]   # multi-resolution TIFF

format = "ULFO"                      # LZFSE-compressed, read-only (macOS 10.11+)
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")   # volume icon

window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 185),
    "Applications": (480, 185),
}
