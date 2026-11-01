#!/bin/bash
# Builds and manages Scope's throwaway test disks.
#
#   scripts/testdisk.sh create    make the disk images, mount them, fill them with fixtures
#   scripts/testdisk.sh reset     eject, delete and create again (a clean slate in a minute or so)
#   scripts/testdisk.sh mount     mount existing images
#   scripts/testdisk.sh eject     eject all test disks
#   scripts/testdisk.sh status    show what exists and what is mounted
#   scripts/testdisk.sh destroy   eject and delete the images
#
# Three disks, all growable images that only take the space their files use:
#   /Volumes/ScopeTest    main test disk, up to 5 GB, with every fixture
#   /Volumes/ScopeTest2   small second disk, for moves between disks
#   /Volumes/ScopeTestCS  small case-sensitive disk, for name clashes
#
# The images live in ~/ScopeTestDisks (override with SCOPE_TESTDISK_DIR).
# This script only ever writes inside that folder and inside the mounted test
# volumes; it checks each mount point before writing to it.
#
# Fixture sizes can be tuned: SCOPE_HUGE_MB (default 1024) for the large file,
# SCOPE_MANY_COUNT (default 100000) for the folder with many files.

set -euo pipefail

IMAGE_DIR="${SCOPE_TESTDISK_DIR:-$HOME/ScopeTestDisks}"
HUGE_MB="${SCOPE_HUGE_MB:-1024}"
MANY_COUNT="${SCOPE_MANY_COUNT:-100000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# name|size|filesystem
DISKS=(
  "ScopeTest|5g|APFS"
  "ScopeTest2|512m|APFS"
  "ScopeTestCS|512m|Case-sensitive APFS"
)

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

image_path() { echo "$IMAGE_DIR/$1.sparsebundle"; }
mount_point() { echo "/Volumes/$1"; }

is_mounted() {
  local name="$1"
  [[ -d "$(mount_point "$name")" ]] || return 1
  # The mount must come from our image, not some other volume with that name.
  hdiutil info | grep -F "$(image_path "$name")" >/dev/null
}

# Refuses to continue unless $1 is the mount point of one of our test images.
assert_test_volume() {
  local path="$1" name
  name="$(basename "$path")"
  [[ "$path" == "/Volumes/ScopeTest" || "$path" == "/Volumes/ScopeTest2" || "$path" == "/Volumes/ScopeTestCS" ]] \
    || die "refusing to write to $path: not a test volume"
  is_mounted "$name" || die "refusing to write to $path: it is not mounted from $(image_path "$name")"
}

attach() {
  local name="$1" image mount output
  image="$(image_path "$name")"
  mount="$(mount_point "$name")"
  [[ -e "$image" ]] || die "$image does not exist; run: $0 create"
  if is_mounted "$name"; then
    return
  fi
  [[ ! -e "$mount" ]] || die "$mount already exists but is not a Scope test disk; eject it first"
  output="$(diskutil image attach "$image")"
  grep -qF "$mount" <<<"$output" || die "$image mounted somewhere other than $mount:"$'\n'"$output"
  # Disk images aren't indexed by default. Scope's Recents and Tags come
  # from Spotlight, so index the test disks like a normal drive.
  mdutil -i on "$mount" >/dev/null 2>&1 || log "Could not turn on Spotlight for $mount"
  log "Mounted $mount"
}

detach() {
  local name="$1"
  if is_mounted "$name"; then
    hdiutil detach "$(mount_point "$name")" -quiet || hdiutil detach "$(mount_point "$name")" -force -quiet
    log "Ejected $(mount_point "$name")"
  fi
}

create_images() {
  mkdir -p "$IMAGE_DIR"
  local entry name size fs image
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r name size fs <<<"$entry"
    image="$(image_path "$name")"
    if [[ -e "$image" ]]; then
      log "$image already exists; use reset to rebuild it"
      continue
    fi
    log "Creating $image ($fs, up to $size)"
    hdiutil create -size "$size" -type SPARSEBUNDLE -fs "$fs" -volname "$name" "$image" -quiet
  done
}

