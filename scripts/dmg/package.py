#!/usr/bin/env python3
"""Package an already signed app without Finder, signing, notarization or upload."""
import argparse
import importlib.metadata
import os
from pathlib import Path
import plistlib
import tempfile

import dmgbuild

from verify import run, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("volume_name")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("output already exists; choose a fresh DMG path")
    if app in output.parents:
        parser.error("output must be outside the signed app")
    if not args.volume_name or any(c in args.volume_name for c in "/:\0\n"):
        parser.error("invalid volume name")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "com.antonispanos.scope":
        parser.error("package the production Scope app")
    if importlib.metadata.version("dmgbuild") != "2.0.0":
        parser.error("run scripts/dmg/setup.sh to install the locked packaging tools")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    output.parent.mkdir(parents=True, exist_ok=True)
    # Publish only a completely built and verified image. Failed attempts leave
    # neither an output DMG nor a checksum that could be mistaken for a release.
    with tempfile.TemporaryDirectory(prefix=".scope-dmg-", dir=output.parent) as scratch:
        temporary = Path(scratch) / "Scope.dmg"
        dmgbuild.build_dmg(
            str(temporary), args.volume_name,
            settings_file=str(Path(__file__).with_name("settings.py")),
            defines={"app": str(app), "assets": str(Path(__file__).resolve().parent)},
        )
        verify(temporary, app, args.volume_name)
        # Hard-link publication fails atomically if another process created the
        # requested path while we were building. rename() would overwrite it.
        os.link(temporary, output)
        temporary.unlink()
    print(output)


if __name__ == "__main__":
    main()
