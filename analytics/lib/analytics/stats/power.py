"""Prospective empirical MWU power; never post-hoc observed power."""

from bisect import bisect_left, bisect_right
from math import ceil, comb, erfc, isfinite, sqrt
from statistics import NormalDist, median

from .power_sampling import draws as _draws
from .ranks import _u_counts


def noether_n(probability, alpha=.05, target=.8, ratio=1):
    """Baseline n, with comparison n=ceil(ratio*n); Noether (1987)."""
    distance = abs(probability - .5)
    if not distance:
        return None
    z = NormalDist().inv_cdf(1 - alpha / 2) + NormalDist().inv_cdf(target)
    return max(5, ceil(z * z * (1 + 1 / ratio) / (12 * distance ** 2)))


def superiority(baseline, factor):
    """P(B<A) + half ties under the empirical multiplicative alternative."""
    a = sorted(baseline)
    return sum(len(a) - (bisect_left(a, x * factor) + bisect_right(a, x * factor)) / 2
               for x in a) / len(a) ** 2


def _pvalues(support, draws, factor, na, nb):
    a_lookup = {x: i for i, x in enumerate(support)}
    b_lookup = {x * factor: i for i, x in enumerate(support)} if factor else {0: 0}
    blocks = [(a_lookup.get(x, -1), b_lookup.get(x, -1))
              for x in sorted(a_lookup.keys() | b_lookup.keys())]
    result = []
    total = na + nb
    for pair in draws:
        ac = pair[0] + [0]
        bc = (pair[1] if factor else [nb]) + [0]
        below_b = u = ties = 0
        for ai, bi in blocks:
            a, b = ac[ai], bc[bi]
            if not (a or b):
                continue
            u += a * (below_b + b / 2)
            below_b += b
            count = a + b
            ties += count * count * count - count
        variance = na * nb / 12 * (total + 1 - ties / (total * (total - 1)))
        z = (abs(u - na * nb / 2) - .5) / sqrt(variance) if variance > 0 else 0
        p = min(1., erfc(z / sqrt(2)))
        if ties == 0 and na * nb <= 2500:
            p = min(1., 2 * sum(_u_counts(na, nb)[:int(min(u, na * nb - u)) + 1]) / comb(total, na))
        result.append(p)
    return result


def simulate(baseline, na, nb, shift, seed, simulations=1000, alpha=.05):
    """Share of two-sided tie/continuity-corrected MWU p-values below alpha."""
    support, draws = _draws(baseline, na, nb, seed, simulations)
    pvalues = _pvalues(support, draws, 1 - shift, na, nb)
    power = sum(p < alpha for p in pvalues) / simulations
    return power, sqrt(power * (1 - power) / simulations)


def estimate(baseline, comparison, mde, seed, alpha=.05, target=.8,
             simulations=1000, higher=False, primary=True):
    """Compute bounded sample and shift searches from completed baseline units."""
    result = {key: None for key in ("power_at_current_n", "mde_at_current_n",
              "samples_needed_per_group", "samples_needed_noether",
              "projected_p_if_effect_holds", "eta_date", "mc_se")}
    result.update(status="not_estimable", simulations=0, baseline_group=None)
    if len(baseline) < 2 or min(baseline) == max(baseline):
        return dict(result, reason="baseline has fewer than two distinct completed values")
    sign = -1 if higher else 1
    ratio = len(comparison) / len(baseline) if comparison else 1
    probability = superiority(baseline, 1 - sign * mde)
    needed = noether_n(probability, alpha, target, ratio)
    result.update(status="estimated", samples_needed_noether=needed, allocation_ratio=ratio)
    if not primary:
        return result
    cache = {}

    def comparison_size(n):
        return max(1, (n * len(comparison) + len(baseline) - 1) // len(baseline)) if comparison else n

    def power(n):
        if n not in cache:
            cache[n] = simulate(baseline, n, comparison_size(n), sign * mde,
                                seed, simulations, alpha)
        return cache[n]

    if comparison:
        result["power_at_current_n"], result["mc_se"] = power(len(baseline))
        result["mde_at_current_n"] = _mde(baseline, comparison, seed, simulations, sign, alpha, target)
    n = _needed(power, needed, target)
    result["samples_needed_per_group"] = n
    if isinstance(n, int) and comparison and median(baseline) != 0:
        nb = comparison_size(n)
        factor = median(comparison) / median(baseline)
        if isfinite(factor):
            support, draws = _draws(baseline, n, nb, seed, simulations)
            result["projected_p_if_effect_holds"] = median(_pvalues(support, draws, factor, n, nb))
    result["simulations"] = simulations
    return result


def _mde(baseline, comparison, seed, simulations, sign, alpha, target):
    na, nb = len(baseline), len(comparison)
    support, draws = _draws(baseline, na, nb, seed, simulations)

    def powered(shift):
        ps = _pvalues(support, draws, 1 - sign * shift, na, nb)
        return sum(p < alpha for p in ps) / simulations >= target

    lo, hi = 0., .9
    if not powered(hi):
        return None
    for _ in range(10):
        mid = (lo + hi) / 2
        if powered(mid):
            hi = mid
        else:
            lo = mid
    return hi


def _needed(power, initial, target):
    lo, hi = 5, min(5000, max(5, initial or 5000))
    while power(hi)[0] < target and hi < 5000:
        lo, hi = hi + 1, min(5000, hi * 2)
    if power(hi)[0] < target:
        return "> 5000"
    while lo < hi:
        mid = (lo + hi) // 2
        if power(mid)[0] >= target:
            hi = mid
        else:
            lo = mid + 1
    return lo
