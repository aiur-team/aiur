"""Monte Carlo label permutations (Phipson and Smyth, 2010)."""

import math

from .numeric import samples
from .rng import PCG32


def permutation_test(a, b, statistic, *, seed=(0, 54), resamples=20_000):
    """Test a two-sample statistic with independent Fisher-Yates shuffles.

    The caller must supply a null-centered contrast (e.g. difference of means).
    Two-sided extremeness is |permuted statistic| >= |observed statistic|;
    p uses (b+1)/(m+1) and mc_se is its binomial Monte Carlo standard error.
    Seed is a PCG32 (state, stream).
    """
    a, b = samples(a, "a"), samples(b, "b")
    if isinstance(resamples, bool) or not isinstance(resamples, int) or resamples < 1:
        raise ValueError("resamples must be a positive integer")
    observed = float(statistic(a, b))
    if not math.isfinite(observed):
        raise ValueError("statistic must return a finite number")
    rng = PCG32(*seed)
    pooled = a + b
    extreme = 0
    tolerance = 100 * math.ulp(1.0) * abs(observed)
    for _ in range(resamples):
        shuffled = pooled.copy()
        for i in range(len(shuffled) - 1, 0, -1):
            j = rng.randbelow(i + 1)
            shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        value = float(statistic(shuffled[:len(a)], shuffled[len(a):]))
        if not math.isfinite(value):
            raise ValueError("statistic must return a finite number on resamples")
        extreme += abs(value) >= abs(observed) - tolerance
    p_value = (extreme + 1) / (resamples + 1)
    return {"statistic": observed, "p_value": p_value,
            "method": "permutation_mc", "resamples": resamples,
            "mc_se": math.sqrt(p_value * (1 - p_value) / resamples)}
