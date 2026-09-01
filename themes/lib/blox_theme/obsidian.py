from __future__ import annotations

import json
import os
import signal
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .core import OBSIDIAN_THEME_DIRECTORY, OBSIDIAN_THEME_NAME, canonical_json, sha256_text
from .editor import EditorSettingsFailure, apply_fragment, members, read_settings_values, restore_settings


class ObsidianFailure(RuntimeError):
    """A safe, user-facing Obsidian integration failure."""


OBSIDIAN_CLI_TIMEOUT_SECONDS = 8.0
OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS = 1.0
OBSIDIAN_PACKAGE_APPLY_SETTLE_SECONDS = 1.0
# Obsidian represents its built-in default theme with no cssTheme value.
OBSIDIAN_LIVE_REFRESH_THEME = ""
LEGACY_OBSIDIAN_THEME_DIRECTORY = "blox-generated"


@dataclass(frozen=True)
class ObsidianVault:
    vault_id: str
    path: Path


@dataclass(frozen=True)
class ObsidianPaths:
    vault: ObsidianVault
    config: Path
    appearance: Path
    themes: Path
    package: Path
    manifest: Path
    stylesheet: Path


def obsidian_config_path() -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return config_home / "obsidian/obsidian.json"


def obsidian_integration_path(root: Path) -> Path:
    return root / "integration/obsidian.json"


def _read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ObsidianFailure(f"Obsidian {label} is invalid: {path}") from error


def _resolved_vault_path(value: Any) -> Path:
    if not isinstance(value, str) or not value:
        raise ObsidianFailure("Obsidian vault paths must be non-empty strings")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise ObsidianFailure(f"Obsidian vault path is not absolute: {value}")
    try:
        return path.resolve()
    except (OSError, RuntimeError) as error:
        raise ObsidianFailure(f"could not resolve Obsidian vault path: {value}") from error


def _vault_entries() -> dict[str, dict[str, Any]]:
    document = _read_json(obsidian_config_path(), "global configuration")
    if not isinstance(document, dict) or not isinstance(document.get("vaults"), dict):
        raise ObsidianFailure(f"Obsidian global configuration has no vault registry: {obsidian_config_path()}")
    entries: dict[str, dict[str, Any]] = {}
    for vault_id, entry in document["vaults"].items():
        if not isinstance(vault_id, str) or not isinstance(entry, dict):
            raise ObsidianFailure(f"Obsidian vault registry contains an invalid entry: {obsidian_config_path()}")
        entries[vault_id] = entry
    return entries


def discover_vault() -> ObsidianVault:
    """Choose one vault explicitly, or the single vault Obsidian marks open.

    ``BLOX_OBSIDIAN_VAULT`` accepts either the registry ID or the absolute
    vault path. It gives headless and multi-vault setups an explicit choice
    without adding a second picker to the Theme Picker yet.
    """
    entries = _vault_entries()
    selector = os.environ.get("BLOX_OBSIDIAN_VAULT", "").strip()
    if selector:
        matches = []
        for vault_id, entry in entries.items():
            if vault_id == selector:
                matches.append((vault_id, entry))
                continue
            try:
                if _resolved_vault_path(entry.get("path")) == _resolved_vault_path(selector):
                    matches.append((vault_id, entry))
            except ObsidianFailure:
                continue
        if len(matches) != 1:
            raise ObsidianFailure(
                f"BLOX_OBSIDIAN_VAULT did not identify exactly one registered vault: {selector}"
            )
    else:
        matches = [(vault_id, entry) for vault_id, entry in entries.items() if entry.get("open") is True]
        if len(matches) != 1:
            if not matches:
                raise ObsidianFailure(
                    "no Obsidian vault is marked open; open one vault or set BLOX_OBSIDIAN_VAULT"
                )
            raise ObsidianFailure(
                "multiple Obsidian vaults are marked open; close all but one or set BLOX_OBSIDIAN_VAULT"
            )
    vault_id, entry = matches[0]
    return ObsidianVault(vault_id, _resolved_vault_path(entry.get("path")))


