"""Independently pinned statsmodels multipletests outputs."""

import unittest

from analytics.stats.multiplicity import adjust


class MultiplicityTest(unittest.TestCase):
    def test_statsmodels_goldens(self):
        # statsmodels 0.14 multipletests; includes ties and p=1.
        raw = dict(zip('abcdef', [.01, .04, .03, .01, .8, 1.]))
        for method, expected in [('holm', [.06, .12, .12, .06, 1., 1.]),
                                 ('bh', [.03, .06, .06, .03, .96, 1.])]:
            with self.subTest(method=method):
                result = adjust(raw, method)
                for key, value in zip(raw, expected):
                    self.assertAlmostEqual(result[key], value, places=12)

    def test_empty_and_invalid(self):
        self.assertEqual(adjust({}, 'holm'), {})
        for value in [-.1, 1.1, float('nan')]:
            with self.assertRaises(ValueError):
                adjust({'x': value}, 'bh')
