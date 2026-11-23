#!/usr/bin/env python3
"""Run the source QML catalogue with frozen fixtures, never a native provider."""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "lib"))
from blox_widgets.model import catalogue, default_widget, validate_profile


def theme_path() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "blox-user/themes/blox-panel.json"


def load_configuration(path: Path) -> dict:
    """Inject the user theme, checked-in fixture values and validated catalogue items."""
    source = json.loads(path.read_text(encoding="utf-8"))
    colours, fonts, shape = source["colours"], source["fonts"], source["shape"]
    values = json.loads((ROOT / "preview-fixtures/snapshots.json").read_text())["values"]
    values["music"]["artUrl"] = (ROOT / "preview-fixtures/fixture-artwork.svg").as_uri()
    supplies = {
        "clock": {"showSeconds": True},
        "calendar": {"path": "/fixture/calendar.sqlite"},
        "notes": {"title": "Fixture note", "text": "Widget renderer\n\n• Separate content and presentation\n• Reuse the theme tokens\n• Keep terminal widgets"},
        "files": {"directory": "/fixture/files"},
        "shortcuts": {"items": [{"id": "fixture-files", "label": "Files", "command": ["fixture-no-execution"]}, {"id": "fixture-browser", "label": "Browser", "command": ["fixture-no-execution"]}]},
        "weather": {"latitude": 51.5074, "longitude": -0.1278},
    }
    styles = {"clock": ["digital", "analogue"], "music": ["card", "radial", "compact"],
              "system": ["rings", "chart"], "calendar": ["month", "agenda"]}
    cases = []
    for entry in catalogue()["widgets"]:
        kind = entry["kind"]
        if entry["route"] != "native":
            continue
        for style in styles.get(kind, [None]):
            settings = copy.deepcopy(supplies.get(kind, {}))
            if style:
                settings["style"] = style
            key = kind + ("-" + style if style else "")
            cases.append({"key": key, "kind": kind, "style": style or "default",
                          "label": entry["name"] + (" / " + style if style else ""),
                          "widget": default_widget(kind, "fixture-" + key, settings)})
    native_count = len(cases)
    for provider in ("clock", "music"):
        key = "example-" + provider
        cases.append({"key": key, "kind": "qml", "style": key, "label": "Trusted QML / " + provider,
                      "widget": default_widget("qml", "fixture-" + key,
                          {"manifest": key, "providers": [provider], "layouts": ["native"], "settings": {}})})
    validate_profile({"schemaVersion": 1, "widgets": [case["widget"] for case in cases]})
    return {"cases": cases, "nativeCaseCount": native_count, "values": values,
            "canvas": colours["background"], "stage": colours["surface_alt"],
            "theme": {"palette": {"background": colours["surface"], "foreground": colours["foreground"],
                "muted": colours["muted"], "accent": colours["accent"], "border": colours["border"],
                "positive": colours["teal"], "secondary": colours["mauve"], "warning": colours["warning"],
                "negative": colours["danger"]}, "fontFamily": fonts["ui"], "monospaceFamily": fonts["mono"],
                "fontSize": 14, "radiusScale": shape["radius_scale"], "densityScale": shape["density_scale"]},
            "workspaces": [{"id": n, "name": str(n), "special": False, "empty": True, "label": str(n)} for n in (1, 2, 3, 5, 6)]
                + [{"id": "studio", "name": "studio", "special": False, "empty": True, "label": "Named studio"},
                   {"id": -99, "name": "scratch", "special": True, "empty": True, "label": "Special scratch"}]}


def isolate_verification(directory: Path) -> None:
    """Use a private Qt session without desktop or service connections."""
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "QT_QPA_PLATFORM_PLUGIN_PATH", "QT_PLUGIN_PATH", "QT_QPA_PLATFORMTHEME", "QT_STYLE_OVERRIDE"):
        os.environ.pop(name, None)
    for name in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"):
        path = directory / name.lower()
        path.mkdir(mode=0o700)
        os.environ[name] = str(path)
    os.environ.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QUICK_CONTROLS_STYLE="Basic")


