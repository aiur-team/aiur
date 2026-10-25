"""Holm family-wise correction and Benjamini-Hochberg false discovery control."""

import math


def adjust(p_values, method):
    """Return ID-to-adjusted-p, preserving the complete declared family size."""
    if method not in ("holm", "bh"):
        raise ValueError("adjustment must be holm or bh")
    if any(not math.isfinite(p) or not 0 <= p <= 1 for p in p_values.values()):
        raise ValueError("p-values must be finite probabilities")
    ordered = sorted(p_values, key=lambda key: (p_values[key], key))
    size = len(ordered)
    result = {}
    running = 0.0 if method == "holm" else 1.0
    indices = range(size) if method == "holm" else range(size - 1, -1, -1)
    for i in indices:
        key = ordered[i]
        value = p_values[key] * (size - i if method == "holm" else size / (i + 1))
        running = max(running, value) if method == "holm" else min(running, value)
        result[key] = min(1.0, running)
    return result
