import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import package_models


class PackageModelsTests(unittest.TestCase):
    def test_manifest_records_engine_hash_after_nested_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine = root / "engine"
            engine.write_bytes(b"engine")
            model = root / "model"
            model.write_bytes(b"weights")
            profile = root / "profile.json"
            original_digest = package_models.digest(engine)
            profile.write_text(json.dumps({"executable": {"path": str(engine), "sha256": original_digest},
                                           "model": {}, "provenance": {"evidence": {}, "limitations": "Fixture."}}))
            def sign(arguments, **kwargs):
                Path(arguments[-1]).write_bytes(b"signed-engine")
            with patch.object(package_models, "MODELS", {"base.en": package_models.digest(model)}), \
                 patch.object(package_models, "cached_model", return_value=model), \
                 patch.object(package_models, "check_dependencies"), \
                 patch.object(package_models.subprocess, "run", side_effect=sign):
                package_models.package(profile, root / "Resources", root / "cache", signing_identity="test")
            result = json.loads((root / "Resources" / "engine-profile-base.en.json").read_text())
            self.assertEqual(result["executable"]["sha256"], hashlib.sha256(b"signed-engine").hexdigest())
            self.assertEqual(result["provenance"]["evidence"]["engine-before-packaging"], original_digest)

    def test_non_system_engine_dependency_is_rejected(self):
        with patch.object(package_models, "run", return_value="engine:\n\t@rpath/libwhisper.dylib (compatibility version 1.0.0)"):
            with self.assertRaisesRegex(ValueError, "external library"):
                package_models.check_dependencies(Path("engine"))

    def test_system_engine_dependencies_are_allowed(self):
        with patch.object(package_models, "run", return_value="engine:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)"):
            package_models.check_dependencies(Path("engine"))

    def test_downloaded_model_is_readable_and_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            response = io.BytesIO(b"weights")
            response.geturl = lambda: "https://example.com/model"
            with patch.object(package_models.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                target = package_models.cached_model("base.en", hashlib.sha256(b"weights").hexdigest(), cache)
            self.assertEqual(target.read_bytes(), b"weights")
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            self.assertEqual(list(cache.glob(".download-*")), [])

    def test_bad_download_is_not_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            response = io.BytesIO(b"corrupt")
            response.geturl = lambda: "https://example.com/model"
            with patch.object(package_models.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    package_models.cached_model("base.en", "0" * 64, cache)
            self.assertEqual(list(cache.iterdir()), [])

    def test_interrupted_download_removes_partial_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            response = io.BytesIO(b"partial")
            response.geturl = lambda: "https://example.com/model"
            with patch.object(package_models.urllib.request, "build_opener") as opener, \
                 patch.object(package_models.shutil, "copyfileobj", side_effect=OSError("interrupted")):
                opener.return_value.open.return_value = response
                with self.assertRaisesRegex(OSError, "interrupted"):
                    package_models.cached_model("base.en", "0" * 64, cache)
            self.assertEqual(list(cache.iterdir()), [])

    def test_package_writes_relocatable_profiles_with_verified_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            engine = root / "engine"
            engine.write_bytes(b"engine")
            engine.chmod(0o755)
            models = {name: hashlib.sha256(name.encode()).hexdigest() for name in package_models.MODELS}
            for name in models:
                (cache / f"ggml-{name}.bin").write_bytes(name.encode())
            profile = root / "profile.json"
            profile.write_text(json.dumps({"executable": {"path": str(engine), "sha256": package_models.digest(engine)},
                                           "model": {"name": "small.en", "path": "unused", "sha256": "unused"}}))
            with patch.object(package_models, "MODELS", models), patch.object(package_models, "check_dependencies"):
                package_models.package(profile, root / "bundle", cache)
            for name, expected in models.items():
                result = json.loads((root / "bundle" / f"engine-profile-{name}.json").read_text())
                self.assertEqual((root / "bundle" / f"engine-profile-{name}.json").stat().st_mode & 0o777, 0o644)
                self.assertEqual(result["executable"]["path"], "../MacOS/whisper-cli")
                self.assertEqual((root / "bundle" / result["executable"]["path"]).read_bytes(), b"engine")
                self.assertEqual(result["model"], {"name": name, "path": f"ggml-{name}.bin", "sha256": expected})
                self.assertEqual((root / "bundle" / result["model"]["path"]).stat().st_mode & 0o777, 0o644)

    def test_corrupted_cache_is_rejected_without_downloading(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            (cache / "ggml-base.en.bin").write_bytes(b"corrupt")
            with patch.object(package_models.urllib.request, "build_opener") as download:
                with self.assertRaisesRegex(ValueError, "Cached model"):
                    package_models.cached_model("base.en", "0" * 64, cache)
                download.assert_not_called()

    def test_insecure_redirect_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            package_models.HTTPSRedirect().redirect_request(None, None, 302, "", {}, "http://example.com/model")


if __name__ == "__main__":
    unittest.main()
