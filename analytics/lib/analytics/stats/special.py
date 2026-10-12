"""Regularized lower gamma and incomplete beta (Numerical Recipes, chapter 6)."""

import math

_EPS = 2e-15
_TINY = 1e-300
_LIMIT = 10000


def _positive(value, name):
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be positive and finite")


def regularized_gamma(a, x):
    """Return lower P(a, x), using a series or upper-tail continued fraction."""
    _positive(a, "a")
    if not math.isfinite(x) or x < 0:
        raise ValueError("x must be nonnegative and finite")
    if x == 0:
        return 0.0
    scale = math.exp(a * math.log(x) - x - math.lgamma(a))
    if x < a + 1:
        term = total = 1 / a
        for i in range(1, _LIMIT + 1):
            term *= x / (a + i)
            total += term
            if abs(term) <= abs(total) * _EPS:
                return min(1.0, total * scale)
    else:
        b = x + 1 - a
        c = 1 / _TINY
        d = 1 / b
        fraction = d
        for i in range(1, _LIMIT + 1):
            numerator = -i * (i - a)
            b += 2
            d = numerator * d + b
            c = b + numerator / c
            if abs(d) < _TINY:
                d = _TINY
            if abs(c) < _TINY:
                c = _TINY
            d = 1 / d
            change = d * c
            fraction *= change
            if abs(change - 1) <= _EPS:
                return max(0.0, min(1.0, 1 - scale * fraction))
    raise ArithmeticError("incomplete gamma did not converge")


def _beta_fraction(x, a, b):
    c = 1.0
    d = 1 - (a + b) * x / (a + 1)
    if abs(d) < _TINY:
        d = _TINY
    d = 1 / d
    fraction = d
    for m in range(1, _LIMIT + 1):
        for numerator in (
            m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)),
            -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1)),
        ):
            d = 1 + numerator * d
            c = 1 + numerator / c
            if abs(d) < _TINY:
                d = _TINY
            if abs(c) < _TINY:
                c = _TINY
            d = 1 / d
            change = d * c
            fraction *= change
        if abs(change - 1) <= _EPS:
            return fraction
    raise ArithmeticError("incomplete beta did not converge")


def regularized_beta(x, a, b):
    """Return I_x(a,b), using the continued fraction and tail symmetry."""
    _positive(a, "a")
    _positive(b, "b")
    if not math.isfinite(x) or not 0 <= x <= 1:
        raise ValueError("x must be finite and between zero and one")
    if x in (0, 1):
        return float(x)
    scale = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
                     + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1) / (a + b + 2):
        result = scale * _beta_fraction(x, a, b) / a
    else:
        result = 1 - scale * _beta_fraction(1 - x, b, a) / b
    return max(0.0, min(1.0, result))


def _beta_quantile(p, a, b):
    # Invert the smaller tail to avoid cancellation near one.
    if p > 0.5:
        return 1 - _beta_quantile(1 - p, b, a)
    lo, hi = 0.0, 1.0
    for _ in range(180):
        mid = (lo + hi) / 2
        if regularized_beta(mid, a, b) < p:
            lo = mid
        else:
            hi = mid
        if lo == hi or (lo > 0 and hi - lo <= lo * _EPS):
            break
    return (lo + hi) / 2