# MARK: - Fixtures

fill_main() {
  local root="/Volumes/ScopeTest"
  assert_test_volume "$root"
  cd "$root"
  log "Filling $root"

  # Names: Unicode in both normalization forms, emoji, odd characters, long names, deep nesting.
  mkdir -p names
  printf 'composed (NFC)\n' > "names/$(printf 'Caf\xc3\xa9 composed.txt')"
  printf 'decomposed (NFD)\n' > "names/$(printf 'Cafe\xcc\x81 decomposed.txt')"
  printf 'emoji\n' > "names/🦊 fox 🚀.txt"
  printf 'greek\n' > "names/Αρχείο.txt"
  printf 'japanese\n' > "names/ファイル.txt"
  printf 'arabic\n' > "names/ملف.txt"
  printf 'spaces\n' > "names/ leading space.txt"
  printf 'trailing dot\n' > "names/trailing dot."
  printf 'colon\n' > "names/colon:shows as slash in Finder.txt"
  printf 'quotes\n' > "names/quotes \"double\" 'single'.txt"
  printf 'no extension\n' > "names/no-extension"
  printf 'multiple dots\n' > "names/archive.backup.old.txt"
  printf 'long\n' > "names/$(printf 'L%.0s' {1..251}).txt"
  local deep="names/deep"
  for i in $(seq 1 60); do deep="$deep/level-$i"; done
  mkdir -p "$deep"
  printf 'bottom of a 60-level tree\n' > "$deep/bottom.txt"

  # Links: inside, relative, outside the disk, dangling, looping, hard links. Aliases come from the Swift helper.
  mkdir -p links/target-folder
  printf 'link target\n' > links/target.txt
  ln -s target.txt links/relative-to-file
  ln -s target-folder links/relative-to-folder
  ln -s "$root/links/target.txt" links/absolute-inside
  ln -s /etc/hosts links/points-outside-file
  ln -s "$HOME" links/points-outside-home
  ln -s ../.. links/points-above-root
  ln -s does-not-exist links/dangling
  ln -s loop-b links/loop-a
  ln -s loop-a links/loop-b
  ln links/target.txt links/hard-link.txt

  # Packages: things Finder shows as single items.
  mkdir -p "packages/Fake App.app/Contents/MacOS" "packages/Fake App.app/Contents/Resources"
  cat > "packages/Fake App.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.antonispanos.scope.fixture</string>
<key>CFBundleName</key><string>Fake App</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\necho fixture\n' > "packages/Fake App.app/Contents/MacOS/Fake App"
  chmod +x "packages/Fake App.app/Contents/MacOS/Fake App"
  mkdir -p "packages/Notes.rtfd"
  printf '{\\rtf1\\ansi fixture}' > "packages/Notes.rtfd/TXT.rtf"
  mkdir -p "packages/Plugin.bundle/Contents"

  # Attributes, permissions and flags.
  mkdir -p attributes
  printf 'custom xattr\n' > attributes/with-xattr.txt
  xattr -w com.antonispanos.scope.note "kept on copy" attributes/with-xattr.txt
  printf 'quarantined\n' > attributes/quarantined.txt
  xattr -w com.apple.quarantine "0081;00000000;Scope;" attributes/quarantined.txt
  printf 'locked\n' > attributes/locked.txt
  chflags uchg attributes/locked.txt
  printf 'read only\n' > attributes/read-only.txt
  chmod 444 attributes/read-only.txt
  printf 'no access\n' > attributes/no-access.txt
  chmod 000 attributes/no-access.txt
  printf 'executable\n' > attributes/script.sh
  chmod 755 attributes/script.sh
  printf 'hidden flag\n' > attributes/hidden-flag.txt
  chflags hidden attributes/hidden-flag.txt
  printf 'dot file\n' > attributes/.dotfile
  printf 'acl\n' > attributes/acl-deny-delete.txt
  chmod +a "everyone deny delete" attributes/acl-deny-delete.txt
  mkdir -p attributes/read-only-folder
  printf 'inside a read-only folder\n' > attributes/read-only-folder/file.txt
  chmod 555 attributes/read-only-folder
  printf 'old date\n' > attributes/dated-2001.txt
  touch -t 200109090146 attributes/dated-2001.txt

  # Sizes.
  mkdir -p sizes
  : > sizes/empty.txt
  printf 'x' > sizes/one-byte.txt
  dd if=/dev/urandom of=sizes/1mb.bin bs=1m count=1 status=none
  dd if=/dev/urandom of=sizes/100mb.bin bs=1m count=100 status=none
  log "Writing a ${HUGE_MB} MB file"
  dd if=/dev/urandom of=sizes/huge.bin bs=1m count="$HUGE_MB" status=none
  mkdir -p "sizes/empty folder"

  # Many files, for listing and scrolling speed.
  log "Writing $MANY_COUNT small files"
  python3 -I - "$root/many" "$MANY_COUNT" <<'PY'
import os, sys
folder, count = sys.argv[1], int(sys.argv[2])
os.makedirs(folder, exist_ok=True)
for i in range(count):
    with open(os.path.join(folder, f"file-{i:06d}.txt"), "w") as f:
        f.write(f"{i}\n")
PY

  # Archives in every format Scope extracts, plus a large one and malicious ones.
  log "Writing archives"
  mkdir -p archives/source/sub
  printf 'archived file\n' > archives/source/a.txt
  printf 'nested file\n' > archives/source/sub/b.txt
  (cd archives/source && zip -qr ../sample.zip . \
    && tar -cf ../sample.tar . && tar -czf ../sample.tar.gz . && tar -cjf ../sample.tar.bz2 . \
    && tar -cJf ../sample.tar.xz . && tar --format 7zip -cf ../sample.7z .)
  gzip -c archives/source/a.txt > archives/single.txt.gz
  xz -c archives/source/a.txt > archives/single.txt.xz
  zip -q -0 -j archives/large-for-cancel.zip sizes/100mb.bin
  python3 -I - "$root/archives" <<'PY'
import io, sys, tarfile, zipfile
folder = sys.argv[1]
with zipfile.ZipFile(f"{folder}/malicious-zip-slip.zip", "w") as z:
    z.writestr("../../escaped.txt", "this entry tries to escape the extraction folder\n")
    z.writestr("/tmp/absolute.txt", "this entry has an absolute path\n")
    z.writestr("innocent.txt", "harmless\n")
with tarfile.open(f"{folder}/malicious-tar-slip.tar", "w") as t:
    for name in ["../../escaped.txt", "/tmp/absolute.txt"]:
        data = b"escape attempt\n"
        info = tarfile.TarInfo(name)
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    link = tarfile.TarInfo("link-out")
    link.type = tarfile.SYMTYPE
    link.linkname = "/etc"
    t.addfile(link)
PY
  printf 'rar archives cannot be created with the tools macOS ships; drop a sample .rar here by hand if needed.\n' \
    > archives/README-no-rar.txt

  # Disk images to mount and eject (tested in the unsandboxed Scope Dev build).
  log "Writing small disk images"
  mkdir -p disk-images/iso-source
  printf 'inside the iso\n' > disk-images/iso-source/readme.txt
  hdiutil create -size 10m -fs APFS -volname "Fixture DMG" disk-images/small.dmg -quiet
  hdiutil create -size 10m -fs APFS -volname "Fixture Sparse" -type SPARSE disk-images/small.sparseimage -quiet
  hdiutil create -size 10m -fs APFS -volname "Fixture Bundle" -type SPARSEBUNDLE disk-images/small.sparsebundle -quiet
  hdiutil makehybrid -iso -joliet -o disk-images/small.iso disk-images/iso-source -quiet
  rm -rf disk-images/iso-source

  # Audio for the preview pane's duration (images come from the Swift helper).
  mkdir -p media
  say -o media/hello.aiff "Hello from the Scope test disk" 2>/dev/null || true

  # Aliases, Finder tags, Recents and images need Foundation.
  log "Writing aliases and Finder tags"
  swift "$SCRIPT_DIR/testdisk-fixtures.swift" "$root"
  # Spotlight indexes a fresh disk slowly; import the folders that Recents and
  # Tags rely on right away.
  mdimport "$root" "$root/names" "$root/sizes" "$root/archives" "$root/attributes" "$root/attributes/tagged" >/dev/null 2>&1 || true

  cat > README.txt <<'TXT'
Scope test disk. Everything here is disposable: scripts/testdisk.sh reset rebuilds it.

names/        Unicode (composed and decomposed), emoji, odd characters, a 255-byte name, 60-level nesting
links/        symlinks inside, outside the disk, dangling and looping; a hard link; Finder aliases
packages/     an app bundle, an .rtfd and a .bundle
attributes/   xattrs, quarantine, Finder tags, locked, read-only, no-access, ACL, hidden flag, old dates
sizes/        empty, 1 byte, 1 MB, 100 MB and one large file
many/         a folder with many small files, for speed tests
archives/     zip, tar, tar.gz, tar.bz2, tar.xz, 7z, gz, xz; a large zip for cancel tests;
              malicious zip and tar with ../ and absolute paths
disk-images/  small .dmg, .sparseimage, .sparsebundle and .iso to mount and eject
images/       a JPEG with camera data, a PNG, and a dozen photos for the gallery
media/        a short audio clip
TXT
  cd - >/dev/null
}

