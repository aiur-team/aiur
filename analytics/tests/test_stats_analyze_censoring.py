"""Open tickets are right-censored durations: primary inference, bias fixture, unchanged path."""

from copy import deepcopy
import json
import math
from pathlib import Path
import unittest
from unittest.mock import patch

from analytics.stats import analyze
from analytics.stats.canonical import encode

FIXTURES = Path(__file__).parent / 'fixtures/stats/experiments'
SPEC = {'metrics': [{'id': 'd', 'kind': 'duration', 'direction': 'lower_is_better', 'mde': .5, 'unit': 'h'}],
        'primary_metrics': ['d'], 'bootstrap_primary': 400, 'permutation_resamples': 500}


def window(prefix, group, n, scale, open_elapsed=()):
    """Exponential quantile grid; the slowest len(open_elapsed) tickets are still open."""
    first_open = n - len(open_elapsed)
    return [{'unit_id': f'{prefix}{i}', 'group': group, 'censored': i >= first_open,
             'value': (float(open_elapsed[i - first_open]) if i >= first_open
                       else round(-math.log(1 - (i + .5) / n) * 50 * scale, 3))} for i in range(n)]


def bias_snapshot():
    """Both windows draw from one process (after is 20% faster); the 10 slowest after-tickets are open."""
    rows = window('b', 'before', 60, 1) + window('a', 'after', 40, .8, range(60, 70))
    return {'experiment_id': 'bias', 'groups': ['before', 'after'], 'metrics': {'d': {'kind': 'duration', 'rows': rows}}}


class CensoredAnalysisTest(unittest.TestCase):
    def test_bias_fixture_completed_only_overclaims_and_primary_is_inconclusive(self):
        snapshot = bias_snapshot()
        completed = deepcopy(snapshot)
        completed['metrics']['d']['rows'] = [r for r in completed['metrics']['d']['rows'] if not r['censored']]
        naive = analyze(completed, SPEC)['metrics']['d']
        self.assertEqual((naive['status'], naive['direction']), ('significant', 'improved'))
        primary = analyze(snapshot, SPEC)['metrics']['d']
        self.assertEqual((primary['status'], primary['direction']), ('inconclusive', 'no_change'))
        self.assertIn('censoring_heavy', primary['flags'])
        self.assertIn('logrank', primary['tests'])
        self.assertGreater(primary['p_raw'], .05)
        # The biased completed-only test is retained, labelled, under sensitivity.
        self.assertEqual(primary['sensitivity']['method'], 'completed_only')
        self.assertLess(primary['sensitivity']['p_raw'], .05)
        self.assertEqual(primary['sensitivity']['p_raw'], naive['p_raw'])

    def test_primary_reports_km_medians_and_horizon(self):
        survival = analyze(bias_snapshot(), SPEC)['metrics']['d']['survival']
        self.assertEqual(survival['groups']['after']['n_censored'], 10)
        self.assertEqual(survival['groups']['after']['n'], 40)
        self.assertEqual(survival['follow_up_horizon'], 69.0)
        self.assertIsNotNone(survival['groups']['before']['median'])

    def test_truncation_sets_flag_only_when_rows_change(self):
        metric = analyze(bias_snapshot(), SPEC)['metrics']['d']
        self.assertIn('follow_up_truncated', metric['flags'])
        snapshot = bias_snapshot()
        for row in snapshot['metrics']['d']['rows']:
            row['value'] = min(row['value'], 60.0)
        # Everything now ends at or before the common horizon, so nothing is cut.
        metric = analyze(snapshot, SPEC)['metrics']['d']
        self.assertNotIn('follow_up_truncated', metric['flags'])

    def test_median_not_yet_reached_summary_names_open_fraction(self):
        snapshot = bias_snapshot()
        for row in snapshot['metrics']['d']['rows']:
            if row['group'] == 'after':
                row['censored'], row['value'] = row['unit_id'] != 'a0', 50.0 + int(row['unit_id'][1:]) / 100
        metric = analyze(snapshot, SPEC)['metrics']['d']
        self.assertIn('median_not_reached', metric['flags'])
        self.assertEqual(metric['status'], 'inconclusive')
        self.assertIn('median not yet reached (', metric['summary_text'])
        self.assertIn('39% still open)', metric['summary_text'])

    def test_censored_row_without_elapsed_time_falls_back_and_says_so(self):
        snapshot = bias_snapshot()
        snapshot['metrics']['d']['rows'][-1]['value'] = None
        metric = analyze(snapshot, SPEC)['metrics']['d']
        self.assertIn('censoring_unknown', metric['flags'])
        self.assertIn('censoring_ignored', metric['flags'])
        self.assertNotIn('survival', metric)
        self.assertIn('mann_whitney_u', metric['tests'])

    def test_unknown_follow_up_with_strata_uses_explicit_completed_only_fallback(self):
        snapshot = bias_snapshot()
        snapshot['metrics']['d']['rows'][-1]['value'] = None
        metric = analyze(snapshot, {**SPEC, 'strata': ['label']})['metrics']['d']
        fallback = analyze(snapshot, SPEC)['metrics']['d']
        self.assertIn('stratification_unavailable', metric['flags'])
        self.assertIn('censoring_unknown', metric['flags'])
        self.assertIn('censoring_ignored', metric['flags'])
        self.assertNotIn('stratified', metric)
        self.assertEqual(metric['tests'], fallback['tests'])
        self.assertEqual(metric['p_raw'], fallback['p_raw'])

    def test_uncensored_body_is_byte_identical_to_pre_censoring_engine(self):
        for name in ('shift', 'inconclusive'):
            with self.subTest(fixture=name):
                snapshot, spec = (json.loads((FIXTURES / f'{name}-{kind}.json').read_text())
                                  for kind in ('snapshot', 'spec'))
                expected = (FIXTURES / f'{name}-result.json').read_text()
                self.assertEqual(encode(analyze(snapshot, spec)), expected)

    def test_uncensored_path_does_not_enter_survival_code(self):
        snapshot = bias_snapshot()
        snapshot['metrics']['d']['rows'] = [r for r in snapshot['metrics']['d']['rows'] if not r['censored']]
        with patch('analytics.stats.analyze.censored_inference', side_effect=AssertionError('survival used')):
            self.assertNotIn('survival', analyze(snapshot, SPEC)['metrics']['d'])


if __name__ == '__main__':
    unittest.main()
