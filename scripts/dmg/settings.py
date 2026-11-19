"""Finder layout, in logical points; artwork uses the same 640 × 400 canvas."""
from pathlib import Path

app = Path(defines["app"])
format = "UDZO"
filesystem = "HFS+"
files = [(str(app), "Scope.app")]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(Path(defines["assets"]) / "background.png")
# Do not SetFile the signed app to hide its extension: com.apple.FinderInfo
# invalidates strict bundle verification. Finder owns the native label display.
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_icon_preview = False
show_item_info = False
window_rect = ((200, 200), (640, 400))
arrange_by = None
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 112
icon_locations = {"Scope.app": (175, 210), "Applications": (465, 210)}
