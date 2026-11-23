"""Editor and IDE theme renderers (VS Code, Cursor, T3 Code, Zed, Obsidian)."""
from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from .core import (
    OBSIDIAN_THEME_AUTHOR,
    OBSIDIAN_THEME_MIN_APP_VERSION,
    OBSIDIAN_THEME_NAME,
    OBSIDIAN_THEME_VERSION,
    ZED_THEME_AUTHOR,
    ZED_THEME_FAMILY_NAME,
    ZED_THEME_SCHEMA,
    canonical_json,
    derive_ansi,
    derive_shape,
    load_json,
    repository_root,
    target_colours,
    themes_dir,
)


def editor_colours(theme: dict[str, Any]) -> dict[str, str]:
    c = theme["colours"]
    custom = {
        "editor.background": c["background"], "editor.foreground": c["foreground"], "editor.selectionBackground": c["selection_background"],
        "editor.inactiveSelectionBackground": c["surface_alt"], "editorCursor.foreground": c["accent"], "editorLineNumber.foreground": c["muted"],
        "editorGroupHeader.tabsBackground": c["surface"], "editorGroup.border": c["border"],
        "tab.activeBackground": c["background"], "tab.activeForeground": c["foreground"], "tab.activeBorderTop": c["accent"],
        "tab.inactiveBackground": c["surface"], "tab.inactiveForeground": c["muted"], "tab.border": c["border"],
        "activityBar.background": c["surface"], "activityBar.foreground": c["foreground"], "activityBar.inactiveForeground": c["muted"],
        "activityBar.border": c["border"], "activityBarBadge.background": c["accent"], "activityBarBadge.foreground": c["background"],
        "sideBar.background": c["surface"], "sideBar.foreground": c["foreground"], "sideBar.border": c["border"],
        "sideBarTitle.foreground": c["foreground"], "sideBarSectionHeader.background": c["surface_alt"],
        "sideBarSectionHeader.foreground": c["foreground"], "sideBarSectionHeader.border": c["border"],
        "list.activeSelectionBackground": c["selection_background"], "list.activeSelectionForeground": c["selection_foreground"],
        "list.inactiveSelectionBackground": c["surface_alt"], "list.inactiveSelectionForeground": c["foreground"],
        "list.hoverBackground": c["surface_alt"], "list.hoverForeground": c["foreground"], "list.focusOutline": c["accent"],
        "gitDecoration.addedResourceForeground": c["success"], "gitDecoration.modifiedResourceForeground": c["warning"],
        "gitDecoration.deletedResourceForeground": c["danger"], "gitDecoration.untrackedResourceForeground": c["teal"],
        "panel.background": c["surface"], "panel.border": c["border"], "panelTitle.activeForeground": c["foreground"],
        "panelTitle.inactiveForeground": c["muted"], "panelTitle.activeBorder": c["accent"],
        "titleBar.activeBackground": c["surface"], "titleBar.activeForeground": c["foreground"], "titleBar.border": c["border"],
        "statusBar.background": c["surface_alt"], "statusBar.foreground": c["foreground"], "statusBar.border": c["border"],
        "input.background": c["background"], "input.foreground": c["foreground"], "input.border": c["border"],
        "dropdown.background": c["surface_alt"], "dropdown.foreground": c["foreground"], "dropdown.border": c["border"],
        "menu.background": c["surface"], "menu.foreground": c["foreground"], "menu.selectionBackground": c["selection_background"],
        "badge.background": c["accent"], "badge.foreground": c["background"],
        "focusBorder": c["accent"], "errorForeground": c["danger"],
    }
    return custom


EDITOR_THEME_PACKAGE_NAME = "blox-theme"
EDITOR_THEME_PUBLISHER = "blox"
EDITOR_THEME_VERSION = "1.0.0"
EDITOR_THEME_LABEL_PREFIX = "Blox: "
EDITOR_THEME_RELATIVE_PATH = "themes/blox-generated-color-theme.json"
EDITOR_MINIMUM_VERSION = "^1.90.0"


def editor_theme_label(theme: dict[str, Any]) -> str:
    return f"{EDITOR_THEME_LABEL_PREFIX}{theme['name']}"