def _regular_directory(path: Path, label: str, create: bool = False) -> None:
    if path.is_symlink():
        raise ObsidianFailure(f"refusing to use symlinked Obsidian {label}: {path}")
    if path.exists() and not path.is_dir():
        raise ObsidianFailure(f"Obsidian {label} is not a directory: {path}")
    if create:
        path.mkdir(parents=True, exist_ok=True)


def _regular_file(path: Path, label: str) -> None:
    if path.is_symlink():
        raise ObsidianFailure(f"refusing to replace symlinked Obsidian {label}: {path}")
    if path.exists() and not path.is_file():
        raise ObsidianFailure(f"Obsidian {label} is not a regular file: {path}")


def safe_paths(vault: ObsidianVault, create: bool = False) -> ObsidianPaths:
    vault_path = vault.path
    if vault_path.is_symlink():
        raise ObsidianFailure(f"refusing to use symlinked Obsidian vault: {vault_path}")
    if not vault_path.is_dir():
        raise ObsidianFailure(f"Obsidian vault is not a directory: {vault_path}")
    config = vault_path / ".obsidian"
    _regular_directory(config, "vault configuration directory")
    if not config.is_dir():
        raise ObsidianFailure(f"Obsidian vault configuration directory is missing: {config}")
    appearance = config / "appearance.json"
    _regular_file(appearance, "appearance settings")
    themes = config / "themes"
    _regular_directory(themes, "themes directory", create=create)
    package = themes / OBSIDIAN_THEME_DIRECTORY
    _regular_directory(package, "generated theme directory")
    manifest = package / "manifest.json"
    stylesheet = package / "theme.css"
    _regular_file(manifest, "generated theme manifest")
    _regular_file(stylesheet, "generated theme stylesheet")
    return ObsidianPaths(vault, config, appearance, themes, package, manifest, stylesheet)


def _legacy_package_path(paths: ObsidianPaths) -> Path:
    return paths.themes / LEGACY_OBSIDIAN_THEME_DIRECTORY


def _integration_package_path(paths: ObsidianPaths, integration: dict[str, Any]) -> Path:
    package = Path(integration["package_path"])
    if package not in {paths.package, _legacy_package_path(paths)}:
        raise ObsidianFailure("Obsidian integration record points to a different vault configuration")
    return package


def _read_package_directory(package: Path) -> tuple[str | None, str | None]:
    if not package.exists():
        return None, None
    _regular_directory(package, "generated theme directory")
    manifest_path = package / "manifest.json"
    stylesheet_path = package / "theme.css"
    _regular_file(manifest_path, "generated theme manifest")
    _regular_file(stylesheet_path, "generated theme stylesheet")
    entries = {path.relative_to(package) for path in package.rglob("*") if path.is_file()}
    if entries != {Path("manifest.json"), Path("theme.css")}:
        raise ObsidianFailure(f"Blox's Obsidian theme directory contains unexpected files: {package}")
    try:
        manifest = manifest_path.read_text(encoding="utf-8")
        stylesheet = stylesheet_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ObsidianFailure(f"could not read Blox's Obsidian theme package: {package}") from error
    try:
        document = json.loads(manifest)
    except json.JSONDecodeError as error:
        raise ObsidianFailure(f"Blox's Obsidian theme manifest is invalid: {manifest_path}") from error
    if not isinstance(document, dict) or document.get("name") != OBSIDIAN_THEME_NAME:
        raise ObsidianFailure(f"refusing to replace a foreign Obsidian theme: {package}")
    return manifest, stylesheet


def _read_package(paths: ObsidianPaths) -> tuple[str | None, str | None]:
    return _read_package_directory(paths.package)


def _remove_package(package: Path) -> None:
    if not package.exists():
        return
    if package.is_symlink() or not package.is_dir():
        raise ObsidianFailure(f"cannot remove Obsidian theme package: {package}")
    shutil.rmtree(package)


