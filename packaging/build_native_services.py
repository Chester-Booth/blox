#!/usr/bin/env python3
"""Build the production Blox.Services QML module before installing or launching tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / "shell/native/services/service_owner.cpp"
IMAGE_SOURCES = ("image_cache.h", "image_cache.cpp", "image_cache_main.cpp")
EMOJI_SOURCES = ("emoji_index.h", "emoji_index.cpp")
KEYBOARD_SOURCES = ("keyboard_backlight.h", "keyboard_backlight.cpp")
HELPER = "blox-image-cache"
PLUGIN = "libbloxservicesplugin.so"
QMLDIR = "module Blox.Services\nplugin bloxservicesplugin\n"


class BuildError(RuntimeError):
    pass


def image_source_sha256(source_root: Path) -> str:
    root = source_root / "shell/native/services"
    return hashlib.sha256(b"".join(name.encode() + b"\0" + (root / name).read_bytes() for name in IMAGE_SOURCES)).hexdigest()


def emoji_source_sha256(source_root: Path) -> str:
    root = source_root / "shell/native/services"
    return hashlib.sha256(b"".join(name.encode() + b"\0" + (root / name).read_bytes() for name in EMOJI_SOURCES)).hexdigest()


def keyboard_source_sha256(source_root: Path) -> str:
    root = source_root / "shell/native/services"
    return hashlib.sha256(b"".join(name.encode() + b"\0" + (root / name).read_bytes() for name in KEYBOARD_SOURCES)).hexdigest()


def run(command: list[str]) -> str:
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise BuildError(detail.strip()) from error


def validate(import_root: Path, source_root: Path | None = None) -> dict[str, object]:
    """Check prebuilt artefacts using file hashes only, without running build tools."""
    root = source_root or Path(__file__).resolve().parents[1]
    module = import_root / "Blox/Services"
    try:
        metadata = json.loads((module / ".build.json").read_text())
        expected = {
            "format": 1,
            "sourceSha256": hashlib.sha256((root / "shell/native/services/service_owner.cpp").read_bytes()).hexdigest(),
            "imageCacheSourceSha256": image_source_sha256(root),
            "emojiIndexSourceSha256": emoji_source_sha256(root),
            "keyboardBacklightSourceSha256": keyboard_source_sha256(root),
            "resolverSha256": hashlib.sha256((root / "shell/native/services/image_cache_resolver.cpp").read_bytes()).hexdigest(),
            "buildScriptSha256": hashlib.sha256((root / "packaging/build_native_services.py").read_bytes()).hexdigest(),
            "sha256": hashlib.sha256((module / PLUGIN).read_bytes()).hexdigest(),
            "imageCacheSha256": hashlib.sha256((module / HELPER).read_bytes()).hexdigest(),
        }
        if not isinstance(metadata, dict) or any(metadata.get(key) != value for key, value in expected.items()):
            raise ValueError("build hashes differ")
        if (module / "qmldir").read_text() != QMLDIR:
            raise ValueError("module declaration differs")
        if not os.access(module / HELPER, os.X_OK):
            raise ValueError("image helper is not executable")
    except (OSError, ValueError, TypeError) as error:
        raise BuildError(
            "Blox.Services is missing or stale. Build it with "
            f"python3 packaging/build_native_services.py --output-import-path {import_root}"
        ) from error
    return metadata


def build(import_root: Path) -> dict[str, object]:
    """Compile into a caller-owned QML import root, reusing matching built artefacts."""
    import_root = import_root.resolve()
    packages = ["Qt6Qml", "Qt6DBus", "Qt6Gui"]
    cflags = shlex.split(run(["pkg-config", "--cflags", *packages]))
    libraries = shlex.split(run(["pkg-config", "--libs", *packages]))
    versions = run(["pkg-config", "--modversion", *packages])
    compiler = shlex.split(os.environ.get("CXX", "c++"))
    if not compiler:
        raise BuildError("CXX is empty")
    prefix = run(["pkg-config", "--variable=prefix", "Qt6Core"])
    libexec = run(["pkg-config", "--variable=libexecdir", "Qt6Core"])
    configured = os.environ.get("QT6_MOC")
    candidates = [configured, str(Path(libexec) / "moc") if libexec else None,
                  str(Path(prefix) / "lib/qt6/moc"), shutil.which("moc6"), shutil.which("moc")]
    moc = next((candidate for candidate in candidates if candidate and Path(candidate).is_file()), None)
    if not moc:
        raise BuildError("Qt 6 moc is required to build Blox.Services")
    source_root = SOURCE.parents[3]
    image_identity = image_source_sha256(source_root)
    emoji_identity = emoji_source_sha256(source_root)
    keyboard_identity = keyboard_source_sha256(source_root)
    resolver = SOURCE.parent / "image_cache_resolver.cpp"
    emoji = SOURCE.parent / "emoji_index.cpp"
    keyboard = SOURCE.parent / "keyboard_backlight.cpp"
    identity = SOURCE.read_bytes() + resolver.read_bytes() + image_identity.encode() + emoji_identity.encode() + keyboard_identity.encode() + Path(__file__).read_bytes()
    identity += json.dumps([compiler, run([*compiler, "--version"]), versions,
                           run([moc, "-v"]), cflags, libraries], sort_keys=True).encode()
    key = hashlib.sha256(identity).hexdigest()
    module = import_root / "Blox/Services"
    manifest = module / ".build.json"
    try:
        previous = json.loads(manifest.read_text())
        cached = (previous.get("key") == key
                  and previous.get("sha256") == hashlib.sha256((module / PLUGIN).read_bytes()).hexdigest()
                  and previous.get("imageCacheSha256") == hashlib.sha256((module / HELPER).read_bytes()).hexdigest()
                  and os.access(module / HELPER, os.X_OK)
                  and (module / "qmldir").read_text() == QMLDIR)
    except (OSError, ValueError, TypeError):
        cached = False
    if not cached:
        module.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".services-build-", dir=module.parent) as temporary:
            staging = Path(temporary)
            run([moc, *cflags, str(SOURCE), "-o", str(staging / "service_owner.moc")])
            run([moc, *cflags, str(resolver), "-o", str(staging / "image_cache_resolver.moc")])
            run([moc, *cflags, str(emoji), "-o", str(staging / "emoji_index.moc")])
            run([moc, *cflags, str(keyboard), "-o", str(staging / "keyboard_backlight.moc")])
            run([moc, *cflags, str(keyboard.with_suffix(".h")), "-o", str(staging / "moc_keyboard_backlight.cpp")])
            options = ["-std=c++17", "-O2", "-fPIC", f'-DBLOX_IMAGE_CACHE_BUILD_ID="{image_identity}"', *cflags]
            core = SOURCE.parent / "image_cache.cpp"
            run([*compiler, *options, "-shared", "-I", str(staging), str(SOURCE), str(resolver), str(core), str(emoji), str(keyboard), str(staging / "moc_keyboard_backlight.cpp"),
                 "-o", str(staging / PLUGIN), *libraries])
            run([*compiler, *options, "-pie", str(core), str(SOURCE.parent / "image_cache_main.cpp"),
                 "-o", str(staging / HELPER), *libraries])
            (staging / "qmldir").write_text(QMLDIR)
            (staging / ".build.json").write_text(json.dumps({
                "format": 1, "key": key,
                "sourceSha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                "imageCacheSourceSha256": image_identity,
                "emojiIndexSourceSha256": emoji_identity,
                "keyboardBacklightSourceSha256": keyboard_identity,
                "resolverSha256": hashlib.sha256(resolver.read_bytes()).hexdigest(),
                "buildScriptSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "qtVersions": versions.splitlines(),
                "sha256": hashlib.sha256((staging / PLUGIN).read_bytes()).hexdigest(),
                "imageCacheSha256": hashlib.sha256((staging / HELPER).read_bytes()).hexdigest(),
            }, sort_keys=True) + "\n")
            for name in (PLUGIN, HELPER, "qmldir", ".build.json"):
                os.replace(staging / name, module / name)
    return {"outputImportPath": str(import_root), "modulePath": str(module),
            "imageCacheHelper": str(module / HELPER),
            "result": "cached" if cached else "compiled", "cacheHit": cached}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-import-path", required=True, type=Path)
    arguments = parser.parse_args()
    if not arguments.output_import_path.is_absolute():
        parser.error("--output-import-path must be absolute")
    try:
        print(json.dumps(build(arguments.output_import_path), sort_keys=True))
    except (BuildError, OSError) as error:
        parser.exit(1, f"build_native_services.py: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