def editor_theme_setting_value(theme: dict[str, Any]) -> str:
    """Return the generated package id that Code uses to restore the theme."""
    return EDITOR_THEME_PACKAGE_NAME


def editor_modern_ui_value(theme: dict[str, Any]) -> bool:
    """Map Blox's square/rounded boundary to Code's binary UI mode."""
    return theme["shape"]["radius_scale"] > 0


def _vscode_source_path(variant: str) -> Path:
    if variant not in ("dark", "light"):
        raise ValueError(f"unsupported VS Code theme variant: {variant}")
    return themes_dir() / "sources/vscode" / f"2026-{variant}.json"


def _merge_vscode_theme(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(base)
    for key, value in overlay.items():
        if key == "include":
            continue
        if key == "colors":
            colours = dict(merged.get(key, {}))
            colours.update(value)
            merged[key] = colours
        elif key == "semanticTokenColors":
            semantic = dict(merged.get(key, {}))
            semantic.update(value)
            merged[key] = semantic
        elif key == "tokenColors":
            merged[key] = list(merged.get(key, [])) + list(value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def _load_vscode_theme(path: Path, stack: tuple[Path, ...] = ()) -> dict[str, Any]:
    path = path.resolve()
    source_root = (themes_dir() / "sources/vscode").resolve()
    try:
        path.relative_to(source_root)
    except ValueError as error:
        raise ValueError(f"VS Code theme include escapes the pinned source directory: {path}") from error
    if path in stack:
        raise ValueError(f"cyclic VS Code theme include: {path}")
    document = load_json(path)
    if not isinstance(document, dict):
        raise ValueError(f"VS Code theme source must be an object: {path}")
    include = document.get("include")
    parent: dict[str, Any] = {}
    if include is not None:
        if not isinstance(include, str):
            raise ValueError(f"VS Code theme include must be a path: {path}")
        parent = _load_vscode_theme(path.parent / include, (*stack, path))
    return _merge_vscode_theme(parent, document)


def _editor_token_colours(theme: dict[str, Any]) -> list[dict[str, Any]]:
    c = theme["colours"]
    return [
        {"scope": ["comment", "punctuation.definition.comment"], "settings": {"foreground": c["muted"]}},
        {"scope": ["keyword", "storage", "storage.type"], "settings": {"foreground": c["danger"]}},
        {"scope": ["string", "string.quoted"], "settings": {"foreground": c["info"]}},
        {"scope": ["entity.name.function", "support.function"], "settings": {"foreground": c["mauve"]}},
        {"scope": ["entity.name.tag", "support.class.component", "entity.name.type", "support.type"], "settings": {"foreground": c["success"]}},
        {"scope": ["constant", "support", "meta.property-name"], "settings": {"foreground": c["info"]}},
        {"scope": ["variable", "variable.other", "meta.object.member"], "settings": {"foreground": c["foreground"]}},
        {"scope": ["constant.numeric", "constant.language"], "settings": {"foreground": c["warning"]}},
        {"scope": ["string.regexp", "source.regexp"], "settings": {"foreground": c["teal"]}},
        {"scope": ["invalid", "invalid.illegal", "invalid.deprecated"], "settings": {"foreground": c["danger"], "fontStyle": "italic"}},
        {"scope": ["markup.heading", "markup.heading entity.name"], "settings": {"foreground": c["accent"], "fontStyle": "bold"}},
        {"scope": ["markup.italic"], "settings": {"foreground": c["foreground"], "fontStyle": "italic"}},
        {"scope": ["markup.bold"], "settings": {"foreground": c["foreground"], "fontStyle": "bold"}},
    ]


def _editor_theme(theme: dict[str, Any]) -> dict[str, Any]:
    source = _load_vscode_theme(_vscode_source_path(theme["variant"]))
    colours = dict(source.get("colors", {}))
    colours.update(editor_colours(theme))
    semantic = dict(source.get("semanticTokenColors", {}))
    c = theme["colours"]
    semantic.update({
        "comment": c["muted"], "keyword": c["danger"], "string": c["info"],
        "function": c["mauve"], "class": c["success"], "type": c["success"],
        "variable": c["foreground"], "property": c["teal"], "number": c["warning"],
        "enumMember": c["info"],
    })
    return {
        "$schema": "vscode://schemas/color-theme",
        "name": editor_theme_label(theme),
        "type": theme["variant"],
        "semanticHighlighting": True,
        "colors": colours,
        "tokenColors": list(source.get("tokenColors", [])) + _editor_token_colours(theme),
        "semanticTokenColors": semantic,
    }


def _editor_package(theme: dict[str, Any]) -> str:
    package = {
        "name": EDITOR_THEME_PACKAGE_NAME,
        "displayName": "Blox editor theme",
        "description": "Generated Blox colour and syntax theme.",
        "version": EDITOR_THEME_VERSION,
        "publisher": EDITOR_THEME_PUBLISHER,
        "engines": {"vscode": EDITOR_MINIMUM_VERSION},
        "categories": ["Themes"],
        "contributes": {"themes": [{
            "id": EDITOR_THEME_PACKAGE_NAME,
            "label": editor_theme_label(theme),
            "uiTheme": "vs-dark" if theme["variant"] == "dark" else "vs",
            "path": f"./{EDITOR_THEME_RELATIVE_PATH}",
        }]},
    }
    return canonical_json(package)


def render_editor(theme: dict[str, Any]) -> str:
    """Render Code's settings fragment alongside the generated package."""
    return canonical_json({
        "workbench.colorTheme": editor_theme_setting_value(theme),
        "workbench.experimental.modernUI": editor_modern_ui_value(theme),
        "editor.fontFamily": theme["fonts"]["mono"],
    })


def render_cursor_editor(theme: dict[str, Any]) -> str:
    """Render Cursor's settings fragment without unsupported Code settings."""
    return canonical_json({
        "workbench.colorTheme": editor_theme_setting_value(theme),
        "editor.fontFamily": theme["fonts"]["mono"],
    })


def render_t3code(theme: dict[str, Any]) -> str:
    """Render T3Code's supported environment-theme document.

    T3Code does not consume the VS Code theme format. Its environment route
    accepts a palette keyed by T3Code's semantic colour roles, so keep this
    projection separate from the Code and Cursor packages.
    """
    c = theme["colours"]
    colours = {
        "canvas": c["background"],
        "chrome": c["background"],
        "toolbar": c["background"],
        "toolbarForeground": c["foreground"],
        "toolbarBorder": c["border"],
        "toolbarControl": c["surface_alt"],
        "toolbarControlForeground": c["foreground"],
        "toolbarControlHover": c["surface_alt"],
        "surface": c["surface"],
        "surfaceRaised": c["surface_alt"],
        "surfaceOverlay": c["surface_alt"],
        "text": c["foreground"],
        "textMuted": c["muted"],
        "border": c["border"],
        "input": c["surface_alt"],
        "focus": c["accent"],
        "accent": c["accent"],
        "accentForeground": c["selection_foreground"],
        "secondary": c["surface"],
        "secondaryForeground": c["foreground"],
        "muted": c["surface"],
        "mutedForeground": c["muted"],
        "placeholder": c["muted"],
        "secondaryLabel": c["muted"],
        "iconMuted": c["muted"],
        "error": c["danger"],
        "errorForeground": c["danger"],
        "errorSurface": c["surface_alt"],
        "warning": c["warning"],
        "warningForeground": c["warning"],
        "warningSurface": c["surface_alt"],
        "update": c["info"],
        "updateForeground": c["info"],
        "updateSurface": c["surface_alt"],
        "accentSurface": c["selection_background"],
        "accentSurfaceForeground": c["selection_foreground"],
        "messageSurface": c["surface_alt"],
        "messageForeground": c["foreground"],
        "messageAction": c["accent"],
        "messageActionForeground": c["selection_foreground"],
        "messageActionHover": c["info"],
        "codeBackground": c["background"],
        "codeForeground": c["foreground"],
        "sidebar": c["surface"],
        "sidebarForeground": c["foreground"],
        "sidebarMutedForeground": c["muted"],
        "sidebarControlSurface": c["surface_alt"],
        "sidebarRowHover": c["surface_alt"],
        "sidebarRowActive": c["surface_alt"],
        "sidebarRowSelected": c["selection_background"],
        "sidebarBorder": c["border"],
        "terminalBackground": c["background"],
        "terminalForeground": c["foreground"],
        "terminalCursor": c["accent"],
        "terminalSelection": c["selection_background"],
        "terminalScrollbar": c["border"],
        "terminalScrollbarHover": c["muted"],
    }
    return canonical_json({
        "version": 1,
        "name": theme["name"],
        "appearance": theme["variant"],
        "canvas": c["background"],
        "accent": c["accent"],
        "colors": colours,
    })


def zed_theme_label(theme: dict[str, Any]) -> str:
    return f"Blox: {theme['name']}"


def render_zed(theme: dict[str, Any]) -> str:
    """Render Zed's native theme-family format from the resolved theme."""
    c = target_colours(theme, "zed")
    ansi = derive_ansi(theme)
    style = {
        "accents": [c["accent"]],
        "background": c["background"],
        "background.appearance": "opaque",
        "border": c["border"],
        "border.disabled": c["surface_alt"],
        "border.focused": c["accent"],
        "border.selected": c["accent"],
        "border.transparent": c["surface"],
        "border.variant": c["surface_alt"],
        "conflict": c["danger"],
        "conflict.background": c["surface_alt"],
        "conflict.border": c["danger"],
        "created": c["success"],
        "created.background": c["surface_alt"],
        "created.border": c["success"],
        "deleted": c["danger"],
        "deleted.background": c["surface_alt"],
        "deleted.border": c["danger"],
        "drop_target.background": c["selection_background"],
        "editor.active_line.background": c["surface"],
        "editor.active_line_number": c["foreground"],
        "editor.background": c["background"],
        "editor.foreground": c["foreground"],
        "editor.gutter.background": c["background"],
        "editor.highlighted_line.background": c["surface"],
        "editor.indent_guide": c["border"],
        "editor.indent_guide_active": c["accent"],
        "editor.invisible": c["muted"],
        "editor.line_number": c["muted"],
        "element.active": c["selection_background"],
        "element.background": c["surface_alt"],
        "element.disabled": c["surface"],
        "element.hover": c["surface_alt"],
        "element.selected": c["selection_background"],
        "elevated_surface.background": c["surface_alt"],
        "error": c["danger"],
        "error.background": c["surface_alt"],
        "error.border": c["danger"],
        "ghost_element.active": c["selection_background"],
        "ghost_element.background": c["surface"],
        "ghost_element.disabled": c["surface"],
        "ghost_element.hover": c["surface_alt"],
        "ghost_element.selected": c["selection_background"],
        "hidden": c["muted"],
        "hidden.background": c["surface"],
        "hidden.border": c["border"],
        "hint": c["info"],
        "hint.background": c["surface_alt"],
        "hint.border": c["info"],
        "icon": c["foreground"],
        "icon.accent": c["accent"],
        "icon.disabled": c["muted"],
        "icon.muted": c["muted"],
        "icon.placeholder": c["muted"],
        "info": c["info"],
        "info.background": c["surface_alt"],
        "info.border": c["info"],
        "link_text.hover": c["accent"],
        "modified": c["warning"],
        "modified.background": c["surface_alt"],
        "modified.border": c["warning"],
        "pane.focused_border": c["accent"],
        "pane_group.border": c["border"],
        "panel.background": c["surface"],
        "panel.focused_border": c["accent"],
        "scrollbar.thumb.background": c["border"],
        "scrollbar.thumb.border": c["border"],
        "scrollbar.thumb.hover_background": c["muted"],
        "scrollbar.track.background": c["background"],
        "scrollbar.track.border": c["background"],
        "search.match_background": c["warning"],
        "status_bar.background": c["surface"],
        "success": c["success"],
        "success.background": c["surface_alt"],
        "success.border": c["success"],
        "surface.background": c["surface"],
        "tab.active_background": c["surface_alt"],
        "tab.inactive_background": c["background"],
        "tab_bar.background": c["background"],
        "terminal.ansi.background": c["background"],
        "terminal.background": c["background"],
        "terminal.bright_foreground": c["foreground"],
        "terminal.dim_foreground": c["muted"],
        "terminal.foreground": c["foreground"],
        "text": c["foreground"],
        "text.accent": c["accent"],
        "text.disabled": c["muted"],
        "text.muted": c["muted"],
        "text.placeholder": c["muted"],
        "title_bar.background": c["background"],
        "title_bar.inactive_background": c["background"],
        "toolbar.background": c["surface"],
        "unreachable": c["danger"],
        "unreachable.background": c["surface_alt"],
        "unreachable.border": c["danger"],
        "warning": c["warning"],
        "warning.background": c["surface_alt"],
        "warning.border": c["warning"],
    }
    ansi_names = (
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "bright_black", "bright_red", "bright_green", "bright_yellow",
        "bright_blue", "bright_magenta", "bright_cyan", "bright_white",
    )
    style.update({f"terminal.ansi.{name}": ansi[f"color{index}"] for index, name in enumerate(ansi_names)})
    style["syntax"] = {
        "attribute": {"color": c["teal"]},
        "boolean": {"color": c["mauve"]},
        "comment": {"color": c["muted"], "font_style": "italic"},
        "constant": {"color": c["warning"]},
        "constructor": {"color": c["success"]},
        "function": {"color": c["accent"]},
        "keyword": {"color": c["danger"]},
        "number": {"color": c["warning"]},
        "operator": {"color": c["teal"]},
        "property": {"color": c["teal"]},
        "punctuation": {"color": c["muted"]},
        "punctuation.bracket": {"color": c["foreground"]},
        "punctuation.delimiter": {"color": c["muted"]},
        "string": {"color": c["info"]},
        "string.escape": {"color": c["warning"]},
        "string.regex": {"color": c["teal"]},
        "tag": {"color": c["success"]},
        "text.literal": {"color": c["info"]},
        "type": {"color": c["success"]},
        "variable": {"color": c["foreground"]},
        "variable.special": {"color": c["mauve"]},
    }
    return canonical_json({
        "$schema": ZED_THEME_SCHEMA,
        "name": ZED_THEME_FAMILY_NAME,
        "author": ZED_THEME_AUTHOR,
        "themes": [{
            "name": zed_theme_label(theme),
            "appearance": theme["variant"],
            "style": style,
        }],
    })


def render_code_extension(theme: dict[str, Any]) -> dict[str, str]:
    colour_theme = _editor_theme(theme)
    return {
        "code/package.json": _editor_package(theme),
        "code/themes/blox-generated-color-theme.json": canonical_json(colour_theme),
        "code/settings.json": render_editor(theme),
    }


def render_cursor_extension(theme: dict[str, Any]) -> dict[str, str]:
    """Render Cursor's package using the same resolved theme JSON as Code."""
    colour_theme = canonical_json(_editor_theme(theme))
    return {
        "cursor-editor/package.json": _editor_package(theme),
        "cursor-editor/themes/blox-generated-color-theme.json": colour_theme,
        "cursor-editor/settings.json": render_cursor_editor(theme),
    }


def render_obsidian(theme: dict[str, Any]) -> dict[str, str]:
    """Render a self-contained native Obsidian theme package.

    Obsidian applies the same package to dark and light app classes. Blox
    therefore emits the selected theme variant for both classes and lets the
    source theme, rather than Obsidian's base theme, own the full palette.
    """
    c = target_colours(theme, "obsidian")
    radius = int(derive_shape(theme)["gtk_radius"])
    radius_s = 0 if radius == 0 else max(2, radius - 4)
    radius_l = 0 if radius == 0 else radius + 4

    def rgb(value: str) -> str:
        return ", ".join(str(int(value[index:index + 2], 16)) for index in (1, 3, 5))

    variables = {
        "background-primary": c["background"],
        "background-primary-alt": c["surface"],
        "background-secondary": c["surface"],
        "background-secondary-alt": c["surface_alt"],
        "background-modifier-border": c["border"],
        "background-modifier-border-hover": c["accent"],
        "background-modifier-hover": c["surface_alt"],
        "background-modifier-form-field": c["background"],
        "background-modifier-active-hover": c["surface_alt"],
        "divider-color": c["border"],
        "text-normal": c["foreground"],
        "text-muted": c["muted"],
        "text-faint": c["muted"],
        "text-accent": c["accent"],
        "text-accent-hover": c["info"],
        "text-on-accent": c["selection_foreground"],
        "interactive-normal": c["surface"],
        "interactive-hover": c["surface_alt"],
        "interactive-accent": c["accent"],
        "interactive-accent-hover": c["info"],
        "code-background": c["surface"],
        "blockquote-border": c["accent"],
        "tag-background": c["surface"],
        "tag-color": c["accent"],
        "titlebar-background": c["background"],
        "titlebar-background-focused": c["background"],
        "ribbon-background": c["surface"],
        "status-bar-background": c["surface"],
        "nav-item-background-active": c["surface_alt"],
        "nav-item-background-hover": c["surface"],
        "nav-item-color": c["muted"],
        "nav-item-color-active": c["foreground"],
        "nav-item-color-hover": c["foreground"],
        "tab-text-color-focused-active": c["foreground"],
        "icon-color": c["muted"],
        "icon-color-active": c["accent"],
        "icon-color-hover": c["foreground"],
        "scrollbar-thumb-bg": c["border"],
        "scrollbar-active-thumb-bg": c["accent"],
        "scrollbar-bg": c["background"],
        "color-accent": c["accent"],
        "color-red": c["danger"],
        "color-orange": c["warning"],
        "color-yellow": c["warning"],
        "color-green": c["success"],
        "color-cyan": c["teal"],
        "color-blue": c["info"],
        "color-purple": c["mauve"],
        "font-interface": f'"{theme["fonts"]["ui"]}", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        "font-text": f'"{theme["fonts"]["ui"]}", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        "font-monospace": f'"{theme["fonts"]["mono"]}", ui-monospace, monospace',
        "radius-s": f"{radius_s}px",
        "radius-m": f"{radius}px",
        "radius-l": f"{radius_l}px",
        "input-radius": f"{radius}px",
        "button-radius": f"{radius}px",
        "checkbox-radius": f"{radius_s}px",
        "tab-radius": f"{radius}px",
        "tab-radius-active": f"{radius}px",
        "modal-radius": f"{radius_l}px",
        "prompt-radius": f"{radius_l}px",
        "callout-radius": f"{radius}px",
        "code-radius": f"{radius}px",
        "embed-border-radius": f"{radius}px",
        "img-radius": f"{radius}px",
        "color-accent-rgb": rgb(c["accent"]),
        "color-red-rgb": rgb(c["danger"]),
        "color-green-rgb": rgb(c["success"]),
        "color-blue-rgb": rgb(c["info"]),
    }
    variable_text = "\n".join(f"  --{name}: {value};" for name, value in variables.items())
    css = f"""/* Generated by themectl for {theme["name"]} ({theme["variant"]}). */
.theme-dark, .theme-light {{
{variable_text}
  color-scheme: {"light" if theme["variant"] == "light" else "dark"};
}}

body, .app-container, .workspace, .workspace-tab-container {{
  background: var(--background-primary);
  color: var(--text-normal);
  font-family: var(--font-text);
}}

.workspace-tab-header-container,
.workspace-tab-header-inner,
.nav-file-title,
.nav-folder-title,
.menu,
.modal,
.prompt,
.callout,
.markdown-rendered pre,
.markdown-rendered table,
.search-result-container,
.suggestion-container {{
  border-radius: var(--radius-m);
}}

.workspace-tab-header.is-active {{
  background: var(--background-secondary);
  border-radius: var(--tab-radius-active) var(--tab-radius-active) 0 0;
}}

.markdown-rendered a,
.cm-s-obsidian .cm-link,
.cm-s-obsidian .cm-hmd-internal-link {{
  color: var(--text-accent);
}}

.markdown-rendered img {{
  border-radius: var(--img-radius);
}}
"""
    manifest = canonical_json({
        "name": OBSIDIAN_THEME_NAME,
        "version": OBSIDIAN_THEME_VERSION,
        "minAppVersion": OBSIDIAN_THEME_MIN_APP_VERSION,
        "author": OBSIDIAN_THEME_AUTHOR,
        "authorUrl": "https://obsidian.md",
    })
    return {
        "obsidian/manifest.json": manifest,
        "obsidian/theme.css": css,
    }


