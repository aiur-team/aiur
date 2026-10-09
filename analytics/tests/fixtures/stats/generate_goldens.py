#!/usr/bin/env python3
"""Offline reference generator; NOT imported by CI or production.

Requires Python 3.12, numpy==2.1.3, scipy==1.14.1, statsmodels==0.14.4,
and R 4.5. Run from any directory; outputs goldens.json beside this script.
No analytics.stats import: references must be independent of production.
"""

import json
import math
from pathlib import Path
import subprocess

import numpy as np
import scipy
from scipy import special, stats
import statsmodels
from statsmodels.stats.proportion import confint_proportions_2indep


def median_difference(a, b, axis=-1):
    return np.median(b, axis=axis) - np.median(a, axis=axis)


def mean_difference(a, b, axis=-1):
    return np.mean(b, axis=axis) - np.mean(a, axis=axis)


def finite(value):
    value = float(value)
    if math.isnan(value):
        return None
    if math.isinf(value):
        return 'inf' if value > 0 else '-inf'
    return value


def generate():
    assert np.__version__ == '2.1.3', np.__version__
    assert scipy.__version__ == '1.14.1', scipy.__version__
    assert statsmodels.__version__ == '0.14.4', statsmodels.__version__
    r_version = subprocess.check_output(['Rscript', '-e', 'cat(as.character(getRversion()))'], text=True)
    result = {'provenance': {'numpy': np.__version__, 'scipy': scipy.__version__,
                            'statsmodels': statsmodels.__version__, 'R': r_version,
                            'bootstrap_resamples': 100000, 'bootstrap_seed': 12345}}
    result['describe'] = []
    for values in ([7], [1, 9], [1, 2, 20], list(range(10)),
                   [i // 3 for i in range(101)]):
        q1, median, q3, p90 = map(float, np.quantile(values, [.25, .5, .75, .9], method='linear'))
        result['describe'].append({'values': values, 'result': {
            'n': len(values), 'q1': q1, 'median': median, 'q3': q3,
            'iqr': q3 - q1, 'p90': p90, 'min': min(values), 'max': max(values)}})
    exact_pairs = [([1, 2, 3, 4], [5, 6, 7, 8]), ([1, 3, 7, 9, 13], [2, 4, 8, 10, 14]),
                   ([1, 9], [2, 3, 4, 8]), ([19, 22, 16, 29, 24], [20, 11, 17, 12]),
                   ([0], [1, 2, 3, 4, 5]), (list(range(50)), list(range(50, 100)))]
    tied_pairs = [([1, 1, 2, 5], [1, 2, 3, 3]), ([1, 2, 3, 4], [1, 2, 3, 4]),
                  ([1, 1, 1], [2, 2, 2]), ([0, 0, 1, 1, 2], [0, 2, 2, 3]),
                  ([1, 2], [2, 3, 3]), (list(range(51)), list(range(51, 102)))]
    result['mann_whitney'] = []
    for pairs, method in ((exact_pairs, 'exact'), (tied_pairs, 'asymptotic')):
        for a, b in pairs:
            test = stats.mannwhitneyu(a, b, alternative='two-sided', method=method)
            result['mann_whitney'].append({'a': a, 'b': b, 'statistic': float(test.statistic),
                                          'p_value': float(test.pvalue),
                                          'method': 'exact' if method == 'exact' else 'normal_tie_corrected'})
    result['hodges_lehmann'] = []
    for index, (a, b) in enumerate(exact_pairs[:4]):
        confidence = .8 if index == 2 else .95
        r = lambda values: 'c(' + ','.join(map(str, values)) + ')'
        code = (f't <- wilcox.test({r(b)},{r(a)},exact=TRUE,conf.int=TRUE,conf.level={confidence}); '
                'options(digits=17); cat(t$estimate,t$conf.int[1],t$conf.int[2],sep=",")')
        estimate, lo, hi = map(float, subprocess.check_output(['Rscript', '-e', code], text=True).split(','))
        result['hodges_lehmann'].append({'a': a, 'b': b, 'statistic': estimate,
                                       'confidence': confidence, 'lo': finite(lo), 'hi': finite(hi), 'method': 'moses_exact'})
    gamma_points = [(a, x) for a, x in [(0.1, 1e-10), (.5, 1e-10), (.5, .2), (.5, 10),
        (1, 1e-10), (1, 1), (2, .1), (2, 10), (5, 1e-3), (5, 5), (10, 2),
        (10, 20), (100, 70), (100, 100), (1000, 1000)]]
    result['gamma'] = [{'a': a, 'x': x, 'value': float(special.gammainc(a, x))} for a, x in gamma_points]
    beta_points = [(x, a, b) for x, a, b in [(1e-10, .1, .2), (1e-10, .5, .5),
        (.2, .5, .5), (.99, .5, .5), (1e-10, 1, 1), (.5, 1, 1), (.1, 2, 5),
        (.9, 2, 5), (.001, 5, 2), (.5, 5, 5), (.1, 10, 20), (.9, 10, 20),
        (.4, 100, 100), (.5, 100, 100), (.5, 1000, 1000)]]
    result['beta'] = [{'x': x, 'a': a, 'b': b, 'value': float(special.betainc(a, b, x))}
                      for x, a, b in beta_points]
    result['fisher'] = []
    for table in ([[1, 9], [11, 3]], [[8, 2], [1, 5]], [[0, 5], [3, 2]],
                  [[0, 0], [0, 0]], [[5, 0], [0, 5]], [[10, 10], [10, 10]]):
        test = stats.fisher_exact(table)
        result['fisher'].append({'table': table, 'statistic': finite(test.statistic), 'p_value': float(test.pvalue)})
    result['newcombe'] = []
    for k1, n1, k2, n2 in ((10, 100, 20, 100), (0, 10, 0, 20), (10, 10, 0, 10),
                            (1, 2, 1, 5), (30, 50, 45, 60), (10, 10, 20, 20)):
        lo, hi = confint_proportions_2indep(k1, n1, k2, n2, method='newcomb', alpha=.05)
        result['newcombe'].append({'k1': k1, 'n1': n1, 'k2': k2, 'n2': n2, 'lo': float(lo), 'hi': float(hi)})
    result['poisson'] = []
    for k1, t1, k2, t2 in ((10, 100, 20, 100), (1, 10, 10, 100), (0, 10, 5, 10),
                          (5, 10, 0, 10), (0, 10, 0, 20), (40, 100, 15, 80)):
        n = k1 + k2
        if n:
            p = stats.binomtest(k1, n, t1 / (t1 + t2)).pvalue
            lo_p = stats.beta.ppf(.025, k1, k2 + 1) if k1 else 0
            upper_complement = stats.beta.ppf(.025, k2, k1 + 1) if k2 else 0
            lo = lo_p / (1 - lo_p) * t2 / t1
            hi = (1 - upper_complement) / upper_complement * t2 / t1 if k2 else math.inf
            ratio = k1 / k2 * t2 / t1 if k2 else math.inf
        else:
            p, ratio, lo, hi = 1, math.nan, math.nan, math.nan
        result['poisson'].append({'k1': k1, 't1': t1, 'k2': k2, 't2': t2, 'p_value': float(p),
                                  'ratio': None if not math.isfinite(ratio) else ratio,
                                  'lo': None if not math.isfinite(lo) else lo,
                                  'hi': None if not math.isfinite(hi) else hi})
    result['bootstrap'] = []
    for n1, n2, shift in ((21, 31, .3), (31, 21, -.2), (41, 51, 1.2)):
        a = [float(i + .17 * math.sin(i)) for i in range(n1)]
        b = [float(i * 1.1 + shift + .23 * math.cos(i)) for i in range(n2)]
        test = stats.bootstrap((np.array(a), np.array(b)), median_difference, vectorized=True,
                               n_resamples=100000, method='BCa', random_state=12345)
        result['bootstrap'].append({'name': f'{n1}x{n2}', 'a': a, 'b': b, 'estimate': float(median_difference(a, b)),
                                    'lo': float(test.confidence_interval.low), 'hi': float(test.confidence_interval.high),
                                    'tolerance': .02 * (max(a + b) - min(a + b)), 'method': 'bca'})
    a, b = [1, 2, 3, 4, 5, 6], [3, 4, 5, 6, 7, 8]
    test = stats.permutation_test((a, b), mean_difference, n_resamples=np.inf, alternative='two-sided')
    exact_p = float(np.mean(np.abs(test.null_distribution) >= abs(test.statistic) - 1e-14))
    result['permutation'] = [{'a': a, 'b': b, 'p_value': exact_p}]
    return result


if __name__ == '__main__':
    # One case per line keeps this reference fixture easy to review and bounded.
    result = generate()
    lines = []
    for key, value in result.items():
        if isinstance(value, list):
            cases = ',\n'.join('    ' + json.dumps(row, allow_nan=False) for row in value)
            lines.append(f'  {json.dumps(key)}: [\n{cases}\n  ]')
        else:
            lines.append(f'  {json.dumps(key)}: {json.dumps(value, allow_nan=False)}')
    Path(__file__).with_name('goldens.json').write_text('{\n' + ',\n'.join(lines) + '\n}\n')
