#!/usr/bin/env python3
"""Bounded, render-node-only readback. Optional correctness fixture, not a benchmark."""

import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw

FIXTURE = Path(__file__).resolve().parent
WIDGETS = FIXTURE.parents[1]
sys.path.insert(0, str(WIDGETS / "lib"))
from blox_widgets.model import default_widget, validate_profile
from blox_widgets.terminal import AnsiScreen
from blox_widgets.broker import OutputQueue


def configuration():
    spec = importlib.util.spec_from_file_location("widget_preview_configuration", WIDGETS / "preview.py")
    preview = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(preview)
    source = preview.load_configuration(preview.theme_path())
    source["values"]["music"]["artUrl"] = "file:///widgets/preview-fixtures/fixture-artwork.svg"
    catalogue = {entry["key"]: entry for entry in source["cases"]}
    cases = []
    choices = [("clock-opaque", "clock-digital", 1, 0, False),
               ("clock-transparent", "clock-digital", 0, 0, False),
               ("clock-analogue-fullscreen", "clock-analogue", 0.5, 1.5, True),
               ("system-chart-fullscreen", "system-chart", 1, 0, True),
               ("system-rings-fullscreen", "system-rings", 1, 0, True),
               ("network-chart-fullscreen", "network", 1, 0, True),
               ("calendar-rounded-fullscreen", "calendar-month", 1, 1.5, True),
               ("music-artwork", "music-compact", 0.8, 1, False),
               ("music-radial", "music-radial", 0.8, 1, False)]
    for name, key, opacity, radius, full in choices:
        entry = catalogue[key]
        widget = copy.deepcopy(entry["widget"])
        widget["placement"].update(anchor="top-left", x=24, y=24)
        widget["appearance"].update(backgroundOpacity=opacity, scrollbars="hide")
        widget["fullscreen"]["enabled"] = True
        validate_profile({"schemaVersion": 1, "widgets": [widget]})
        cases.append(dict(name=name, widget=widget, value=source["values"][entry["kind"]], radiusScale=radius, fullscreen=full))

    def frame(screen, sequence, rows, generation=1):
        retained = [dict(runs=screen.runs(row)) for row in range(screen.rows)]
        return dict(generation=generation, columns=screen.columns, rowCount=screen.rows, rows=retained,
                    changedRuns=[dict(row=row, **run) for row in rows for run in retained[row]["runs"]], sequence=sequence)

    terminal = default_widget("terminal", "fixture-terminal", {"command": ["fixture-no-execution"], "columns": 30, "rows": 4})
    terminal["placement"].update(anchor="top-left", x=24, y=24, width=360, height=120)
    terminal["appearance"].update(backgroundOpacity=0, scrollbars="hide")
    screen = AnsiScreen(4, 30)
    screen.feed(b"\x1b[41m    \x1b[0m FIXTURE\r\n\x1b[44m    \x1b[0m")
    initial = frame(screen, 1, range(4))
    cases.append(dict(name="terminal-painted", widget=terminal, value=initial, radiusScale=0, fullscreen=False))
    queue = OutputQueue()
    screen.feed(b"\x1b[1;1H\x1b[2K")
    queue.emit(dict(consumerId="fixture", snapshot=dict(value=frame(screen, 2, [0]))))
    screen.feed(b"\x1b[2;1H\x1b[2K")
    queue.emit(dict(consumerId="fixture", snapshot=dict(value=frame(screen, 3, [1]))))
    dropped = json.loads(queue.chunk())["snapshot"]["value"]
    screen.feed(b"\x1b[3;1HFIXTURE NEW GENERATION")
    fresh = frame(screen, 1, range(4), generation=2)
    paths = list((WIDGETS / "qml/Blox/Widgets").rglob("*.qml")) + [WIDGETS / "qml/Blox/Widgets/WorkspaceRules.js"]
    hashes = {str(path.relative_to(WIDGETS)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}
    return dict(theme=source["theme"], cases=cases, terminalDropped=dropped, terminalFresh=fresh, sourceHashes=hashes)


def enclosure(output, backend):
    command = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64", "--proc", "/proc", "--dev", "/dev",
        "--ro-bind", "/sys", "/sys", "--tmpfs", "/tmp", "--tmpfs", "/run", "--dir", "/etc",
        "--ro-bind", "/etc/fonts", "/etc/fonts", "--bind", str(output), "/work",
        "--ro-bind", str(WIDGETS), "/widgets", "--ro-bind", str(FIXTURE), "/fixture",
        "--ro-bind", str(WIDGETS / "tests/fixtures"), "/fixtures",
        "--ro-bind", str(WIDGETS.parent / "shell/assets/phosphor"), "/shell/assets/phosphor"]
    if backend == "vulkan":
        command += ["--dir", "/dev/dri", "--dev-bind", "/dev/dri/renderD128", "/dev/dri/renderD128"]
    command += ["--clearenv", "--setenv", "PATH", "/usr/bin", "--setenv", "HOME", "/tmp",
        "--setenv", "XDG_RUNTIME_DIR", "/run", "--setenv", "QT_QPA_PLATFORM", "offscreen",
        "--setenv", "QT_QUICK_CONTROLS_STYLE", "Basic", "--setenv", "LANG", "C.UTF-8",
        "--setenv", "VK_DRIVER_FILES", "/usr/share/vulkan/icd.d/radeon_icd.json",
        "--setenv", "VK_LOADER_LAYERS_DISABLE", "~all~"]
    if backend == "software":
        command += ["--setenv", "QT_QUICK_BACKEND", "software"]
    else:
        command += ["--setenv", "QSG_RHI_BACKEND", "vulkan"]
    return command + ["--", "/work/build/widget-gpu-fixture", backend]