def _setting_matches(value: dict[str, Any], expected: Any) -> bool:
    return value.get("present") is True and value.get("value") == expected


def _theme_selection_matches(value: dict[str, Any], expected: str) -> bool:
    if expected == "":
        # Obsidian has used both an absent key and an empty string for its
        # built-in theme across releases.
        return not value.get("present") or value.get("value") == ""
    return _setting_matches(value, expected)


def _load_integration(root: Path) -> dict[str, Any] | None:
    path = obsidian_integration_path(root)
    if not path.is_file():
        return None
    data = _read_json(path, "integration record")
    expected = {
        "schema_version", "vault_id", "vault_path", "appearance_path", "package_path",
        "previous_css_theme", "previous_appearance_existed", "last_css_theme",
        "last_manifest_sha256", "last_stylesheet_sha256",
    }
    if not isinstance(data, dict) or set(data) != expected or data["schema_version"] != 1:
        raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    if any(not isinstance(data[key], str) for key in ("vault_id", "vault_path", "appearance_path", "package_path", "last_css_theme", "last_manifest_sha256", "last_stylesheet_sha256")):
        raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    if not isinstance(data["previous_css_theme"], dict) or not isinstance(data["previous_css_theme"].get("present"), bool):
        raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    if data["previous_css_theme"]["present"] and "value" not in data["previous_css_theme"]:
        raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    if not isinstance(data["previous_appearance_existed"], bool):
        raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    for key in ("last_manifest_sha256", "last_stylesheet_sha256"):
        if len(data[key]) != 64 or any(character not in "0123456789abcdef" for character in data[key]):
            raise ObsidianFailure(f"Obsidian integration record is invalid: {path}")
    return data


def _save_integration(root: Path, data: dict[str, Any]) -> None:
    path = obsidian_integration_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    with temporary.open("x", encoding="utf-8") as handle:
        handle.write(canonical_json(data))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _empty_integration(paths: ObsidianPaths, previous: dict[str, Any], appearance_existed: bool) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "vault_id": paths.vault.vault_id,
        "vault_path": str(paths.vault.path),
        "appearance_path": str(paths.appearance),
        "package_path": str(paths.package),
        "previous_css_theme": previous,
        "previous_appearance_existed": appearance_existed,
        "last_css_theme": OBSIDIAN_THEME_NAME,
        "last_manifest_sha256": "0" * 64,
        "last_stylesheet_sha256": "0" * 64,
    }


def _integration_is_pending(integration: dict[str, Any]) -> bool:
    return (
        integration["last_manifest_sha256"] == "0" * 64
        and integration["last_stylesheet_sha256"] == "0" * 64
    )


def _check_integration_package(root: Path, integration: dict[str, Any], paths: ObsidianPaths) -> tuple[str, str, Path]:
    if integration["vault_id"] != paths.vault.vault_id or integration["vault_path"] != str(paths.vault.path):
        raise ObsidianFailure("Obsidian integration record points to a different vault")
    if integration["appearance_path"] != str(paths.appearance):
        raise ObsidianFailure("Obsidian integration record points to a different vault configuration")
    package = _integration_package_path(paths, integration)
    manifest, stylesheet = _read_package_directory(package)
    if manifest is None or stylesheet is None:
        raise ObsidianFailure(f"Blox's Obsidian theme package is missing: {package}")
    if sha256_text(manifest) != integration["last_manifest_sha256"] or sha256_text(stylesheet) != integration["last_stylesheet_sha256"]:
        raise ObsidianFailure(f"Blox's Obsidian theme package changed outside Blox: {package}")
    return manifest, stylesheet, package


def _check_integration_state(root: Path, integration: dict[str, Any], paths: ObsidianPaths, current: dict[str, Any]) -> tuple[str, str]:
    manifest, stylesheet, _ = _check_integration_package(root, integration, paths)
    if not _setting_matches(current, integration["last_css_theme"]):
        raise ObsidianFailure("Obsidian theme selection changed outside Blox")
    return manifest, stylesheet


