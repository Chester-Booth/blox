"""QML surfaces must style through theme tokens, not colour literals.

Some literals are application data, such as calendar colours and theme-picker
seed values. Those exceptions are matched by path and line shape so they cannot
hide unrelated styling in the same file.
"""

import re
import unittest
from pathlib import Path
from typing import Iterable

REPOSITORY = Path(__file__).resolve().parents[1]
SHELL = REPOSITORY / "shell"
SCAN_ROOTS = ["modules", "popouts", "services", "shared"]
TOKEN_LAYER = {"Theme.qml", "ThemeDefaults.qml"}

HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
QT_COLOUR = re.compile(r"Qt\.(?:rgba|color)\(\s*[0-9.]")
FONT_LITERAL = re.compile(r'font\.family:\s*"[^"]+"')

CALENDAR_COLOUR = re.compile(r'^"(?:c|\d+)": "#[0-9a-fA-F]{6}",?$')
GENERATED_THEME_COLOUR = re.compile(
    r'^"(?:background|surface|surface_alt|foreground|muted|accent|danger|success|warning|info|'
    r'mauve|teal|selection_background|selection_foreground|border|canvas|chrome_background|color\d+)": '
    r'light \? "#[0-9a-fA-F]{6,8}" : "#[0-9a-fA-F]{6,8}",?$'
)

ALLOWED_EXACT = {
    "modules/EmojiPicker.qml": {
        'readonly property var toneColours: ["#ffdc5d", "#f7dece", "#e0bb95", "#c58c6b", "#a56b46", "#6f432a"]',
        'font.family: "Twemoji"',
    },
    "modules/LauncherMainSurface.qml": {'color: "#18000000"'},
    "modules/ThemePickerColourController.qml": {
        'property string hex: "#ffffff"',
        'const normalised = /^#[0-9a-fA-F]{6}$/.test(String(colour || "")) ? colour : "#ffffff";',
    },
    "modules/ThemePickerColourPicker.qml": {
        'color: Theme.withAlpha("#000000", 0.68)',
        'color: "#ffffff"',
        'color: "#00ffffff"',
        'color: "#00000000"',
        'color: "#000000"',
        'color: "#ff0000"',
        'color: "#ffff00"',
        'color: "#00ff00"',
        'color: "#00ffff"',
        'color: "#0000ff"',
        'color: "#ff00ff"',
    },
    "modules/ThemePickerController.qml": {
        'const value = String(colour || "#000000").replace("#", "");',
        'return (red * 299 + green * 587 + blue * 114) / 1000 > 145 ? "#111111" : "#f5f5f5";',
    },
    "modules/ThemePickerLibrary.qml": {'color: "#18000000"'},
    "modules/ThemePickerModal.qml": {'color: Theme.withAlpha("#000000", 0.68)'},
    "modules/ThemePickerOverview.qml": {
        'text: "const accent = \\"#89b4fa\\";  {} [] () => ⚡󰍹"'
    },
    "modules/ThemePickerWidgets.qml": {'color: Qt.rgba(0, 0, 0, 0.22)'},
    "popouts/MediaPlayer.qml": {
        'border.color: Qt.rgba(1, 1, 1, 0.1)',
        'border.color: Qt.rgba(1, 1, 1, 0.08)',
    },
    "shared/HoverPopupWindow.qml": {'color: Qt.rgba(0, 0, 0, 0.004)'},
}


def is_allowed_data_literal(path: str, line: str) -> bool:
    stripped = line.strip()
    if stripped in ALLOWED_EXACT.get(path, set()):
        return True
    if path in {
        "modules/CalendarEventWindows.qml",
        "popouts/CalendarEventMenu.qml",
        "services/CalendarController.qml",
    }:
        return CALENDAR_COLOUR.fullmatch(stripped) is not None
    if path == "modules/ThemePickerGenerationController.qml":
        return GENERATED_THEME_COLOUR.fullmatch(stripped) is not None
    return False


def literal_offenders(files: Iterable[tuple[str, str]]) -> list[str]:
    offenders: list[str] = []
    for path, source in files:
        if Path(path).name in TOKEN_LAYER:
            continue
        for number, line in enumerate(source.splitlines(), start=1):
            has_literal = HEX.search(line) or QT_COLOUR.search(line) or FONT_LITERAL.search(line)
            if has_literal and not is_allowed_data_literal(path, line):
                offenders.append(f"{path}:{number}: {line.strip()[:90]}")
    return offenders


class QmlTokenHygieneTests(unittest.TestCase):
    def test_surfaces_carry_no_colour_or_font_literals(self):
        files = []
        for root in SCAN_ROOTS:
            for qml in sorted((SHELL / root).rglob("*.qml")):
                files.append((qml.relative_to(SHELL).as_posix(), qml.read_text(encoding="utf-8")))

        offenders = literal_offenders(files)
        self.assertEqual(
            [],
            offenders,
            "colour/font literals outside the token layer (use Theme.*): "
            + "; ".join(offenders[:8]),
        )

    def test_data_file_does_not_exempt_unrelated_style_literals(self):
        offenders = literal_offenders(
            [("modules/ThemePickerGenerationController.qml", 'Rectangle { color: "#123456" }')]
        )

        self.assertEqual(
            ['modules/ThemePickerGenerationController.qml:1: Rectangle { color: "#123456" }'],
            offenders,
        )

    def test_generated_theme_values_remain_allowed_data(self):
        offenders = literal_offenders(
            [
                (
                    "modules/ThemePickerGenerationController.qml",
                    '    "background": light ? "#ffffff" : "#111318",',
                )
            ]
        )

        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
