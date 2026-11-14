#!/usr/bin/env python3
"""Stage, validate and ad-hoc sign the independent Rust app using cached models."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

NATIVE = Path(__file__).resolve().parents[1]
ROOT = NATIVE.parents[1]
IDENTIFIER = "dev.akib.openwisper.rust"
OWNERSHIP = "open-wisper-rust-bundle-v1\n"


def run(*arguments, **options):
    return subprocess.run([str(argument) for argument in arguments], check=True, **options)


def ensure_not_running():
    result = subprocess.run(["pgrep", "-x", "OpenWisperRust"], capture_output=True)
    if result.returncode != 1:
        raise ValueError("Refusing to replace a running Rust app (or process state could not be checked). Quit it first.")


def owned_bundle(path):
    if path.is_symlink() or not path.is_dir():
        raise ValueError("Destination is not an owned Rust bundle directory.")
    if path.stat().st_uid != os.getuid():
        raise ValueError("Destination is not owned by this user.")
    for current, directories, files in os.walk(path, followlinks=False):
        for name in directories + files:
            if (Path(current) / name).is_symlink():
                raise ValueError("Refusing a bundle containing symbolic links.")
    marker = path / "Contents/Resources/.open-wisper-rust-owned"
    if marker.read_text() != OWNERSHIP:
        raise ValueError("Destination does not carry this packager's ownership marker.")
    with (path / "Contents/Info.plist").open("rb") as source:
        if plistlib.load(source).get("CFBundleIdentifier") != IDENTIFIER:
            raise ValueError("Destination bundle identity differs.")


def rust_notices(resources, environment):
    result = run("cargo", "metadata", "--locked", "--offline", "--format-version", "1", "--manifest-path", NATIVE / "Cargo.toml", env=environment, capture_output=True, text=True)
    metadata = json.loads(result.stdout)
    notices = ["Open Wisper Rust — linked Rust dependency declarations and source license texts", ""]
    for package in metadata["packages"]:
        if package["source"] is None:
            continue
        name = f'{package["name"]}-{package["version"]}'
        notices.append(f'{name}: {package["license"] or "See source license texts"}')
        source_root = Path(package["manifest_path"]).parent
        licenses = [entry for entry in source_root.iterdir() if entry.is_file() and entry.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT"))]
        if not licenses and package["repository"] == "https://github.com/madsmtm/objc2":
            licenses = [NATIVE / "Resources/OBJC2-LICENSE.md"]
        if not licenses:
            raise ValueError(f"No source license text found for {name}.")
        target = resources / "ThirdPartyRust" / name
        target.mkdir(parents=True)
        for license_file in licenses:
            shutil.copy2(license_file, target / license_file.name)
    (resources / "RUST-DEPENDENCIES.txt").write_text("\n".join(notices) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, default=ROOT / "tools/engine/runtime/manifest.json")
    parser.add_argument("--cache", type=Path, default=ROOT / "tools/engine/runtime/models")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        raise ValueError("Packaging requires macOS, the SDK, codesign and a Rust toolchain.")
    ensure_not_running()
    destination_root = NATIVE / "dist"
    if destination_root.is_symlink():
        raise ValueError("Refusing a symlinked dist directory.")
    destination_root.mkdir(mode=0o700, exist_ok=True)
    if destination_root.stat().st_uid != os.getuid():
        raise ValueError("dist is not owned by this user.")
    destination = destination_root / "Open Wisper Rust.app"
    if destination.exists() or destination.is_symlink():
        owned_bundle(destination)
    specification = importlib.util.spec_from_file_location("package_models", ROOT / "tools/engine/package_models.py")
    sys.path.insert(0, str(ROOT / "tools/engine"))
    packager = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(packager)
    for name, digest in packager.MODELS.items():
        model = arguments.cache / f"ggml-{name}.bin"
        if model.is_symlink() or not model.is_file() or packager.digest(model) != digest:
            raise ValueError(f"Verified cached {name} is required. This script never downloads models.")
    environment = os.environ.copy()
    environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    run("cargo", "build", "--locked", "--release", "--workspace", "--manifest-path", NATIVE / "Cargo.toml", env=environment)
    with tempfile.TemporaryDirectory(prefix=".rust-stage-", dir=destination_root) as temporary:
        stage = Path(temporary) / destination.name
        contents = stage / "Contents"
        resources = contents / "Resources"
        macos = contents / "MacOS"
        resources.mkdir(parents=True)
        macos.mkdir()
        shutil.copy2(NATIVE / "target/release/OpenWisperRust", macos / "OpenWisperRust")
        shutil.copy2(NATIVE / "Resources/Info.plist", contents / "Info.plist")
        notice = (ROOT / "native/swift/Resources/THIRD-PARTY-NOTICES.txt").read_text()
        (resources / "THIRD-PARTY-NOTICES.txt").write_text(notice.replace("Open Wisper Swift", "Open Wisper Rust", 1))
        rust_notices(resources, environment)
        (resources / ".open-wisper-rust-owned").write_text(OWNERSHIP)
        packager.package(arguments.profile.resolve(), resources, arguments.cache.resolve(), signing_identity="-")
        run("plutil", "-lint", contents / "Info.plist")
        run("codesign", "--force", "--sign", "-", "--identifier", IDENTIFIER, stage)
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", stage)
        executable = macos / "OpenWisperRust"
        run(executable, "--self-check")
        for name in packager.MODELS:
            run(executable, "--check-profile", "--profile", resources / f"engine-profile-{name}.json")
        ensure_not_running()
        if destination.exists() or destination.is_symlink():
            owned_bundle(destination)
            backup = Path(temporary) / "previous.app"
            destination.rename(backup)
            try:
                stage.rename(destination)
            except OSError:
                backup.rename(destination)
                raise
        else:
            stage.rename(destination)
    print(f"Packaged and verified without GUI launch: {destination}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Rust packaging failed: {error}")
