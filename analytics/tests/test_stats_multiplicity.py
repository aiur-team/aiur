"""Independently pinned statsmodels multipletests outputs."""

import unittest
import json
from pathlib import Path

from analytics.stats.multiplicity import adjust


class MultiplicityTest(unittest.TestCase):
    def test_statsmodels_goldens(self):
        golden = json.loads((Path(__file__).parent / 'fixtures/stats/multiplicity-goldens.json').read_text())
        raw = dict(zip('abcdef', golden['p_values']))
        for method in ('holm', 'bh'):
            expected = golden[method]
            with self.subTest(method=method):
                result = adjust(raw, method)
                for key, value in zip(raw, expected):
                    self.assertAlmostEqual(result[key], value, places=12)

    def test_empty_and_invalid(self):
        self.assertEqual(adjust({}, 'holm'), {})
        for value in [-.1, 1.1, float('nan')]:
            with self.assertRaises(ValueError):
                adjust({'x': value}, 'bh')
