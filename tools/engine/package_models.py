#!/usr/bin/env python3
"""Build relocatable schema-1 engine profiles using verified upstream models."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

from provision import MODEL_REVISION, digest, require, run, write_profile

MODELS = {
    "tiny.en-q5_1": "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
    "base.en": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
    "small.en": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
}


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        require(new_url.startswith("https://"), "Model download redirected away from HTTPS.")
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def cached_model(name, expected, cache):
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / f"ggml-{name}.bin"
    if target.exists():
        require(target.is_file() and digest(target) == expected,
                f"Cached model {name} failed SHA-256 verification; remove it and retry.")
        return target
    url = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REVISION}/{target.name}"
    fd, temporary = tempfile.mkstemp(prefix=".download-", dir=cache)
    try:
        with os.fdopen(fd, "wb") as output, urllib.request.build_opener(HTTPSRedirect()).open(url, timeout=60) as response:
            require(response.geturl().startswith("https://"), "Model download redirected away from HTTPS.")
            shutil.copyfileobj(response, output)
        require(digest(temporary) == expected, f"Downloaded model {name} failed SHA-256 verification.")
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target


def check_dependencies(executable):
    dependencies = run("otool", "-L", str(executable)).splitlines()[1:]
    require(dependencies, "The engine has no inspectable Mach-O dependencies.")
    for line in dependencies:
        dependency = os.path.normpath(line.strip().split(" (", 1)[0])
        require(dependency.startswith(("/usr/lib/", "/System/Library/")),
                f"Engine depends on an external library: {dependency}. Package a system-library-only engine.")


def package(profile_path, destination, cache, signing_identity=None):
    profile = json.loads(profile_path.read_text())
    executable = (profile_path.parent / profile["executable"]["path"]).resolve()
    require(digest(executable) == profile["executable"]["sha256"], "Source engine hash changed.")
    check_dependencies(executable)
    models = {name: cached_model(name, expected, cache) for name, expected in MODELS.items()}
    destination.mkdir(parents=True, exist_ok=True)
    packaged_engine = destination.parent / "MacOS" / "whisper-cli"
    packaged_engine.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, packaged_engine)
    require(digest(packaged_engine) == profile["executable"]["sha256"], "Copied engine hash changed.")
    packaged_engine.chmod(0o755)
    if signing_identity is not None:
        subprocess.run(["codesign", "--force", "--sign", signing_identity,
                        "--identifier", "dev.akib.openwisper.whisper-cli", str(packaged_engine)], check=True)
    packaged_digest = digest(packaged_engine)
    for name, source in models.items():
        target = destination / source.name
        shutil.copy2(source, target)
        target.chmod(0o644)
        require(digest(target) == MODELS[name], f"Copied model {name} failed SHA-256 verification.")
        result = copy.deepcopy(profile)
        result["executable"] = {"path": "../MacOS/whisper-cli", "sha256": packaged_digest}
        if signing_identity is not None:
            result["provenance"]["evidence"]["engine-before-packaging"] = profile["executable"]["sha256"]
            result["provenance"]["limitations"] += " Packaged engine re-signed; source build evidence refers to the pre-packaging executable."
        result["model"].update(path=target.name, sha256=MODELS[name], name=name)
        manifest = destination / f"engine-profile-{name}.json"
        write_profile(result, manifest)
        manifest.chmod(0o644)


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 5, "Usage: package_models.py PROFILE RESOURCES CACHE SIGNING_IDENTITY")
        package(*(Path(value).resolve() for value in sys.argv[1:4]), signing_identity=sys.argv[4])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Model packaging: {error}")
