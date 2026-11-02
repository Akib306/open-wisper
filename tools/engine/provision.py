#!/usr/bin/env python3
"""Provision a shared, hash-pinned offline whisper.cpp profile. No Python packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
COMMIT = "a91dd3be72f70dd1b3cb6e252f35fa17b93f596c"
VERSION = "v1.8.1"
MODEL = "small.en"
MODEL_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
# Artifact digest, not an upstream signing/authenticity assertion.
MODEL_SHA256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
DECODE = ["--no-prints", "--no-timestamps", "--no-gpu", "--beam-size", "5",
          "--best-of", "5", "--temperature", "0", "--temperature-inc", "0.2", "--flash-attn"]
FLAGS = {"CMAKE_BUILD_TYPE": "Release", "BUILD_SHARED_LIBS": "OFF", "GGML_CPU": "ON",
         "GGML_BACKEND_DL": "OFF", "GGML_METAL": "OFF", "GGML_CUDA": "OFF",
         "WHISPER_COREML": "OFF", "WHISPER_OPENVINO": "OFF", "WHISPER_CURL": "OFF",
         "GGML_ACCELERATE": "ON", "GGML_BLAS": "ON", "GGML_HIP": "OFF", "GGML_VULKAN": "OFF",
         "GGML_SYCL": "OFF", "GGML_RPC": "OFF", "GGML_OPENCL": "OFF", "GGML_WEBGPU": "OFF", "GGML_MUSA": "OFF"}


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_profile(path):
    profile = json.loads(path.read_text())
    require(profile["schemaVersion"] == 1 and profile["sourceCommit"] == COMMIT,
            "Existing profile has a different schema or source commit.")
    require(profile["model"]["name"] == MODEL and profile["decodeArguments"] == DECODE,
            "Existing profile uses a different model or decoding configuration.")
    for name in ("executable", "model"):
        artifact = (path.parent / profile[name]["path"]).resolve()
        require(artifact.is_file() and digest(artifact) == profile[name]["sha256"],
                f"Existing {name} is missing or its hash changed. Restore it, or explicitly rerun with --refresh after reviewing the change.")
        profile[name]["path"] = str(artifact)
    require(profile["model"]["sha256"] == MODEL_SHA256, "The model does not match the declared reference profile.")
    return profile


def write_profile(profile, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".profile-", dir=destination.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(profile, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepare_build(source):
    require(shutil.which("cmake"), "CMake is required to build the engine. Existing artifacts can instead be imported offline.")
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", VERSION,
                        "https://github.com/ggml-org/whisper.cpp.git", str(source)], check=True)
    require(run("git", "rev-parse", "HEAD", cwd=source) == COMMIT, "Existing source checkout is not the pinned commit; it has not been modified.")
    require(not run("git", "status", "--porcelain", "--untracked-files=no", cwd=source), "Engine source has tracked modifications; refusing to label it a clean pinned build.")
    subprocess.run(["cmake", "-S", str(source), "-B", str(source / "build")]
                   + [f"-D{k}={v}" for k, v in sorted(FLAGS.items())], check=True)
    subprocess.run(["cmake", "--build", str(source / "build"), "--config", "Release", "--target", "whisper-cli",
                    "-j", str(min(os.cpu_count() or 4, 8))], check=True)
    model = source / "models" / f"ggml-{MODEL}.bin"
    if not model.exists():
        fd, temporary = tempfile.mkstemp(prefix=".model-", dir=model.parent)
        try:
            with os.fdopen(fd, "wb") as output, urllib.request.urlopen(
                    f"https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REVISION}/ggml-{MODEL}.bin", timeout=60) as response:
                shutil.copyfileobj(response, output)
            require(digest(temporary) == MODEL_SHA256, "Downloaded model does not match the reference SHA-256; nothing was installed.")
            os.replace(temporary, model)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return source / "build/bin/whisper-cli", model


def make_profile(source, executable, model, threads):
    require(source.is_dir(), "No existing whisper.cpp checkout. Run with --build, or use --import-profile for an offline manifest.")
    require(run("git", "rev-parse", "HEAD", cwd=source) == COMMIT, "Source checkout does not match the pinned v1.8.1 commit.")
    require(not run("git", "status", "--porcelain", "--untracked-files=no", cwd=source), "Engine checkout has tracked changes.")
    cache_path = source / "build/CMakeCache.txt"
    cache = {}
    for line in cache_path.read_text().splitlines():
        match = re.fullmatch(r"([A-Za-z0-9_]+):[^=]+=(.*)", line)
        if match:
            cache[match[1]] = match[2]
    require(all(cache.get(k) == v for k, v in FLAGS.items()), "The engine's build flags differ from the CPU baseline. Use a separately reviewed profile or run --build.")
    require(executable.is_file() and os.access(executable, os.X_OK), "The whisper-cli executable is missing or not executable.")
    require(digest(executable) == digest(source / "build/bin/whisper-cli"), "Runtime executable does not match the recorded source build output.")
    require(digest(model) == MODEL_SHA256, f"The model does not match the {MODEL} reference digest.")
    architecture = run("/usr/bin/lipo", "-archs", str(executable))
    require(architecture in ("arm64", "x86_64") and architecture == platform.machine(), "Engine must be a thin executable for this Mac's architecture.")
    # Record effective cache declarations as well as hashes of complete build evidence.
    build_flags = {k: v for k, v in cache.items() if v and (k.startswith(("GGML_", "WHISPER_", "CMAKE_C_FLAGS", "CMAKE_CXX_FLAGS")) or k in FLAGS)
                   and not k.endswith(("-STRINGS", "_FOUND"))}
    build_flags.update(FLAGS)
    evidence = {"CMakeCache.txt": digest(cache_path),
                "source-index": hashlib.sha256(run("git", "ls-files", "-s", cwd=source).encode()).hexdigest()}
    return {"schemaVersion": 1, "engine": "whisper.cpp", "sourceVersion": VERSION, "sourceCommit": COMMIT,
            "executable": {"path": str(executable.resolve()), "sha256": digest(executable)},
            "model": {"path": str(model.resolve()), "sha256": digest(model), "name": MODEL, "license": "MIT",
                      "licenseURL": "https://github.com/openai/whisper/blob/main/LICENSE"},
            "architecture": architecture, "buildFlags": [f"-D{k}={v}" for k, v in sorted(build_flags.items())],
            "threads": threads, "acceleration": "cpu-accelerate", "decodeArguments": DECODE,
            "language": "en", "residency": "short-lived",
            "provenance": {"kind": "local-build-metadata", "evidence": evidence,
                           "limitations": "Observed clean source checkout, local CMake metadata, and matching build/runtime binary hashes. This is not a reproducible-build or upstream authenticity proof. The model hash identifies the local reference artifact."}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Build the pinned source; downloads only missing source/model files.")
    parser.add_argument("--source", type=Path, help="Existing pinned source checkout.")
    parser.add_argument("--import-profile", type=Path, help="Verify and import a complete existing profile without network access.")
    parser.add_argument("--output", type=Path, default=ROOT / "tools/engine/runtime/manifest.json")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--refresh", action="store_true", help="Explicitly replace a previously recorded profile after reviewing artifact changes.")
    args = parser.parse_args()
    require(platform.system() == "Darwin", "This provisioning profile targets macOS.")
    require(1 <= args.threads <= 64, "Thread count must be 1–64.")
    destination = args.output.expanduser().absolute()
    if destination.exists() and not args.refresh:
        check_profile(destination)
        print(f"Verified existing profile: {destination}")
        return
    if args.import_profile:
        profile = check_profile(args.import_profile.expanduser().resolve())
    else:
        source = (args.source or ROOT / "mvp/tools/whisper.cpp").expanduser().resolve()
        if args.build:
            executable, model = prepare_build(source)
        else:
            runtime = ROOT / "mvp/tools/runtime"
            executable, model = runtime / "whisper-cli", runtime / f"ggml-{MODEL}.bin"
        profile = make_profile(source, executable, model, args.threads)
    write_profile(profile, destination)
    print(f"Ready: {destination}")
    print("Engine and model are shared in place. No runtime download or account is required.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Engine setup: {error}")
