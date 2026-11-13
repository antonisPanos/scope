#!/usr/bin/env python3
"""Provision and inspect Scope's disposable, two-volume stress image."""

import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build" / "stress"
IMAGE = BASE / "ScopeStress.sparsebundle"
IDENTITY = BASE / "volumes.json"
MANIFEST = BASE / "fixture-manifest.json"
SOURCE_NAME = "ScopeStressSource"
TARGET_NAME = "ScopeStressTarget"
MARKER = ".scope-stress-volume"
GIB = 1024 ** 3


def run(*args, timeout=180):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout).stdout


def plist(*args):
    return plistlib.loads(run(*args))


def image_entry():
    if not IMAGE.exists():
        return None
    expected = IMAGE.resolve()
    for entry in plist("/usr/bin/hdiutil", "info", "-plist").get("images", []):
        path = entry.get("image-path")
        if path and Path(path).resolve() == expected:
            return entry
    return None


def mounted_volumes():
    entry = image_entry()
    if entry is None:
        raise RuntimeError("The stress image is not mounted")
    found = {}
    for entity in entry.get("system-entities", []):
        mount = entity.get("mount-point")
        if not mount:
            continue
        info = plist("/usr/sbin/diskutil", "info", "-plist", mount)
        name = info.get("VolumeName")
        if name in (SOURCE_NAME, TARGET_NAME):
            if info.get("ReadOnlyVolume") or info.get("ReadOnlyMedia"):
                raise RuntimeError("A stress volume is read-only")
            found[name] = {"mount": mount, "uuid": str(info["VolumeUUID"]).upper(),
                           "device": info["DeviceIdentifier"]}
    if set(found) != {SOURCE_NAME, TARGET_NAME}:
        raise RuntimeError("Both ScopeStress APFS volumes must be mounted from the image")
    if found[SOURCE_NAME]["uuid"] == found[TARGET_NAME]["uuid"]:
        raise RuntimeError("The stress volumes have the same UUID")
    return found


def verify_identity(volumes, create=False):
    recorded = json.loads(IDENTITY.read_text()) if IDENTITY.exists() else None
    ids = {name: volumes[name]["uuid"] for name in (SOURCE_NAME, TARGET_NAME)}
    if recorded is None and not create:
        raise RuntimeError("No stress identity record; run make stress-prepare")
    if recorded is not None and recorded != ids:
        raise RuntimeError("Mounted volume UUIDs differ from the recorded stress image")
    if recorded is None:
        IDENTITY.write_text(json.dumps(ids, indent=2) + "\n")
    for name, volume in volumes.items():
        marker = Path(volume["mount"]) / MARKER
        expected = f"scope-stress-v1 {name} {ids[name]}\n"
        if marker.exists():
            if marker.read_text() != expected:
                raise RuntimeError(f"Marker mismatch on {name}")
        elif create:
            marker.write_text(expected)
        else:
            raise RuntimeError(f"Missing marker on {name}")


def ensure_no_active_stress_app():
    commands = run("/bin/ps", "-axo", "command=").decode(errors="replace")
    if any("Scope Dev.app/Contents/MacOS/Scope Dev" in line and "--scope-stress-image" in line
           for line in commands.splitlines()):
        raise RuntimeError("Quit the active Scope Dev stress session before changing fixtures")


def prepare():
    BASE.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(BASE).free
    if free < 30 * GIB:
        raise RuntimeError("At least 30 GiB of host free space is required")
    new_image = not IMAGE.exists()
    if new_image:
        run("/usr/bin/hdiutil", "create", "-size", "20g", "-type", "SPARSEBUNDLE",
            "-fs", "APFS", "-volname", SOURCE_NAME, str(IMAGE), "-quiet", timeout=300)
    if image_entry() is None:
        attached = plist("/usr/bin/hdiutil", "attach", "-nobrowse", "-plist", str(IMAGE))
    else:
        attached = image_entry()
    if new_image:
        source = next((entity["mount-point"] for entity in attached["system-entities"]
                       if "mount-point" in entity), None)
        if source is None:
            raise RuntimeError("The new source volume did not mount")
        info = plist("/usr/sbin/diskutil", "info", "-plist", source)
        container = info["APFSContainerReference"]
        run("/usr/sbin/diskutil", "apfs", "addVolume", container, "APFS", TARGET_NAME, timeout=300)
    volumes = mounted_volumes()
    verify_identity(volumes, create=new_image)
    if not MANIFEST.exists():
        reset()
    print(json.dumps({"image": str(IMAGE), "volumes": volumes, "fixture_manifest": str(MANIFEST)}, indent=2))


