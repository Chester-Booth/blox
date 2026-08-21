from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "shell/modules/ThemePickerController.qml"
WIDGET_CONTROLLER = ROOT / "shell/modules/ThemePickerWidgetController.qml"
WIDGETS = ROOT / "shell/modules/ThemePickerWidgets.qml"
WIDGET_DIALOG = ROOT / "shell/modules/ThemePickerWidgetDialog.qml"
EDIT_MODE = ROOT / "shell/modules/WidgetEditMode.qml"


class WidgetPickerSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.controller = CONTROLLER.read_text(encoding="utf-8")
        cls.widget_controller = WIDGET_CONTROLLER.read_text(encoding="utf-8")
        cls.widgets = WIDGETS.read_text(encoding="utf-8")
        cls.widget_dialog = WIDGET_DIALOG.read_text(encoding="utf-8")

    def test_widget_editor_uses_grouped_content_specific_presets(self) -> None:
        self.assertIn('model: ["file", "music", "calendar", "clock", "decorative", "custom"]', self.widget_dialog)
        self.assertIn('model: ["aquarium", "pipes", "tree", "matrix", "fortune", "train"]', self.widget_dialog)
        self.assertIn('text: "Clock options"', self.widget_dialog)
        self.assertIn('text: "File options"', self.widget_dialog)

    def test_new_widgets_are_inserted_first_and_editor_excludes_geometry(self) -> None:
        self.assertIn("current.unshift(draft);", self.widget_controller)
        self.assertNotIn('text: "Position"', self.widget_dialog)
        self.assertNotIn('text: "Shape"', self.widget_dialog)

    def test_picker_launches_real_widget_edit_mode(self) -> None:
        self.assertIn('text: "Edit mode"', self.widgets)
        self.assertIn("Theme.widgetEditModeRequested();", self.widget_controller)
        self.assertIn("onWidgetEditModeFinished", self.controller)
        edit_mode = EDIT_MODE.read_text(encoding="utf-8")
        self.assertIn("Shared.DesktopWidget {", edit_mode)
        self.assertIn("property int selectedIndex", edit_mode)
        self.assertIn('text: "Automatic size"', edit_mode)
        self.assertIn('text: "Visibility"', edit_mode)
        self.assertGreaterEqual(edit_mode.count("Qt.SizeHorCursor"), 1)
        self.assertGreaterEqual(edit_mode.count("Qt.SizeVerCursor"), 1)
        self.assertIn("height: 48", edit_mode)
        self.assertIn("width: root.selectedItem ? 300", edit_mode)
        self.assertIn('text: "Scale"', edit_mode)


if __name__ == "__main__":
    unittest.main()
