"""Driver tests exercise inference and the published numeric result body."""

from copy import deepcopy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from analytics.stats import analyze
from analytics.stats.canonical import encode

FIXTURES = Path(__file__).parent / 'fixtures/stats/experiments'


def fixture(name='shift'):
    return tuple(json.loads((FIXTURES / f'{name}-{kind}.json').read_text())
                 for kind in ('snapshot', 'spec'))


class AnalyzeTest(unittest.TestCase):
    def test_shift_and_direction(self):
        snapshot, spec = fixture()
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual((result['status'], result['direction']), ('significant', 'improved'))
        self.assertAlmostEqual(result['effects']['median_ratio']['estimate'], .7)
        self.assertLess(result['effects']['median_ratio']['hi'], 1)
        self.assertEqual(set(result['tests']), {'mann_whitney_u', 'permutation'})
        self.assertIn('hodges_lehmann', result['effects'])
        self.assertIn('cliffs_delta', result['effects'])
        spec['metrics'][0]['direction'] = 'higher_is_better'
        self.assertEqual(analyze(snapshot, spec)['metrics']['latency']['direction'], 'regressed')

    def test_guard_does_not_compute_inference(self):
        snapshot, spec = fixture('guard')
        with patch('analytics.stats.analyze.infer', side_effect=AssertionError('guard bypassed')):
            result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['status'], 'insufficient_data')
        self.assertEqual([result['groups'][g]['n'] for g in ['a', 'b']], [6, 40])
        self.assertNotIn('tests', result)
        self.assertNotIn('effects', result)
        self.assertIn('n 6 vs 40', result['summary_text'])

    def test_small_shift_pinned_labels(self):
        for name, status in [('equivalent', 'practically_equivalent'), ('inconclusive', 'inconclusive')]:
            with self.subTest(name=name):
                snapshot, spec = fixture(name)
                result = analyze(snapshot, spec)['metrics']['latency']
                self.assertEqual(result['status'], status)
                self.assertIn('n 40 vs 40', result['summary_text'])
                self.assertIn('95% CI', result['summary_text'])
                self.assertIn('p ', result['summary_text'])

    def test_exclusions_confounded_and_censoring(self):
        snapshot, spec = fixture()
        snapshot['metrics']['latency']['rows'][4]['censored'] = True
        annotations = {'flags':[{'metric':'*','flag':'confounded','reason':'release overlap','author':'analyst'}],
                       'exclusions':[{'unit_id':f'a{i}','reason':'wrong cohort'} for i in range(3)]}
        before = deepcopy((snapshot, spec, annotations))
        body = analyze(snapshot, spec, annotations)
        result = body['metrics']['latency']
        self.assertEqual(result['groups']['a']['n'], 36)
        self.assertEqual(result['groups']['a']['n_censored'], 1)
        self.assertEqual(result['analyst_flags'], annotations['flags'])
        self.assertEqual(body['exclusions'], annotations['exclusions'])
        self.assertNotIn('censoring_ignored', result['flags'])
        self.assertIn('logrank', result['tests'])
        self.assertIn('confounded', result['flags'])
        self.assertIn('release overlap', result['summary_text'])
        self.assertIn('3 units excluded', result['summary_text'])
        self.assertEqual((snapshot, spec, annotations), before)
        self.assertNotIn('confounded', analyze(snapshot, spec)['metrics']['latency']['flags'])

    def test_exploratory_freeze_warning_and_family_guard(self):
        snapshot, spec = fixture()
        spec['primary_metrics'] = []
        result = analyze(snapshot, spec)
        self.assertEqual(result['overall']['note'], 'no pre-registered primary')
        self.assertIn('exploratory', result['metrics']['latency']['flags'])
        self.assertEqual(result['metrics']['latency']['adjustment'], 'bh')
        spec['primary_metrics'] = ['latency']
        spec['frozen_at'] = '2026-10-09T00:00:00Z'
        spec['metrics'][0]['added_at'] = '2026-10-10T00:00:00+00:00'
        self.assertIn('added after frozen_at', analyze(snapshot, spec)['warnings'][0])
        del spec['metrics'][0]['added_at']
        spec['metrics'].append({'id':'missing','kind':'count'})
        spec['primary_metrics'].append('missing')
        body = analyze(snapshot, spec)
        metric = body['metrics']['latency']
        self.assertAlmostEqual(metric['p_adj'], 2 * metric['p_raw'])
        snapshot['metrics']['extra'] = {'rows':[]}
        self.assertIn('extra: not in spec; skipped', analyze(snapshot, spec)['warnings'])

    def test_binary_rate_bucketed(self):
        snapshot, spec = fixture()
        snapshot['metrics']['latency']['kind'] = 'binary'
        spec['metrics'][0]['kind'] = 'binary'
        for row in snapshot['metrics']['latency']['rows']:
            row['value'] = int(row['unit_id'].startswith('b'))
        binary = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(binary['effects']['proportion_difference']['estimate'], 1)
        self.assertIn('fisher', binary['tests'])
        snapshot['metrics']['latency'] = {'kind':'rate','groups':{'a':{'events':40,'exposure':100,'n':40},'b':{'events':20,'exposure':100,'n':40}}}
        spec['metrics'][0]['kind'] = 'rate'
        rate = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(rate['effects']['rate_ratio']['estimate'], .5)
        self.assertIn('conditional_poisson', rate['tests'])
        snapshot, spec = fixture()
        spec['metrics'][0]['kind'] = 'bucketed'
        self.assertIn('autocorrelated_units', analyze(snapshot, spec)['metrics']['latency']['flags'])

    def test_primary_test_selection_for_ties_and_cutoff(self):
        snapshot, spec = fixture()
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(metric['p_raw'], metric['tests']['mann_whitney_u']['p_value'])
        for size, primary in [(40, 'permutation'), (51, 'mann_whitney_u')]:
            snapshot['metrics']['latency']['rows'] = [
                {'unit_id':g+str(i),'group':g,'value':i % 3 + offset}
                for g, offset in [('a', 1), ('b', 10)] for i in range(size)]
            metric = analyze(snapshot, spec)['metrics']['latency']
            self.assertEqual(metric['p_raw'], metric['tests'][primary]['p_value'])
            self.assertNotEqual(metric['tests']['mann_whitney_u']['p_value'],
                                metric['tests']['permutation']['p_value'])

    def test_unbounded_rate_interval_preserves_direction_and_cause(self):
        snapshot, spec = fixture()
        spec['metrics'][0]['kind'] = 'rate'
        snapshot['metrics']['latency'] = {'kind':'rate','groups':{
            'a':{'events':0,'exposure':100,'n':40},
            'b':{'events':40,'exposure':100,'n':40}}}
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual((metric['status'], metric['direction']), ('significant', 'regressed'))
        effect = metric['effects']['rate_ratio']
        self.assertIsNone(effect['hi'])
        self.assertEqual(effect['unbounded'], ['estimate', 'hi'])
        self.assertGreater(effect['lo'], 1)
        rates = snapshot['metrics']['latency']['groups']
        rates['a'], rates['b'] = rates['b'], rates['a']
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(metric['direction'], 'improved')
        self.assertEqual(metric['effects']['rate_ratio']['estimate'], 0)
        for group in rates.values():
            group['events'] = 0
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(metric['direction'], 'no_change')
        self.assertEqual(metric['effects']['rate_ratio']['unbounded'], [])

    def test_zero_and_empty_groups_are_not_plausible_defaults(self):
        snapshot, spec = fixture()
        for row in snapshot['metrics']['latency']['rows']:
            row['value'] = 0
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertIn('relative_effect_undefined', metric['flags'])
        self.assertEqual(metric['status'], 'inconclusive')
        self.assertEqual(metric['direction'], 'no_change')
        self.assertNotIn('median_ratio', metric['effects'])
        snapshot['metrics']['latency']['rows'] = []
        metric = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(metric['groups']['a'], {'n':0,'n_censored':0})
        self.assertIsNone(metric['min_achievable_p'])
        self.assertIn('undefined', metric['summary_text'])
        snapshot, spec = fixture('guard')
        snapshot['metrics']['latency']['rows'] = snapshot['metrics']['latency']['rows'][:1] + snapshot['metrics']['latency']['rows'][6:7]
        self.assertIn('cannot_reach_significance', analyze(snapshot, spec)['metrics']['latency']['flags'])

    def test_unknown_primary_rejected(self):
        snapshot, spec = fixture()
        spec['primary_metrics'].append('misspelled')
        with self.assertRaisesRegex(ValueError, 'primary_metrics IDs'):
            analyze(snapshot, spec)

    def test_invalid_inputs_and_flat_adapter(self):
        for bad in [float('nan'), -1, True, '1']:
            snapshot, spec = fixture()
            snapshot['metrics']['latency']['rows'][0]['value'] = bad
            with self.assertRaises(ValueError):
                analyze(snapshot, spec)
        snapshot, spec = fixture()
        snapshot['metrics']['latency']['rows'][0]['group'] = 'unknown'
        with self.assertRaises(ValueError):
            analyze(snapshot, spec)
        snapshot, spec = fixture()
        flat = {'experiment_id':'shift','groups':['a','b'],'rows':[dict(row, metric='latency') for row in snapshot['metrics']['latency']['rows']]}
        self.assertEqual(analyze(flat, spec)['metrics']['latency']['status'], 'significant')
        spec['metrics'][0]['kind'] = 'unknown'
        with self.assertRaises(ValueError):
            analyze(flat, spec)

    def test_deterministic_body_and_full_precision_input_hash(self):
        snapshot, spec = fixture()
        first = analyze(snapshot, spec)
        self.assertEqual(encode(first), encode(analyze(snapshot, spec)))
        snapshot['metrics']['latency']['rows'][0]['value'] += 1e-10
        self.assertNotEqual(first['inputs']['snapshot_sha256'], analyze(snapshot, spec)['inputs']['snapshot_sha256'])
