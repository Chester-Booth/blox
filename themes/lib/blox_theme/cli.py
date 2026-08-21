from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any

from . import API_VERSION
from .core import (
    EXIT_APPLY,
    EXIT_DEPENDENCY,
    EXIT_LOCKED,
    EXIT_OK,
    EXIT_RELOAD_WARNING,
    EXIT_RENDER,
    EXIT_USAGE,
    EXIT_VALIDATION,
    DEFAULT_THEME_ID,
    builtin_themes_dir,
    canonical_json,
    contrast_ratio,
    dependency_checks,
    derive_ansi,
    list_themes,
    load_theme,
    is_builtin_theme_path,
    render_manifest,
    render_theme,
    rendered_diff,
    repository_root,
    state_dir,
    theme_path,
    themes_dir,
    user_theme_library,
    validate_theme,
    write_render,
)
from .runtime import (
    LockContended,
    RuntimeFailure,
    TARGET_NAMES,
    TARGET_FILES,
    apply_theme,
    configured_targets,
    current_generation,
    loader_checks,
    reconcile,
    reset_target,
    rollback,
    setup_cursor,
    setup_gtk,
)
from .generators import BACKENDS, GeneratorFailure, generate_theme, save_theme_source
from .portability import PortabilityFailure, export_bundle, import_theme
from .trust import strip_widget_document


def envelope(command: str, data: Any = None, errors: list[str] | None = None, warnings: list[str] | None = None) -> dict[str, Any]:
    errors = errors or []
    warnings = warnings or []
    return {"api_version": API_VERSION, "command": command, "ok": not errors, "status": "error" if errors else "warning" if warnings else "ok", "data": data, "warnings": warnings, "errors": errors}


