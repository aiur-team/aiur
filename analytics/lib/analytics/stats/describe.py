"""Descriptives using Hyndman-Fan type-7 quantiles (R/NumPy linear default)."""

import math

from .numeric import samples


def quantile(values, p):
    """Type-7 sample quantile: interpolate at (n-1)*p, endpoints inclusive."""
    if not math.isfinite(p) or not 0 <= p <= 1:
        raise ValueError("p must be in [0, 1]")
    values = sorted(samples(values))
    index = (len(values) - 1) * p
    lower = int(index)
    if lower == len(values) - 1:
        return values[lower]
    weight = index - lower
    # Weighted endpoints avoid overflowing the subtraction of opposite signs.
    return (1 - weight) * values[lower] + weight * values[lower + 1]


def describe(values):
    """n, median, Q1/Q3/IQR, p90, min/max; empty samples return only n=0."""
    values = list(values)
    if not values:
        return {"n": 0}
    values = samples(values)
    q1, q3 = quantile(values, .25), quantile(values, .75)
    return {"n": len(values), "median": quantile(values, .5), "q1": q1,
            "q3": q3, "iqr": q3 - q1, "p90": quantile(values, .9),
            "min": min(values), "max": max(values)}
