"""Prospective power calibration and bounded solver regressions."""

from statistics import NormalDist
from time import monotonic
import unittest

from analytics.stats.power import estimate, noether_n, simulate, _pvalues
from analytics.stats.power_sampling import draws
from analytics.stats.ranks import mann_whitney_u
from analytics.stats.rng import seed_from

SEED = seed_from('power-fixture')
BASELINE = [10 + NormalDist().inv_cdf((i + .5) / 200) for i in range(200)]


class PowerTest(unittest.TestCase):
    def test_normal_baseline_half_sd_and_noether_published_formula(self):
        # Multiplicative 5% at mean 10 is d=.5, with a slightly smaller B variance.
        power, se = simulate(BASELINE, 64, 64, .05, SEED)
        self.assertAlmostEqual(power, .8, delta=.03)
        self.assertAlmostEqual(se, (power * (1-power) / 1000) ** .5)
        # ceil((z_.975 + z_.8)^2 / (6*(.64-.5)^2)) = 67 per arm.
        self.assertEqual(noether_n(.64), 67)

    def test_sample_solver_monotonic_and_zero_variance_not_estimable(self):
        baseline = [i + 1 for i in range(40)]
        small = estimate(baseline, baseline, .2, SEED, simulations=100)
        large = estimate(baseline, baseline, .3, SEED, simulations=100)
        self.assertLessEqual(large['samples_needed_per_group'], small['samples_needed_per_group'])
        self.assertLess(large['mde_at_current_n'], .9)
        undefined = estimate([7]*40, [6]*40, .2, SEED)
        self.assertEqual(undefined['status'], 'not_estimable')
        self.assertIsNone(undefined['samples_needed_per_group'])
        self.assertIsNone(undefined['power_at_current_n'])

    def test_bounded_search_and_noether_only_exploratory(self):
        result = estimate(BASELINE, BASELINE, .00001, SEED, simulations=30)
        self.assertEqual(result['samples_needed_per_group'], '> 5000')
        result = estimate(BASELINE, BASELINE, .2, SEED, primary=False)
        self.assertEqual(result['simulations'], 0)
        self.assertEqual(result['samples_needed_noether'], 7)
        self.assertIsNone(result['power_at_current_n'])

    def test_counted_rank_method_matches_real_mwu_with_ties(self):
        support, simulations = draws([1, 1, 2, 3], 60, 80, SEED, 10)
        actual = _pvalues(support, simulations, .8, 60, 80)
        for p, pair in zip(actual, simulations):
            a = [x for x, n in zip(support, pair[0]) for _ in range(n)]
            b = [x*.8 for x, n in zip(support, pair[1]) for _ in range(n)]
            self.assertEqual(sum(pair[0]), 60)
            self.assertEqual(sum(pair[1]), 80)
            self.assertAlmostEqual(p, mann_whitney_u(a, b)['p_value'])

    def test_normal_reference_sample_size_mde_and_projected_p(self):
        # Textbook d=.5: about 64 per arm for two-sided alpha=.05, power=.8.
        # A 5% shift at mean 10 and SD 1 gives d=.5; allow MC/rank-efficiency error.
        result = estimate(BASELINE, [x*.95 for x in BASELINE], .05, SEED)
        n = result['samples_needed_per_group']
        self.assertGreaterEqual(n, 56)
        self.assertLessEqual(n, 72)
        self.assertAlmostEqual(n, result['samples_needed_noether'], delta=12)
        # Check the inversion itself: returning the unrefined Noether n is insufficient.
        self.assertGreaterEqual(simulate(BASELINE, n, n, .05, SEED)[0], .8)
        self.assertLess(simulate(BASELINE, n-1, n-1, .05, SEED)[0], .8)
        # At 80% power, median Z is about z_.975+z_.8=2.80, two-sided p about .005.
        self.assertGreater(result['projected_p_if_effect_holds'], .001)
        self.assertLess(result['projected_p_if_effect_holds'], .02)
        baseline64 = [10 + NormalDist().inv_cdf((i+.5)/64) for i in range(64)]
        null_effect = estimate(baseline64, baseline64, .05, SEED)
        # Inverting the same textbook case at 64/64 should recover a roughly 5% MDE.
        self.assertAlmostEqual(null_effect['mde_at_current_n'], .05, delta=.005)
        # With no observed shift the projected p median is near .5, not .005.
        self.assertGreater(null_effect['projected_p_if_effect_holds'], .35)
        self.assertLess(null_effect['projected_p_if_effect_holds'], .65)

    def test_primary_at_n200_within_per_metric_runtime_budget(self):
        # One representative primary gets one third of the three-primary 20 s budget.
        baseline = list(range(1, 201))
        start = monotonic()
        result = estimate(baseline, [x*.98 for x in baseline], .2, seed_from('0'))
        elapsed = monotonic()-start
        self.assertEqual(result['simulations'], 1000)
        self.assertGreater(result['power_at_current_n'], .8)
        self.assertLess(elapsed, 20/3)
