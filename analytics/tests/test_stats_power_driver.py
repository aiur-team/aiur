"""Power remains available when the inference guard rejects a metric."""

from copy import deepcopy
import unittest

from analytics.stats import analyze
from tests.test_stats_analyze import fixture


class PowerDriverTest(unittest.TestCase):
    def test_insufficient_data_still_has_sample_requirement_eta_and_sentence(self):
        snapshot, spec = fixture('guard')
        snapshot['taken_at'] = '2026-10-12T00:00:00Z'
        spec['windows'] = {'b': {'start': '2026-10-09T00:00:00Z'}}
        spec['metrics'][0]['mde'] = .2
        result = analyze(snapshot, spec)['metrics']['latency']
        power = result['power']
        self.assertEqual(result['status'], 'insufficient_data')
        self.assertIsInstance(power['samples_needed_per_group'], int)
        self.assertEqual(power['baseline_group'], 'a')
        self.assertIsNotNone(power['projected_p_if_effect_holds'])
        self.assertAlmostEqual(power['accrual_per_day'], 40/3, places=8)
        self.assertEqual(power['eta_date'], '2026-10-12')
        self.assertIn('need about', result['summary_text'])
        self.assertIn('days at the current rate', result['summary_text'])
        del snapshot['taken_at']
        self.assertIsNone(analyze(snapshot, spec)['metrics']['latency']['power']['eta_date'])

    def test_flags_use_registered_mde_and_exploratory_is_noether_only(self):
        snapshot, spec = fixture()
        for i, row in enumerate(snapshot['metrics']['latency']['rows']):
            row['value'] = 100 + (i % 40)
        spec['metrics'][0]['mde'] = .02
        small = analyze(snapshot, spec)['metrics']['latency']
        self.assertIn('underpowered', small['flags'])
        spec['metrics'][0]['mde'] = .3
        large = analyze(snapshot, spec)['metrics']['latency']
        self.assertNotIn('underpowered', large['flags'])
        spec['primary_metrics'] = []
        exploratory = analyze(snapshot, spec)['metrics']['latency']
        self.assertIn('power_estimate_approximate', exploratory['flags'])
        self.assertEqual(exploratory['power']['simulations'], 0)
        self.assertIsNotNone(exploratory['power']['samples_needed_noether'])
        snapshot['metrics']['latency']['rows'][0]['censored'] = True
        self.assertIn('power_ignores_censoring', analyze(snapshot, spec)['metrics']['latency']['flags'])

    def test_non_mwu_kinds_do_not_publish_misleading_power(self):
        snapshot, spec = fixture('guard')
        spec['metrics'][0]['kind'] = 'binary'
        for i, row in enumerate(snapshot['metrics']['latency']['rows']):
            row['value'] = i % 2
        result = analyze(snapshot, spec)['metrics']['latency']['power']
        self.assertEqual(result['status'], 'not_estimable')
        self.assertIsNone(result['power_at_current_n'])
        self.assertIsNone(result['samples_needed_noether'])
        self.assertIn('binary', result['reason'])

    def test_future_eta_and_short_window_omission(self):
        snapshot, spec = fixture('guard')
        for i, row in enumerate(snapshot['metrics']['latency']['rows']):
            row['value'] = 100 + (i % 6) * 10
        spec['metrics'][0]['mde'] = .02
        snapshot['taken_at'] = '2026-10-12T00:00:00Z'
        spec['windows'] = {'b': {'start': '2026-10-09T00:00:00Z'}}
        power = analyze(snapshot, spec)['metrics']['latency']['power']
        self.assertGreater(power['days_needed'], 0)
        self.assertGreater(power['eta_date'], '2026-10-12')
        shorter = deepcopy(spec)
        shorter['windows']['b']['start'] = '2026-10-11T23:00:00Z'
        self.assertIsNone(analyze(snapshot, shorter)['metrics']['latency']['power']['eta_date'])
