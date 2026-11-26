#!/usr/bin/env python3
"""Offline reference generator for survival-goldens.json; NOT imported by CI.

Requires lifelines, numpy, scipy, pandas<2.3 (versions recorded in provenance).
Run from any directory; writes survival-goldens.json beside this script.
No analytics.stats import: references must be independent of production.
The stratified reference is an independent hypergeometric implementation
(lifelines has no stratified log-rank); it is asserted equal to lifelines
for a single stratum.
"""

import json
from pathlib import Path

import numpy as np
import lifelines
from lifelines import KaplanMeierFitter
from lifelines.statistics import logrank_test
from lifelines.utils import median_survival_times
from scipy import stats

rng = np.random.default_rng(3)


def fixture(n, censored, ties=False):
    t = rng.exponential(50, n)
    t = np.round(t / 10) * 10 + 10 if ties else np.round(t, 3) + .001
    c = rng.random(n) < censored
    return [{"value": float(x), "censored": bool(k)} for x, k in zip(t, c)]


def kaplan_meier(rows):
    km = KaplanMeierFitter().fit([r["value"] for r in rows], [not r["censored"] for r in rows])
    lo, hi = median_survival_times(km.confidence_interval_).values[0]

    def finite(v):
        return None if np.isinf(v) else float(v)

    return {"rows": rows, "median": finite(km.median_survival_time_), "lo": finite(lo), "hi": finite(hi)}


def score(a, b):
    """Independent hypergeometric log-rank score and variance for one stratum."""
    u = v = 0.0
    for t in sorted({r["value"] for r in a + b if not r["censored"]}):
        na = sum(r["value"] >= t for r in a)
        nb = sum(r["value"] >= t for r in b)
        d = sum(r["value"] == t and not r["censored"] for r in a + b)
        da = sum(r["value"] == t and not r["censored"] for r in a)
        n = na + nb
        u += da - d * na / n
        if n > 1:
            v += na * nb * d * (n - d) / (n * n * (n - 1))
    return u, v


def logrank(pairs):
    parts = [score(a, b) for a, b in pairs]
    chi = sum(p[0] for p in parts) ** 2 / sum(p[1] for p in parts)
    return {"statistic": float(chi), "p_value": float(stats.chi2.sf(chi, 1))}


def times(rows):
    return [r["value"] for r in rows], [not r["censored"] for r in rows]


result = {"provenance": {"lifelines": lifelines.__version__, "numpy": np.__version__}, "km": {}, "logrank": {}}
for name, (ca, cb, ties) in {"none": (0, 0, False), "light": (.1, .1, False),
                             "heavy": (.5, .4, False), "ties": (.2, .2, True)}.items():
    a, b = fixture(30, ca, ties), fixture(30, cb, ties)
    result["km"][name] = [kaplan_meier(a), kaplan_meier(b)]
    (ta, ea), (tb, eb) = times(a), times(b)
    reference = logrank_test(ta, tb, ea, eb)
    assert abs(logrank([(a, b)])["statistic"] - reference.test_statistic) < 1e-9, name
    result["logrank"][name] = {"a": a, "b": b, "statistic": float(reference.test_statistic),
                               "p_value": float(reference.p_value)}
strata = {f"s{i}": (fixture(14, .25), fixture(12, .3)) for i in range(3)}
result["stratified_logrank"] = {"strata": {k: {"a": a, "b": b} for k, (a, b) in strata.items()},
                                **logrank(list(strata.values()))}
Path(__file__).with_name("survival-goldens.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
