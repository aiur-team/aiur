"""Finite-input helpers and canonical decimal rounding for statistics."""

import math


def samples(values, name="sample"):
    """Copy a finite, nonempty numeric sample; reject missing observations."""
    try:
        result = [float(value) for value in values]
    except (ValueError, TypeError, OverflowError) as error:
        raise ValueError(f"{name} must contain finite numbers") from error
    if not result:
        raise ValueError(f"{name} must not be empty")
    if not all(math.isfinite(value) for value in result):
        raise ValueError(f"{name} must contain finite numbers")
    return result


def mean(values):
    """Arithmetic mean using math.fsum to limit cancellation error."""
    values = samples(values)
    return math.fsum(value / len(values) for value in values)


def round_sig(value, digits=10):
    """Round a finite number to decimal significant digits, including subnormals."""
    if not math.isfinite(value):
        raise ValueError("value must be finite")
    if isinstance(digits, bool) or not isinstance(digits, int) or digits < 1:
        raise ValueError("digits must be a positive integer")
    return float(format(value, f".{digits}g"))
