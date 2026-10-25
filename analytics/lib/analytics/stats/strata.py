"""Stratified rank/count tests and fixed-composition percentile intervals.

All contrasts are B minus A or B divided by A. The caller excludes strata
with fewer than two observations in either group from inference, but retains
all strata for the composition comparison.
"""

import math

from .counts import fisher_exact
from .describe import quantile
from .ranks import _rank_summary
from .rng import PCG32
from .special import regularized_gamma


def _score_test(score, variance, method):
    statistic = score * score / variance if variance > 0 else 0.0
    return {"statistic": statistic, "p_value": math.erfc(math.sqrt(statistic / 2)),
            "method": method}


def _rank_score(a, b):
    u, _, variance = _rank_summary(a, b)
    weight = 1 / (len(a) + len(b) + 1)
    return weight * (u - len(a) * len(b) / 2), weight * weight * variance


def _binary_score(a, b):
    total, successes = len(a) + len(b), sum(a) + sum(b)
    score = sum(a) - len(a) * successes / total
    variance = len(a) * len(b) * successes * (total - successes) / (total * total * (total - 1))
    return score, variance


def _logrank_score(a, b):
    """Hypergeometric event score; censoring at a tied time follows events."""
    score = variance = 0.0
    risk_a, risk_b = len(a), len(b)
    times = {}
    for group, rows in enumerate((a, b)):
        for row in rows:
            event = times.setdefault(row["value"], [[0, 0], [0, 0]])
            event[group][0] += not row.get("censored", False)
            event[group][1] += 1
    for _, ((events_a, removed_a), (events_b, removed_b)) in sorted(times.items()):
        risk, events = risk_a + risk_b, events_a + events_b
        score += events_a - events * risk_a / risk
        if risk > 1:
            variance += risk_a * risk_b * events * (risk - events) / (risk * risk * (risk - 1))
        risk_a -= removed_a
        risk_b -= removed_b
    return score, variance


def pooled(strata, groups, kind):
    """One-df chi-square test, without continuity correction.

    van Elteren uses tie-corrected Wilcoxon scores with weight 1/(N_s+1).
    CMH uses the hypergeometric variance (statsmodels correction=False).
    Censored nonbinary metrics use summed log-rank scores and variances.
    """
    censored = any(row.get("censored", False) for cell in strata.values()
                   for group in groups for row in cell[group])
    method = "cmh" if kind == "binary" else "stratified_logrank" if censored else "van_elteren"
    components = []
    for cell in strata.values():
        a, b = (cell[group] for group in groups)
        if method == "stratified_logrank":
            components.append(_logrank_score(a, b))
        else:
            a, b = [row["value"] for row in a], [row["value"] for row in b]
            components.append(_binary_score(a, b) if method == "cmh" else _rank_score(a, b))
    return _score_test(math.fsum(x[0] for x in components),
                       math.fsum(x[1] for x in components), method)


def composition(strata, groups):
    """Compare stratum frequencies with Fisher (2x2) or Pearson chi-square.

    TVD compares group-normalized stratum frequencies and ranges from 0 to 1.
    The chi-square test has number-of-nonempty-strata minus one degrees of freedom.
    """
    table = [[len(cell[group]) for group in groups] for cell in strata.values()]
    table = [row for row in table if sum(row)]
    totals = [sum(row[i] for row in table) for i in (0, 1)]
    if not table or min(totals) == 0:
        return {"p_value": None, "tvd": None, "method": "unavailable"}
    tvd = math.fsum(abs(row[0] / totals[0] - row[1] / totals[1]) for row in table) / 2
    if len(table) == 1:
        return {"p_value": 1.0, "tvd": tvd, "method": "single_stratum"}
    if len(table) == 2:
        return {"p_value": fisher_exact(table)["p_value"], "tvd": tvd, "method": "fisher_exact"}
    total = sum(totals)
    statistic = 0.0
    for row in table:
        for observed, column in zip(row, totals):
            expected = sum(row) * column / total
            statistic += (observed - expected) ** 2 / expected
    return {"p_value": max(0.0, 1 - regularized_gamma((len(table) - 1) / 2, statistic / 2)),
            "tvd": tvd, "method": "chi_square"}


def _weighted_median(cells, weights):
    observations = sorted((value, weight / len(cell)) for cell, weight in zip(cells, weights)
                          for value in cell)
    cumulative = 0.0
    for i, (value, weight) in enumerate(observations):
        cumulative = math.fsum((cumulative, weight))
        if math.isclose(cumulative, .5, rel_tol=0, abs_tol=1e-12):
            return (value + observations[min(i + 1, len(observations) - 1)][0]) / 2
        if cumulative > .5:
            return value
    return observations[-1][0]


def _contrasts(a, b, weights, ratio, binary):
    if binary:
        ma, mb = (math.fsum(weight * math.fsum(cell) / len(cell) for cell, weight in zip(group, weights))
                  for group in (a, b))
        return {"proportion_difference": mb - ma}
    ma, mb = _weighted_median(a, weights), _weighted_median(b, weights)
    result = {"median_difference": mb - ma}
    if ratio:
        result["median_ratio"] = mb / ma
    return result


def standardized(strata, groups, seed=(0, 54), resamples=10_000, kind=None):
    """Weighted median B-A and B/A, standardized to the pooled stratum mix.

    Binary metrics instead report the weighted proportion difference.
    Draw independently within each group/stratum, retaining fixed pooled weights.
    Intervals are 95% percentile intervals (type 7), never BCa. mc_se is the
    bootstrap mean's Monte Carlo standard error, not an endpoint error bound.
    A positive baseline is required for a finite ratio on every resample.
    Censored rows are rejected: ordinary medians are not survival estimates.
    """
    if isinstance(resamples, bool) or not isinstance(resamples, int) or resamples < 2:
        raise ValueError("resamples must be an integer of at least two")
    if not strata:
        return {}
    if any(row.get("censored", False) for cell in strata.values()
           for group in groups for row in cell[group]):
        raise ValueError("standardized medians require uncensored values")
    a, b = ([[row["value"] for row in cell[group]] for cell in strata.values()] for group in groups)
    if any(not cell for cell in a + b):
        raise ValueError("standardization requires both groups in every stratum")
    counts = [len(x) + len(y) for x, y in zip(a, b)]
    total = sum(counts)
    weights = [count / total for count in counts]
    ratio = min(value for cell in a for value in cell) > 0
    estimates = _contrasts(a, b, weights, ratio, kind == "binary")
    distributions = {name: [] for name in estimates}
    rng = PCG32(*seed)
    for _ in range(resamples):
        drawn = [[[cell[rng.randbelow(len(cell))] for _ in cell] for cell in group] for group in (a, b)]
        for name, value in _contrasts(*drawn, weights, ratio, kind == "binary").items():
            distributions[name].append(value)
    result = {}
    for name, values in distributions.items():
        average = math.fsum(values) / resamples
        mc_se = math.sqrt(math.fsum((value - average) ** 2 for value in values) / (resamples - 1) / resamples)
        result[name] = {"estimate": estimates[name], "lo": quantile(values, .025),
                        "hi": quantile(values, .975), "null": 1 if name == "median_ratio" else 0,
                        "method": "percentile_stratified", "resamples": resamples, "mc_se": mc_se}
        if kind == "binary":
            result[name]["baseline"] = math.fsum(w * math.fsum(cell) / len(cell) for cell, w in zip(a, weights))
    return result