def checked_volumes():
    volumes = mounted_volumes()
    verify_identity(volumes)
    return volumes


def fixture_root(volume, suffix):
    mount = Path(volume["mount"]).resolve()
    parent = mount / "ScopeStress"
    root = parent / suffix
    if parent.is_symlink() or root.is_symlink():
        raise RuntimeError(f"Unsafe fixture path: {root}")
    for path in (parent, root):
        if path.exists() and (not path.is_dir() or path.resolve() != path
                              or path.stat().st_dev != mount.stat().st_dev):
            raise RuntimeError(f"Unsafe fixture path: {path}")
    return root


def remove_owned_trash_item(volume, identity):
    """Remove one fixture item the app moved to this image's Trash by inode."""
    mount = Path(volume["mount"]).resolve()
    trash_parent = mount / ".Trashes"
    trash = trash_parent / str(os.getuid())
    if not trash.exists():
        return False
    if (trash_parent.is_symlink() or trash.is_symlink()
            or trash_parent.resolve() != trash_parent or trash.resolve() != trash
            or trash.stat().st_dev != mount.stat().st_dev):
        raise RuntimeError("Unsafe stress image Trash path")
    for item in trash.iterdir():
        info = item.lstat()
        if (info.st_dev, info.st_ino) != identity:
            continue
        if stat.S_ISDIR(info.st_mode):
            shutil.rmtree(item)
        else:
            item.unlink()
        return True
    return False


def reset():
    ensure_no_active_stress_app()
    volumes = checked_volumes()
    roots = [fixture_root(volumes[name], suffix)
             for name, suffix in ((SOURCE_NAME, "fixtures"), (TARGET_NAME, "target"))]
    for root in roots:
        if root.exists():
            shutil.rmtree(root)
    seed(volumes)


