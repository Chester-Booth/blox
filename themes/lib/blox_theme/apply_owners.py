"""Concrete generated-file owners for the Settings Apply transaction.

These owners activate theme files through the existing theme runtime.
Application owners also publish packages and selections. Other targets report
the restart or manual work still needed to load their generated files.
"""
from __future__ import annotations

import re
import copy
import base64
import json
import hashlib
import os
import shutil
from pathlib import Path
from typing import Any

from shell.scripts.hyprland_settings import HyprlandSettingsOwner, HyprlandSettingsError, HyprlandSettingsBeforeMutationError, JOURNAL as HYPRLAND_JOURNAL, render as render_hyprland_settings
from shell.scripts.settings_document import SettingsDocument

from . import runtime, target_preimage, hyprland
from .composition import CompositionDocument, component_digest
from .core import widget_model, canonical_json, load_theme, sha256_text, state_home, validate_theme
from .apply_coordinator import BeforeTargetPublicationFailure, ApplyCoordinator, ApplyError, CoreApplyFailure, BeforeCoreMutationFailure
from .component_bundle import PortabilityFailure, review_export


MANUAL_TARGETS = {"stylus"}


def _snapshot() -> dict[str, Any]:
    root = runtime.state_dir()
    current = runtime.current_generation(root)
    generations = sorted(
        path.name for path in (root / "generations").iterdir()
        if path.is_dir() and runtime.GENERATION_PATTERN.fullmatch(path.name)
    ) if (root / "generations").exists() else []
    return {"current": current[0].name if current else None, "generations": generations}


def _validate_snapshot(image: Any) -> None:
    if not isinstance(image, dict) or set(image) - {"current", "generations", "targetDigest", "external"} or not {"current", "generations"}.issubset(image):
        raise ApplyError("invalid theme generation pre-image")
    current, generations = image["current"], image["generations"]
    if current is not None and (not isinstance(current, str) or not runtime.GENERATION_PATTERN.fullmatch(current)):
        raise ApplyError("invalid current generation pre-image")
    if not isinstance(generations, list) or len(generations) != len(set(generations)) or any(
        not isinstance(name, str) or not runtime.GENERATION_PATTERN.fullmatch(name) for name in generations
    ) or (current is not None and current not in generations):
        raise ApplyError("invalid generation history pre-image")
    if "targetDigest" in image and (not isinstance(image["targetDigest"], str)
                                     or not re.fullmatch(r"[0-9a-f]{64}", image["targetDigest"])):
        raise ApplyError("invalid target digest pre-image")


def _restore_snapshot(image: dict[str, Any], selected: tuple[str, ...], *, widget_publication: str | None = None) -> None:
    _validate_snapshot(image)
    root = runtime.state_dir()
    with runtime.ApplicationLock(root):
        current = runtime.current_generation(root)
        current_name = current[0].name if current else None
        if widget_publication is not None:
            # The durable request reserves one generation. Equal contents do not
            # make any later generation ours to replace or delete.
            if not runtime.GENERATION_PATTERN.fullmatch(widget_publication):
                raise ApplyError("invalid widget publication identity")
            new_names = set(_snapshot()["generations"]) - set(image["generations"])
            if (widget_publication in image["generations"]
                    or new_names - {widget_publication}
                    or current_name not in {image["current"], widget_publication}):
                raise ApplyError("widget recovery would overwrite a competing generation")
        if current_name != image["current"]:
            if image["current"] is None:
                runtime.cleanup_managed_loaders(root, selected)
                (root / "current").unlink(missing_ok=True)
                (root / "active.json").unlink(missing_ok=True)
                runtime._fsync_directory(root)
            else:
                previous = root / "generations" / image["current"]
                manifest = runtime.validate_generation(previous)
                runtime._switch_generation(root, previous)
                runtime.sync_dynamic_loaders(root, manifest["enabled_targets"], selected)
        elif current is not None:
            runtime.sync_dynamic_loaders(root, current[1]["enabled_targets"], selected)
        else:
            runtime.cleanup_managed_loaders(root, selected)
        generations = root / "generations"
        if generations.exists():
            for path in generations.iterdir():
                if path.is_dir() and runtime.GENERATION_PATTERN.fullmatch(path.name) and path.name not in image["generations"]:
                    runtime.validate_generation(path)
                    shutil.rmtree(path)
            runtime._fsync_directory(generations)
    if _snapshot() != {key: image[key] for key in ("current", "generations")}:
        raise ApplyError("theme generation restore did not match its pre-image")


