"""Empirical bootstrap counts, bounded in cost for large sample-size searches."""

from bisect import bisect_left
from collections import Counter
from functools import lru_cache
from math import fsum

from .rng import PCG32


@lru_cache(maxsize=16384)
def _binomial_cdf(n, count, total):
    # Recur outwards from the mode to avoid underflow at n=5000; tail < 1e-14.
    p = count / total
    mode = int((n + 1) * p)
    weights = {mode: 1.}
    value = 1.
    k = mode
    while k > 0 and value > 1e-14:
        value *= k / (n - k + 1) * (1 - p) / p
        k -= 1
        weights[k] = value
    low = k
    value = 1.
    k = mode
    while k < n and value > 1e-14:
        value *= (n - k) / (k + 1) * p / (1 - p)
        k += 1
        weights[k] = value
    normalizer = fsum(weights.values())
    cumulative = 0.
    cdf = []
    for k in range(low, k + 1):
        cumulative += weights[k] / normalizer
        cdf.append(cumulative)
    cdf[-1] = 1.
    return low, cdf


def draws(baseline, na, nb, seed, simulations):
    """Multinomial sampling is the same bootstrap, with aggregated identical rows."""
    frequencies = Counter(baseline)
    support = sorted(frequencies)
    weights = [frequencies[x] for x in support]
    indices = [support.index(x) for x in baseline]
    rng = PCG32(*seed)
    result = []
    size = len(indices)
    threshold = (1 << 32) % size
    draw = rng.next_u32
    for _ in range(simulations):
        pair = []
        for n in (na, nb):
            counts = [0] * len(support)
            if n < 2 * len(support):
                for _ in range(n):
                    word = draw()
                    while word < threshold:
                        word = draw()
                    counts[indices[word % size]] += 1
            else:
                remaining = len(baseline)
                for i, weight in enumerate(weights[:-1]):
                    low, cdf = _binomial_cdf(n, weight, remaining)
                    counts[i] = low + bisect_left(cdf, rng.uniform())
                    n -= counts[i]
                    remaining -= weight
                counts[-1] = n
            pair.append(counts)
        result.append(pair)
    return support, result
