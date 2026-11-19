#!/bin/bash
# Install packaging tools explicitly, before release signing credentials are imported.
set -euo pipefail
cd "$(dirname "$0")/../.."
python="${SCOPE_DMG_PYTHON:-python3.12}"
"$python" -c 'import sys; assert sys.version_info[:2] == (3, 12), "DMG packaging requires Python 3.12"'
"$python" -m venv build/dmg-venv
build/dmg-venv/bin/python3 -m pip install --require-hashes --only-binary=:all: -r scripts/dmg/requirements.txt