def emit(result: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(canonical_json(result), end="")
        return
    for error in result["errors"]:
        print(f"error: {error}", file=sys.stderr)
    for warning in result["warnings"]:
        print(f"warning: {warning}", file=sys.stderr)
    data = result["data"]
    if isinstance(data, str):
        print(data)
    elif data is not None:
        print(canonical_json(data), end="")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="themectl", description="Validate, render, and atomically apply built-in or user themes.")
    subcommands = root.add_subparsers(dest="command", required=True)

    list_parser = subcommands.add_parser("list", help="list source themes")
    list_parser.add_argument("--json", action="store_true")
    for name in ("show", "validate", "preview", "diff"):
        child = subcommands.add_parser(name)
        child.add_argument("theme")
        child.add_argument("--json", action="store_true")
    render = subcommands.add_parser("render")
    render.add_argument("theme")
    render.add_argument("--output", type=Path)
    render.add_argument("--json", action="store_true")
    doctor = subcommands.add_parser("doctor")
    doctor.add_argument("--json", action="store_true")
    apply_parser = subcommands.add_parser("apply")
    apply_parser.add_argument("theme")
    apply_parser.add_argument("--targets", help="comma-separated runtime targets")
    apply_parser.add_argument("--json", action="store_true")
    apply_parser.add_argument("--progress-ndjson", action="store_true", help="write structured progress events to stderr")
    reconcile_parser = subcommands.add_parser("reconcile")
    reconcile_parser.add_argument("--targets", help="comma-separated active targets")
    reconcile_parser.add_argument("--json", action="store_true")
    rollback_parser = subcommands.add_parser("rollback")
    rollback_parser.add_argument("generation", nargs="?")
    rollback_parser.add_argument("--json", action="store_true")
    reset_parser = subcommands.add_parser("reset-target")
    reset_parser.add_argument("target", choices=TARGET_NAMES)
    reset_parser.add_argument("--json", action="store_true")
    setup_parser = subcommands.add_parser("setup")
    setup_parser.add_argument("feature", choices=("gtk", "cursor"))
    setup_parser.add_argument("--yes", action="store_true", help="confirm the reversible loader migration")
    setup_parser.add_argument("--json", action="store_true")
    generate_parser = subcommands.add_parser("generate", help="generate an editable theme from a wallpaper")
    generate_parser.add_argument("wallpaper", type=Path)
    generate_parser.add_argument("--backend", default="matugen", help=f"generator backend ({', '.join(BACKENDS)}; default: matugen)")
    generate_parser.add_argument("--mode", choices=("dark", "light"), default="dark")
    generate_parser.add_argument("--scheme", default="scheme-tonal-spot", help="matugen colour scheme")
    generate_parser.add_argument("--contrast", type=float, default=0.0, help="matugen contrast from -1 to 1")
    generate_parser.add_argument("--source-colour-index", type=int, default=0, help="matugen 4.1 source colour index from 0 to 3")
    generate_parser.add_argument("--saturate", type=float, help="pywal saturation from 0 to 1")
    generate_parser.add_argument("--id", dest="theme_id")
    generate_parser.add_argument("--name")
    generate_parser.add_argument("--json", action="store_true")
    palette_parser = subcommands.add_parser("palette", help="preview available generator palettes for a wallpaper")
    palette_parser.add_argument("wallpaper", type=Path)
    palette_parser.add_argument("--mode", choices=("dark", "light"), default="dark")
    palette_parser.add_argument("--json", action="store_true")
    save_parser = subcommands.add_parser("save", help="save validated theme JSON as an editable source theme")
    save_parser.add_argument("theme_json", help="JSON file, inline JSON, or - for stdin")
    save_parser.add_argument("--replace", action="store_true", help="replace the same theme ID using optimistic concurrency")
    save_parser.add_argument("--expect-sha256", help="source digest returned by list")
    save_parser.add_argument("--json", action="store_true")
    duplicate_parser = subcommands.add_parser("duplicate", help="duplicate a source theme under a new stable ID")
    duplicate_parser.add_argument("theme")
    duplicate_parser.add_argument("new_id")
    duplicate_parser.add_argument("--name")
    duplicate_parser.add_argument("--json", action="store_true")
    rename_parser = subcommands.add_parser("rename", help="change a theme display name without changing its ID")
    rename_parser.add_argument("theme")
    rename_parser.add_argument("display_name")
    rename_parser.add_argument("--json", action="store_true")
    delete_parser = subcommands.add_parser("delete", help="delete an inactive user theme")
    delete_parser.add_argument("theme")
    delete_parser.add_argument("--yes", action="store_true", help="confirm permanent source deletion")
    delete_parser.add_argument("--json", action="store_true")
    import_parser = subcommands.add_parser("import", help="validate and add loose theme JSON or a .blox-theme bundle")
    import_parser.add_argument("file", type=Path)
    import_parser.add_argument("--json", action="store_true")
    export_parser = subcommands.add_parser("export", help="create a portable .blox-theme bundle")
    export_parser.add_argument("theme")
    export_parser.add_argument("--output", type=Path)
    export_parser.add_argument("--include-wallpaper", action="store_true", default=True)
    export_parser.add_argument("--exclude-wallpaper", action="store_false", dest="include_wallpaper")
    export_parser.add_argument("--exclude-widgets", action="store_true")
    export_parser.add_argument("--json", action="store_true")
    target_export = subcommands.add_parser("export-target", help="copy a generated target file to a chosen path")
    target_export.add_argument("target", choices=TARGET_NAMES)
    target_export.add_argument("--file", dest="target_file", help="generated file to copy when a target produces more than one")
    target_export.add_argument("--archive", action="store_true", help="export every generated file for the target as a zip archive")
    target_export.add_argument("--output", type=Path, required=True)
    target_export.add_argument("--json", action="store_true")
    widgets_export = subcommands.add_parser("widgets-export", help="export a detached widget configuration")
    widgets_export.add_argument("widgets_json")
    widgets_export.add_argument("--output", type=Path, required=True)
    widgets_export.add_argument("--json", action="store_true")
    widgets_import = subcommands.add_parser("widgets-import", help="validate a detached widget configuration")
    widgets_import.add_argument("file", type=Path)
    widgets_import.add_argument("--json", action="store_true")
    return root


