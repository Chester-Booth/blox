"""Public examples must pass the real settings and broker subscription contract."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from blox_widgets.broker import Broker
from blox_widgets.model import validate_settings

EXAMPLES = Path(__file__).resolve().parents[1] / "examples"


class SdkExampleTests(unittest.TestCase):
    def options(self, file, provider):
        text = (EXAMPLES / file).read_text(encoding="utf-8")
        match = re.search(r'context\.requestData\("' + provider + r'",\s*(\{[^}]*\})\)', text)
        self.assertIsNotNone(match, f"{file} must declare its concrete request options")
        return json.loads(match.group(1))

    def test_examples_use_complete_native_settings(self):
        for filename, provider in (("Clock.qml", "clock"), ("Music.qml", "music")):
            with self.subTest(provider=provider):
                options = self.options(filename, provider)
                self.assertEqual(validate_settings(provider, options), options)

    def test_clock_example_gets_real_ready_broker_observation(self):
        output = []
        broker = Broker(output.append)
        self.addCleanup(broker.close)
        broker.handle({"requestId": "example", "op": "subscribe", "consumerId": "example-clock",
                       "provider": "clock", "options": self.options("Clock.qml", "clock"), "generation": 7})
        self.assertFalse([response for response in output if "error" in response], output)
        broker.tick()
        ready = [response["snapshot"] for response in output
                 if response.get("snapshot", {}).get("state") == "ready"]
        self.assertEqual(len(ready), 1, output)
        self.assertEqual(ready[0]["generation"], 7)
        self.assertIsInstance(ready[0]["value"]["epochMs"], (int, float))
        broker.unsubscribe("example-clock")
        self.assertIsNone(broker.wait_seconds())


if __name__ == "__main__":
    unittest.main()
