"""Reference tails and trust-boundary checks for the special functions."""

import json
import math
from pathlib import Path
import unittest

from analytics.stats.special import regularized_beta, regularized_gamma

GOLDENS = Path(__file__).parent / "fixtures" / "stats" / "goldens.json"


class SpecialFunctionsTest(unittest.TestCase):
    def test_gamma_scipy_goldens(self):
        for case in json.loads(GOLDENS.read_text())["gamma"]:
            with self.subTest(case=case):
                actual = regularized_gamma(case["a"], case["x"])
                self.assertAlmostEqual(actual, case["value"],
                                       delta=abs(case["value"]) * 1e-10)

    def test_beta_scipy_goldens(self):
        for case in json.loads(GOLDENS.read_text())["beta"]:
            with self.subTest(case=case):
                actual = regularized_beta(case["x"], case["a"], case["b"])
                self.assertAlmostEqual(actual, case["value"],
                                       delta=abs(case["value"]) * 1e-10)

    def test_boundaries(self):
        self.assertEqual(regularized_gamma(0.5, 0), 0)
        self.assertEqual(regularized_beta(0, 0.5, 0.5), 0)
        self.assertEqual(regularized_beta(1, 0.5, 0.5), 1)
        self.assertAlmostEqual(regularized_gamma(1, 2), 1 - math.exp(-2))
        self.assertAlmostEqual(regularized_beta(0.3, 1, 1), 0.3)

    def test_rejects_invalid_parameters(self):
        for a, x in ((0, 1), (-1, 1), (1, -1), (float("inf"), 1),
                     (1, float("nan")), (1, float("inf"))):
            with self.subTest(a=a, x=x), self.assertRaises(ValueError):
                regularized_gamma(a, x)
        for x, a, b in ((-0.1, 1, 1), (1.1, 1, 1), (0.5, 0, 1),
                         (0.5, 1, -1), (float("nan"), 1, 1),
                         (0.5, float("inf"), 1), (0.5, 1, float("inf"))):
            with self.subTest(x=x, a=a, b=b), self.assertRaises(ValueError):
                regularized_beta(x, a, b)
