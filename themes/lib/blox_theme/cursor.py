from __future__ import annotations

import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from urllib.parse import urlparse

from .core import canonical_json, contrast_ratio, repository_root, state_dir


CURSOR_THEME_NAME = "blox-generated"
DOWNLOAD_LIMIT = 25 * 1024 * 1024


class CursorFailure(RuntimeError):
    pass


def cursor_manifest() -> dict[str, Any]:
    path = repository_root() / "themes/cursor/source.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CursorFailure(f"cursor source manifest is invalid: {path}") from error
    if not isinstance(data, dict) or set(data) != {"schema_version", "bibata", "cbmp", "clickgen"} or data.get("schema_version") != 1:
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    bibata = data["bibata"]
    cbmp = data["cbmp"]
    clickgen = data["clickgen"]
    if not isinstance(bibata, dict) or set(bibata) != {"archive_sha256", "archive_url", "commit", "licence", "licence_path", "source_directory", "version"}:
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    if not isinstance(cbmp, dict) or set(cbmp) != {"integrity", "licence", "package", "version"}:
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    if not isinstance(clickgen, dict) or set(clickgen) != {"licence", "package", "version", "wheel_sha256", "wheel_url"}:
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    if not all(isinstance(value, str) for section in (bibata, cbmp, clickgen) for value in section.values()):
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    if not re.fullmatch(r"[0-9a-f]{64}", bibata.get("archive_sha256", "")) or not re.fullmatch(r"[0-9a-f]{40}", bibata.get("commit", "")) or not re.fullmatch(r"[0-9a-f]{64}", clickgen.get("wheel_sha256", "")):
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    if not bibata.get("archive_url", "").startswith("https://") or not clickgen.get("wheel_url", "").startswith("https://"):
        raise CursorFailure(f"cursor source manifest is invalid: {path}")
    return data


def cursor_data_home() -> Path:
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()
    return base / "blox-theme/cursor-toolchain"


def _toolchain_id(manifest: dict[str, Any]) -> str:
    return f"bibata-{manifest['bibata']['version']}-clickgen-{manifest['clickgen']['version']}-cbmp-{manifest['cbmp']['version']}"


def toolchain_paths() -> dict[str, Path]:
    manifest = cursor_manifest()
    root = cursor_data_home() / _toolchain_id(manifest)
    return {
        "root": root,
        "source": root / "source",
        "ctgen": root / "venv/bin/ctgen",
        "cbmp": root / "npm/node_modules/.bin/cbmp",
        "record": root / "installed.json",
    }


