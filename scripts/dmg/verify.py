#!/usr/bin/env python3
"""Verify the contents and Finder layout of a read-only mounted Scope DMG."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile

from ds_store import DSStore
from mac_alias import Alias


def run(*args):
    result = subprocess.run(args, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").digest()


def tiff_sizes(path):
    """Read TIFF directory dimensions, including both HiDPI representations."""
    data = path.read_bytes()
    endian = {b"II": "<", b"MM": ">"}[data[:2]]
    require(struct.unpack_from(endian + "H", data, 2)[0] == 42, "not a TIFF")
    offset = struct.unpack_from(endian + "I", data, 4)[0]
    sizes = []
    visited = set()
    while offset:
        require(offset not in visited, "cyclic TIFF directories")
        visited.add(offset)
        count = struct.unpack_from(endian + "H", data, offset)[0]
        dimensions = {}
        for index in range(count):
            entry = offset + 2 + index * 12
            tag, kind, length = struct.unpack_from(endian + "HHI", data, entry)
            if tag in (256, 257):
                require(length == 1 and kind in (3, 4), "unexpected TIFF dimension")
                dimensions[tag] = struct.unpack_from(endian + ("H" if kind == 3 else "I"), data, entry + 8)[0]
        sizes.append((dimensions[256], dimensions[257]))
        offset = struct.unpack_from(endian + "I", data, offset + 2 + count * 12)[0]
    return sizes


def verify_mounted(root, app, volume_name):
    require(
        {entry.name for entry in root.iterdir() if not entry.name.startswith(".")}
        == {"Scope.app", "Applications"},
        "unexpected visible installer contents",
    )
    require((root / "Applications").is_symlink(), "Applications must be a symlink")
    require(os.readlink(root / "Applications") == "/Applications", "wrong Applications target")
    copied = root / "Scope.app"
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(copied))
    run("/usr/bin/codesign", "--verify", "--strict", str(copied / "Contents/XPCServices/ScopeArchiveService.xpc"))
    run(str(Path(__file__).resolve().parents[1] / "check-release-entitlements.sh"), str(copied))
    require(
        digest(copied / "Contents/Info.plist") == digest(app / "Contents/Info.plist"),
        "packaged version differs from the built app",
    )
    require(
        digest(root / ".VolumeIcon.icns") == digest(app / "Contents/Resources/AppIcon.icns"),
        "volume icon differs from the production icon",
    )
    require(b"C" in run("/usr/bin/GetFileInfo", "-a", str(root)), "missing custom volume icon flag")
    require(tiff_sizes(root / ".background.tiff") == [(640, 400), (1280, 800)], "missing 1x/2x artwork")
    with DSStore.open(str(root / ".DS_Store"), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"), "installer must open in icon view")
        window = store["."]["bwsp"]
        require(window["WindowBounds"] == "{{200, 200}, {640, 400}}", "wrong window bounds")
        for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowTabView", "ShowPathbar"):
            require(window[key] is False, f"unexpected Finder chrome: {key}")
        options = store["."]["icvp"]
        expected = {
            "iconSize": 112, "textSize": 14, "arrangeBy": "none", "labelOnBottom": True,
            "scrollPositionX": 0, "scrollPositionY": 0, "backgroundType": 2,
        }
        for key, value in expected.items():
            require(options[key] == value, f"wrong Finder setting: {key}")
        require(store["Scope.app"]["Iloc"] == (175, 210), "wrong Scope icon location")
        require(store["Applications"]["Iloc"] == (465, 210), "wrong Applications icon location")
        alias = Alias.from_bytes(options["backgroundImageAlias"])
        require(alias.target.filename == ".background.tiff", "wrong background alias target")
        require(alias.volume.name == volume_name, "background alias references another volume")


def verify(dmg, app, volume_name):
    dmg = Path(dmg).resolve(strict=True)
    app = Path(app).resolve(strict=True)
    run("/usr/bin/hdiutil", "verify", str(dmg))
    # A fresh mount location catches dependencies on the build-time mount path.
    # Never follow Applications, launch Scope, or copy anything to the real /Applications.
    with tempfile.TemporaryDirectory(prefix="scope-dmg-check-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        attached = plistlib.loads(run(
            "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", str(mount), "-plist", str(dmg),
        ))
        device = next(entity["dev-entry"] for entity in attached["system-entities"] if entity.get("mount-point"))
        try:
            verify_mounted(mount, app, volume_name)
        finally:
            run("/usr/bin/hdiutil", "detach", device)
    print("Verified mounted app, Applications link, Finder layout, Retina background and volume icon")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("volume_name")
    arguments = parser.parse_args()
    verify(arguments.dmg, arguments.app, arguments.volume_name)