def run(config: dict, verify: bool, output: Path) -> int:
    # Qt is deliberately imported after the verification environment is isolated.
    from PySide6.QtCore import QUrl, qInstallMessageHandler, QtMsgType
    from PySide6.QtGui import QColor, QGuiApplication, QPalette
    from PySide6.QtQuick import QQuickView
    from PySide6.QtTest import QTest

    app = QGuiApplication([sys.argv[0]])
    palette = QPalette()
    colours = config["theme"]["palette"]
    for role, colour in {QPalette.Window: colours["background"], QPalette.Base: colours["background"],
            QPalette.Button: config["stage"], QPalette.Text: colours["foreground"], QPalette.WindowText: colours["foreground"],
            QPalette.ButtonText: colours["foreground"], QPalette.Highlight: colours["accent"], QPalette.HighlightedText: colours["background"]}.items():
        palette.setColor(role, QColor(colour))
    app.setPalette(palette)
    errors = []

    def message(kind, context, text):
        if kind in (QtMsgType.QtWarningMsg, QtMsgType.QtCriticalMsg, QtMsgType.QtFatalMsg):
            errors.append(text)
        print(text, file=sys.stderr)

    qInstallMessageHandler(message)
    view = QQuickView()
    view.setTitle("Blox widget catalogue, fixture data only")
    view.setColor(QColor(config["canvas"]))
    view.setResizeMode(QQuickView.SizeRootObjectToView)
    view.engine().addImportPath(str(ROOT / "qml"))
    view.rootContext().setContextProperty("previewConfig", config)
    view.setSource(QUrl.fromLocalFile(str(ROOT / "preview-fixtures/Catalogue.qml")))
    if view.status() == QQuickView.Error:
        raise RuntimeError("\n".join(error.toString() for error in view.errors()))
    view.resize(1280, 900)
    view.show()
    if not verify:
        return app.exec()
    root = view.rootObject()

    def settle(expected="visible"):
        deadline = time.monotonic() + 4
        while root.property("phase") != expected and time.monotonic() < deadline:
            app.processEvents()
            QTest.qWait(5)
        if root.property("phase") != expected:
            raise RuntimeError(f"Expected {expected}, got {root.property('phase')}: {root.property('viewError')}")
        view.requestUpdate()
        QTest.qWait(20)
        if errors:
            raise RuntimeError("QML warnings or errors: " + "\n".join(errors))

    def capture(name):
        image = view.grabWindow()
        if image.isNull() or image.width() != view.width() or image.height() != view.height():
            raise RuntimeError("Qt did not render the expected viewport")
        if not image.save(str(output / name)):
            raise RuntimeError("Could not save rendered fixture " + name)

    output.mkdir(parents=True, exist_ok=True)
    rows = []
    shapes = [("minimum", 0, 0.75), ("theme", config["theme"]["radiusScale"], config["theme"]["densityScale"]), ("maximum", 2, 1.5)]
    settle()
    for presentation in ("open", "compact"):
        root.setProperty("presentation", presentation)
        for index, case in enumerate(config["cases"]):
            root.setProperty("caseIndex", index)
            for shape, radius, density in shapes:
                root.setProperty("radiusScale", radius)
                root.setProperty("densityScale", density)
                for full in (False, True):
                    root.setProperty("nativeFullscreen", full)
                    settle()
                    image = view.grabWindow()
                    if image.isNull():
                        raise RuntimeError("Empty Qt frame for " + case["key"])
                    rows.append({"presentation": presentation, "case": case["key"], "shape": shape, "fullscreen": full,
                                 "phase": root.property("phase"), "generation": root.property("generation"),
                                 "viewport": [image.width(), image.height()]})
                    if shape == "theme" and full and case["key"] in ("clock-analogue", "music-radial", "system-chart", "calendar-month", "example-music"):
                        capture("fixture-" + presentation + "-" + case["key"] + "-fullscreen.png")
    # Exercise exact IDs, inclusive ranges, named and special identities in fake state only.
    root.setProperty("caseIndex", 0)
    root.setProperty("scopeIndex", 2)
    root.setProperty("workspaceIndex", 2)
    settle()
    old_generation = root.property("generation")
    root.setProperty("workspaceIndex", 1)
    settle("hidden")
    root.setProperty("workspaceIndex", 3)
    settle()
    if root.property("generation") <= old_generation:
        raise RuntimeError("Fake workspace reveal did not obtain a fresh generation")
    for scope, workspace in ((1, 0), (3, 5), (4, 6)):
        root.setProperty("scopeIndex", scope)
        root.setProperty("workspaceIndex", workspace)
        settle()
    root.setProperty("scopeIndex", 0)
    root.setProperty("workspaceIndex", 0)
    root.setProperty("nativeFullscreen", False)
    root.setProperty("radiusScale", config["theme"]["radiusScale"])
    root.setProperty("densityScale", config["theme"]["densityScale"])
    root.setProperty("backgroundOpacity", 0)
    settle()
    capture("fixture-clock-transparent.png")
    root.setProperty("backgroundOpacity", 0.88)
    root.setProperty("galleryMode", True)
    view.resize(1440, 1240)
    for presentation in ("open", "compact"):
        root.setProperty("presentation", presentation)
        for shape, radius, density in shapes:
            root.setProperty("radiusScale", radius)
            root.setProperty("densityScale", density)
            app.processEvents()
            deadline = time.monotonic() + 4
            while not root.property("galleryReady") and time.monotonic() < deadline:
                app.processEvents()
                QTest.qWait(5)
            if not root.property("galleryReady"):
                raise RuntimeError("Not every native gallery host became ready")
            view.requestUpdate()
            QTest.qWait(30)
            if errors:
                raise RuntimeError("QML gallery warnings: " + "\n".join(errors))
            capture("fixture-native-" + presentation + "-" + shape + ".png")
    report = {"fixtureDataOnly": True, "nativeCases": config["nativeCaseCount"], "renderedCases": len(rows),
              "theme": config["theme"], "workspaceChecks": "IDs, inclusive ranges, named and special identities",
              "fixtureSubscriptions": root.property("fixtureSubscriptions"), "fixtureActionsRecorded": root.property("fixtureActions"),
              "nativeProviderAdaptersLoaded": False, "galleryReady": root.property("galleryReady"),
              "frames": rows, "artifacts": sorted(path.name for path in output.glob("fixture-*.png")),
              "limitation": "Private software Qt rendering. No live provider, shell, performance or physical desktop freshness acceptance."}
    (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"renderedCases": len(rows), "nativeCases": config["nativeCaseCount"], "output": str(output), "artifacts": report["artifacts"]}, indent=2))
    view.close()
    app.processEvents()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="Render privately offscreen, validate the catalogue and save fixture PNGs")
    parser.add_argument("--output", type=Path, default=Path.home() / ".cache/blox-widget-source-preview")
    parser.add_argument("--theme", type=Path, default=theme_path())
    args = parser.parse_args()
    config = load_configuration(args.theme.expanduser().resolve())
    if args.verify:
        with tempfile.TemporaryDirectory(prefix="blox-widget-verify-") as temporary:
            isolate_verification(Path(temporary))
            return run(config, True, args.output.expanduser().resolve())
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")
    return run(config, False, args.output)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Widget preview: {error}", file=sys.stderr)
        raise SystemExit(1)
