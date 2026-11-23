#!/usr/bin/env python3
"""Build or validate Blox.Widgets.Terminal in an explicit QML import root."""
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

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("widgets/native/terminal.h", "widgets/native/terminal.cpp", "widgets/native/plugin.cpp",
           "widgets/qml/Blox/Widgets/Terminal/qmldir", "packaging/build_native_widgets.py")
PLUGIN = "libbloxwidgetsterminalplugin.so"


class BuildError(RuntimeError):
    pass


def hashes(root: Path) -> dict[str, str]:
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in SOURCES}


def validate(import_root: Path, source_root: Path | None = None) -> dict:
    """Hash-only installation guard. Never invokes a compiler or mutates files."""
    root = source_root or ROOT
    module = import_root / "Blox/Widgets/Terminal"
    try:
        metadata = json.loads((module / ".build.json").read_text())
        if (metadata.get("format") != 1 or metadata.get("sources") != hashes(root)
                or metadata.get("sha256") != hashlib.sha256((module / PLUGIN).read_bytes()).hexdigest()
                or (module / "qmldir").read_bytes() != (root / SOURCES[3]).read_bytes()):
            raise ValueError("build hashes differ")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise BuildError("Blox.Widgets.Terminal is missing or stale. Build it with "
                         f"python3 packaging/build_native_widgets.py --output-import-path {import_root}") from error
    return metadata


def run(command: list[str]) -> str:
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise BuildError((getattr(error, "stderr", "") or str(error)).strip()) from error


def build(import_root: Path) -> dict:
    import_root = import_root.resolve()
    packages = ["Qt6Quick", "Qt6Qml", "Qt6Gui", "Qt6Core"]
    flags = shlex.split(run(["pkg-config", "--cflags", *packages]))
    libraries = shlex.split(run(["pkg-config", "--libs", *packages]))
    versions = run(["pkg-config", "--modversion", *packages])
    compiler = shlex.split(os.environ.get("CXX", "c++"))
    if not compiler:
        raise BuildError("CXX is empty")
    libexec = run(["pkg-config", "--variable=libexecdir", "Qt6Core"])
    prefix = run(["pkg-config", "--variable=prefix", "Qt6Core"])
    candidates = [os.environ.get("QT6_MOC"), str(Path(libexec) / "moc"), str(Path(prefix) / "lib/qt6/moc"),
                  shutil.which("moc6"), shutil.which("moc")]
    moc = next((name for name in candidates if name and Path(name).is_file()), None)
    if not moc:
        raise BuildError("Qt 6 moc is required")
    source_hashes = hashes(ROOT)
    identity = [source_hashes, compiler, run([*compiler, "--version"]), versions, flags, libraries, run([moc, "-v"])]
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    module = import_root / "Blox/Widgets/Terminal"
    try:
        previous = validate(import_root)
        if previous.get("key") == key:
            return {"outputImportPath": str(import_root), "modulePath": str(module), "result": "cached", "cacheHit": True}
    except BuildError:
        pass
    module.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".widgets-build-", dir=module.parent) as directory:
        staging = Path(directory)
        run([moc, *flags, str(ROOT / SOURCES[0]), "-o", str(staging / "moc_terminal.cpp")])
        run([moc, *flags, str(ROOT / SOURCES[2]), "-o", str(staging / "plugin.moc")])
        run([*compiler, "-std=c++20", "-O2", "-fPIC", "-shared", "-I", str(staging), "-I", str(ROOT / "widgets/native"),
             *flags, str(ROOT / SOURCES[1]), str(ROOT / SOURCES[2]), str(staging / "moc_terminal.cpp"),
             "-o", str(staging / PLUGIN), *libraries])
        (staging / "qmldir").write_bytes((ROOT / SOURCES[3]).read_bytes())
        (staging / ".build.json").write_text(json.dumps({"format": 1, "key": key, "sources": source_hashes,
            "qtVersions": versions.splitlines(), "sha256": hashlib.sha256((staging / PLUGIN).read_bytes()).hexdigest()}, sort_keys=True) + "\n")
        module.mkdir(exist_ok=True)
        for name in (PLUGIN, "qmldir", ".build.json"):
            os.replace(staging / name, module / name)
    return {"outputImportPath": str(import_root), "modulePath": str(module), "result": "compiled", "cacheHit": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-import-path", required=True, type=Path)
    args = parser.parse_args()
    if not args.output_import_path.is_absolute():
        parser.error("--output-import-path must be absolute")
    try:
        print(json.dumps(build(args.output_import_path), sort_keys=True))
    except (BuildError, OSError) as error:
        parser.exit(1, f"build_native_widgets.py: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
