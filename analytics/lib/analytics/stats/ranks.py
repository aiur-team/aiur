"""Two-sample rank statistics; shifts and effects are oriented B minus A."""

from bisect import bisect_left, bisect_right
from functools import lru_cache
from math import comb, erfc, floor, isfinite, sqrt
from statistics import NormalDist

from .describe import quantile
from .numeric import samples


@lru_cache(maxsize=32)
def _u_counts(n1, n2):
    """Coefficients of the Gaussian binomial, using exact integer arithmetic."""
    m, n = sorted((n1, n2))
    size = m * n
    counts = [1] + [0] * size
    for i in range(1, m + 1):
        for k in range(i, size + 1):
            counts[k] += counts[k - i]
        for k in range(size, n + i - 1, -1):
            counts[k] -= counts[k - n - i]
    return tuple(counts)


def _rank_summary(a, b):
    pooled = sorted([(x, 0) for x in a] + [(x, 1) for x in b])
    rank_sum = 0.0
    tie_sum = 0
    start = 0
    while start < len(pooled):
        end = start + 1
        while end < len(pooled) and pooled[end][0] == pooled[start][0]:
            end += 1
        rank = (start + 1 + end) / 2
        rank_sum += rank * sum(group == 0 for _, group in pooled[start:end])
        count = end - start
        tie_sum += count ** 3 - count
        start = end
    u = rank_sum - len(a) * (len(a) + 1) / 2
    n = len(pooled)
    variance = len(a) * len(b) / 12 * (n + 1 - tie_sum / (n * (n - 1)))
    return u, tie_sum, max(0.0, variance)


def min_achievable_p(n1, n2):
    """Smallest two-sided untied U p-value, 2 / binomial(n1+n2, n1)."""
    for size in (n1, n2):
        if isinstance(size, bool) or not isinstance(size, int) or size < 1:
            raise ValueError("group sizes must be positive integers")
    return min(1.0, 2 / comb(n1 + n2, n1))


def mann_whitney_u(a, b):
    """Two-sided U for A, using SciPy's exact or tie/continuity-corrected normal method.

    Exact integer U-distribution DP applies without ties when n1*n2 <= 2500.
    The normal method uses midranks, pooled tie correction, and a 0.5 continuity
    correction toward the mean (Mann and Whitney, 1947).
    """
    a, b = samples(a, "a"), samples(b, "b")
    u, ties, variance = _rank_summary(a, b)
    size = len(a) * len(b)
    if not ties and size <= 2500:
        counts = _u_counts(len(a), len(b))
        tail = int(min(u, size - u))
        p = min(1.0, 2 * sum(counts[:tail + 1]) / comb(len(a) + len(b), len(a)))
        method = "exact"
    else:
        z = (abs(u - size / 2) - 0.5) / sqrt(variance) if variance else 0.0
        p = min(1.0, erfc(z / sqrt(2)))
        method = "normal_tie_corrected"
    return {"statistic": u, "p_value": p, "method": method,
            "min_achievable_p": min_achievable_p(len(a), len(b))}


def hodges_lehmann(a, b, confidence=0.95):
    """Median B-A difference with a Moses rank-inversion confidence interval.

    Uses exact U critical ranks for untied n1*n2 <= 2500, otherwise a normal
    critical rank with pooled tie and continuity corrections (Hollander,
    Wolfe and Chicken, Nonparametric Statistical Methods, two-sample shifts).
    Too few observations for the requested coverage give unbounded endpoints.
    """
    a, b = samples(a, "a"), samples(b, "b")
    if (isinstance(confidence, bool) or not isinstance(confidence, (int, float))
            or not isfinite(confidence) or not 0 < confidence < 1):
        raise ValueError("confidence must be finite and between 0 and 1")
    differences = sorted(y - x for x in a for y in b)
    if not all(isfinite(value) for value in differences):
        raise ValueError("pairwise differences must be finite")
    size = len(differences)
    _, ties, variance = _rank_summary(a, b)
    alpha_tail = (1 - confidence) / 2
    if not ties and size <= 2500:
        total = comb(len(a) + len(b), len(a))
        cumulative = 0
        critical = -1
        for rank, count in enumerate(_u_counts(len(a), len(b))):
            cumulative += count
            if cumulative / total > alpha_tail:
                break
            critical = rank
        method = "moses_exact"
    else:
        z = NormalDist().inv_cdf(alpha_tail)
        critical = floor(size / 2 + z * sqrt(variance) - 0.5)
        critical = max(-1, min(critical, (size - 1) // 2))
        method = "moses_normal_tie_corrected"
    lo = differences[critical] if critical >= 0 else float("-inf")
    hi = differences[size - critical - 1] if critical >= 0 else float("inf")
    return {"statistic": quantile(differences, 0.5), "lo": lo, "hi": hi,
            "confidence": confidence, "method": method}


def cliffs_delta(a, b):
    """Cliff's B-A delta in O(n log n), with Romano et al. (2006) bands."""
    a, b = sorted(samples(a, "a")), samples(b, "b")
    score = sum(bisect_left(a, y) - (len(a) - bisect_right(a, y)) for y in b)
    delta = score / (len(a) * len(b))
    magnitude = next((name for limit, name in ((0.147, "negligible"),
                                              (0.33, "small"),
                                              (0.474, "medium"))
                      if abs(delta) < limit), "large")
    return {"statistic": delta, "magnitude": magnitude, "method": "cliffs_delta"}
