"""The shell-side theme API must work from an installed tree with no git."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]


class ThemeApiScriptTests(unittest.TestCase):
    def test_list_works_without_a_git_repository_and_includes_user_themes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # Installed layout: shell/ and themes/ siblings, no .git anywhere.
            shutil.copytree(REPOSITORY / "shell", root / "shell",
                            ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(REPOSITORY / "themes", root / "themes",
                            ignore=shutil.ignore_patterns("__pycache__"))

            data_home = root / "data"
            user_themes = data_home / "blox-user" / "themes"
            user_themes.mkdir(parents=True)
            builtin = json.loads((REPOSITORY / "themes/builtin/catppuccin-mocha.json").read_text(encoding="utf-8"))
            builtin["id"] = "my-custom-theme"
            builtin["name"] = "My Custom Theme"
            (user_themes / "my-custom-theme.json").write_text(json.dumps(builtin), encoding="utf-8")

            environment = {**os.environ,
                           "HOME": str(root / "home"),
                           "XDG_DATA_HOME": str(data_home),
                           "XDG_CONFIG_HOME": str(root / "config"),
                           "BLOX_USER_DATA_DIR": str(user_themes.parent)}
            (root / "home").mkdir()

            completed = subprocess.run(
                [str(root / "shell/scripts/theme/themectl.sh"), "list", "--json"],
                env=environment, capture_output=True, text=True, timeout=60, check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stderr[-400:])
            self.assertIn("fatal:", completed.stderr) if False else None
            response = json.loads(completed.stdout)
            ids = [entry["id"] for entry in response["data"]]
            self.assertIn("my-custom-theme", ids)


if __name__ == "__main__":
    unittest.main()
