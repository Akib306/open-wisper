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
mkdir -p "$(dirname "$APP_DIR")"
STAGING_ROOT="$(mktemp -d "$(dirname "$APP_DIR")/.open-wisper-build.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$(basename "$APP_DIR")"
cleanup_staging() {
  local status=$?
  python3 - "$STAGING_ROOT" "$status" <<'PYCLEANUP'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
if sys.argv[2] != "0" and (root / "previous.app").exists():
    print(f"Previous app preserved for recovery at {root / 'previous.app'}", file=sys.stderr)
else:
    shutil.rmtree(root)
PYCLEANUP
}
trap cleanup_staging EXIT
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/OpenWisper" "$STAGED_APP/Contents/MacOS/OpenWisper"
cp "$SWIFT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"

PROFILE="${OPEN_WISPER_PROFILE:-$REPO_DIR/tools/engine/runtime/manifest.json}"
"$BIN_DIR/OpenWisper" --check-profile --profile "$PROFILE"
python3 "$REPO_DIR/tools/engine/package_models.py" "$PROFILE" "$STAGED_APP/Contents/Resources" "${OPEN_WISPER_MODEL_CACHE:-$REPO_DIR/tools/engine/runtime/models}" "$SIGNING_IDENTITY"
for model in tiny.en-q5_1 base.en small.en; do
  "$BIN_DIR/OpenWisper" --check-profile --profile "$STAGED_APP/Contents/Resources/engine-profile-$model.json"
done
codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.akib.openwisper.swift "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  printf 'Warning: ad-hoc signing changes code identity on rebuild; macOS may require permission renewal. See docs/macos-updates.md.\n' >&2
fi
check_not_running
python3 - "$STAGED_APP" "$APP_DIR" <<'PYINSTALL'
from pathlib import Path
import os
import sys

staged, destination = (Path(value).absolute() for value in sys.argv[1:])
if destination.is_symlink():
    sys.exit("Refusing to replace a symlink app destination.")
backup = staged.parent / "previous.app"
had_previous = destination.exists()
if had_previous:
    os.rename(destination, backup)
try:
    os.rename(staged, destination)
except BaseException:
    if had_previous:
        os.rename(backup, destination)
    raise
PYINSTALL
printf 'Built %s\n' "$APP_DIR"
printf 'Launch: open "%s"\n' "$APP_DIR"
