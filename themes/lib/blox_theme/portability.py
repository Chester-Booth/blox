from __future__ import annotations

import copy
import hashlib
import html
import json
import os
import re
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable

from .core import apply_theme_defaults, canonical_json, dependency_checks, resolve_wallpaper_path, validate_theme
from .generators import GeneratorFailure, save_theme_source
from .trust import strip_widget_commands, write_trust_record


BUNDLE_VERSION = 1
THEME_SCHEMA_VERSION = 1
MAX_LOOSE_JSON_BYTES = 1024 * 1024
MAX_BUNDLE_BYTES = 64 * 1024 * 1024
MAX_MEMBER_BYTES = 48 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_MEMBERS = 8


class PortabilityFailure(RuntimeError):
    pass


# Each hook migrates one schema version to the next. Keeping this registry in
# the import boundary prevents future migrations from weakening current schema
# validation or silently accepting unknown fields.
THEME_MIGRATIONS: dict[int, Callable[[dict[str, Any]], dict[str, Any]]] = {}


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def migrate_theme(value: Any) -> tuple[dict[str, Any], list[str]]:
    if not isinstance(value, dict):
        raise PortabilityFailure("theme root must be a JSON object")
    theme = copy.deepcopy(value)
    version = theme.get("schema_version")
    if not isinstance(version, int) or isinstance(version, bool):
        raise PortabilityFailure("theme schema_version must be an integer")
    warnings: list[str] = []
    while version < THEME_SCHEMA_VERSION:
        migration = THEME_MIGRATIONS.get(version)
        if migration is None:
            raise PortabilityFailure(f"theme schema version {version} has no migration to version {version + 1}")
        theme = migration(theme)
        next_version = theme.get("schema_version")
        if next_version != version + 1:
            raise PortabilityFailure(f"theme migration from version {version} did not produce version {version + 1}")
        warnings.append(f"migrated theme schema from version {version} to {next_version}")
        version = next_version
    if version > THEME_SCHEMA_VERSION:
        raise PortabilityFailure(f"theme schema version {version} is newer than supported version {THEME_SCHEMA_VERSION}")
    return apply_theme_defaults(theme), warnings


def dependency_notes(theme: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "fonts": sorted(set(theme["fonts"][role] for role in ("ui", "mono", "panel"))),
        "gtk_theme": theme["gtk"]["base_theme"],
        "icon_theme": theme["icons"]["theme"],
        "cursor": {"mode": theme["cursor"]["mode"], "base": theme["cursor"]["base"]},
        "generator": ({key: theme["generator"][key] for key in ("backend", "version", "mapping_version")} if theme.get("generator") else None),
        "bundled_assets": [],
    }


def _dependency_warnings(theme: dict[str, Any], source_path: Path | None = None) -> list[str]:
    checked = dependency_checks(theme, source_path=source_path, apply_gate=False)
    return [f"missing dependency: {message}" for message in checked.errors] + checked.warnings


def preview_svg(theme: dict[str, Any]) -> bytes:
    colours = theme["colours"]
    swatches = ("background", "surface", "surface_alt", "accent", "success", "warning", "danger", "mauve", "teal", "foreground")
    blocks = "".join(
        f'<rect x="{24 + index * 45}" y="116" width="45" height="44" fill="{colours[name].lower()}"/>'
        for index, name in enumerate(swatches)
    )
    name = html.escape(theme["name"], quote=True)
    variant = html.escape(theme["variant"], quote=True)
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="498" height="184" viewBox="0 0 498 184">'
        f'<rect width="498" height="184" rx="18" fill="{colours["background"].lower()}"/>'
        f'<rect x="18" y="18" width="462" height="148" rx="12" fill="{colours["surface"].lower()}" stroke="{colours["border"].lower()}"/>'
        f'<text x="34" y="57" fill="{colours["foreground"].lower()}" font-family="sans-serif" font-size="22">{name}</text>'
        f'<text x="34" y="84" fill="{colours["muted"].lower()}" font-family="sans-serif" font-size="13">Blox theme · {variant}</text>'
        f'{blocks}</svg>\n'
    )
    return svg.encode("utf-8")