def normalise_option_dashes(arguments: list[str]) -> list[str]:
    """Accept option prefixes copied from typography-aware applications."""
    normalised = []
    for argument in arguments:
        match = re.match(r"^[\u2010-\u2015\u2212]+-?", argument)
        normalised.append("--" + argument[match.end() :] if match else argument)
    return normalised


def checked_theme(command: str, reference: str, check_dependencies: bool = True, dependency_gate: bool = True) -> tuple[Path | None, dict[str, Any] | None, dict[str, Any] | None, int]:
    try:
        if reference.lstrip().startswith("{"):
            if command == "apply":
                raise ValueError("apply requires a saved source theme ID or path")
            theme = json.loads(reference)
            if not isinstance(theme, dict):
                raise ValueError("theme root must be a JSON object")
            source = theme_path(str(theme.get("id", "")))
            path = source if source.is_file() else builtin_themes_dir() / ".inline-theme.json"
        else:
            path, theme = load_theme(reference)
    except FileNotFoundError as error:
        return None, None, envelope(command, errors=[str(error)]), EXIT_DEPENDENCY
    except (OSError, json.JSONDecodeError, ValueError) as error:
        return None, None, envelope(command, errors=[str(error)]), EXIT_VALIDATION
    checked = validate_theme(theme, check_dependencies=check_dependencies, source_path=path, dependency_gate=dependency_gate)
    if checked.errors:
        return path, theme, envelope(command, errors=checked.errors, warnings=checked.warnings), EXIT_VALIDATION
    return path, theme, None, EXIT_OK


