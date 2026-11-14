import importlib.util
from pathlib import Path
import plistlib
import tempfile
import types
import unittest
from unittest.mock import patch


SPECIFICATION = importlib.util.spec_from_file_location("build_app", Path(__file__).with_name("build-app.py"))
BUILD = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(BUILD)


class PackagingSafety(unittest.TestCase):
    def test_process_probe_fails_closed(self):
        for returncode in (0, 2, 3):
            with patch.object(BUILD.subprocess, "run", return_value=types.SimpleNamespace(returncode=returncode)):
                with self.assertRaises(ValueError):
                    BUILD.ensure_not_running()
        with patch.object(BUILD.subprocess, "run", return_value=types.SimpleNamespace(returncode=1)):
            BUILD.ensure_not_running()

    def test_replacement_requires_owned_identity_and_no_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "test.app"
            resources = bundle / "Contents/Resources"
            resources.mkdir(parents=True)
            marker = resources / ".open-wisper-rust-owned"
            marker.write_text(BUILD.OWNERSHIP)
            info = bundle / "Contents/Info.plist"
            with info.open("wb") as target:
                plistlib.dump({"CFBundleIdentifier": BUILD.IDENTIFIER}, target)
            BUILD.owned_bundle(bundle)
            alias = resources / "alias"
            alias.symlink_to(info)
            with self.assertRaises(ValueError):
                BUILD.owned_bundle(bundle)
            alias.unlink()
            marker.write_text("foreign bundle")
            with self.assertRaises(ValueError):
                BUILD.owned_bundle(bundle)
            marker.write_text(BUILD.OWNERSHIP)
            with info.open("wb") as target:
                plistlib.dump({"CFBundleIdentifier": "different.application"}, target)
            with self.assertRaises(ValueError):
                BUILD.owned_bundle(bundle)


if __name__ == "__main__":
    unittest.main()