def seed(volumes):
    source = fixture_root(volumes[SOURCE_NAME], "fixtures")
    target = fixture_root(volumes[TARGET_NAME], "target")
    source.mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    wide = source / "wide"
    wide.mkdir(exist_ok=True)
    for index in range(100_000):
        (wide / f"file-{index:06d}.txt").touch(exist_ok=False)

    transfer = source / "transfer"
    transfer.mkdir()
    small = transfer / "small"
    small.mkdir()
    small_digest = hashlib.sha256()
    for index in range(10_000):
        content = hashlib.shake_256(f"scope-small-{index}".encode()).digest(8192)
        name = f"item-{index:05d}.bin"
        (small / name).write_bytes(content)
        small_digest.update(name.encode())
        small_digest.update(content)
    checksums = {}
    for index in range(4):
        path = transfer / f"large-{index}.bin"
        digest = hashlib.sha256()
        with path.open("wb") as output:
            for chunk in range(1024):
                content = hashlib.shake_256(f"scope-large-{index}-{chunk}".encode()).digest(1024 * 1024)
                output.write(content)
                digest.update(content)
        checksums[path.name] = digest.hexdigest()

    nested = source / "nested"
    nested.mkdir()
    cursor = nested
    for depth in range(24):
        cursor = cursor / f"level-{depth:02d}"
        cursor.mkdir()
        (cursor / "note.txt").write_text(f"depth {depth}\n")
    conflicts = source / "conflicts"
    conflicts.mkdir()
    for name in ("replace.txt", "keep-both.txt", "skip.txt", "older.txt", "merge.txt"):
        (conflicts / name).write_text(f"source {name}\n")
    metadata = source / "metadata"
    metadata.mkdir()
    tagged = metadata / "tagged.txt"
    tagged.write_text("Scope stress metadata\n")
    run("/usr/bin/xattr", "-w", "com.scope.stress", "fixture-v1", str(tagged))
    tag_data = plistlib.dumps(["Red\n6"], fmt=plistlib.FMT_BINARY)
    run("/usr/bin/xattr", "-wx", "com.apple.metadata:_kMDItemUserTags", tag_data.hex(), str(tagged))
    (metadata / "inside-link").symlink_to(tagged)
    sentinel = BASE / "outside-sentinel.txt"
    if not sentinel.exists():
        sentinel.write_text("Scope must never change this file.\n")
    (metadata / "outside-link").symlink_to(sentinel)
    archive = source / "archive"
    archive.mkdir()
    with zipfile.ZipFile(archive / "sample.zip", "w", compression=zipfile.ZIP_DEFLATED) as output:
        for index in range(100):
            output.writestr(f"folder/item-{index:03d}.txt", f"archive item {index}\n")
    manifest = {
        "version": 2, "source_uuid": volumes[SOURCE_NAME]["uuid"],
        "target_uuid": volumes[TARGET_NAME]["uuid"], "wide_count": 100_000,
        "transfer_small_count": 10_000, "transfer_small_tree_sha256": small_digest.hexdigest(),
        "transfer_large_sha256": checksums,
        "outside_sentinel_sha256": hashlib.sha256(sentinel.read_bytes()).hexdigest(),
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Seeded {source} and {target}")


def status():
    volumes = checked_volumes()
    print(json.dumps({"image": str(IMAGE), "volumes": volumes, "manifest": json.loads(MANIFEST.read_text())}, indent=2))


def launch_arguments():
    volumes = checked_volumes()
    print("--scope-stress-image", str(IMAGE), "--scope-stress-source", volumes[SOURCE_NAME]["uuid"],
          "--scope-stress-target", volumes[TARGET_NAME]["uuid"])


def open_app():
    ensure_no_active_stress_app()
    volumes = checked_volumes()
    app = ROOT / "build/DerivedData/Build/Products/Debug/Scope Dev.app/Contents/MacOS/Scope Dev"
    if not app.exists():
        raise RuntimeError("Build Scope Dev first with make build")
    run_id = "manual-" + datetime.now().strftime("%Y%m%d-%H%M%S")
    env = dict(os.environ, SCOPE_STRESS_RUN_ID=run_id)
    process = subprocess.Popen(
        [str(app), "--scope-stress-image", str(IMAGE),
         "--scope-stress-source", volumes[SOURCE_NAME]["uuid"],
         "--scope-stress-target", volumes[TARGET_NAME]["uuid"]],
        env=env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Launched Scope Dev stress mode: run {run_id}, process {process.pid}")


def fill():
    ensure_no_active_stress_app()
    volumes = checked_volumes()
    target = fixture_root(volumes[TARGET_NAME], "target")
    target.mkdir(parents=True, exist_ok=True)
    filler = target / "space-filler.bin"
    if filler.exists():
        raise RuntimeError("The space filler already exists; run make stress-reset first")
    chunk = hashlib.shake_256(b"scope-space-filler").digest(4 * 1024 * 1024)
    with filler.open("xb") as output:
        while shutil.disk_usage(target).free > GIB:
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    print(f"Remaining image free space: {shutil.disk_usage(target).free / GIB:.2f} GiB")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("prepare", "reset", "status", "launch-arguments", "open", "fill"):
        raise SystemExit("usage: stress_image.py prepare|reset|status|launch-arguments|open|fill")
    {"prepare": prepare, "reset": reset, "status": status,
     "launch-arguments": launch_arguments, "open": open_app, "fill": fill}[sys.argv[1]]()


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError, RuntimeError) as error:
        raise SystemExit(f"stress image: {error}")
