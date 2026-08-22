"""QML surfaces must style through theme tokens, not colour literals.

Data-driven colour is exempt where the literal IS the data: calendar
service palettes, emoji tone swatches, preview scrim chrome inside
picker and launcher previews, hairlines drawn over unpredictable media
artwork, and one imperceptible hover-shadow seed. Everything else in a
surface file must come from Theme.
"""

import re
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
SHELL = REPOSITORY / "shell"
SCAN_ROOTS = ["modules", "popouts", "services", "shared"]
TOKEN_LAYER = {"Theme.qml", "ThemeDefaults.qml"}

# Whole files whose literals are data or self-contained preview machinery.
DATA_FILES = {
    "services/CalendarController.qml",
    "popouts/CalendarEventMenu.qml",
    "modules/CalendarEventWindows.qml",
    "modules/EmojiPicker.qml",
    "modules/LauncherMainSurface.qml",
    "popouts/MediaPlayer.qml",
    "shared/HoverPopupWindow.qml",
}
DATA_PREFIXES = ("modules/ThemePicker",)

HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
QT_COLOUR = re.compile(r"Qt\.(?:rgba|color)\(\s*[0-9.]")
FONT_LITERAL = re.compile(r'font\.family:\s*"[^"]+"')


class QmlTokenHygieneTests(unittest.TestCase):
    def test_surfaces_carry_no_colour_or_font_literals(self):
        offenders: list[str] = []
        for root in SCAN_ROOTS:
            for qml in sorted((SHELL / root).rglob("*.qml")):
                rel = qml.relative_to(SHELL).as_posix()
                if rel in TOKEN_LAYER or rel in DATA_FILES or rel.startswith(DATA_PREFIXES):
                    continue
                for number, line in enumerate(qml.read_text(encoding="utf-8").splitlines(), start=1):
                    if HEX.search(line) or QT_COLOUR.search(line) or FONT_LITERAL.search(line):
                        offenders.append(f"{rel}:{number}: {line.strip()[:90]}")
        self.assertEqual(
            [],
            offenders,
            "colour/font literals outside the token layer (use Theme.*): "
            + "; ".join(offenders[:8]),
        )


if __name__ == "__main__":
    unittest.main()
