"""Metric-kind inference; every contrast is B minus A or B divided by A."""

from .bootstrap import bootstrap
from .counts import fisher_exact, newcombe_interval, poisson_rate_test
from .describe import quantile
from .numeric import mean
from .permutation import permutation_test
from .ranks import cliffs_delta, hodges_lehmann, mann_whitney_u


def median_difference(a, b):
    return quantile(b, .5) - quantile(a, .5)


def median_ratio(a, b):
    return quantile(b, .5) / quantile(a, .5)


def mean_difference(a, b):
    return mean(b) - mean(a)


def infer(metric, groups, seed, settings):
    a, b = (metric["values"][g] for g in groups)
    kind = metric["kind"]
    if kind == "rate":
        ra, rb = (metric["rates"][g] for g in groups)
        test = poisson_rate_test(rb["events"], rb["exposure"], ra["events"], ra["exposure"])
        effect = {"estimate": test["rate_ratio"], "lo": test["lo"], "hi": test["hi"],
                  "method": "conditional_exact", "null": 1}
        return {"conditional_poisson": test}, {"rate_ratio": effect}, "rate_ratio", test["p_value"]
    if kind == "binary":
        ka, kb = int(sum(a)), int(sum(b))
        test = fisher_exact([[kb, len(b) - kb], [ka, len(a) - ka]])
        effect = {**newcombe_interval(kb, len(b), ka, len(a)), "null": 0}
        return {"fisher": test}, {"proportion_difference": effect}, "proportion_difference", test["p_value"]
    test = mann_whitney_u(a, b)
    permutation = permutation_test(a, b, mean_difference, seed=seed,
                                   resamples=settings["permutation_resamples"])
    statistics = {"median_difference": median_difference,
                  "cliffs_delta": lambda x, y: cliffs_delta(x, y)["statistic"]}
    # A bootstrap draw can have a zero median even when the observed median is positive.
    if min(a) > 0:
        statistics["median_ratio"] = median_ratio
    resamples = settings["bootstrap_primary" if metric["primary"] else "bootstrap_exploratory"]
    effects = bootstrap(a, b, statistics, seed=seed, resamples=resamples)
    for name, effect in effects.items():
        effect["null"] = 1 if name == "median_ratio" else 0
    effects["cliffs_delta"]["magnitude"] = cliffs_delta(a, b)["magnitude"]
    effects["hodges_lehmann"] = hodges_lehmann(a, b)
    primary_effect = "median_ratio" if "median_ratio" in effects else "median_difference"
    # With small tied samples permutation is the primary p-value, U is sensitivity.
    tied = len(set(a + b)) < len(a + b)
    p = permutation["p_value"] if tied and len(a) * len(b) <= 2500 else test["p_value"]
    return {"mann_whitney_u": test, "permutation": permutation}, effects, primary_effect, p
