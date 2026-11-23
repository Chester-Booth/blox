"""Focused tests for tools/bench.py."""

import unittest

from tools.bench import run


class BenchTests(unittest.TestCase):
    def test_offline_benchmarks_return_positive_timings(self):
        report = run(iterations=5, include_live=False)
        for key in ("theme_load", "widget_validation"):
            self.assertIn(key, report)
            self.assertEqual(report[key]["iterations"], 5)
            self.assertGreaterEqual(report[key]["median_ms"], 0.0)
            self.assertGreaterEqual(report[key]["p95_ms"], report[key]["median_ms"])


if __name__ == "__main__":
    unittest.main()
