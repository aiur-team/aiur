"""Dependency-free experiment statistics, with explicit inferential methods.

Rank effects and two-sample contrasts are B minus A; count differences and rate
ratios are group 1 versus group 2, as each function documents. No driver or I/O.
"""

from .bootstrap import bootstrap
from .counts import fisher_exact, newcombe_interval, poisson_rate_test
from .describe import describe, quantile
from .numeric import mean, round_sig
from .permutation import permutation_test
from .ranks import cliffs_delta, hodges_lehmann, mann_whitney_u, min_achievable_p
from .rng import PCG32, seed_from
from .special import regularized_beta, regularized_gamma

__all__ = [
    "PCG32", "seed_from", "mean", "round_sig", "describe", "quantile",
    "mann_whitney_u", "min_achievable_p", "hodges_lehmann", "cliffs_delta",
    "permutation_test", "bootstrap", "fisher_exact", "newcombe_interval",
    "poisson_rate_test", "regularized_beta", "regularized_gamma",
]