def compare(output):
    reports = {backend: json.loads((output / (backend + "-result.json")).read_text()) for backend in ("software", "vulkan")}
    gpu = reports["vulkan"]
    checks = []
    if gpu.get("deviceType") not in (1, 2, 3):
        raise RuntimeError("The Vulkan device is not reported as a physical GPU: " + repr(gpu))
    checks.append({"check": "physical GPU", "passed": True, "device": gpu.get("deviceName")})
    for backend, report in reports.items():
        checks.append({"check": backend + " has no native window or visibility", "passed": not report["nativeWindow"] and not report["visible"]})
        checks.append({"check": backend + " warning-free QML", "passed": not report["warnings"], "warnings": report["warnings"]})
        for case in report["cases"]:
            checks.append({"check": backend + " first content equals stable " + case["name"], "passed": case["firstEqualsStable"]})
    rows = []
    names = [case["name"] for case in reports["software"]["cases"]]
    montage = Image.new("RGB", (640, 202 * len(names)), "#242424")
    draw = ImageDraw.Draw(montage)
    for index, name in enumerate(names):
        images = [Image.open(output / (backend + "-" + name + ".png")).convert("RGBA") for backend in ("software", "vulkan")]
        composite = []
        for column, (backend, image) in enumerate(zip(("software", "vulkan"), images)):
            background = Image.new("RGBA", image.size, "#242424")
            background.alpha_composite(image)
            composite.append(background.convert("RGB"))
            montage.paste(background.convert("RGB").resize((320, 180)), (column * 320, index * 202 + 22))
            draw.text((column * 320 + 8, index * 202 + 6), backend + " / " + name, fill="#cdd6f4")
        diff = ImageChops.difference(composite[0], composite[1])
        pixels = list(diff.get_flattened_data())
        changed = sum(any(pixel) for pixel in pixels)
        maximum = max(max(pixel) for pixel in pixels)
        row = {"name": name, "differentCompositedPixels": changed, "differentPercent": changed / (640 * 360) * 100,
               "maximumChannelDifference": maximum}
        rows.append(row)
        a = next(case for case in reports["software"]["cases"] if case["name"] == name)
        b = next(case for case in reports["vulkan"]["cases"] if case["name"] == name)
        checks.append({"check": "geometry parity " + name, "passed": a["geometry"] == b["geometry"]})
        for backend, image, case in zip(("software", "vulkan"), images, (a, b)):
            if name.startswith("terminal-"):
                first_cell = 26 + int(case["contentInset"])
                row_two = first_cell + int(case["cellHeight"])
                expected = [(204, 36, 29, 255), (69, 133, 136, 255)] if name == "terminal-painted" else [(0, 0, 0, 0)] * 2
                actual = [image.getpixel((first_cell, first_cell)), image.getpixel((first_cell, row_two))]
                checks.append({"check": backend + " terminal painted/cleared probes " + name, "passed": actual == expected, "actual": actual})
            if name == "clock-opaque":
                checks.append({"check": backend + " opaque background", "passed": image.getpixel((28, 28))[3] == 255})
            elif name == "clock-transparent":
                checks.append({"check": backend + " transparent background", "passed": image.getpixel((28, 28))[3] == 0})
            elif name in ("clock-analogue-fullscreen", "calendar-rounded-fullscreen"):
                expected_alpha = 128 if name.startswith("clock") else 255
                actual = [image.getpixel((0, 0))[3], image.getpixel((24, 24))[3]]
                checks.append({"check": backend + " rounded/fullscreen alpha " + name, "passed": actual[0] == 0 and abs(actual[1] - expected_alpha) <= 1, "actual": actual})
    montage.save(output / "fixture-software-vulkan-montage.png")
    inputs = json.loads((output / "config.json").read_text())
    result = {"fixtureDataOnly": True, "purpose": "bounded correctness readback, no performance acceptance",
              "sourceHashes": inputs.get("sourceHashes", {}),
              "device": gpu.get("deviceName"), "frames": {backend: report["frames"] for backend, report in reports.items()},
              "checks": checks, "rasterComparisons": rows, "passed": all(check["passed"] for check in checks),
              "limitation": "Qt6.12 private no-presentation Vulkan adapter. Cross-backend font and edge rasterisation can differ."}
    (output / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path.home() / ".cache/blox-widget-gpu-fixture")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "config.json").write_text(json.dumps(configuration()) + "\n")
    subprocess.run([sys.executable, "-B", str(WIDGETS.parent / "packaging/build_native_widgets.py"),
        "--output-import-path", str(output / "native-qml")], check=True, capture_output=True, text=True, timeout=120)
    for command in (["cmake", "-S", str(FIXTURE), "-B", str(output / "build"), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release"],
                    ["cmake", "--build", str(output / "build"), "-j2"]):
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
    for backend in ("software", "vulkan"):
        result = subprocess.run(enclosure(output, backend), capture_output=True, text=True, timeout=15)
        (output / (backend + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(backend + " failed: " + result.stdout + result.stderr)
    result = compare(output)
    print(json.dumps({"passed": result["passed"], "device": result["device"], "frames": result["frames"],
                      "failedChecks": [check for check in result["checks"] if not check["passed"]], "output": str(output)}, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
