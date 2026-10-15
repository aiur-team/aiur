"""End-to-end composition and correction regressions for declared strata."""

from copy import deepcopy
import unittest

from analytics.stats import analyze
from analytics.stats.canonical import encode
from analytics.stats.multiplicity import adjust
from tests.test_experiment_schema import SCHEMA, validate
from tests.test_stats_analyze import fixture


def simpson():
    rows = []
    for group, sizes in [('a', (8, 32)), ('b', (32, 8))]:
        for complexity, size in enumerate(sizes, 1):
            for i in range(size):
                rows.append({'unit_id': f'{group}-{complexity}-{i}', 'group': group,
                             'value': complexity * 100 + i % 4,
                             'strata': {'complexity': complexity}})
    snapshot = {'experiment_id': 'simpson', 'groups': ['a', 'b'],
                'metrics': {'latency': {'rows': rows}}}
    spec = {'metrics': [{'id': 'latency', 'kind': 'duration'}],
            'primary_metrics': ['latency'], 'strata': ['complexity'],
            'bootstrap_primary': 100, 'bootstrap_exploratory': 100,
            'permutation_resamples': 99}
    return snapshot, spec


class StratificationTest(unittest.TestCase):
    def test_simpson_standardizes_effect_and_primary_p(self):
        snapshot, spec = simpson()
        original = deepcopy((snapshot, spec))
        body = analyze(snapshot, spec)
        result = body['metrics']['latency']
        self.assertLess(result['unstratified']['p_raw'], .05)
        self.assertGreater(result['p_raw'], .05)
        self.assertEqual(result['p_raw_source'], 'stratified')
        self.assertEqual(result['p_raw'], result['stratified']['p_value'])
        self.assertEqual(result['p_adj'], result['p_raw'])
        self.assertNotEqual(result['status'], 'significant')
        self.assertIn('composition_shift', result['flags'])
        effect = result['effects']['median_difference']
        self.assertLessEqual(effect['lo'], 0)
        self.assertGreaterEqual(effect['hi'], 0)
        self.assertEqual(effect['estimate'], 0)
        self.assertIn('stratum mix changed; standardized effect shown', result['summary_text'])
        self.assertTrue(all('exploratory' in r['flags'] for r in result['strata'].values()))
        self.assertEqual(result['strata']['1']['status'], 'insufficient_data')
        validate({'generated_at': '2026-10-15T00:00:00Z', 'body': body}, SCHEMA)
        self.assertEqual((snapshot, spec), original)
        self.assertEqual(encode(body), encode(analyze(snapshot, spec)))

    def test_unknown_sparse_strata_and_exclusions(self):
        snapshot, spec = simpson()
        rows = snapshot['metrics']['latency']['rows']
        for row in rows[:5]:
            row.pop('strata')
        rows[5]['strata'] = {'complexity': 'rare'}
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['strata']['unknown']['groups']['a']['n'], 5)
        self.assertEqual(result['strata']['unknown']['groups']['b']['n'], 0)
        self.assertEqual(result['strata_dropped'], ['rare', 'unknown'])
        self.assertIn('small_stratum_dropped', result['flags'])
        result = analyze(snapshot, spec, {'exclusions': [
            {'unit_id': r['unit_id'], 'reason': 'test'} for r in rows[:5]]})['metrics']['latency']
        self.assertNotIn('unknown', result['strata'])
        self.assertEqual(result['excluded_counts']['a'], 5)

    def test_x2_adapter_and_post_treatment_warning(self):
        snapshot, spec = simpson()
        spec['stratify_by'] = spec.pop('strata')
        snapshot['metric_metadata'] = {'latency': {'strata_metadata': {'complexity': {'post_treatment': True}}}}
        flat = {'experiment_id': 'simpson', 'groups': ['a', 'b'],
                'rows': [dict(row, metric='latency') for row in snapshot['metrics']['latency']['rows']],
                'metric_metadata': snapshot['metric_metadata']}
        result = analyze(flat, spec)['metrics']['latency']
        self.assertIn('stratum_may_be_affected_by_treatment', result['flags'])
        self.assertEqual(result['strata_fields'], ['complexity'])
        self.assertEqual(result['p_raw_source'], 'stratified')
        nested = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['stratified'], nested['stratified'])
        self.assertEqual(result['composition'], nested['composition'])

    def test_bh_family_and_holm_include_guarded_strata_and_metrics(self):
        snapshot, spec = fixture()
        spec['strata'] = ['complexity']
        for row in snapshot['metrics']['latency']['rows']:
            row['strata'] = {'complexity': int(row['unit_id'][1:]) % 2}
        spec['metrics'].append({'id': 'missing', 'kind': 'duration'})
        spec['primary_metrics'].append('missing')
        result = analyze(snapshot, spec)['metrics']['latency']
        expected_holm = min(1, 2 * result['stratified']['p_value'])
        self.assertAlmostEqual(result['p_adj'], expected_holm, delta=expected_holm * 1e-8)
        expected = adjust({k: r.get('p_raw', 1) for k, r in result['strata'].items()}, 'bh')
        for key, child in result['strata'].items():
            self.assertAlmostEqual(child['p_adj'], expected[key], delta=expected[key] * 1e-8)
            self.assertEqual(child['adjustment'], 'bh')
            self.assertIn('95% CI', child['summary_text'])

    def test_bh_combines_strata_across_metrics(self):
        snapshot, spec = simpson()
        spec['min_samples'] = 2
        rows = []
        for group in ['a', 'b']:
            for stratum in ['shift', 'same']:
                for i in range(20):
                    rows.append({'unit_id': f'{group}-{stratum}-{i}', 'group': group,
                                 'value': i + (100 if group == 'b' and stratum == 'shift' else 1),
                                 'strata': {'complexity': stratum}})
        rows.append({'unit_id': 'sparse', 'group': 'a', 'value': 1, 'strata': {'complexity': 'sparse'}})
        snapshot['metrics']['latency']['rows'] = rows
        snapshot['metrics']['other'] = {'rows': [r for r in rows if r['strata']['complexity'] == 'same']}
        spec['metrics'].append({'id': 'other', 'kind': 'count'})
        body = analyze(snapshot, spec)
        child = body['metrics']['latency']['strata']['shift']
        # Four hypotheses: shift, same, guarded sparse, and other's same stratum.
        self.assertLess(child['p_raw'], .01)
        self.assertAlmostEqual(child['p_adj'], 4 * child['p_raw'], delta=child['p_raw'] * 1e-8)

    def test_empty_and_all_sparse_remain_guarded(self):
        snapshot, spec = simpson()
        for row in snapshot['metrics']['latency']['rows']:
            row['strata'] = {'complexity': row['unit_id']}
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['status'], 'insufficient_data')
        self.assertNotIn('p_raw', result)
        snapshot['metrics']['latency']['rows'] = []
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['status'], 'insufficient_data')
        self.assertIsNone(result['composition']['tvd'])

    def test_censored_rows_enter_stratified_logrank(self):
        snapshot, spec = simpson()
        spec['min_samples'] = 2
        for row in snapshot['metrics']['latency']['rows']:
            row['censored'] = row['group'] == 'b'
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['stratified']['method'], 'stratified_logrank')
        self.assertEqual(result['groups']['b']['n'], 40)
        self.assertEqual(result['groups']['b']['n_censored'], 40)
        self.assertEqual(result['unstratified']['groups']['b']['n'], 0)
        self.assertNotIn('median', result['groups']['b'])
        self.assertEqual(result['strata']['1']['groups']['b']['n'], 32)
        self.assertNotIn('censoring_ignored', result['flags'])
        self.assertIn('standardized_effect_unavailable', result['flags'])
        self.assertIsNone(result['primary_effect'])
        self.assertEqual(result['direction'], 'no_change')
        self.assertIn('effect unavailable', result['summary_text'])
        validate({'generated_at': '2026-10-15T00:00:00Z', 'body': analyze(snapshot, spec)}, SCHEMA)

    def test_binary_uses_cmh_and_standardized_proportions(self):
        snapshot, spec = simpson()
        spec['metrics'][0]['kind'] = 'binary'
        for row in snapshot['metrics']['latency']['rows']:
            row['value'] = int(row['unit_id'].split('-')[-1]) % 2
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(result['stratified']['method'], 'cmh')
        self.assertEqual(result['primary_effect'], 'proportion_difference')
        self.assertEqual(result['effects']['proportion_difference']['estimate'], 0)
        self.assertEqual(result['p_raw'], 1)

    def test_crossed_fields_and_zero_baseline(self):
        snapshot, spec = simpson()
        spec['strata'] = [['complexity', 'backend']]
        for row in snapshot['metrics']['latency']['rows']:
            row['backend'] = 'codex'
            row['value'] = 0
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(set(result['strata']), {'[1,"codex"]', '[2,"codex"]'})
        self.assertEqual(result['primary_effect'], 'median_difference')
        self.assertIn('relative_effect_undefined', result['flags'])
        self.assertNotIn('median_ratio', result['effects'])

    def test_feature_tags_use_canonical_list_stratum(self):
        snapshot, spec = simpson()
        spec['stratify_by'] = ['feature_tags']
        del spec['strata']
        for i, row in enumerate(snapshot['metrics']['latency']['rows']):
            row['strata'] = {'feature_tags': ['one', 'two'] if i % 2 else ['two', 'one']}
        result = analyze(snapshot, spec)['metrics']['latency']
        self.assertEqual(list(result['strata']), ['["one","two"]'])
        self.assertEqual(result['strata']['["one","two"]']['groups']['a']['n'], 40)

    def test_aggregate_rate_stratification_is_explicitly_unavailable(self):
        snapshot, spec = simpson()
        spec['metrics'][0]['kind'] = 'rate'
        snapshot['metrics']['latency'] = {'groups': {
            g: {'events': 10, 'exposure': 100, 'n': 10} for g in ['a', 'b']}}
        body = analyze(snapshot, spec)
        result = body['metrics']['latency']
        self.assertIn('stratification_unavailable', result['flags'])
        self.assertIn('conditional_poisson', result['tests'])
        self.assertNotIn('stratified', result)
        self.assertEqual(body['warnings'], ['latency: aggregate rate evidence cannot be stratified'])

    def test_explicit_empty_strata_retains_legacy_results(self):
        # Intentional future-regression guard: no declared strata must stay opt-in.
        snapshot, spec = fixture()
        legacy = analyze(snapshot, spec)
        spec['strata'] = []
        explicit = analyze(snapshot, spec)
        self.assertEqual(explicit['metrics'], legacy['metrics'])
        self.assertNotIn('stratified', explicit['metrics']['latency'])

    def test_invalid_declarations_and_attribute_values_rejected(self):
        for fields in ['complexity', [None], ['complexity', 'backend'], [['complexity', 'complexity']]]:
            snapshot, spec = simpson()
            spec['strata'] = fields
            with self.assertRaises(ValueError):
                analyze(snapshot, spec)
        snapshot, spec = simpson()
        snapshot['metrics']['latency']['rows'][1]['strata']['complexity'] = '1'
        with self.assertRaisesRegex(ValueError, 'labels collide'):
            analyze(snapshot, spec)
        snapshot, spec = simpson()
        snapshot['metrics']['latency']['rows'][0]['strata'] = []
        with self.assertRaisesRegex(ValueError, 'strata must be an object'):
            analyze(snapshot, spec)
