"""Kaplan-Meier medians, log-rank tests and censored two-group inference.

Rows are dicts with "value" (follow-up in the metric's unit) and optional "censored".
Intervals follow Brookmeyer-Crowley on the log-log Greenwood variance, as lifelines.
"""

import math
from statistics import NormalDist

from .describe import quantile
from .rng import PCG32
from .strata import _logrank_score, _score_test

HEAVY_CENSORING = .2
MAX_UNREACHED = .1


def _steps(rows):
    """Return (time, survival, cumulative Greenwood sum) after each event time."""
    events, removed = {}, {}
    for row in rows:
        removed[row["value"]] = removed.get(row["value"], 0) + 1
        events[row["value"]] = events.get(row["value"], 0) + (not row.get("censored", False))
    risk, log_survival, greenwood, steps = len(rows), 0.0, 0.0, []
    for time in sorted(removed):
        d = events[time]
        if d:
            # exp(sum(log)) like lifelines, so a curve landing on 0.5 compares the same way.
            log_survival += math.log((risk - d) / risk) if d < risk else -math.inf
            survival = math.exp(log_survival)
            greenwood += d / (risk * (risk - d)) if risk > d else math.inf
            steps.append((time, survival, greenwood))
        risk -= removed[time]
    return steps


def _first_at_most_half(steps, curve):
    return next((step[0] for step, value in zip(steps, curve) if value <= .5), None)


def km_median(rows):
    """First time the survival curve reaches 0.5, or None when it never does."""
    steps = _steps(rows)
    return _first_at_most_half(steps, [s for _, s, _ in steps])


def km_median_interval(rows, confidence=.95):
    """Return {"median", "lo", "hi"}; None means the quantity is not reached."""
    steps = _steps(rows)
    z = NormalDist().inv_cdf((1 + confidence) / 2)
    low, high = [], []
    for _, survival, greenwood in steps:
        if survival == 0:
            low.append(0.0)
            high.append(0.0)
            continue
        v = math.log(survival)
        shift = z * math.sqrt(greenwood) / v
        low.append(math.exp(-math.exp(math.log(-v) - shift)))
        high.append(math.exp(-math.exp(math.log(-v) + shift)))
    return {"median": _first_at_most_half(steps, [s for _, s, _ in steps]),
            "lo": _first_at_most_half(steps, low), "hi": _first_at_most_half(steps, high)}


def stratified_logrank(strata):
    """Log-rank over a {name: (rows_a, rows_b)} map; one stratum is the plain test."""
    parts = [_logrank_score(a, b) for a, b in strata.values()]
    return _score_test(math.fsum(p[0] for p in parts), math.fsum(p[1] for p in parts), "logrank")


def logrank(a, b):
    return stratified_logrank({"all": (a, b)})


def truncate(groups):
    """Censor every row beyond the shortest group's longest follow-up.

    Returns (rows by group, horizon, changed).
    """
    horizon = min(max(r["value"] for r in rows) for rows in groups.values())
    cut = {g: [r if r["value"] <= horizon else {**r, "value": horizon, "censored": True}
               for r in rows] for g, rows in groups.items()}
    return cut, horizon, any(r["value"] > horizon for rows in groups.values() for r in rows)


def _bootstrap_difference(a, b, seed, resamples):
    rng = PCG32(*seed)
    draws, unreached = [], 0
    for _ in range(resamples):
        medians = [km_median([rows[rng.randbelow(len(rows))] for _ in rows]) for rows in (a, b)]
        if None in medians:
            unreached += 1
        else:
            draws.append(medians[1] - medians[0])
    return draws, unreached / resamples


def censored_inference(groups_rows, names, seed, resamples):
    """Primary analysis when any row is right-censored.

    Returns (tests, effects, survival, flags, p_value).
    """
    rows, horizon, truncated = truncate(groups_rows)
    a, b = (rows[g] for g in names)
    flags = ["follow_up_truncated"] if truncated else []
    summary = {}
    for g in names:
        censored = sum(r.get("censored", False) for r in rows[g])
        summary[g] = {"n": len(rows[g]), "n_events": len(rows[g]) - censored, "n_censored": censored,
                      **km_median_interval(rows[g])}
        if censored / len(rows[g]) > HEAVY_CENSORING:
            flags.append("censoring_heavy")
    test = logrank(a, b)
    draws, unreached = _bootstrap_difference(a, b, seed, resamples)
    medians = [summary[g]["median"] for g in names]
    effect = {"estimate": None, "lo": None, "hi": None, "method": "km_median_bootstrap_percentile",
              "null": 0, "resamples": resamples, "not_reached_fraction": unreached}
    if None in medians or unreached > MAX_UNREACHED:
        flags.append("median_not_reached")
    if None not in medians:
        effect["estimate"] = medians[1] - medians[0]
        if unreached <= MAX_UNREACHED:
            effect["lo"], effect["hi"] = (quantile(draws, p) for p in (.025, .975))
    survival = {"follow_up_horizon": horizon, "groups": summary}
    return {"logrank": test}, {"median_difference": effect}, survival, flags, test["p_value"]
