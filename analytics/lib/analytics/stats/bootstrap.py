"""Two-sample BCa intervals (Efron and Tibshirani, 1993, chapter 14)."""

import math
from statistics import NormalDist

from .describe import quantile
from .numeric import samples
from .rng import PCG32


def _value(statistic, a, b):
    value = float(statistic(a, b))
    if not math.isfinite(value):
        raise ValueError("statistics must return finite numbers, including on resamples")
    return value


def _strata(values, labels, name):
    if labels is None:
        return [list(range(len(values)))]
    labels = list(labels)
    if len(labels) != len(values):
        raise ValueError(f"strata for {name} must have one label per observation")
    groups = {}
    for i, label in enumerate(labels):
        groups.setdefault(label, []).append(i)
    return list(groups.values())


def _draw(values, strata, rng):
    result = values.copy()
    for indices in strata:
        for i in indices:
            result[i] = values[indices[rng.randbelow(len(indices))]]
    return result


def _acceleration(a, b, statistic, strata=None):
    if min(len(a), len(b)) < 2:
        return None
    numerator = denominator = 0.0
    group_strata = strata if strata is not None else ([range(len(a))], [range(len(b))])
    for group, other, first, strata_indices in ((a, b, True, group_strata[0]),
                                               (b, a, False, group_strata[1])):
        n = len(group)
        for indices in strata_indices:
            if len(indices) == 1:
                continue
            jack = []
            for i in indices:
                deleted = group[:i] + group[i + 1:]
                jack.append(_value(statistic, deleted, other) if first
                            else _value(statistic, other, deleted))
            average = math.fsum(jack) / len(jack)
            # Center within strata: fixed stratum counts have no between-stratum variance.
            influences = [(n - 1) * (average - value) / n for value in jack]
            numerator += math.fsum(value ** 3 for value in influences)
            denominator += math.fsum(value ** 2 for value in influences)
    if denominator == 0:
        return None
    return numerator / (6 * denominator ** 1.5)


def _probabilities(distribution, estimate, acceleration, confidence):
    alpha = (1 - confidence) / 2
    if acceleration is None:
        return alpha, 1 - alpha, "percentile"
    fraction = (sum(value < estimate for value in distribution)
                + sum(value <= estimate for value in distribution)) / (2 * len(distribution))
    if not 0 < fraction < 1:
        return alpha, 1 - alpha, "percentile"
    normal = NormalDist()
    bias = normal.inv_cdf(fraction)
    adjusted = []
    for probability in (alpha, 1 - alpha):
        z = bias + normal.inv_cdf(probability)
        divisor = 1 - acceleration * z
        if divisor <= 0:
            return alpha, 1 - alpha, "percentile"
        adjusted.append(normal.cdf(bias + z / divisor))
    return adjusted[0], adjusted[1], "bca"


def bootstrap(a, b, statistics, *, seed=(0, 54), resamples=10_000,
              confidence=0.95, strata=None):
    """Return BCa intervals for a mapping of names to two-sample callables.

    Every bootstrap iteration draws independent groups once and evaluates all
    statistics on those shared draws. strata is an optional (a_labels, b_labels)
    pair; each group's stratum sizes and positions are preserved. The two-sample
    delete-one jackknife centers influences within strata; degenerate jackknives
    or bias correction fall back to percentile intervals. Quantiles use type 7.
    mc_se is the Monte Carlo SE of the bootstrap mean (SD/sqrt(resamples)),
    not an endpoint error bound. Seed is a PCG32 (state, stream) tuple.
    """
    a, b = samples(a, "a"), samples(b, "b")
    if isinstance(resamples, bool) or not isinstance(resamples, int) or resamples < 2:
        raise ValueError("resamples must be an integer of at least two")
    if not math.isfinite(confidence) or not 0 < confidence < 1:
        raise ValueError("confidence must be between zero and one")
    if not statistics:
        raise ValueError("statistics must contain at least one callable")
    if strata is not None and len(strata) != 2:
        raise ValueError("strata must contain the labels for a and b")
    strata_a = _strata(a, None if strata is None else strata[0], "a")
    strata_b = _strata(b, None if strata is None else strata[1], "b")
    estimates = {name: _value(stat, a, b) for name, stat in statistics.items()}
    distributions = {name: [] for name in statistics}
    rng = PCG32(*seed)
    for _ in range(resamples):
        drawn_a, drawn_b = _draw(a, strata_a, rng), _draw(b, strata_b, rng)
        for name, statistic in statistics.items():
            distributions[name].append(_value(statistic, drawn_a, drawn_b))
    results = {}
    for name, statistic in statistics.items():
        distribution = distributions[name]
        lo, hi, method = _probabilities(distribution, estimates[name],
                                        _acceleration(a, b, statistic, (strata_a, strata_b)), confidence)
        average = math.fsum(distribution) / resamples
        mc_se = math.sqrt(math.fsum((value - average) ** 2 for value in distribution)
                          / (resamples - 1) / resamples)
        results[name] = {"estimate": estimates[name], "lo": quantile(distribution, lo),
                         "hi": quantile(distribution, hi), "method": method,
                         "resamples": resamples, "mc_se": mc_se}
    return results
