"""Type-7 descriptives against committed NumPy reference values."""

import json
import math
from pathlib import Path
import unittest

from analytics.stats.describe import describe, quantile


class DescribeTests(unittest.TestCase):
    def test_descriptive_goldens(self):
        fixtures = json.loads((Path(__file__).parent / 'fixtures/stats/goldens.json').read_text())
        for row in fixtures['describe']:
            with self.subTest(n=len(row['values'])):
                result = describe(row['values'])
                self.assertEqual(result.keys(), row['result'].keys())
                for key, expected in row['result'].items():
                    self.assertAlmostEqual(result[key], expected, delta=1e-12)

    def test_empty_validation_and_order(self):
        self.assertEqual(describe([]), {'n': 0})
        values = [10, 1, 4, 2]
        self.assertEqual(quantile(values, .25), 1.75)
        self.assertEqual(values, [10, 1, 4, 2])
        self.assertEqual(quantile([-1e308, 1e308], .5), 0)
        for p in (-.1, 1.1, math.nan, math.inf):
            with self.assertRaises(ValueError):
                quantile([1], p)
        for value in (math.inf, math.nan, None):
            with self.assertRaises(ValueError):
                describe([value])
        with self.assertRaises(ValueError):
            quantile([], .5)
