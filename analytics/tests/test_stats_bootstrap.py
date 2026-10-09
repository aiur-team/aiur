"""Independent and shared resampling checks for BCa intervals."""

import json
import math
from pathlib import Path
import unittest
from statistics import mean, median
from unittest.mock import patch

from analytics.stats.bootstrap import bootstrap, _acceleration, _probabilities


def difference(a, b):
    return mean(b) - mean(a)


class BootstrapTests(unittest.TestCase):
    def test_scipy_bca_median_difference_goldens(self):
        path = Path(__file__).parent / 'fixtures' / 'stats' / 'goldens.json'
        for fixture in json.loads(path.read_text())['bootstrap']:
            with self.subTest(fixture=fixture['name']):
                result = bootstrap(fixture['a'], fixture['b'],
                                   {'median': lambda a, b: median(b) - median(a)},
                                   seed=(42, 54), resamples=20_000)['median']
                self.assertEqual(result['estimate'], fixture['estimate'])
                self.assertEqual(result['method'], fixture['method'])
                self.assertLessEqual(abs(result['lo'] - fixture['lo']), fixture['tolerance'])
                self.assertLessEqual(abs(result['hi'] - fixture['hi']), fixture['tolerance'])

    def test_unequal_group_acceleration_matches_analytic_mean(self):
        a, b = [1, 2, 9], [2, 3, 4, 5, 9]
        influences = [(mean(a) - x) / len(a) for x in a]
        influences += [(x - mean(b)) / len(b) for x in b]
        expected = sum(x ** 3 for x in influences) / (6 * sum(x ** 2 for x in influences) ** 1.5)
        self.assertAlmostEqual(_acceleration(a, b, difference), expected, places=14)

    def test_stratified_acceleration_conditions_on_counts(self):
        a, b = [1, 2, 9, 1000, 1002], [2, 3, 4, 10, 2000, 2003, 9000]
        strata = ([[0, 1, 2], [3, 4]], [[0, 1, 2, 3], [4, 5], [6]])
        influences = []
        for group, indices_by_stratum, sign in ((a, strata[0], -1), (b, strata[1], 1)):
            for indices in indices_by_stratum:
                average = mean(group[i] for i in indices)
                influences.extend(sign * (group[i] - average) / len(group) for i in indices)
        expected = sum(x ** 3 for x in influences) / (6 * sum(x ** 2 for x in influences) ** 1.5)
        self.assertAlmostEqual(_acceleration(a, b, difference, strata), expected, places=12)
        self.assertGreater(abs(_acceleration(a, b, difference) - expected), 0.01)
        with patch('analytics.stats.bootstrap._probabilities', wraps=_probabilities) as probabilities:
            bootstrap(a, b, {'difference': difference}, resamples=50,
                      strata=(['low'] * 3 + ['high'] * 2,
                              ['low'] * 4 + ['high'] * 2 + ['singleton']))
        self.assertAlmostEqual(probabilities.call_args.args[2], expected, places=12)

    def test_all_singleton_strata_skip_jackknife_and_use_percentile(self):
        evaluations = []
        def statistic(a, b):
            evaluations.append((len(a), len(b)))
            return difference(a, b)
        result = bootstrap([1, 100], [3, 200, 300], {'difference': statistic}, resamples=10,
                           strata=([0, 1], [0, 1, 2]))['difference']
        self.assertEqual(evaluations, [(2, 3)] * 11)
        self.assertEqual(result['method'], 'percentile')
        self.assertEqual(result['lo'], result['estimate'])
        self.assertEqual(result['hi'], result['estimate'])

    def test_shared_draws_and_exact_call_count(self):
        a, b, draws, resamples = [1, 2, 3], [5, 6, 7, 8], [], 20
        calls = {name: 0 for name in ('first', 'second', 'third')}

        def statistic(name):
            def evaluate(a, b):
                calls[name] += 1
                if 1 < calls[name] <= resamples + 1:
                    draws.append((name, tuple(a), tuple(b)))
                return difference(a, b)
            return evaluate

        result = bootstrap(a, b, {name: statistic(name) for name in calls}, resamples=resamples)
        self.assertEqual(list(calls.values()), [1 + resamples + len(a) + len(b)] * 3)
        for i in range(0, len(draws), 3):
            self.assertEqual(draws[i][1:], draws[i + 1][1:])
            self.assertEqual(draws[i][1:], draws[i + 2][1:])
        self.assertEqual(result['first'], result['second'])
        self.assertEqual(result['first'], result['third'])

    def test_degenerate_jackknife_uses_percentile(self):
        result = bootstrap([1, 1, 1], [2, 2, 2], {'median': lambda a, b: median(b) - median(a)},
                           resamples=50)['median']
        self.assertEqual(result, {'estimate': 1, 'lo': 1, 'hi': 1, 'method': 'percentile',
                                  'resamples': 50, 'mc_se': 0})
        self.assertEqual(bootstrap([1], [2], {'difference': difference}, resamples=10)
                         ['difference']['method'], 'percentile')

    def test_stratum_sizes_and_positions_preserved(self):
        seen = []
        def statistic(a, b):
            seen.append((a.copy(), b.copy()))
            return difference(a, b)
        bootstrap([1, 2, 100], [4, 5, 200], {'difference': statistic}, resamples=20,
                  strata=(['low', 'low', 'high'], ['low', 'low', 'high']))
        self.assertEqual(len(seen[1:21]), 20)
        self.assertTrue(any(a[:2] != [1, 2] for a, _ in seen[1:21]))
        for a, b in seen[1:21]:
            self.assertEqual(a[2], 100)
            self.assertEqual(b[2], 200)
            self.assertTrue(set(a[:2]) <= {1, 2})
            self.assertTrue(set(b[:2]) <= {4, 5})

    def test_known_draws_percentiles_and_mc_se(self):
        # A singleton group makes BCa undefined: verify actual percentile arithmetic.
        with patch('analytics.stats.bootstrap._draw', side_effect=[[0], [2], [0], [4],
                                                                   [0], [6]]):
            result = bootstrap([0], [2, 4, 6], {'difference': difference},
                               resamples=3, confidence=0.5)['difference']
        self.assertEqual((result['lo'], result['hi']), (3, 5))
        self.assertAlmostEqual(result['mc_se'], 2 / math.sqrt(3))

    def test_validation_and_input_preservation(self):
        a, b = [3, 1, 2], [5, 4, 6]
        original = a.copy(), b.copy()
        first = bootstrap(a, b, {'difference': difference}, seed=(42, 54), resamples=50)
        self.assertEqual(first, bootstrap(a, b, {'difference': difference},
                                         seed=(42, 54), resamples=50))
        self.assertEqual((a, b), original)
        for kwargs in ({'resamples': 1}, {'resamples': True}, {'confidence': 1},
                       {'confidence': math.nan}, {'strata': ([0], [0, 1, 2])}):
            with self.assertRaises(ValueError):
                bootstrap(a, b, {'difference': difference}, **kwargs)
        with self.assertRaises(ValueError):
            bootstrap(a, b, {})
        with self.assertRaisesRegex(ValueError, 'finite'):
            bootstrap(a, b, {'bad': lambda a, b: math.inf})
        calls = iter([1.0, math.nan])
        with self.assertRaisesRegex(ValueError, 'finite'):
            bootstrap(a, b, {'bad': lambda a, b: next(calls)}, resamples=2)