def _safe_wallpaper_name(path: Path) -> str:
    suffix = path.suffix.lower()
    if not suffix or len(suffix) > 10 or not suffix[1:].isalnum():
        suffix = ".img"
    return f"wallpaper/source{suffix}"


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def export_bundle(
    theme: dict[str, Any], output: Path, include_wallpaper: bool = True, include_widgets: bool = True, source_path: Path | None = None
) -> tuple[dict[str, Any], list[str]]:
    migrated, migration_warnings = migrate_theme(theme)
    checked = validate_theme(migrated, check_dependencies=False, source_path=source_path)
    if checked.errors:
        raise PortabilityFailure("invalid theme: " + "; ".join(checked.errors))

    exported_theme = copy.deepcopy(migrated)
    if not include_widgets:
        exported_theme.pop("widgets", None)
    notes = dependency_notes(migrated)
    files: dict[str, bytes] = {
        "theme.json": canonical_json(exported_theme).encode("utf-8"),
        "preview.svg": preview_svg(migrated),
    }
    wallpaper_record: dict[str, Any] | None = None
    if include_wallpaper:
        source = resolve_wallpaper_path(migrated["wallpaper"]["path"], source_path)
        if source.is_symlink() or not source.is_file():
            raise PortabilityFailure(f"wallpaper is not a regular file: {source}")
        if source.stat().st_size > MAX_MEMBER_BYTES:
            raise PortabilityFailure(f"wallpaper exceeds the {MAX_MEMBER_BYTES}-byte bundle member limit")
        wallpaper_name = _safe_wallpaper_name(source)
        wallpaper_data = source.read_bytes()
        files[wallpaper_name] = wallpaper_data
        wallpaper_record = {"path": wallpaper_name, "source_path": migrated["wallpaper"]["path"]}
        notes["bundled_assets"] = ["wallpaper"]
    files["dependencies.json"] = canonical_json(notes).encode("utf-8")
    manifest = {
        "bundle_version": BUNDLE_VERSION,
        "theme_schema_version": migrated["schema_version"],
        "theme_id": migrated["id"],
        "wallpaper": wallpaper_record,
        "files": {name: {"sha256": _digest(data), "size": len(data)} for name, data in sorted(files.items())},
    }
    manifest_data = canonical_json(manifest).encode("utf-8")

    destination = output.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() or destination.is_symlink():
        raise PortabilityFailure(f"export destination already exists: {destination}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}-", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", allowZip64=False) as archive:
            archive.writestr(_zip_info("manifest.json"), manifest_data)
            for name, data in sorted(files.items()):
                archive.writestr(_zip_info(name), data)
        if temporary.stat().st_size > MAX_BUNDLE_BYTES:
            raise PortabilityFailure(f"bundle exceeds the {MAX_BUNDLE_BYTES}-byte archive limit")
        try:
            os.link(temporary, destination)
        except FileExistsError as error:
            raise PortabilityFailure(f"export destination already exists: {destination}") from error
    finally:
        temporary.unlink(missing_ok=True)
    data = {
        "id": migrated["id"],
        "path": str(destination),
        "files": sorted(["manifest.json", *files]),
        "wallpaper_included": include_wallpaper,
        "widgets_included": include_widgets,
    }
    return data, migration_warnings + checked.warnings + _dependency_warnings(migrated, source_path)


def _safe_member_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and "\\" not in name and not path.is_absolute() and all(part not in ("", ".", "..") for part in path.parts)


def _read_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    if info.file_size > MAX_MEMBER_BYTES:
        raise PortabilityFailure(f"bundle member exceeds size limit: {info.filename}")
    with archive.open(info, "r") as handle:
        data = handle.read(MAX_MEMBER_BYTES + 1)
    if len(data) > MAX_MEMBER_BYTES or len(data) != info.file_size:
        raise PortabilityFailure(f"bundle member has an invalid size: {info.filename}")
    return data


def _load_bundle(path: Path) -> tuple[dict[str, Any], bytes | None, str | None, list[str]]:
    if path.stat().st_size > MAX_BUNDLE_BYTES:
        raise PortabilityFailure(f"bundle exceeds the {MAX_BUNDLE_BYTES}-byte archive limit")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_MEMBERS:
                raise PortabilityFailure(f"bundle must contain between 1 and {MAX_MEMBERS} regular files")
            names: set[str] = set()
            for info in infos:
                if not _safe_member_name(info.filename) or info.filename in names:
                    raise PortabilityFailure(f"bundle contains an unsafe or duplicate path: {info.filename}")
                mode = info.external_attr >> 16
                if info.is_dir() or (mode and not stat.S_ISREG(mode)):
                    raise PortabilityFailure(f"bundle member is not a regular file: {info.filename}")
                names.add(info.filename)
            if sum(info.file_size for info in infos) > MAX_TOTAL_BYTES:
                raise PortabilityFailure(f"bundle exceeds the {MAX_TOTAL_BYTES}-byte extracted size limit")
            by_name = {info.filename: info for info in infos}
            if "manifest.json" not in by_name:
                raise PortabilityFailure("bundle is missing manifest.json")
            manifest = json.loads(_read_member(archive, by_name["manifest.json"]))
            required_manifest = {"bundle_version", "theme_schema_version", "theme_id", "wallpaper", "files"}
            if (
                not isinstance(manifest, dict)
                or set(manifest) != required_manifest
                or type(manifest.get("bundle_version")) is not int
                or manifest["bundle_version"] != BUNDLE_VERSION
                or type(manifest.get("theme_schema_version")) is not int
                or not isinstance(manifest.get("theme_id"), str)
            ):
                raise PortabilityFailure("bundle manifest is invalid or unsupported")
            records = manifest.get("files")
            if not isinstance(records, dict) or set(records) != names - {"manifest.json"}:
                raise PortabilityFailure("bundle manifest file list does not match the archive")
            contents: dict[str, bytes] = {}
            for name, record in records.items():
                if (
                    not isinstance(record, dict)
                    or set(record) != {"sha256", "size"}
                    or not isinstance(record["size"], int)
                    or isinstance(record["size"], bool)
                    or record["size"] < 0
                    or not isinstance(record["sha256"], str)
                    or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
                ):
                    raise PortabilityFailure(f"bundle manifest record is invalid: {name}")
                data = _read_member(archive, by_name[name])
                if record["size"] != len(data) or record["sha256"] != _digest(data):
                    raise PortabilityFailure(f"bundle digest or size mismatch: {name}")
                contents[name] = data
    except (zipfile.BadZipFile, zipfile.LargeZipFile, json.JSONDecodeError, UnicodeDecodeError, RuntimeError) as error:
        raise PortabilityFailure(f"could not read theme bundle: {error}") from error
    for required in ("theme.json", "preview.svg", "dependencies.json"):
        if required not in contents:
            raise PortabilityFailure(f"bundle is missing {required}")
    try:
        theme_value = json.loads(contents["theme.json"])
        dependencies = json.loads(contents["dependencies.json"])
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PortabilityFailure(f"bundle metadata is not valid JSON: {error}") from error
    if not isinstance(dependencies, dict) or type(dependencies.get("schema_version")) is not int or dependencies["schema_version"] != 1:
        raise PortabilityFailure("bundle dependency notes are invalid")
    theme, warnings = migrate_theme(theme_value)
    if manifest["theme_schema_version"] != theme_value.get("schema_version") or manifest["theme_id"] != theme.get("id"):
        raise PortabilityFailure("bundle manifest does not identify its theme JSON")
    wallpaper = manifest["wallpaper"]
    if wallpaper is None:
        if dependencies != dependency_notes(theme):
            raise PortabilityFailure("bundle dependency notes do not match the validated theme")
        return theme, None, None, warnings
    if (
        not isinstance(wallpaper, dict)
        or set(wallpaper) != {"path", "source_path"}
        or not isinstance(wallpaper["path"], str)
        or not isinstance(wallpaper["source_path"], str)
        or wallpaper["path"] not in contents
        or not wallpaper["path"].startswith("wallpaper/")
    ):
        raise PortabilityFailure("bundle wallpaper record is invalid")
    wallpaper_data = contents[wallpaper["path"]]
    if theme.get("generator") and _digest(wallpaper_data) != theme["generator"]["wallpaper_sha256"]:
        raise PortabilityFailure("bundled wallpaper does not match the generator wallpaper digest")
    expected_dependencies = dependency_notes(theme)
    expected_dependencies["bundled_assets"] = ["wallpaper"]
    if dependencies != expected_dependencies:
        raise PortabilityFailure("bundle dependency notes do not match the validated theme")
    return theme, wallpaper_data, Path(wallpaper["path"]).name, warnings


def _load_loose_json(path: Path) -> tuple[dict[str, Any], list[str]]:
    if path.stat().st_size > MAX_LOOSE_JSON_BYTES:
        raise PortabilityFailure(f"theme JSON exceeds the {MAX_LOOSE_JSON_BYTES}-byte limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PortabilityFailure(f"could not read theme JSON: {error}") from error
    return migrate_theme(value)


def import_theme(path: Path, library: Path, reserved_ids: set[str] | None = None) -> tuple[dict[str, Any], list[str]]:
    source = path.expanduser().resolve()
    if path.expanduser().is_symlink() or not source.is_file():
        raise PortabilityFailure(f"import source is not a regular file: {path}")
    source_sha256 = _digest(source.read_bytes())
    if zipfile.is_zipfile(source):
        theme, wallpaper_data, wallpaper_name, warnings = _load_bundle(source)
        source_kind = "bundle"
    else:
        theme, warnings = _load_loose_json(source)
        wallpaper_data = None
        wallpaper_name = None
        source_kind = "json"
        if not Path(theme["wallpaper"]["path"]).expanduser().is_absolute():
            theme["wallpaper"]["path"] = str(resolve_wallpaper_path(theme["wallpaper"]["path"], source))
    theme, executable_fields = strip_widget_commands(theme)
    checked = validate_theme(theme, check_dependencies=False, source_path=source)
    if checked.errors:
        raise PortabilityFailure("invalid imported theme: " + "; ".join(checked.errors))
    if reserved_ids and theme["id"] in reserved_ids:
        raise PortabilityFailure(f"theme source already exists: {theme['id']}")
    theme_destination = library / "themes" / f"{theme['id']}.json"
    if theme_destination.exists() or theme_destination.is_symlink():
        raise PortabilityFailure(f"theme source already exists: {theme_destination}")

    wallpaper_destination: Path | None = None
    if wallpaper_data is not None and wallpaper_name is not None:
        wallpaper_directory = library / "wallpapers" / theme["id"]
        if wallpaper_directory.exists() or wallpaper_directory.is_symlink():
            raise PortabilityFailure(f"imported wallpaper destination already exists: {wallpaper_directory}")
        wallpaper_directory.mkdir(parents=True)
        wallpaper_destination = wallpaper_directory / wallpaper_name
        try:
            wallpaper_destination.write_bytes(wallpaper_data)
            theme["wallpaper"]["path"] = str(wallpaper_destination.resolve())
        except OSError:
            wallpaper_destination.unlink(missing_ok=True)
            wallpaper_directory.rmdir()
            raise
    destination: Path | None = None
    trust_path: Path | None = None
    try:
        destination = save_theme_source(theme, library / "themes")
        trust_path = write_trust_record(
            library,
            theme["id"],
            source_sha256,
            _digest(destination.read_bytes()),
            executable_fields,
        )
    except (GeneratorFailure, OSError, ValueError):
        if destination is not None:
            destination.unlink(missing_ok=True)
        if wallpaper_destination is not None:
            wallpaper_destination.unlink(missing_ok=True)
            wallpaper_destination.parent.rmdir()
        if trust_path is not None:
            trust_path.unlink(missing_ok=True)
        raise
    result_warnings = warnings + checked.warnings + _dependency_warnings(theme, destination)
    if executable_fields:
        result_warnings.append("disabled executable fields from untrusted import: " + ", ".join(executable_fields))
    data = {
        "id": theme["id"],
        "path": str(destination),
        "source": str(source),
        "source_kind": source_kind,
        "wallpaper_imported": wallpaper_destination is not None,
        "applied": False,
        "source_sha256": source_sha256,
        "content_sha256": _digest(destination.read_bytes()),
        "trusted": False,
        "trust_record": str(trust_path),
        "executable_fields": executable_fields,
    }
    return data, result_warnings