def run(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    command = args.command
    if command == "list":
        themes = list_themes()
        if args.json:
            return envelope(command, themes), EXIT_OK
        summary = "\n".join(f"{item['id']:<24} {item['variant'] or '-':<6} {item['name']}" for item in themes)
        return envelope(command, summary), EXIT_OK

    if command == "doctor":
        checks = {
            "repository": {"ok": repository_root().is_dir(), "path": str(repository_root())},
            "schema": {"ok": (themes_dir() / "schema/theme.schema.json").is_file()},
            "theme_library": {"ok": builtin_themes_dir().is_dir(), "path": str(builtin_themes_dir())},
            "jsonschema": {"ok": False, "required": False},
            "fc_match": {"ok": shutil.which("fc-match") is not None},
            "state_directory": {"ok": state_dir().is_dir(), "path": str(state_dir()), "required": False},
            "active_generation": {"ok": (state_dir() / "current").exists(), "required": False},
        }
        try:
            import jsonschema  # noqa: F401

            checks["jsonschema"]["ok"] = True
        except ImportError:
            pass
        warnings = ["jsonschema is not installed; using the bundled strict validator"] if not checks["jsonschema"]["ok"] else []
        if not checks["state_directory"]["ok"]:
            warnings.append("theme state directory does not exist yet; apply will create it")
        active_targets: set[str] = set()
        if checks["active_generation"]["ok"]:
            try:
                generation = current_generation()
                checks["generation_integrity"] = {"ok": generation is not None, "generation": generation[0].name if generation else None}
                active_targets = set(generation[1]["enabled_targets"]) if generation else set()
            except RuntimeFailure as error:
                checks["generation_integrity"] = {"ok": False, "error": str(error)}
        for name, check in loader_checks().items():
            if name == "kitty_generated_link":
                check["required"] = "kitty" in active_targets
            elif name in ("gtk3_loader", "gtk4_loader", "gtk3_generated_links", "gtk4_generated_links"):
                check["required"] = "gtk" in active_targets
            elif name == "cursor_setup":
                check["required"] = "cursor" in active_targets
            elif name == "cursor_generated_link":
                check["required"] = bool(check.get("expected"))
            else:
                check["required"] = True
            checks[name] = check
            if not check["ok"] and not check["required"]:
                warnings.append(f"{name} is not installed because its generated target is inactive")
        from .cursor import toolchain_check

        cursor_toolchain = toolchain_check()
        generated_cursor_active = bool(checks.get("cursor_generated_link", {}).get("expected"))
        cursor_toolchain["required"] = generated_cursor_active
        checks["cursor_toolchain"] = cursor_toolchain
        if not cursor_toolchain["ok"] and not cursor_toolchain["required"]:
            warnings.append(f"cursor toolchain is optional until a generated cursor is applied; run: {cursor_toolchain['recovery']}")
        if os.environ.get("GTK_THEME"):
            checks["gtk_session_environment"] = {"ok": False, "required": False, "value": os.environ["GTK_THEME"]}
            warnings.append("the current session still exports GTK_THEME; log out and back in for installed-theme mode to take full effect")
        errors = [name for name, check in checks.items() if not check["ok"] and check.get("required", True)]
        return envelope(command, checks, errors=[f"failed check: {name}" for name in errors], warnings=warnings), EXIT_DEPENDENCY if errors else EXIT_OK

    if command == "setup":
        if not args.yes:
            return envelope(command, errors=["setup requires explicit confirmation with --yes"]), EXIT_USAGE
        try:
            integration = setup_gtk() if args.feature == "gtk" else setup_cursor()
        except LockContended as error:
            return envelope(command, errors=[str(error)]), EXIT_LOCKED
        except (OSError, RuntimeFailure) as error:
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        return envelope(command, {"feature": args.feature, "integration": integration}), EXIT_OK

    if command == "export-target":
        available = TARGET_FILES[args.target]
        if args.archive and args.target_file:
            return envelope(command, errors=["--archive cannot be combined with --file"]), EXIT_USAGE
        relative_name = args.target_file or available[0]
        if relative_name not in available:
            return envelope(command, errors=[f"{relative_name} is not a generated file for {args.target}"]), EXIT_VALIDATION
        relative = Path(relative_name)
        source = state_dir() / "current" / relative
        output = args.output.expanduser()
        try:
            output.parent.mkdir(parents=True, exist_ok=True)
            if args.archive:
                missing = [name for name in available if not (state_dir() / "current" / name).is_file()]
                if missing:
                    raise FileNotFoundError(f"apply a theme with the {args.target} target before exporting it")
                with output.open("xb") as handle:
                    with zipfile.ZipFile(handle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                        for name in available:
                            archive.write(state_dir() / "current" / name, arcname=name)
            else:
                if not source.is_file():
                    raise FileNotFoundError(f"apply a theme with the {args.target} target before exporting it")
                with output.open("xb") as handle:
                    handle.write(source.read_bytes())
        except FileExistsError:
            return envelope(command, errors=[f"refusing to overwrite existing file: {output}"]), EXIT_VALIDATION
        except OSError as error:
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        return envelope(command, {"target": args.target, "output": str(output), "archive": args.archive}), EXIT_OK

    if command in ("widgets-export", "widgets-import"):
        try:
            if command == "widgets-export":
                widgets = json.loads(args.widgets_json)
                document = {"schema_version": 1, "kind": "blox-widgets", "widgets": widgets}
                probe = copy.deepcopy(load_theme(DEFAULT_THEME_ID)[1])
                probe["widgets"] = widgets
                checked = validate_theme(probe, check_dependencies=False)
                if checked.errors:
                    return envelope(command, errors=checked.errors), EXIT_VALIDATION
                output = args.output.expanduser()
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("x", encoding="utf-8") as handle:
                    handle.write(canonical_json(document))
                return envelope(command, {"output": str(output)}), EXIT_OK
            document = json.loads(args.file.read_text(encoding="utf-8"))
            if not isinstance(document, dict) or document.get("schema_version") != 1 or document.get("kind") != "blox-widgets" or not isinstance(document.get("widgets"), dict):
                raise ValueError("not a Blox widgets JSON document")
            probe = copy.deepcopy(load_theme(DEFAULT_THEME_ID)[1])
            probe["widgets"] = document["widgets"]
            checked = validate_theme(probe, check_dependencies=False)
            if checked.errors:
                return envelope(command, errors=checked.errors), EXIT_VALIDATION
            safe_document, executable_fields = strip_widget_document(document)
            warnings = []
            if executable_fields:
                warnings.append("disabled executable fields from untrusted import: " + ", ".join(executable_fields))
            return envelope(command, safe_document["widgets"], warnings=warnings), EXIT_OK
        except FileExistsError:
            return envelope(command, errors=[f"refusing to overwrite existing file: {args.output}"]), EXIT_VALIDATION
        except (OSError, json.JSONDecodeError, ValueError) as error:
            return envelope(command, errors=[str(error)]), EXIT_VALIDATION

    if command == "palette":
        entries = []
        warnings = []
        for backend in BACKENDS:
            for mode in ("dark", "light"):
                try:
                    theme, contrasts = generate_theme(args.wallpaper, backend=backend, mode=mode)
                    entries.append({"backend": backend, "mode": mode, "available": True, "colours": theme["colours"], "contrast": contrasts})
                except (FileNotFoundError, GeneratorFailure, OSError) as error:
                    entries.append({"backend": backend, "mode": mode, "available": False, "colours": {}, "contrast": [], "reason": str(error)})
                    warnings.append(f"{backend} {mode} palette unavailable: {error}")
        if not any(entry["available"] for entry in entries):
            return envelope(command, entries, errors=["no palette generator is available"], warnings=warnings), EXIT_DEPENDENCY
        return envelope(command, entries, warnings=warnings), EXIT_OK

    if command == "generate":
        try:
            theme, contrasts = generate_theme(
                args.wallpaper,
                backend=args.backend,
                mode=args.mode,
                scheme=args.scheme,
                contrast=args.contrast,
                source_colour_index=args.source_colour_index,
                saturation=args.saturate,
                theme_id=args.theme_id,
                name=args.name,
            )
        except FileNotFoundError as error:
            return envelope(command, errors=[str(error)]), EXIT_DEPENDENCY
        except (GeneratorFailure, OSError) as error:
            return envelope(command, errors=[str(error)]), EXIT_RENDER
        checked = validate_theme(theme, check_dependencies=False)
        data = {"theme": theme, "contrast": contrasts, "save_command": "themectl save <theme-json>"}
        return envelope(command, data, errors=checked.errors, warnings=checked.warnings), EXIT_VALIDATION if checked.errors else EXIT_OK

    if command == "save":
        try:
            if args.theme_json == "-":
                source = sys.stdin.read()
            else:
                candidate = Path(args.theme_json).expanduser()
                source = candidate.read_text(encoding="utf-8") if candidate.is_file() else args.theme_json
            theme = json.loads(source)
            if not isinstance(theme, dict):
                raise ValueError("theme root must be a JSON object")
        except (OSError, json.JSONDecodeError, ValueError) as error:
            return envelope(command, errors=[f"could not read theme JSON: {error}"]), EXIT_VALIDATION
        checked = validate_theme(theme, check_dependencies=False)
        if checked.errors:
            return envelope(command, {"theme": theme}, errors=checked.errors, warnings=checked.warnings), EXIT_VALIDATION
        try:
            existing = theme_path(theme["id"])
            if existing.is_file() and not args.replace:
                return envelope(command, errors=[f"theme source already exists: {theme['id']}"]), EXIT_VALIDATION
            if args.replace and existing.is_file() and is_builtin_theme_path(existing):
                return envelope(command, errors=["built-in themes are read-only; duplicate the theme first"]), EXIT_VALIDATION
            directory = existing.parent if args.replace and existing.is_file() else user_theme_library() / "themes"
            destination = save_theme_source(theme, directory, replace=args.replace, expected_sha256=args.expect_sha256)
        except (GeneratorFailure, OSError) as error:
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        digest = hashlib.sha256(destination.read_bytes()).hexdigest()
        return envelope(command, {"id": theme["id"], "path": str(destination), "source_sha256": digest}, warnings=checked.warnings), EXIT_OK

    if command == "import":
        try:
            reserved_ids = {path.stem for path in builtin_themes_dir().glob("*.json")}
            data, warnings = import_theme(args.file, user_theme_library(), reserved_ids=reserved_ids)
        except PortabilityFailure as error:
            return envelope(command, errors=[str(error)]), EXIT_VALIDATION
        except (GeneratorFailure, OSError) as error:
            return envelope(command, errors=[f"could not import theme: {error}"]), EXIT_APPLY
        return envelope(command, data, warnings=warnings), EXIT_OK

    if command == "export":
        path, theme, failure, code = checked_theme(command, args.theme, check_dependencies=False)
        if failure:
            return failure, code
        assert path is not None and theme is not None
        output = args.output or Path.cwd() / f"{theme['id']}.blox-theme"
        try:
            data, warnings = export_bundle(
                theme,
                output,
                include_wallpaper=args.include_wallpaper,
                include_widgets=not args.exclude_widgets,
                source_path=path,
            )
        except PortabilityFailure as error:
            return envelope(command, errors=[str(error)]), EXIT_VALIDATION
        except OSError as error:
            return envelope(command, errors=[f"could not export theme: {error}"]), EXIT_APPLY
        return envelope(command, data, warnings=warnings), EXIT_OK

    if command in ("duplicate", "rename", "delete"):
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.theme):
            return envelope(command, errors=["theme library mutations require a stable theme ID"]), EXIT_USAGE
        source = theme_path(args.theme)
        if not source.is_file() or source.is_symlink():
            return envelope(command, errors=[f"theme not found: {args.theme}"]), EXIT_DEPENDENCY
        if command in ("rename", "delete") and is_builtin_theme_path(source):
            return envelope(command, errors=["built-in themes are read-only; duplicate the theme first"]), EXIT_VALIDATION
        if command == "delete":
            if not args.yes:
                return envelope(command, errors=["delete requires explicit confirmation with --yes"]), EXIT_USAGE
            try:
                active = current_generation()
            except RuntimeFailure as error:
                return envelope(command, errors=[str(error)]), EXIT_APPLY
            if active and active[1]["theme_id"] == args.theme:
                return envelope(command, errors=["the active theme cannot be deleted; apply another theme first"]), EXIT_VALIDATION
            try:
                source.unlink()
                descriptor = os.open(source.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            except OSError as error:
                return envelope(command, errors=[f"could not delete theme: {error}"]), EXIT_APPLY
            return envelope(command, {"id": args.theme, "deleted": True}), EXIT_OK
        try:
            theme = json.loads(source.read_text(encoding="utf-8"))
            if not isinstance(theme, dict):
                raise ValueError("theme root must be a JSON object")
        except (OSError, json.JSONDecodeError, ValueError) as error:
            return envelope(command, errors=[f"could not read theme: {error}"]), EXIT_VALIDATION
        candidate = copy.deepcopy(theme)
        if command == "duplicate":
            candidate["id"] = args.new_id
            candidate["name"] = args.name or f"{theme['name']} Copy"
            if theme_path(candidate["id"]).is_file():
                return envelope(command, errors=[f"theme source already exists: {candidate['id']}"]), EXIT_VALIDATION
        else:
            candidate["name"] = args.display_name
        checked = validate_theme(candidate, check_dependencies=False)
        if checked.errors:
            return envelope(command, errors=checked.errors, warnings=checked.warnings), EXIT_VALIDATION
        try:
            if command == "duplicate":
                destination = save_theme_source(candidate, user_theme_library() / "themes")
            else:
                expected = hashlib.sha256(source.read_bytes()).hexdigest()
                destination = save_theme_source(candidate, source.parent, replace=True, expected_sha256=expected)
        except (GeneratorFailure, OSError) as error:
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        return envelope(command, {"id": candidate["id"], "name": candidate["name"], "path": str(destination), "source_sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}), EXIT_OK

    if command in ("reconcile", "rollback", "reset-target"):
        try:
            if command == "reconcile":
                selected = tuple(value.strip() for value in args.targets.split(",") if value.strip()) if args.targets else None
                manifest, warnings = reconcile(selected)
            elif command == "rollback":
                manifest, warnings = rollback(args.generation)
            else:
                manifest, warnings = reset_target(args.target)
        except LockContended as error:
            return envelope(command, errors=[str(error)]), EXIT_LOCKED
        except (OSError, RuntimeFailure) as error:
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        data = {"generation": manifest["generation_id"], "theme_id": manifest["theme_id"], "active_targets": manifest["enabled_targets"]}
        return envelope(command, data, warnings=warnings), EXIT_RELOAD_WARNING if warnings else EXIT_OK

    path, theme, failure, code = checked_theme(command, args.theme, check_dependencies=command not in ("show", "apply"), dependency_gate=command == "apply")
    if failure:
        return failure, code
    assert path is not None and theme is not None

    checked = validate_theme(theme, check_dependencies=command != "show", source_path=path, dependency_gate=command == "apply")
    if command == "show":
        return envelope(command, theme), EXIT_OK
    if command == "validate":
        data = {"id": theme["id"], "path": str(path), "valid": True}
        return envelope(command, data, warnings=checked.warnings), EXIT_OK

    if command == "apply":
        try:
            selected = configured_targets(theme, args.targets)
        except RuntimeFailure as error:
            return envelope(command, errors=[str(error)]), EXIT_VALIDATION
        checked = validate_theme(theme, check_dependencies=True, targets=set(selected), source_path=path)
        if checked.errors:
            return envelope(command, errors=checked.errors, warnings=checked.warnings), EXIT_VALIDATION
        progress_total = 3 + len(selected)
        last_progress: dict[str, Any] = {}

        def emit_progress(event: dict[str, Any]) -> None:
            nonlocal last_progress
            last_progress = event
            if not args.progress_ndjson:
                return
            print(json.dumps({"type": "theme-progress", **event}, sort_keys=True, separators=(",", ":")), file=sys.stderr, flush=True)

        def emit_failure(error: Exception) -> None:
            if last_progress.get("state") == "failed":
                return
            emit_progress({
                "kind": "stage",
                "stage": last_progress.get("stage", "source"),
                "state": "failed",
                "message": str(error),
                "completed": last_progress.get("completed", 0),
                "total": progress_total,
            })

        emit_progress({
            "kind": "stage",
            "stage": "prepare",
            "state": "active",
            "message": "Checking theme and dependencies",
            "completed": 0,
            "total": progress_total,
            "targets": list(selected),
        })
        try:
            manifest, warnings = apply_theme(path, theme, selected, progress=emit_progress)
        except LockContended as error:
            emit_failure(error)
            return envelope(command, errors=[str(error)]), EXIT_LOCKED
        except (OSError, RuntimeFailure, TypeError, ValueError) as error:
            emit_failure(error)
            return envelope(command, errors=[str(error)]), EXIT_APPLY
        data = {"generation": manifest["generation_id"], "theme_id": manifest["theme_id"], "changed_targets": list(selected), "active_targets": manifest["enabled_targets"]}
        operation_warnings = []
        if "gtk" in selected:
            operation_warnings.append("GTK changes apply to newly started applications; Libadwaita support is limited to best-effort user CSS")
            if os.environ.get("GTK_THEME"):
                operation_warnings.append("the current session still exports GTK_THEME; log out and back in to remove the legacy forced base theme")
        if "cursor" in selected:
            operation_warnings.append("cursor changes apply to new surfaces immediately; existing applications may require a restart")
        all_warnings = checked.warnings + operation_warnings + warnings
        return envelope(command, data, warnings=all_warnings), EXIT_RELOAD_WARNING if warnings else EXIT_OK

    try:
        files, render_warnings = render_theme(theme, path)
        manifest = render_manifest(path, theme, files)
    except (KeyError, TypeError, ValueError) as error:
        return envelope(command, errors=[f"render failed: {error}"]), EXIT_RENDER
    warnings = checked.warnings + render_warnings
    if command == "render":
        if args.output:
            try:
                write_render(args.output, files, manifest)
            except (OSError, ValueError) as error:
                return envelope(command, errors=[f"render failed: {error}"]), EXIT_RENDER
        data = {"theme_id": theme["id"], "output": str(args.output.expanduser().resolve()) if args.output else None, "manifest": manifest}
        return envelope(command, data, warnings=warnings), EXIT_OK
    if command == "diff":
        return envelope(command, {"theme_id": theme["id"], "state_directory": str(state_dir()), "changes": rendered_diff(files)}, warnings=warnings), EXIT_OK

    colours = theme["colours"]
    pairs = {}
    for foreground, background in (("foreground", "background"), ("foreground", "surface"), ("muted", "background"), ("selection_foreground", "selection_background"), ("accent", "background")):
        pairs[f"{foreground}/{background}"] = round(contrast_ratio(colours[foreground], colours[background]), 2)
    data = {
        "id": theme["id"], "name": theme["name"], "variant": theme["variant"],
        "colours": colours, "ansi": derive_ansi(theme), "fonts": theme["fonts"],
        "contrast": pairs, "enabled_targets": [name for name, enabled in theme["targets"].items() if enabled],
        "rendered_files": list(files),
    }
    if theme["targets"]["cursor"]:
        from .cursor import cursor_colours, cursor_metadata, toolchain_check, validate_cursor_cache

        cursor = cursor_metadata(theme)
        cursor_preview = {
            "mode": cursor["mode"],
            "theme_name": cursor["theme_name"],
            "size": cursor["size"],
            "states": ["left_ptr", "hand2", "text", "wait", "not-allowed", "move", "resize"],
            "restart_required_for_existing_processes": True,
        }
        if cursor["mode"] == "generated":
            cache = state_dir() / f"cursors/{cursor['cache_key']}"
            cursor_preview.update({
                "sizes": cursor["sizes"],
                "handedness": cursor["handedness"],
                "colours": cursor_colours(theme),
                "cache_key": cursor["cache_key"],
                "cache_hit": validate_cursor_cache(cache, cursor),
                "toolchain": toolchain_check(),
            })
        data["cursor"] = cursor_preview
        warnings.append("existing applications may retain the previous cursor until they restart or create new surfaces")
    if theme["targets"]["gtk"]:
        data["gtk"] = {
            "mode": theme["gtk"]["mode"],
            "base_theme": theme["gtk"]["base_theme"],
            "generated_css": theme["gtk"]["mode"] == "generated",
            "restart_required": True,
            "libadwaita_support": "partial-user-css",
            "session_gtk_theme": os.environ.get("GTK_THEME"),
        }
        warnings.append("GTK changes require applications to restart; Libadwaita may ignore base-theme and widget overrides")
    return envelope(command, data, warnings=warnings), EXIT_OK


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    args = parser().parse_args(normalise_option_dashes(arguments))
    result, code = run(args)
    emit(result, args.json)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
