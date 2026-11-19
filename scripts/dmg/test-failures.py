#!/usr/bin/env python3
"""Integration checks against disposable DMGs; never launch or install Scope."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

import dmgbuild

import package
from verify import run


def expect_rejected(app, output, override, expected):
    original_build = dmgbuild.build_dmg

    def build(*args, **kwargs):
        kwargs["settings"] = override
        return original_build(*args, **kwargs)

    with patch.object(sys, "argv", ["package.py", str(app), "Scope Failure QA", str(output)]):
        with patch.object(dmgbuild, "build_dmg", build):
            try:
                package.main()
            except ValueError as error:
                if expected not in str(error):
                    raise
            else:
                raise AssertionError("malformed installer was accepted")
    if output.exists() or output.with_suffix(".dmg.sha256").exists():
        raise AssertionError("failed packaging published a deliverable")
    if list(output.parent.glob(".scope-dmg-*")):
        raise AssertionError("failed packaging left staging directories behind")
    print(f"Rejected {expected}; no deliverable or staging directory remains")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: test-failures.py SIGNED_APP EXISTING_DMG")
    app = Path(sys.argv[1]).resolve(strict=True)
    existing = Path(sys.argv[2]).resolve(strict=True)
    before = existing.stat()
    with patch.object(sys, "argv", ["package.py", str(app), "Scope QA", str(existing)]):
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                package.main()
            except SystemExit as error:
                if error.code != 2:
                    raise
            else:
                raise AssertionError("existing image was overwritten")
    if existing.stat() != before:
        raise AssertionError("existing image changed")
    print("Refused to overwrite an existing installer")
    with tempfile.TemporaryDirectory(prefix="scope-dmg-failures-") as scratch:
        root = Path(scratch)
        expect_rejected(
            app, root / "bad-link.dmg", {"symlinks": {"Applications": "/tmp"}},
            "wrong Applications target",
        )
        # Only a 1x image lives here; dmgbuild must not find the checked-in @2x sibling.
        background = root / "background.tiff"
        run("/usr/bin/tiffutil", "-none", str(Path(__file__).with_name("background.png")), "-out", str(background))
        expect_rejected(
            app, root / "no-retina.dmg", {"background": str(background)},
            "missing 1x/2x artwork",
        )


if __name__ == "__main__":
    main()
