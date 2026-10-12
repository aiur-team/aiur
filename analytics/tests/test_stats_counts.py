"""Binary and exposure-rate tests against committed independent references."""

import json
import math
from pathlib import Path
import unittest

from analytics.stats.counts import fisher_exact, newcombe_interval, poisson_rate_test

GOLDENS = Path(__file__).parent / "fixtures" / "stats" / "goldens.json"


class CountsTest(unittest.TestCase):
    def test_fisher_scipy_goldens(self):
        for case in json.loads(GOLDENS.read_text())["fisher"]:
            with self.subTest(case=case):
                result = fisher_exact(case["table"])
                self.assertAlmostEqual(result["p_value"], case["p_value"], delta=1e-9)
                expected = case["statistic"]
                if isinstance(expected, str):
                    expected = float(expected)
                if expected is None:
                    self.assertTrue(math.isnan(result["statistic"]) or
                                    math.isinf(result["statistic"]))
                else:
                    self.assertAlmostEqual(result["statistic"], expected, delta=1e-9)
                self.assertEqual(result["method"], "exact")

    def test_newcombe_statsmodels_goldens(self):
        for case in json.loads(GOLDENS.read_text())["newcombe"]:
            with self.subTest(case=case):
                result = newcombe_interval(case["k1"], case["n1"],
                                           case["k2"], case["n2"])
                self.assertAlmostEqual(result["lo"], case["lo"], delta=1e-9)
                self.assertAlmostEqual(result["hi"], case["hi"], delta=1e-9)
                self.assertEqual(result["estimate"], case["k1"] / case["n1"] -
                                 case["k2"] / case["n2"])
                self.assertEqual(result["method"], "newcombe")

    def test_poisson_scipy_goldens(self):
        for case in json.loads(GOLDENS.read_text())["poisson"]:
            with self.subTest(case=case):
                result = poisson_rate_test(case["k1"], case["t1"],
                                           case["k2"], case["t2"])
                self.assertAlmostEqual(result["p_value"], case["p_value"], delta=1e-9)
                if case["k1"] + case["k2"] == 0:
                    self.assertIsNone(result["rate_ratio"])
                    self.assertIsNone(result["lo"])
                    self.assertIsNone(result["hi"])
                    self.assertEqual(result["method"], "exact_undefined_ratio")
                    continue
                for key, expected in (("rate_ratio", case["ratio"]),
                                      ("lo", case["lo"]), ("hi", case["hi"])):
                    if expected is None:
                        self.assertEqual(result[key], math.inf)
                    else:
                        self.assertAlmostEqual(result[key], expected,
                                               delta=max(1e-9, abs(expected) * 1e-10))
                self.assertEqual(result["method"], "conditional_exact")

    def test_fisher_zero_denominators_distinguish_infinite_and_undefined_odds(self):
        self.assertEqual(fisher_exact([[2, 0], [0, 2]])["statistic"], math.inf)
        self.assertTrue(math.isnan(fisher_exact([[0, 0], [1, 2]])["statistic"]))

    def test_exact_rate_probability_for_complete_separation(self):
        result = poisson_rate_test(4, 10, 0, 10)
        self.assertAlmostEqual(result["p_value"], 2 / 16, delta=1e-14)

    def test_no_events_are_explicitly_undefined(self):
        self.assertEqual(poisson_rate_test(0, 2, 0, 8), {
            "statistic": None, "rate_ratio": None, "p_value": 1.0,
            "lo": None, "hi": None, "method": "exact_undefined_ratio"})

    def test_rate_orientation_and_zero_event_bounds(self):
        self.assertEqual(poisson_rate_test(4, 10, 2, 10)["rate_ratio"], 2)
        first_zero = poisson_rate_test(0, 10, 2, 10)
        self.assertEqual(first_zero["lo"], 0)
        self.assertGreater(first_zero["hi"], 0)
        second_zero = poisson_rate_test(2, 10, 0, 10)
        self.assertEqual(second_zero["hi"], math.inf)
        self.assertGreater(second_zero["lo"], 0)

    def test_extreme_finite_exposure_does_not_round_the_null_probability(self):
        result = poisson_rate_test(1, 1e-300, 0, 1e300)
        self.assertEqual(result["p_value"], 0.0)
        self.assertEqual(result["rate_ratio"], math.inf)
        zero = poisson_rate_test(0, 1e-300, 1, 1e300)
        self.assertEqual(zero["rate_ratio"], 0)
        self.assertEqual(zero["lo"], 0)

    def test_rejects_invalid_counts_exposures_and_confidence(self):
        for k in (-1, 1.5, True):
            with self.subTest(k=k), self.assertRaises(ValueError):
                fisher_exact([[k, 2], [3, 4]])
            with self.subTest(k=k), self.assertRaises(ValueError):
                poisson_rate_test(k, 1, 1, 1)
            with self.subTest(k=k), self.assertRaises(ValueError):
                newcombe_interval(k, 4, 1, 4)
        for table in ([[1, 2]], [[1, 2, 3], [1, 2, 3]]):
            with self.assertRaises(ValueError):
                fisher_exact(table)
        for t in (0, -1, float("nan"), float("inf")):
            with self.subTest(t=t), self.assertRaises(ValueError):
                poisson_rate_test(1, t, 1, 1)
        for confidence in (0, 1, float("nan"), float("inf")):
            with self.subTest(confidence=confidence), self.assertRaises(ValueError):
                poisson_rate_test(1, 1, 1, 1, confidence)
            with self.subTest(confidence=confidence), self.assertRaises(ValueError):
                newcombe_interval(1, 4, 1, 4, confidence)
        for args in ((1, 0, 1, 4), (5, 4, 1, 4), (1, 4, 5, 4)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                newcombe_interval(*args)
