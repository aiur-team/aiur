"""Deterministic, finite-population checks for permutation inference."""

import itertools
import json
from pathlib import Path
import math
import unittest
from statistics import mean, median

from analytics.stats.permutation import permutation_test


def difference(a, b):
    return mean(b) - mean(a)


class PermutationTests(unittest.TestCase):
    def test_scipy_exact_absolute_tail_golden_and_mc_se(self):
        path = Path(__file__).parent / 'fixtures' / 'stats' / 'goldens.json'
        for fixture in json.loads(path.read_text())['permutation']:
            with self.subTest(a=fixture['a'], b=fixture['b']):
                result = permutation_test(fixture['a'], fixture['b'], difference,
                                          seed=(42, 54), resamples=20_000)
                expected_se = math.sqrt(result['p_value'] * (1 - result['p_value']) / 20_000)
                self.assertAlmostEqual(result['mc_se'], expected_se, places=15)
                self.assertLess(abs(result['p_value'] - fixture['p_value']), 3 * expected_se)

    def test_exact_population_with_monte_carlo_tolerance(self):
        a, b = [1, 2, 3, 4], [4, 5, 6, 7]
        pooled = a + b
        observed = difference(a, b)
        statistics = []
        for indices in itertools.combinations(range(len(pooled)), len(a)):
            selected = set(indices)
            statistics.append(difference([x for i, x in enumerate(pooled) if i in selected],
                                         [x for i, x in enumerate(pooled) if i not in selected]))
        expected = sum(abs(x) >= abs(observed) for x in statistics) / len(statistics)
        result = permutation_test(a, b, difference, seed=(42, 54), resamples=20_000)
        self.assertEqual(result['method'], 'permutation_mc')
        self.assertEqual(result['statistic'], 3)
        self.assertEqual(result['p_value'], 0.05824708764561772)
        self.assertLess(abs(result['p_value'] - expected), 3 * result['mc_se'])
        self.assertEqual(result, permutation_test(a, b, difference,
                                                seed=(42, 54), resamples=20_000))

    def test_plus_one_and_absolute_two_sided_tail(self):
        seen = []
        def statistic(a, b):
            seen.append((a.copy(), b.copy()))
            return difference(a, b)
        result = permutation_test([0, 1], [10, 11], statistic, seed=(42, 54), resamples=1)
        self.assertEqual(seen, [([0, 1], [10, 11]), ([1, 10], [0, 11])])
        # The actual permutation has contrast zero versus observed ten: b=0, m=1.
        self.assertEqual(result['p_value'], 0.5)
        self.assertEqual(result['mc_se'], 0.5)
        self.assertEqual(permutation_test([0], [1], difference, resamples=5)['p_value'], 1)

    def test_inputs_preserved_and_invalid_input_rejected(self):
        a, b = [3, 1, 2], [5, 4]
        permutation_test(a, b, lambda a, b: median(b) - median(a), resamples=10)
        self.assertEqual(a, [3, 1, 2])
        self.assertEqual(b, [5, 4])
        for invalid in (0, -1, True, 1.5):
            with self.assertRaisesRegex(ValueError, 'resamples'):
                permutation_test(a, b, difference, resamples=invalid)
        for invalid in (math.nan, math.inf):
            with self.assertRaises(ValueError):
                permutation_test([invalid], b, difference)
            with self.assertRaisesRegex(ValueError, 'finite'):
                permutation_test(a, b, lambda a, b: invalid)
        with self.assertRaisesRegex(ValueError, 'a'):
            permutation_test([], b, difference)

    def test_resampled_nonfinite_statistic_rejected(self):
        calls = iter([1.0, math.inf])
        with self.assertRaisesRegex(ValueError, 'resamples'):
            permutation_test([0], [1], lambda a, b: next(calls), resamples=2)
