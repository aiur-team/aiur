"""Exact count tests and score intervals for binary and exposure-rate outcomes."""

import math
from statistics import NormalDist

from .special import _beta_quantile


def _count(k, name):
    if isinstance(k, bool) or not isinstance(k, int) or k < 0:
        raise ValueError(f"{name} must be a nonnegative integer")


def _confidence(confidence):
    if not math.isfinite(confidence) or not 0 < confidence < 1:
        raise ValueError("confidence must be finite and between zero and one")


def fisher_exact(table):
    """Two-sided Fisher hypergeometric test, probability ordering (SciPy semantics)."""
    if len(table) != 2 or any(len(row) != 2 for row in table):
        raise ValueError("table must be two by two")
    a, b = table[0]
    c, d = table[1]
    for k in (a, b, c, d):
        _count(k, "table count")
    row, col, total = a + b, a + c, a + b + c + d
    odds = a * d / (b * c) if b * c else (math.inf if a * d else math.nan)
    if total == 0 or min(row, col, total - row, total - col) == 0:
        return {"statistic": odds, "p_value": 1.0, "method": "exact"}
    denominator = math.comb(total, row)
    observed = math.comb(col, a) * math.comb(total - col, row - a)
    numerator = sum(
        weight for k in range(max(0, row + col - total), min(row, col) + 1)
        if (weight := math.comb(col, k) * math.comb(total - col, row - k))
        <= observed + observed // 10000000
    )
    return {"statistic": odds, "p_value": min(1.0, numerator / denominator),
            "method": "exact"}


def _wilson(k, n, z):
    p = k / n
    z2 = z * z
    center = (p + z2 / (2 * n)) / (1 + z2 / n)
    radius = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return center - radius, center + radius


def newcombe_interval(k1, n1, k2, n2, confidence=0.95):
    """Newcombe (1998) unpaired Wilson interval for proportion1 minus proportion2."""
    for value, name in ((k1, "k1"), (k2, "k2"), (n1, "n1"), (n2, "n2")):
        _count(value, name)
    if n1 == 0 or n2 == 0 or k1 > n1 or k2 > n2:
        raise ValueError("each sample must be nonempty with successes <= sample size")
    _confidence(confidence)
    z = -NormalDist().inv_cdf((1 - confidence) / 2)
    p1, p2 = k1 / n1, k2 / n2
    l1, u1 = _wilson(k1, n1, z)
    l2, u2 = _wilson(k2, n2, z)
    difference = p1 - p2
    return {"estimate": difference,
            "lo": difference - math.hypot(p1 - l1, u2 - p2),
            "hi": difference + math.hypot(p2 - l2, u1 - p1),
            "method": "newcombe"}


def _binomial_two_sided(k, n, log_p, log_q):
    def log_probability(j):
        return (math.lgamma(n + 1) - math.lgamma(j + 1) - math.lgamma(n - j + 1)
                + j * log_p + (n - j) * log_q)
    threshold = log_probability(k) + math.log1p(1e-7)
    return min(1.0, math.fsum(
        math.exp(logp) for j in range(n + 1)
        if (logp := log_probability(j)) <= threshold
    ))


def poisson_rate_test(k1, t1, k2, t2, confidence=0.95):
    """Conditional exact binomial rate test; Clopper-Pearson rate1/rate2 interval."""
    _count(k1, "k1")
    _count(k2, "k2")
    for t, name in ((t1, "t1"), (t2, "t2")):
        if not math.isfinite(t) or t <= 0:
            raise ValueError(f"{name} must be positive and finite")
    _confidence(confidence)
    n = k1 + k2
    if n == 0:
        return {"statistic": None, "rate_ratio": None, "p_value": 1.0,
                "lo": None, "hi": None, "method": "exact_undefined_ratio"}
    exposure_ratio = t2 / t1
    log_ratio = math.log(t2) - math.log(t1)
    log_norm = math.log1p(math.exp(-abs(log_ratio)))
    log_p = -max(0.0, log_ratio) - log_norm
    log_q = min(0.0, log_ratio) - log_norm
    alpha = (1 - confidence) / 2
    lower = _beta_quantile(alpha, k1, k2 + 1) if k1 else 0.0
    upper_complement = _beta_quantile(alpha, k2, k1 + 1) if k2 else 0.0
    ratio = ((k1 / k2) * exposure_ratio if k1 else 0.0) if k2 else math.inf
    return {"statistic": ratio, "rate_ratio": ratio,
            "p_value": _binomial_two_sided(k1, n, log_p, log_q),
            "lo": lower / (1 - lower) * exposure_ratio if k1 else 0.0,
            "hi": (1 - upper_complement) / upper_complement * exposure_ratio
            if upper_complement else math.inf,
            "method": "conditional_exact"}
