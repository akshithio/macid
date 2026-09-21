# dmgbuild settings for the MacID installer window; run by scripts/release.sh.
# Icon positions match the arrow drawn by scripts/make-dmg-background.swift.
import os.path

app = defines.get("app", "build/MacID.app")  # noqa: F821 (dmgbuild provides `defines`)
background = defines.get("background", "build/dmg-background.tiff")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Taller than the 640x400 background: the title bar and the status bar macOS 26 always shows sit over it.
window_rect = ((200, 160), (640, 462))
background = background
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 196),
    "Applications": (470, 196),
}