def _target_observation(target: str) -> dict[str, Any]:
    current = runtime.current_generation()
    manifest = current[1] if current else {"files": {}}
    files = {}
    for name in runtime.TARGET_FILES[target]:
        if name in manifest["files"]:
            path = current[0] / name
            files[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    # Check the live loader too. A manifest alone cannot reveal a replaced link.
    loaders = {}
    specs = runtime.phase7_loader_specs(runtime.state_dir())
    if target in specs:
        link, _ = specs[target]
        if link.is_symlink():
            loaders[str(link)] = {"kind": "symlink", "target": os.readlink(link)}
        elif link.is_file():
            loaders[str(link)] = {"kind": "file", "sha256": hashlib.sha256(link.read_bytes()).hexdigest()}
        elif link.exists():
            loaders[str(link)] = {"kind": "other"}
        else:
            loaders[str(link)] = {"kind": "absent"}
    if target in target_preimage.EXTERNAL_TARGETS:
        loaders["external"] = target_preimage.capture(target)["files"]
        if target in ("code", "cursor_editor"):
            # The other editor publishes into the same integration file.
            integration = str(runtime.editor_settings_integration_path(runtime.state_dir()))
            loaders["external"][integration] = {"record": runtime._load_editor_integration(runtime.state_dir())["editors"].get(target)}
    if target == "cursor" and current and "cursor" in manifest["enabled_targets"]:
        metadata = runtime._cursor_metadata(runtime.state_dir())
        if metadata["mode"] == "generated":
            from .cursor import _cache_files, validate_cursor_cache
            cache = runtime.state_dir() / "cursors" / metadata["cache_key"]
            loaders["cursorCache"] = {"valid": validate_cursor_cache(cache, metadata),
                "digest": component_digest(_cache_files(cache / "theme"))}
    checks = runtime.loader_checks() if target in ("gtk", "kitty", "quickshell", "cursor") else {}
    prefixes = ("gtk3_", "gtk4_") if target == "gtk" else (target + "_",)
    for key, value in checks.items():
        if key.startswith(prefixes):
            loaders[key] = value
    return {"digest": component_digest({"files": files, "loaders": loaders}), "revision": None}


class ThemeApplyCore:
    component_id = "theme-metadata"

    def __init__(self, settings: SettingsDocument, theme_path: Path, theme: dict[str, Any], selected: list[str],
                 hyprland_runner=None):
        self.settings = settings
        self.theme_path = theme_path
        self.theme = theme
        self.selected = tuple(selected)
        self.hyprland = HyprlandSettingsOwner(settings.root, hyprland_runner) if hyprland_runner else HyprlandSettingsOwner(settings.root)
        self.activation_attempted = False
        self.force_restore_reload = False

    def validate(self, request: dict[str, Any], settings: dict[str, Any], selected: list[str]) -> None:
        if request["themeId"] != self.theme["id"] or request["sourceDigest"] != sha256_text(canonical_json(self.theme)):
            raise ApplyError("theme source changed since review")
        try:
            _, current_theme = load_theme(str(self.theme_path))
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ApplyError("theme source is unavailable") from error
        if sha256_text(canonical_json(current_theme)) != request["sourceDigest"]:
            raise ApplyError("theme source changed since review")
        checked = validate_theme(self.theme, check_dependencies=True, targets=set(selected), source_path=self.theme_path)
        if checked.errors:
            raise ApplyError("; ".join(checked.errors))
        try:
            reviews = review_export(self.theme, settings, "full")
        except PortabilityFailure as error:
            raise ApplyError(str(error)) from error
        approvals = request["approvals"]
        required = {entry["path"]: entry["sha256"] for entry in reviews}
        if any(approvals.get(path) != digest for path, digest in required.items()):
            raise ApplyError("a user-owned script requires review and matching approval")
        try:
            self.hyprland.preflight()
        except HyprlandSettingsError as error:
            raise ApplyError(str(error)) from error
        source = render_hyprland_settings(settings)
        syntax = self.hyprland.runner(["luac", "-p", "-"], input=source)
        if syntax.returncode:
            raise ApplyError("generated Hyprland Settings Lua failed syntax validation")
        self.selected = tuple(selected)

    def capture(self) -> dict[str, Any]:
        return {"theme": _snapshot(), "hyprland": self.hyprland.capture_preimage()}

    def validate_image(self, image: Any) -> None:
        if not isinstance(image, dict) or set(image) != {"theme", "hyprland"}:
            raise ApplyError("invalid core pre-image")
        _validate_snapshot(image["theme"])
        if not isinstance(image["hyprland"], dict) or set(image["hyprland"]) != {
            "hyprland-settings.lua", "settings.json", "settings.json.bak"
        }:
            raise ApplyError("invalid Hyprland pre-image")

    def can_restore(self, image: dict[str, Any]) -> bool:
        try:
            self.validate_image(image)
            theme = image["theme"]
            if theme["current"] is not None:
                runtime.validate_generation(runtime.state_dir() / "generations" / theme["current"])
            return True
        except (ApplyError, OSError, runtime.RuntimeFailure):
            return False

    def apply(self, request: dict[str, Any]) -> dict[str, Any]:
        current = self.settings.get()
        if not current.ok or current.revision != request["settingsRevision"]:
            raise BeforeCoreMutationFailure("Settings changed before core activation")
        self.activation_attempted = True
        try:
            committed = self.hyprland.apply(current.data, current.revision)
        except HyprlandSettingsBeforeMutationError as error:
            self.activation_attempted = False
            raise BeforeCoreMutationFailure(str(error)) from error
        return {"digest": component_digest(committed), "revision": committed['settings']['revision'],
                "settingsDigest": component_digest(committed['settings'])}

    def verify(self, request: dict[str, Any]) -> None:
        current = self.settings.get()
        if not current.ok:
            raise CoreApplyFailure(f"Settings observation failed: {current.code}")

    def observe(self) -> dict[str, Any]:
        current = self.settings.get()
        if not current.ok:
            raise ApplyError(f"Settings observation failed: {current.code}")
        module = self.hyprland.capture_preimage()["hyprland-settings.lua"]
        return {"digest": component_digest({"settings": current.data, "module": module}),
                "revision": current.revision}

    def restore(self, image: dict[str, Any]) -> None:
        errors = []
        try:
            reload_needed = self.activation_attempted or self.hyprland.capture_preimage() != image["hyprland"]
        except Exception:
            reload_needed = self.activation_attempted
        try:
            _restore_snapshot(image["theme"], tuple(name for name in self.selected if name not in ("gtk", "cursor")))
        except Exception as error:
            errors.append(f"theme: {error}")
        try:
            prior = image['hyprland']['settings.json'] or image['hyprland']['settings.json.bak']
            before = self.settings._migrate(json.loads(base64.b64decode(prior))) if prior is not None else copy.deepcopy(self.settings.defaults)
            after = copy.deepcopy(before)
            after['revision'] = before['revision'] + 1
            allowed_settings = {(document['revision'], component_digest(document)) for document in (before, after)}
            module_after = base64.b64encode(render_hyprland_settings(after)).decode()
            self.hyprland.restore_preimage(image["hyprland"], allowed_settings=allowed_settings,
                                          allowed_modules=(image['hyprland']['hyprland-settings.lua'], module_after))
            if reload_needed or self.force_restore_reload:
                self.hyprland.reload_restored()
        except Exception as error:
            errors.append(f"Hyprland Settings: {error}")
        if errors:
            raise ApplyError("; ".join(errors))

    def verify_restored(self, image: dict[str, Any]) -> None:
        if _snapshot() != image["theme"] or self.hyprland.capture_preimage() != image["hyprland"]:
            raise ApplyError("core generation pre-image differs")

    def release_history(self) -> None:
        """Prune history only after the coordinator releases its recovery images."""
        root = runtime.state_dir()
        with runtime.ApplicationLock(root):
            current = runtime.current_generation(root)
            if current is not None:
                runtime._prune_generations(root, current[0])

    def no_mutation_since_capture(self, image: dict[str, Any]) -> bool:
        """An unchanged module and generation prove interrupted activation did not publish."""
        self.validate_image(image)
        dfd = self.settings._dir(False)
        try:
            if self.hyprland._read(dfd, HYPRLAND_JOURNAL) is not None:
                return False
        finally:
            os.close(dfd)
        return (_snapshot() == image['theme'] and
                self.hyprland.capture_preimage()['hyprland-settings.lua'] == image['hyprland']['hyprland-settings.lua'])


def rendering_theme(theme: dict[str, Any], settings: dict[str, Any]) -> dict[str, Any]:
    """Render the saved Settings components without changing the editable source."""
    result = copy.deepcopy(theme)
    bar = settings['bar']
    result['shell']['bar'] = {
        'position': bar['layout']['position'], 'separate_groups': bar['layout']['separateGroups'],
        'border': bar['style']['border'], 'edge_inset': bar['style']['edgeInset'],
        'radius_automatic': bar['style']['radiusAutomatic'], 'radius_scale': bar['style']['radiusScale'],
        'density_automatic': bar['style']['densityAutomatic'], 'density_scale': bar['style']['densityScale'],
        'items': copy.deepcopy(bar['items'])}
    for component in ('osd', 'notifications'):
        section = settings[component]
        result['shell'][component] = {'position': section['position'],
            'offset_x': section['offsetX'], 'offset_y': section['offsetY']}
    from .core import widget_model
    result['widgets'] = widget_model().validate_profile(settings['widgets'])
    overrides = result.setdefault('overrides', {})
    for target, entry in settings['targets'].items():
        if target in ('gtk', 'hyprlock') and 'overrides' in entry:
            # Settings owns these dictionaries; a removed key inherits the palette.
            overrides[target] = copy.deepcopy(entry['overrides'])
            if target == 'gtk' and not entry['overrides']:
                result['gtk']['colour_source'] = 'theme'
        elif entry.get('overrides'):
            overrides[target] = {**overrides.get(target, {}), **entry['overrides']}
    return result


class ThemeTargetOwner:
    """Activate one target generation and report work still needed to load it."""

    independent = True

    def __init__(self, target: str, component_id: str, theme_path: Path, theme: dict[str, Any],
                 run_command=runtime._run):
        if target not in runtime.TARGET_NAMES:
            raise ApplyError(f"no theme runtime owner for {target}")
        self.target = target
        self.component_id = component_id
        self.theme_path = theme_path
        self.theme = theme
        self.rendered_theme = theme
        self.run_command = run_command

    def validate(self, request: dict[str, Any], settings: dict[str, Any]) -> None:
        if not settings["targets"][self.target]["enabled"]:
            raise ApplyError(f"saved target is disabled: {self.target}")
        if self.target == "obsidian":
            from .obsidian import preflight, ObsidianFailure
            try:
                preflight(runtime.state_dir())
            except ObsidianFailure as error:
                raise ApplyError(str(error)) from error
        self.rendered_theme = rendering_theme(self.theme, settings)
        checked = validate_theme(self.rendered_theme, check_dependencies=False, targets={self.target}, source_path=self.theme_path)
        if checked.errors:
            raise ApplyError('; '.join(checked.errors))

    def bind_transaction_image(self, image: dict[str, Any], result: dict[str, Any] | None = None) -> None:
        if self.target in target_preimage.EDITOR_TARGETS or self.target == 'obsidian':
            self.external_preimage = image["external"]
            self.publication_conflict = bool(result and (result.get("publicationConflict") or result.get("state") == "pending"))

    def capture(self) -> dict[str, Any]:
        try:
            image = {**_snapshot(), "targetDigest": self.observe()["digest"]}
            if self.target in target_preimage.EXTERNAL_TARGETS:
                image["external"] = target_preimage.capture(self.target)
                if not hasattr(self, "external_preimage"):
                    self.external_preimage = image["external"]
            return image
        except (ApplyError, OSError) as error:
            if self.target in ("code", "cursor_editor") and hasattr(self, "external_preimage"):
                raise BeforeTargetPublicationFailure(str(error)) from error
            raise

    def restore_before_publication_failure(self, image: dict[str, Any] | None) -> None:
        self.publication_conflict = True
        if image is not None:
            _restore_snapshot(image, (self.target,))

    def validate_image(self, image: Any) -> None:
        _validate_snapshot(image)
        if self.target in target_preimage.EXTERNAL_TARGETS:
            target_preimage.validate(self.target, image.get("external"))
        elif "external" in image:
            raise ApplyError("unexpected external target pre-image")

    def can_restore(self, image: dict[str, Any]) -> bool:
        try:
            self.validate_image(image)
            if image["current"] is not None:
                runtime.validate_generation(runtime.state_dir() / "generations" / image["current"])
            return True
        except (ApplyError, OSError, runtime.RuntimeFailure):
            return False

    def can_retry(self, image: dict[str, Any]) -> bool:
        if not self.can_restore(image):
            return False
        try:
            _, current_theme = load_theme(str(self.theme_path))
            return sha256_text(canonical_json(current_theme)) == sha256_text(canonical_json(self.theme))
        except (OSError, ValueError, KeyError, TypeError):
            return False

    def apply(self, request: dict[str, Any]) -> dict[str, Any]:
        try:
            manifest, _ = runtime.apply_theme(
                self.theme_path, self.rendered_theme, (self.target,),
                run_command=self.run_command, preserve_history=True, activate_only=self.target != "obsidian",
            )
            if self.target in target_preimage.EDITOR_TARGETS:
                runtime.publish_editor_target(runtime.state_dir(), self.target, external_image=self.external_preimage)
            if self.target == 'hyprland':
                hyprland.activate(self.rendered_theme, self.run_command)
        except runtime.ObsidianPublicationConflict as error:
            raise BeforeTargetPublicationFailure(str(error)) from error
        except (OSError, ValueError, runtime.RuntimeFailure, runtime.EditorSettingsFailure, hyprland.HyprlandFailure) as error:
            raise CoreApplyFailure(f"{self.target} generation or activation failed: {error}") from error
        observed = self.observe()
        state = "success" if self.target in ("obsidian", "zed", "t3code") else "manual" if self.target in MANUAL_TARGETS else "restart"
        message = "Application theme selected" if state == "success" else "Apply generated files manually" if state == "manual" else "Restart to load generated files"
        if self.target == 'hyprland':
            message = 'Window appearance applied; restart Hyprtoolkit apps to load their theme'
        return {"state": state, "message": message,
                "digest": observed["digest"], "revision": observed["revision"],
                "generationId": manifest["generation_id"]}

    def observe(self) -> dict[str, Any]:
        return _target_observation(self.target)

    def restore(self, image: dict[str, Any]) -> None:
        if self.target == 'obsidian' and getattr(self, 'publication_conflict', False):
            if target_preimage.capture(self.target)['files'] != image['external']['files']:
                raise ApplyError('Obsidian restoration would overwrite newer vault files')
        if self.target in ("code", "cursor_editor"):
            target_preimage.verify_editor_link(self.target, image["external"])
            if getattr(self, "publication_conflict", False):
                _, fd = target_preimage.editor_publication_destination(self.target, image["external"])
                os.close(fd)
        _restore_snapshot(image, (self.target,))
        if "external" in image:
            target_preimage.restore(self.target, image["external"])
            if self.target == "obsidian":
                from . import obsidian
                from .editor import read_settings_values
                paths = obsidian.safe_paths(obsidian.discover_vault())
                if self.run_command is runtime._run and obsidian._obsidian_is_running():
                    # Let the restored appearance file reach the renderer before
                    # its temporary default switch, as native publish does.
                    obsidian.time.sleep(obsidian.OBSIDIAN_THEME_SWITCH_SETTLE_SECONDS)
                previous = read_settings_values(paths.appearance, ("cssTheme",))["cssTheme"]
                # Refresh the renderer through the same native owner as Apply.
                obsidian._select_theme(paths, previous.get("value", "") if previous["present"] else "",
                                       self.run_command, self.run_command is runtime._run)
                target_preimage.restore(self.target, image["external"])

    def verify_restored(self, image: dict[str, Any]) -> None:
        if self.observe()["digest"] != image["targetDigest"]:
            raise ApplyError(f"{self.target} pre-image differs")


class WidgetApplyCore:
    """Observe saved Settings without publishing or restoring unrelated settings."""
    component_id = "widgets"

    def __init__(self, settings):
        self.settings = settings

    def observe(self):
        current = self.settings.get()
        if not current.ok:
            raise ApplyError("Settings observation failed")
        return {"digest": component_digest(current.data), "revision": current.revision}

    def validate(self, request, settings, selected):
        if request.get("scope") != "widgets" or selected != ["widgets"]:
            raise ApplyError("invalid widgets Apply scope")
        if component_digest(settings["widgets"]) != request.get("profileDigest"):
            raise ApplyError("saved widget profile changed")
        widget_model().validate_profile(settings["widgets"])
        _, theme = load_theme(request["themePath"])
        if theme["id"] != request["themeId"] or sha256_text(canonical_json(theme)) != request["sourceDigest"]:
            raise ApplyError("active theme source changed")
        active = runtime.current_generation()
        if active is None or active[0].name != request.get("widgetGeneration"):
            raise ApplyError("active widget generation changed")

    def capture(self):
        return self.observe()

    def validate_image(self, image):
        if (not isinstance(image, dict) or set(image) != {"digest", "revision"}
                or type(image["revision"]) is not int
                or not isinstance(image["digest"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", image["digest"])):
            raise ApplyError("invalid widgets core pre-image")

    def can_restore(self, image):
        self.validate_image(image)
        return True

    def apply(self, request):
        observed = self.observe()
        if observed["revision"] != request["settingsRevision"]:
            raise BeforeCoreMutationFailure("Settings changed before widget publication")
        return {**observed, "settingsDigest": observed["digest"]}

    def verify(self, request):
        self.apply(request)

    def restore(self, image):
        # This core never writes Settings. A newer document belongs to its writer.
        pass

    def verify_restored(self, image):
        pass

    release_history = ThemeApplyCore.release_history


class WidgetTargetOwner(ThemeTargetOwner):
    def observe(self):
        with runtime.ApplicationLock(runtime.state_dir()):
            current = runtime.current_generation()
            observed = super().observe()
            return {**observed, "digest": component_digest({
                "target": observed["digest"], "generation": current[0].name if current else None})}

    def verify_restored(self, image):
        super().verify_restored(image)
        if _snapshot() != {key: image[key] for key in ("current", "generations")}:
            raise ApplyError("widget generation changed since capture")

    def restore(self, image):
        _restore_snapshot(image, ("widgets",), widget_publication=self.publication_id)

    def restore_before_publication_failure(self, image):
        pass

    def validate(self, request, settings):
        if request.get("scope") != "widgets" or not settings["targets"]["widgets"]["enabled"]:
            raise ApplyError("invalid widgets Apply selection")
        identity = request.get("widgetPublication")
        if (not isinstance(identity, str) or not runtime.GENERATION_PATTERN.fullmatch(identity)
                or identity != self.publication_id):
            raise ApplyError("invalid widget publication identity")
        self.rendered_theme = copy.deepcopy(self.theme)
        self.rendered_theme["widgets"] = widget_model().validate_profile(settings["widgets"])
        checked = validate_theme(self.rendered_theme, check_dependencies=False,
                                 targets={"widgets"}, source_path=self.theme_path)
        if checked.errors:
            raise ApplyError("; ".join(checked.errors))

    def apply(self, request):
        try:
            manifest, _ = runtime.apply_theme(self.theme_path, self.rendered_theme, ("widgets",),
                                              preserve_history=True, activate_only=True,
                                              widget_generation=request["widgetGeneration"],
                                              widget_publication=request["widgetPublication"])
        except runtime.WidgetPublicationConflict as error:
            raise BeforeTargetPublicationFailure(str(error)) from error
        with runtime.ApplicationLock(runtime.state_dir()):
            current = runtime.current_generation()
            if current is None or current[0].name != self.publication_id:
                raise BeforeTargetPublicationFailure("widget generation changed after publication")
            profile = json.loads((current[0] / "widgets/profile.json").read_text())
            if component_digest(profile) != self.profile_digest:
                raise ApplyError("published widget profile differs from request")
            observed = super().observe()
            observed["digest"] = component_digest({"target": observed["digest"], "generation": current[0].name})
        return {**observed, "state": "success", "generationId": manifest["generation_id"]}


def create_widget_apply(expected_revision: int):
    """Publish only the exact saved widget profile through the Apply transaction."""
    settings = SettingsDocument()
    current = settings.get()
    if not current.ok:
        raise ApplyError(f"Settings read failed: {current.code}")
    if type(expected_revision) is not int or current.revision != expected_revision:
        raise ApplyError("Settings revision conflict")
    active = runtime.current_generation()
    if active is None:
        raise ApplyError("widgets Apply requires an active theme generation")
    generation, manifest = active
    path, theme = load_theme(manifest["source"])
    if theme["id"] != manifest["theme_id"]:
        raise ApplyError("active theme source identity changed")
    profile = widget_model().validate_profile(current.data["widgets"])
    request = {"scope": "widgets", "settingsRevision": expected_revision,
               "profileDigest": component_digest(profile), "widgetGeneration": generation.name,
               "widgetPublication": runtime._new_generation_id(),
               "themeId": theme["id"], "sourceDigest": sha256_text(canonical_json(theme)),
               "components": {"widgets": "widgets"}, "approvals": {},
               "themePath": str(path.resolve()), "themeDocument": theme}
    coordinator = ApplyCoordinator(settings, CompositionDocument(), state_home() / "blox/theme/apply",
                                   WidgetApplyCore(settings),
                                   {"widgets": WidgetTargetOwner("widgets", "widgets", path, theme)})
    coordinator.owners["widgets"].profile_digest = request["profileDigest"]
    coordinator.owners["widgets"].publication_id = request["widgetPublication"]
    return coordinator, request


def create_apply(theme_reference: str, *, approvals: dict[str, str] | None = None,
                 run_command=runtime._run, hyprland_runner=None) -> tuple[ApplyCoordinator, dict[str, Any]]:
    """Build the production backend request from saved target selection."""
    settings = SettingsDocument()
    current = settings.get()
    if not current.ok:
        raise ApplyError(f"Settings read failed: {current.code}")
    path, theme = load_theme(theme_reference)
    selected = [name for name, item in current.data["targets"].items() if item["enabled"]]
    unsupported = sorted(set(selected) - set(runtime.TARGET_NAMES))
    if unsupported:
        raise ApplyError("target owner unavailable: " + ", ".join(unsupported))
    components = {name: "wallpaper" if name == "wallpaper" else "widgets" if name == "widgets" else "appearance"
                  for name in selected}
    owners = {name: ThemeTargetOwner(name, components[name], path, theme, run_command) for name in selected}
    request = {"settingsRevision": current.revision, "themeId": theme["id"],
               "sourceDigest": sha256_text(canonical_json(theme)), "components": components,
               "approvals": dict(approvals or {}), "themePath": str(path.resolve()),
               "themeDocument": theme}
    coordinator = ApplyCoordinator(settings, CompositionDocument(), state_home() / "blox/theme/apply",
                                   ThemeApplyCore(settings, path, theme, selected, hyprland_runner), owners)
    return coordinator, request


def open_existing_apply(*, run_command=runtime._run, hyprland_runner=None) -> ApplyCoordinator:
    """Rebuild owners from the durable journal for status, retry and recovery."""
    settings = SettingsDocument()
    ledger = CompositionDocument()
    journal_dir = state_home() / "blox/theme/apply"
    journal = journal_dir / "apply.json"
    if not journal.exists() and not journal.is_symlink():
        raise ApplyError("no Apply transaction exists")
    probe = ApplyCoordinator(settings, ledger, journal_dir, None, {})
    dfd, fd = probe._lock()
    try:
        record = probe._read(dfd)
    finally:
        probe._unlock(dfd, fd)
    if record is None:
        raise ApplyError("no Apply transaction exists")
    request = record.get("request")
    if not isinstance(request, dict):
        raise ApplyError("Apply journal has no request")
    path_value, theme = request.get("themePath"), request.get("themeDocument")
    selected = record.get("selected")
    if not isinstance(path_value, str) or not Path(path_value).is_absolute() or not isinstance(theme, dict):
        raise ApplyError("Apply journal has no recoverable theme source")
    if not isinstance(selected, list) or not selected or any(not isinstance(name, str) for name in selected):
        raise ApplyError("Apply journal has invalid target selection")
    if request.get("sourceDigest") != sha256_text(canonical_json(theme)) or request.get("themeId") != theme.get("id"):
        raise ApplyError("Apply journal theme source differs")
    if set(selected) - set(runtime.TARGET_NAMES):
        raise ApplyError("Apply journal names an unavailable owner")
    owner_class = WidgetTargetOwner if request.get("scope") == "widgets" else ThemeTargetOwner
    if request.get("scope") == "widgets" and (selected != ["widgets"] or request.get("components") != {"widgets": "widgets"}):
        raise ApplyError("invalid widgets Apply journal")
    owners = {name: owner_class(name, request["components"][name], Path(path_value), theme, run_command)
              for name in selected}
    coordinator = ApplyCoordinator(settings, ledger, journal_dir,
                                   WidgetApplyCore(settings) if request.get("scope") == "widgets" else
                                   ThemeApplyCore(settings, Path(path_value), theme, selected, hyprland_runner), owners)
    if request.get("scope") == "widgets":
        owners["widgets"].profile_digest = request["profileDigest"]
        owners["widgets"].publication_id = request["widgetPublication"]
    coordinator._verify_journal(record)
    return coordinator
