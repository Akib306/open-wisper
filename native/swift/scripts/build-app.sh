#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$SWIFT_DIR/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="${OPEN_WISPER_APP_DIR:-$SWIFT_DIR/dist/Open Wisper Swift.app}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# Replacing a running executable leaves the old process and its settings alive.
# Refuse rather than making a completed build look like a completed update.
check_not_running() {
  python3 - "$APP_DIR/Contents/MacOS/OpenWisper" <<'PYGUARD'
from pathlib import Path
import subprocess
import sys

executable = Path(sys.argv[1]).resolve()
for line in subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines():
    fields = line.strip().split(maxsplit=1)
    if len(fields) == 2 and Path(fields[1]).resolve() == executable:
        sys.exit(f"Open Wisper is running (PID {fields[0]}). Keep any transcript you need, "
                 "then quit it before rebuilding. To stage an update without touching "
                 "the running app, set OPEN_WISPER_APP_DIR to another output path.")
PYGUARD
}

check_not_running
swift build --package-path "$SWIFT_DIR" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SWIFT_DIR" -c "$CONFIGURATION" --show-bin-path)"
check_not_running
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/OpenWisper" "$APP_DIR/Contents/MacOS/OpenWisper"
cp "$SWIFT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# An optional manifest is copied with absolute artifact paths by the provisioning
# tool; the large engine/model remain outside the app and are shared with MVPs.
PROFILE="${OPEN_WISPER_PROFILE:-$REPO_DIR/tools/engine/runtime/manifest.json}"
if [[ -f "$PROFILE" ]]; then
  "$BIN_DIR/OpenWisper" --check-profile --profile "$PROFILE"
  python3 - "$PROFILE" "$APP_DIR/Contents/Resources/engine-profile.json" <<'PY'
import json, pathlib, sys
source = pathlib.Path(sys.argv[1]).resolve()
profile = json.loads(source.read_text())
for name in ('executable', 'model'):
    profile[name]['path'] = str((source.parent / profile[name]['path']).resolve())
pathlib.Path(sys.argv[2]).write_text(json.dumps(profile, indent=2, sort_keys=True) + '\n')
PY
  "$BIN_DIR/OpenWisper" --check-profile --profile "$APP_DIR/Contents/Resources/engine-profile.json"
elif [[ -f "$APP_DIR/Contents/Resources/engine-profile.json" ]]; then
  rm "$APP_DIR/Contents/Resources/engine-profile.json"
fi
codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.akib.openwisper.swift "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
printf 'Launch: open "%s"\n' "$APP_DIR"