def toolchain_check() -> dict[str, Any]:
    paths = toolchain_paths()
    missing = []
    required_source = ("LICENSE", "configs/right/x.build.toml", "configs/normal/x.build.toml", "svg/modern-right", "svg/modern")
    if not paths["source"].is_dir() or any(not (paths["source"] / name).exists() for name in required_source):
        missing.append("source")
    for name in ("ctgen", "cbmp"):
        if not paths[name].is_file():
            missing.append(name)
    manifest = cursor_manifest()
    try:
        lock = json.loads((paths["root"] / "npm/package-lock.json").read_text(encoding="utf-8"))
        cbmp_lock = lock["packages"]["node_modules/cbmp"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        cbmp_lock = None
    if not isinstance(cbmp_lock, dict) or cbmp_lock.get("version") != manifest["cbmp"]["version"] or cbmp_lock.get("integrity") != manifest["cbmp"]["integrity"]:
        missing.append("cbmp_lock")
    expected_record = {"schema_version": 1, "source": manifest["bibata"], "tools": {name: manifest[name] for name in ("clickgen", "cbmp")}}
    try:
        record = json.loads(paths["record"].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        record = None
    if record != expected_record:
        missing.append("record")
    return {
        "ok": not missing,
        "path": str(paths["root"]),
        "missing": missing,
        "recovery": "themes/bin/themectl setup cursor --yes",
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "blox-themectl/1"})
    with urllib.request.urlopen(request, timeout=30) as response, destination.open("xb") as output:
        total = 0
        while chunk := response.read(64 * 1024):
            total += len(chunk)
            if total > DOWNLOAD_LIMIT:
                raise CursorFailure(f"cursor setup download exceeds {DOWNLOAD_LIMIT} bytes")
            output.write(chunk)


def _extract_source(archive: Path, destination: Path, expected_directory: str) -> None:
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        prefix = f"{expected_directory}/"
        if not members or any(member.name != expected_directory and not member.name.startswith(prefix) for member in members):
            raise CursorFailure("Bibata archive contains an unexpected top-level path")
        if any(PurePosixPath(member.name).is_absolute() or ".." in PurePosixPath(member.name).parts for member in members):
            raise CursorFailure("Bibata archive contains an unsafe path")
        if any(not (member.isfile() or member.isdir() or member.issym()) for member in members):
            raise CursorFailure("Bibata archive contains unsupported special files")
        for member in members:
            if not member.issym():
                continue
            if PurePosixPath(member.linkname).is_absolute():
                raise CursorFailure("Bibata archive contains an unsafe link")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
            if resolved != expected_directory and not resolved.startswith(prefix):
                raise CursorFailure("Bibata archive contains an escaping link")
        bundle.extractall(destination, filter="data")


def _checked_run(command: list[str], cwd: Path | None = None, timeout: int = 300) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CursorFailure(f"cursor setup command failed to run: {' '.join(command)}: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit status {result.returncode}"
        raise CursorFailure(f"cursor setup command failed: {' '.join(command)}: {detail}")
    return result


def _checked_run_with_bitmap_progress(
    command: list[str],
    source: Path,
    output: Path,
    progress: Callable[[str], None],
    cwd: Path | None = None,
    timeout: int = 900,
) -> subprocess.CompletedProcess[str]:
    """Run cbmp while reporting each bitmap it finishes."""
    total = sum(1 for _, _, files in os.walk(source, followlinks=True) for name in files if name.endswith(".svg"))
    started = time.monotonic()
    try:
        with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
            process = subprocess.Popen(command, cwd=cwd, stdout=stdout, stderr=stderr, text=True)
            progress(f"cbmp started • 0/{total}")
            reported = 0
            while process.poll() is None:
                generated = sorted(output.glob("*.png"), key=lambda path: path.stat().st_mtime_ns)
                if len(generated) > reported:
                    reported = len(generated)
                    progress(f"Rendering {generated[-1].stem}.svg • {min(reported, total)}/{total}")
                if time.monotonic() - started >= timeout:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    raise subprocess.TimeoutExpired(command, timeout)
                time.sleep(0.2)

            generated = sorted(output.glob("*.png"), key=lambda path: path.stat().st_mtime_ns)
            if len(generated) > reported:
                progress(f"Rendering {generated[-1].stem}.svg • {min(len(generated), total)}/{total}")
            if process.returncode == 0:
                progress(f"cbmp finished • {min(len(generated), total)}/{total}")
            stdout.seek(0)
            stderr.seek(0)
            result = subprocess.CompletedProcess(command, process.returncode, stdout.read(), stderr.read())
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CursorFailure(f"cursor setup command failed to run: {' '.join(command)}: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit status {result.returncode}"
        raise CursorFailure(f"cursor setup command failed: {' '.join(command)}: {detail}")
    return result


def setup_toolchain(download: Callable[[str, Path], None] = _download) -> dict[str, Any]:
    manifest = cursor_manifest()
    paths = toolchain_paths()
    if toolchain_check()["ok"]:
        return {"path": str(paths["root"]), "cache_hit": True, "versions": {name: manifest[name]["version"] for name in ("bibata", "clickgen", "cbmp")}}
    for executable in ("npm", "node"):
        if not shutil.which(executable):
            raise CursorFailure(f"cursor setup requires {executable}; install it and rerun: themectl setup cursor --yes")
    root = paths["root"]
    if root.exists():
        raise CursorFailure(f"cursor toolchain is incomplete: {root}; remove that directory and rerun setup")
    root.parent.mkdir(parents=True, exist_ok=True)
    candidate = root.parent / f".{root.name}-{uuid.uuid4().hex}.tmp"
    candidate.mkdir(mode=0o700)
    activated = False
    try:
        archive = candidate / "bibata.tar.gz"
        download(manifest["bibata"]["archive_url"], archive)
        if _sha256(archive) != manifest["bibata"]["archive_sha256"]:
            raise CursorFailure("Bibata source archive checksum mismatch")
        extracted = candidate / "extracted"
        extracted.mkdir()
        _extract_source(archive, extracted, manifest["bibata"]["source_directory"])
        os.replace(extracted / manifest["bibata"]["source_directory"], candidate / "source")
        licence = candidate / "source" / manifest["bibata"]["licence_path"]
        if not licence.is_file():
            raise CursorFailure("Bibata source archive is missing its licence")

        wheel = candidate / Path(urlparse(manifest["clickgen"]["wheel_url"]).path).name
        download(manifest["clickgen"]["wheel_url"], wheel)
        if _sha256(wheel) != manifest["clickgen"]["wheel_sha256"]:
            raise CursorFailure("Clickgen wheel checksum mismatch")
        _checked_run([sys.executable, "-m", "venv", str(candidate / "venv")])
        _checked_run([str(candidate / "venv/bin/pip"), "install", str(wheel)])
        _checked_run(["npm", "install", "--ignore-scripts", "--prefix", str(candidate / "npm"), f"cbmp@{manifest['cbmp']['version']}"])
        try:
            package_lock = json.loads((candidate / "npm/package-lock.json").read_text(encoding="utf-8"))
            installed_cbmp = package_lock["packages"]["node_modules/cbmp"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            raise CursorFailure("npm did not record the installed cbmp package") from error
        if installed_cbmp.get("version") != manifest["cbmp"]["version"] or installed_cbmp.get("integrity") != manifest["cbmp"]["integrity"]:
            raise CursorFailure("installed cbmp package does not match the pinned version and integrity")
        _checked_run([str(candidate / "venv/bin/ctgen"), "--version"])
        _checked_run([str(candidate / "npm/node_modules/.bin/cbmp"), "--version"])
        archive.unlink()
        wheel.unlink()
        record = {
            "schema_version": 1,
            "source": manifest["bibata"],
            "tools": {name: manifest[name] for name in ("clickgen", "cbmp")},
        }
        (candidate / "installed.json").write_text(canonical_json(record), encoding="utf-8")
        try:
            os.replace(candidate, root)
            activated = True
        except OSError as error:
            if root.is_dir() and toolchain_check()["ok"]:
                shutil.rmtree(candidate, ignore_errors=True)
            else:
                raise CursorFailure(f"could not activate cursor toolchain: {error}") from error
        old_prefix = str(candidate).encode()
        new_prefix = str(root).encode()
        for script in (root / "venv/bin").iterdir():
            if script.is_symlink() or not script.is_file():
                continue
            content = script.read_bytes()
            if content.startswith(b"#!") and old_prefix in content:
                script.write_bytes(content.replace(old_prefix, new_prefix, 1))
        _checked_run([str(root / "venv/bin/ctgen"), "--version"])
    except Exception:
        shutil.rmtree(candidate, ignore_errors=True)
        if activated:
            shutil.rmtree(root, ignore_errors=True)
        raise
    return {"path": str(root), "cache_hit": False, "versions": {name: manifest[name]["version"] for name in ("bibata", "clickgen", "cbmp")}}


def cursor_colours(theme: dict[str, Any]) -> dict[str, str]:
    cursor = theme["cursor"]
    colours = theme["colours"]
    return {
        "base": cursor.get("base_colour", colours["accent"]).lower(),
        "outline": cursor.get("outline_colour", colours["foreground"]).lower(),
        "watch_background": cursor.get("watch_background", colours["surface"]).lower(),
    }


def cursor_metadata(theme: dict[str, Any]) -> dict[str, Any]:
    cursor = theme["cursor"]
    if cursor["mode"] == "installed":
        return {"schema_version": 1, "mode": "installed", "theme_name": cursor["base"], "size": cursor["sizes"][0]}
    manifest = cursor_manifest()
    values = {
        "source_version": manifest["bibata"]["version"],
        "source_commit": manifest["bibata"]["commit"],
        "clickgen_version": manifest["clickgen"]["version"],
        "cbmp_version": manifest["cbmp"]["version"],
        "style": cursor["base"],
        "handedness": cursor["handedness"],
        "sizes": cursor["sizes"],
        "colours": cursor_colours(theme),
    }
    key = hashlib.sha256(canonical_json(values).encode()).hexdigest()
    return {"schema_version": 1, "mode": "generated", "theme_name": CURSOR_THEME_NAME, "size": cursor["sizes"][0], "cache_key": key, **values}


def validate_cursor_theme(theme: dict[str, Any]) -> tuple[list[str], list[str]]:
    cursor = theme["cursor"]
    if cursor["mode"] != "generated":
        return [], []
    errors = []
    warnings = []
    if cursor["base"] != "Bibata-Modern-Classic":
        errors.append("generated cursor base must be Bibata-Modern-Classic")
    colours = cursor_colours(theme)
    if contrast_ratio(colours["base"], colours["outline"]) < 3:
        warnings.append("generated cursor base/outline contrast recommends 3.0:1")
    for surface in dict.fromkeys((theme["colours"]["background"], "#000000", "#ffffff")):
        if max(contrast_ratio(colours["base"], surface), contrast_ratio(colours["outline"], surface)) < 3:
            warnings.append(f"generated cursor may not be distinguishable from preview surface {surface}")
    if contrast_ratio(colours["watch_background"], colours["base"]) < 3 and contrast_ratio(colours["watch_background"], colours["outline"]) < 3:
        warnings.append("generated cursor watch background recommends 3.0:1 contrast with its base or outline")
    return errors, warnings


def _cache_files(theme_path: Path) -> list[dict[str, str]]:
    entries = []
    for path in sorted(theme_path.rglob("*")):
        relative = str(path.relative_to(theme_path))
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or ".." in Path(target).parts:
                raise CursorFailure(f"cursor cache contains unsafe symlink: {relative}")
            entries.append({"path": relative, "symlink": target})
        elif path.is_file():
            entries.append({"path": relative, "sha256": _sha256(path)})
    return entries


def validate_cursor_cache(cache: Path, metadata: dict[str, Any]) -> bool:
    try:
        record = json.loads((cache / "cache.json").read_text(encoding="utf-8"))
        theme = cache / "theme"
        files = _cache_files(theme)
    except (OSError, json.JSONDecodeError, CursorFailure):
        return False
    return record == {"schema_version": 1, "metadata": metadata, "files": files} and (theme / "index.theme").is_file() and (theme / "cursors/left_ptr").is_file()


def build_cursor_cache(metadata: dict[str, Any], root: Path | None = None, progress: Callable[[str], None] | None = None) -> tuple[Path, bool]:
    if metadata.get("mode") != "generated":
        raise CursorFailure("installed cursor mode does not use the generated cache")
    check = toolchain_check()
    if not check["ok"]:
        raise CursorFailure(f"cursor toolchain is not installed; run: {check['recovery']}")
    root = root or state_dir()
    caches = root / "cursors"
    cache = caches / metadata["cache_key"]
    if validate_cursor_cache(cache, metadata):
        return cache / "theme", True
    if cache.exists():
        raise CursorFailure(f"generated cursor cache is corrupt: {cache}")
    paths = toolchain_paths()
    candidate = caches / f".candidate-{metadata['cache_key']}-{uuid.uuid4().hex}"
    bitmaps = candidate / "bitmaps"
    output = candidate / "output"
    caches.mkdir(parents=True, exist_ok=True)
    candidate.mkdir(mode=0o700)
    source = paths["source"]
    suffix = "-right" if metadata["handedness"] == "right" else ""
    config_variant = "right" if metadata["handedness"] == "right" else "normal"
    svg = source / f"svg/modern{suffix}"
    config = source / f"configs/{config_variant}/x.build.toml"
    colours = metadata["colours"]
    try:
        bitmap_command = [
            str(paths["cbmp"]), "-d", str(svg), "-o", str(bitmaps),
            "-bc", colours["base"], "-oc", colours["outline"], "-wc", colours["watch_background"],
        ]
        if progress is None:
            _checked_run(bitmap_command, cwd=source, timeout=900)
        else:
            _checked_run_with_bitmap_progress(bitmap_command, svg, bitmaps, progress, cwd=source)
            progress("ctgen started")
        _checked_run([
            str(paths["ctgen"]), str(config), "-s", *[str(size) for size in metadata["sizes"]],
            "-p", "x11", "-d", str(bitmaps), "-o", str(output), "-n", CURSOR_THEME_NAME,
            "-c", "Generated by blox themectl from Bibata Cursor",
        ], cwd=source)
        built = output / CURSOR_THEME_NAME
        if not (built / "index.theme").is_file() or not (built / "cursors/left_ptr").is_file():
            raise CursorFailure("cursor compiler did not produce a complete Xcursor theme")
        os.replace(built, candidate / "theme")
        shutil.rmtree(bitmaps, ignore_errors=True)
        shutil.rmtree(output, ignore_errors=True)
        if progress is not None:
            progress("Validating cursor cache")
        record = {"schema_version": 1, "metadata": metadata, "files": _cache_files(candidate / "theme")}
        (candidate / "cache.json").write_text(canonical_json(record), encoding="utf-8")
        os.replace(candidate, cache)
    except Exception:
        shutil.rmtree(candidate, ignore_errors=True)
        raise
    if not validate_cursor_cache(cache, metadata):
        raise CursorFailure(f"generated cursor cache failed validation: {cache}")
    return cache / "theme", False