def needs_reapply(root: Path) -> bool:
    """Report whether the active generation needs Obsidian repair work."""
    integration = _load_integration(root)
    if integration is None or _integration_is_pending(integration):
        return True
    try:
        paths = safe_paths(ObsidianVault(integration["vault_id"], Path(integration["vault_path"])))
        current = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
        _check_integration_state(root, integration, paths, current)
    except (OSError, EditorSettingsFailure, ObsidianFailure):
        return True
    return False


def preflight(root: Path) -> ObsidianVault:
    """Check vault ownership before a new generation is activated."""
    vault = discover_vault()
    paths = safe_paths(vault)
    current = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
    integration = _load_integration(root)
    if integration is not None:
        if _integration_is_pending(integration):
            if integration["vault_id"] != vault.vault_id or integration["vault_path"] != str(vault.path):
                raise ObsidianFailure("Obsidian integration record points to a different vault")
            if integration["appearance_path"] != str(paths.appearance):
                raise ObsidianFailure("Obsidian integration record points to a different vault configuration")
            _read_package_directory(_integration_package_path(paths, integration))
        else:
            # An explicit Apply is authoritative. If the user changed the
            # selected Obsidian theme outside Blox, publish will preserve that
            # choice as the new reset target instead of failing before it can
            # apply the requested theme.
            _check_integration_package(root, integration, paths)
    elif paths.package.exists():
        raise ObsidianFailure(f"refusing to replace an existing Obsidian theme directory: {paths.package}")
    elif _legacy_package_path(paths).exists():
        raise ObsidianFailure(f"refusing to replace an existing Obsidian theme directory: {_legacy_package_path(paths)}")
    elif _setting_matches(current, OBSIDIAN_THEME_NAME):
        raise ObsidianFailure("Obsidian already selects Blox generated without a Blox ownership record")
    return vault


