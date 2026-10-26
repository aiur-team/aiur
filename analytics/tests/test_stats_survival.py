"""Kaplan-Meier and log-rank statistics against lifelines goldens (see generate_survival_goldens.py)."""

import json
from pathlib import Path
import unittest

from analytics.stats.survival import (censored_inference, km_median, km_median_interval, logrank,
                                      stratified_logrank, truncate)

GOLDENS = json.loads((Path(__file__).parent / 'fixtures/stats/survival-goldens.json').read_text())


def rows(*pairs):
    return [{'value': float(v), 'censored': bool(c)} for v, c in pairs]


class SurvivalGoldenTest(unittest.TestCase):
    def test_kaplan_meier_median_and_interval_match_lifelines(self):
        for name, groups in GOLDENS['km'].items():
            for i, golden in enumerate(groups):
                with self.subTest(fixture=name, group=i):
                    got = km_median_interval(golden['rows'])
                    for key in ('median', 'lo', 'hi'):
                        if golden[key] is None:
                            self.assertIsNone(got[key])
                        else:
                            self.assertAlmostEqual(got[key], golden[key], delta=1e-6)

    def test_logrank_matches_lifelines(self):
        for name, golden in GOLDENS['logrank'].items():
            with self.subTest(fixture=name):
                got = logrank(golden['a'], golden['b'])
                self.assertAlmostEqual(got['statistic'], golden['statistic'], delta=1e-6)
                self.assertAlmostEqual(got['p_value'], golden['p_value'], delta=1e-6)

    def test_stratified_logrank_sums_scores_across_strata(self):
        golden = GOLDENS['stratified_logrank']
        got = stratified_logrank({k: (v['a'], v['b']) for k, v in golden['strata'].items()})
        self.assertAlmostEqual(got['statistic'], golden['statistic'], delta=1e-6)
        self.assertAlmostEqual(got['p_value'], golden['p_value'], delta=1e-6)
        # Pooling strata would give a different statistic; the sum over strata is the contract.
        pooled = logrank(*(sum((v[i] for v in ((s['a'], s['b']) for s in golden['strata'].values())), [])
                           for i in (0, 1)))
        self.assertNotAlmostEqual(pooled['statistic'], golden['statistic'], delta=1e-6)


class SurvivalEdgeTest(unittest.TestCase):
    def test_all_censored_has_no_median_and_no_exception(self):
        sample = rows((5, 1), (7, 1), (9, 1))
        self.assertIsNone(km_median(sample))
        self.assertEqual(km_median_interval(sample), {'median': None, 'lo': None, 'hi': None})

    def test_even_n_median_is_first_time_survival_reaches_half(self):
        # Type-7 would average 2 and 3; Kaplan-Meier reports the first time S(t) <= .5.
        self.assertEqual(km_median(rows((1, 0), (2, 0), (3, 0), (4, 0))), 2.0)

    def test_truncate_censors_beyond_shorter_groups_longest_follow_up(self):
        cut, horizon, changed = truncate({'a': rows((3, 0), (10, 0)), 'b': rows((4, 0), (6, 1))})
        self.assertEqual((horizon, changed), (6.0, True))
        self.assertEqual(cut['a'], rows((3, 0), (6, 1)))
        self.assertEqual(cut['b'], rows((4, 0), (6, 1)))

    def test_truncate_without_change(self):
        _, horizon, changed = truncate({'a': rows((3, 0), (6, 0)), 'b': rows((4, 0), (6, 1))})
        self.assertEqual((horizon, changed), (6.0, False))

    def test_interval_withheld_when_more_than_tenth_of_resamples_lack_a_median(self):
        a = rows(*[(i, 0) for i in range(1, 11)])
        b = rows(*[(i, 1 if i > 4 else 0) for i in range(1, 11)])
        _, effects, survival, flags, _ = censored_inference({'a': a, 'b': b}, ['a', 'b'], (1, 2), 200)
        effect = effects['median_difference']
        self.assertIn('median_not_reached', flags)
        self.assertIsNone(survival['groups']['b']['median'])
        self.assertEqual((effect['estimate'], effect['lo'], effect['hi']), (None, None, None))

    def test_unreached_resamples_withhold_interval_but_keep_estimate(self):
        # Medians exist in both groups, but about 40% of resamples lose theirs.
        a = rows(*[(i, 0) for i in range(1, 11)])
        b = rows(*[(i, 0 if i < 6 else 1) for i in range(1, 11)])
        _, effects, _, flags, _ = censored_inference({'a': a, 'b': b}, ['a', 'b'], (1, 2), 200)
        effect = effects['median_difference']
        self.assertEqual(effect['estimate'], km_median(b) - km_median(a))
        self.assertGreater(effect['not_reached_fraction'], .1)
        self.assertEqual((effect['lo'], effect['hi']), (None, None))
        self.assertIn('median_not_reached', flags)


if __name__ == '__main__':
    unittest.main()
