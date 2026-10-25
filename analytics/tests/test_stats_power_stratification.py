"""Power integration retains the landed stratified inference contract."""

import unittest

from analytics.stats import analyze
from tests.test_experiment_schema import SCHEMA, validate
from tests.test_stats_stratification import simpson


class PowerStratificationTest(unittest.TestCase):
    def test_pooled_power_and_exploratory_strata_preserve_stratified_result(self):
        snapshot, spec = simpson()
        body = analyze(snapshot, spec)
        result = body['metrics']['latency']
        self.assertEqual(result['p_raw_source'], 'stratified')
        self.assertEqual(result['p_raw'], result['stratified']['p_value'])
        self.assertLess(result['unstratified']['p_raw'], .05)
        self.assertGreater(result['p_raw'], .05)
        self.assertEqual(result['power']['simulations'], 1000)
        self.assertIsInstance(result['power']['samples_needed_per_group'], int)
        self.assertIn('power_estimate_approximate', result['flags'])
        self.assertEqual(set(result['strata']), {'1', '2'})
        for child in result['strata'].values():
            self.assertIn('power_estimate_approximate', child['flags'])
            self.assertEqual(child['power']['simulations'], 0)
            self.assertGreaterEqual(child['power']['samples_needed_noether'], 5)
        validate({'generated_at': '2026-10-17T00:00:00Z', 'body': body}, SCHEMA)