fill_second() {
  local root="/Volumes/ScopeTest2"
  assert_test_volume "$root"
  log "Filling $root"
  mkdir -p "$root/incoming"
  printf 'lives on the second disk\n' > "$root/on-second-disk.txt"
  dd if=/dev/urandom of="$root/20mb.bin" bs=1m count=20 status=none
}

fill_case_sensitive() {
  local root="/Volumes/ScopeTestCS"
  assert_test_volume "$root"
  log "Filling $root"
  printf 'lower\n' > "$root/readme.txt"
  printf 'upper\n' > "$root/README.txt"
  printf 'mixed\n' > "$root/ReadMe.txt"
  mkdir -p "$root/Folder" "$root/folder"
}

# MARK: - Commands

each_disk() {
  local entry name
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r name _ <<<"$entry"
    "$1" "$name"
  done
}

cmd_create() {
  local fresh=()
  local entry name
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r name _ <<<"$entry"
    [[ -e "$(image_path "$name")" ]] || fresh+=("$name")
  done
  create_images
  each_disk attach
  for name in ${fresh[@]+"${fresh[@]}"}; do
    case "$name" in
      ScopeTest) fill_main ;;
      ScopeTest2) fill_second ;;
      ScopeTestCS) fill_case_sensitive ;;
    esac
  done
  log "Test disks ready"
  cmd_status
}

cmd_destroy() {
  each_disk detach
  local entry name image
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r name _ <<<"$entry"
    image="$(image_path "$name")"
    if [[ -e "$image" ]]; then
      # Only ever deletes the exact image paths this script creates.
      rm -rf "$image"
      log "Deleted $image"
    fi
  done
}

cmd_status() {
  local entry name image
  for entry in "${DISKS[@]}"; do
    IFS='|' read -r name _ <<<"$entry"
    image="$(image_path "$name")"
    if [[ ! -e "$image" ]]; then
      printf '%-14s no image\n' "$name"
    elif is_mounted "$name"; then
      printf '%-14s mounted at %s, image uses %s\n' "$name" "$(mount_point "$name")" "$(du -sh "$image" | cut -f1)"
    else
      printf '%-14s not mounted, image uses %s\n' "$name" "$(du -sh "$image" | cut -f1)"
    fi
  done
}

case "${1:-}" in
  create) cmd_create ;;
  reset) cmd_destroy; cmd_create ;;
  mount) each_disk attach ;;
  eject) each_disk detach ;;
  status) cmd_status ;;
  destroy) cmd_destroy ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