def _write_new_file(path: Path, content: str) -> None:
    with path.open("x", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


def _install_package(paths: ObsidianPaths, manifest: str, stylesheet: str) -> None:
    paths.themes.mkdir(parents=True, exist_ok=True)
    temporary = paths.themes / f".{OBSIDIAN_THEME_DIRECTORY}.{uuid.uuid4().hex}.tmp"
    temporary.mkdir(mode=0o700)
    backup = paths.themes / f".{OBSIDIAN_THEME_DIRECTORY}.{uuid.uuid4().hex}.backup"
    try:
        _write_new_file(temporary / "manifest.json", manifest)
        _write_new_file(temporary / "theme.css", stylesheet)
        if paths.package.exists():
            os.replace(paths.package, backup)
        try:
            os.replace(temporary, paths.package)
        except Exception:
            if backup.exists() and not paths.package.exists():
                os.replace(backup, paths.package)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
        shutil.rmtree(backup, ignore_errors=True)


def _restore_package(paths: ObsidianPaths, manifest: str | None, stylesheet: str | None) -> None:
    _remove_package(paths.package)
    if manifest is not None and stylesheet is not None:
        _install_package(paths, manifest, stylesheet)


def _remove_empty_appearance(paths: ObsidianPaths, existed_before: bool) -> None:
    if existed_before or not paths.appearance.is_file():
        return
    try:
        parsed, _ = members(paths.appearance.read_text(encoding="utf-8"))
    except (OSError, EditorSettingsFailure):
        return
    if not parsed:
        paths.appearance.unlink()


def _obsidian_is_running() -> bool:
    """Return whether the installed Obsidian desktop process is running."""
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return False
    for process in proc_root.iterdir():
        if not process.name.isdigit():
            continue
        try:
            arguments = (process / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if any(
            b"obsidian/app.asar" in argument or b"obsidian/obsidian.asar" in argument
            for argument in arguments
        ):
            return True
    return False


def _stop_obsidian_cli(process: subprocess.Popen[bytes]) -> None:
    """Stop only the isolated helper process used for a live CLI request."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=1)


def _run_live_theme_set(paths: ObsidianPaths, name: str) -> None:
    """Ask an already running Obsidian instance to select a theme.

    Obsidian's command wrapper can remain alive with the desktop process, so
    its exit status is not a useful completion signal. Watch the vault file
    instead and keep the helper bounded.
    """
    command = ["obsidian", f"vault={paths.vault.vault_id}", "theme:set", f"name={name}"]
    environment = os.environ.copy()
    environment.pop("ELECTRON_RUN_AS_NODE", None)
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            start_new_session=True,
        )
    except OSError as error:
        raise ObsidianFailure(f"Obsidian could not select {name!r}: {error}") from error

    try:
        deadline = time.monotonic() + OBSIDIAN_CLI_TIMEOUT_SECONDS
        returncode: int | None = None
        while time.monotonic() < deadline:
            selected = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
            if _theme_selection_matches(selected, name):
                return
            returncode = process.poll()
            if returncode is not None:
                if returncode != 0:
                    raise ObsidianFailure(
                        f"Obsidian could not select {name!r}: CLI exited with status {returncode}"
                    )
            time.sleep(0.1)
    finally:
        _stop_obsidian_cli(process)
    raise ObsidianFailure(f"Obsidian did not select {name!r} within {OBSIDIAN_CLI_TIMEOUT_SECONDS:g} seconds")


def _run_theme_set(vault: ObsidianVault, name: str, run_command: Callable[[list[str]], subprocess.CompletedProcess[str]]) -> None:
    command = ["obsidian", f"vault={vault.vault_id}", "theme:set", f"name={name}"]
    result = run_command(command)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "command failed").strip().replace("\n", " ")
        raise ObsidianFailure(f"Obsidian could not select {name!r}: {detail}")


def _select_theme(
    paths: ObsidianPaths,
    name: str,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    real_cli: bool,
) -> None:
    if not real_cli:
        _run_theme_set(paths.vault, name, run_command)
    elif _obsidian_is_running():
        selected = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
        if _setting_matches(selected, name):
            # The generated package keeps one stable native name while its
            # CSS changes with each Blox theme. Obsidian does not repaint when
            # asked to select the already-selected name, so visit its built-in
            # theme first to force the open window to reload the package.
            _run_live_theme_set(paths, OBSIDIAN_LIVE_REFRESH_THEME)
            # The CLI updates appearance.json before the open renderer has
            # dropped the old stylesheet. Let that transition finish before
            # selecting the generated package again, or Obsidian can reuse
            # the cached CSS for the previous generation.
            time.sleep(OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS)
        _run_live_theme_set(paths, name)
    else:
        # Starting Obsidian just to run a setter leaves the apply process
        # attached to the GUI. The native package and this setting are enough
        # for the next launch, and avoid opening an app as a side effect.
        apply_fragment(paths.appearance, {"cssTheme": name}, atomic=False)


def _restore_previous_setting(
    paths: ObsidianPaths,
    previous: dict[str, Any],
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    real_cli: bool,
) -> None:
    if previous["present"]:
        value = previous.get("value")
        if not isinstance(value, str):
            raise ObsidianFailure("the previous Obsidian cssTheme value was not a string")
        _select_theme(paths, value, run_command, real_cli)
    else:
        restore_settings(paths.appearance, {}, ("cssTheme",), atomic=False)
    restored = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
    if previous["present"] and not _setting_matches(restored, previous["value"]):
        raise ObsidianFailure("Obsidian did not restore its previous theme selection")
    if not previous["present"] and restored["present"]:
        raise ObsidianFailure("Obsidian did not clear its generated theme selection")


def publish(
    root: Path,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    real_cli: bool = False,
) -> Path:
    source_manifest = root / "current/obsidian/manifest.json"
    source_stylesheet = root / "current/obsidian/theme.css"
    try:
        manifest = source_manifest.read_text(encoding="utf-8")
        stylesheet = source_stylesheet.read_text(encoding="utf-8")
        document = json.loads(manifest)
    except (OSError, json.JSONDecodeError) as error:
        raise ObsidianFailure(f"generated Obsidian theme package is invalid: {source_manifest}") from error
    if not isinstance(document, dict) or document.get("name") != OBSIDIAN_THEME_NAME:
        raise ObsidianFailure(f"generated Obsidian theme manifest has the wrong package name: {source_manifest}")

    vault = discover_vault()
    paths = safe_paths(vault, create=True)
    current = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
    appearance_existed = paths.appearance.is_file()
    integration = _load_integration(root)
    created_integration = integration is None
    previous_package_path: Path | None = None
    if integration is None:
        previous_manifest, previous_stylesheet = _read_package(paths)
        if previous_manifest is not None or previous_stylesheet is not None:
            raise ObsidianFailure(f"refusing to replace an existing Obsidian theme directory: {paths.package}")
        legacy_package = _legacy_package_path(paths)
        if legacy_package.exists():
            raise ObsidianFailure(f"refusing to replace an existing Obsidian theme directory: {legacy_package}")
        if _setting_matches(current, OBSIDIAN_THEME_NAME):
            raise ObsidianFailure("Obsidian already selects Blox generated without a Blox ownership record")
        previous_package = (None, None)
        integration = _empty_integration(paths, current, paths.appearance.is_file())
        _save_integration(root, integration)
    else:
        if _integration_is_pending(integration):
            if integration["vault_id"] != paths.vault.vault_id or integration["vault_path"] != str(paths.vault.path):
                raise ObsidianFailure("Obsidian integration record points to a different vault")
            if integration["appearance_path"] != str(paths.appearance):
                raise ObsidianFailure("Obsidian integration record points to a different vault configuration")
            pending_package = _integration_package_path(paths, integration)
            _read_package_directory(pending_package)
            if current != integration["previous_css_theme"]:
                _restore_previous_setting(paths, integration["previous_css_theme"], run_command, real_cli)
            _remove_empty_appearance(paths, integration["previous_appearance_existed"])
            _remove_package(pending_package)
            obsidian_integration_path(root).unlink(missing_ok=True)
            integration = None
            created_integration = True
            previous_package = (None, None)
            current = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
            integration = _empty_integration(paths, current, paths.appearance.is_file())
            _save_integration(root, integration)
        else:
            previous_manifest, previous_stylesheet, previous_package_path = _check_integration_package(root, integration, paths)
            previous_package = (previous_manifest, previous_stylesheet)
            if previous_package_path != paths.package:
                # The old implementation used a slugged directory while its
                # manifest used a display name. Keep the old package intact
                # until the recognised package has been installed and selected.
                if paths.package.exists():
                    raise ObsidianFailure(f"refusing to replace an existing Obsidian theme directory: {paths.package}")
                integration["package_path"] = str(paths.package)
            if not _setting_matches(current, integration["last_css_theme"]):
                # An explicit Apply should take ownership of the selected
                # theme while preserving the user's external choice for reset.
                integration["previous_css_theme"] = current

    live_package_was_selected = (
        real_cli
        and _obsidian_is_running()
        and _setting_matches(current, integration["last_css_theme"])
    )
    live_package_was_cleared = False
    try:
        if live_package_was_selected:
            # Obsidian keeps the active native stylesheet cached by package
            # path. Leave the package before replacing it so the next select
            # loads the newly generated CSS instead of the previous theme.
            _run_live_theme_set(paths, OBSIDIAN_LIVE_REFRESH_THEME)
            time.sleep(OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS)
            _remove_package(paths.package)
            time.sleep(OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS / 2)
            live_package_was_cleared = True
        _install_package(paths, manifest, stylesheet)
        if live_package_was_selected:
            # Wait for the new package files to be visible to Obsidian before
            # asking it to load the package again.
            time.sleep(OBSIDIAN_PACKAGE_APPLY_SETTLE_SECONDS)
        _select_theme(paths, OBSIDIAN_THEME_NAME, run_command, real_cli)
        selected = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
        if not _setting_matches(selected, OBSIDIAN_THEME_NAME):
            raise ObsidianFailure("Obsidian did not select the generated Blox theme")
        integration["last_manifest_sha256"] = sha256_text(manifest)
        integration["last_stylesheet_sha256"] = sha256_text(stylesheet)
        integration["last_css_theme"] = OBSIDIAN_THEME_NAME
        if previous_package_path is not None and previous_package_path != paths.package:
            _remove_package(previous_package_path)
        _save_integration(root, integration)
    except (OSError, EditorSettingsFailure, ObsidianFailure):
        try:
            if previous_package_path is not None and previous_package_path != paths.package:
                _remove_package(paths.package)
            else:
                _restore_package(paths, *previous_package)
            if live_package_was_cleared and current["present"] and isinstance(current.get("value"), str):
                try:
                    _select_theme(paths, current["value"], run_command, real_cli)
                except (EditorSettingsFailure, ObsidianFailure, OSError):
                    restore_settings(paths.appearance, {"cssTheme": current["value"]}, atomic=False)
            elif current["present"]:
                restore_settings(paths.appearance, {"cssTheme": current["value"]}, atomic=False)
            else:
                restore_settings(paths.appearance, {}, ("cssTheme",), atomic=False)
            _remove_empty_appearance(paths, appearance_existed)
        finally:
            if created_integration:
                obsidian_integration_path(root).unlink(missing_ok=True)
        raise
    return paths.vault.path


def reset(
    root: Path,
    run_command: Callable[[list[str]], subprocess.CompletedProcess[str]],
    real_cli: bool = False,
) -> list[str]:
    integration = _load_integration(root)
    if integration is None:
        return ["Obsidian has no Blox ownership record; its vault theme was left untouched"]
    vault = ObsidianVault(integration["vault_id"], Path(integration["vault_path"]))
    paths = safe_paths(vault)
    current = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
    if integration["appearance_path"] != str(paths.appearance):
        raise ObsidianFailure("Obsidian integration record points to a different vault configuration")
    package_path = _integration_package_path(paths, integration)
    if _integration_is_pending(integration):
        try:
            _read_package_directory(package_path)
            if current != integration["previous_css_theme"]:
                _restore_previous_setting(paths, integration["previous_css_theme"], run_command, real_cli)
            _remove_empty_appearance(paths, integration["previous_appearance_existed"])
            _remove_package(package_path)
            obsidian_integration_path(root).unlink(missing_ok=True)
        except (OSError, EditorSettingsFailure, ObsidianFailure) as error:
            return [f"Obsidian's incomplete theme apply was not reset: {error}"]
        return []
    if not _setting_matches(current, integration["last_css_theme"]):
        return ["Obsidian theme selection changed outside Blox; its vault theme was left untouched"]
    manifest, stylesheet, package_path = _check_integration_package(root, integration, paths)
    if manifest is None or stylesheet is None:
        return [f"Blox's Obsidian theme package is missing; left the vault theme untouched: {package_path}"]
    if sha256_text(manifest) != integration["last_manifest_sha256"] or sha256_text(stylesheet) != integration["last_stylesheet_sha256"]:
        return [f"Blox's Obsidian theme package changed outside Blox; left it untouched: {package_path}"]
    try:
        _restore_previous_setting(paths, integration["previous_css_theme"], run_command, real_cli)
        _remove_empty_appearance(paths, integration["previous_appearance_existed"])
        _remove_package(package_path)
        obsidian_integration_path(root).unlink(missing_ok=True)
    except (OSError, EditorSettingsFailure, ObsidianFailure) as error:
        try:
            restore_settings(paths.appearance, {"cssTheme": OBSIDIAN_THEME_NAME}, atomic=False)
        except (OSError, EditorSettingsFailure):
            pass
        return [f"Obsidian theme was not reset: {error}"]
    return []
