"""Pure experiment analysis facade; no I/O, clock or environment reads."""

from math import isfinite

from .canonical import input_hash, rounded
from .describe import describe
from .inputs import normalize
from .methods import infer
from .multiplicity import adjust
from .ranks import min_achievable_p
from .rng import seed_from
from .summary_text import summarize
from .stratification import stratify, submetric

ENGINE_VERSION = "1.0.0"


def _metric(metric, groups, annotations, settings, seed):
    flags = [] if metric["primary"] else ["exploratory"]
    if metric.get("stratification_unavailable"):
        flags.append("stratification_unavailable")
    if metric["kind"] == "bucketed":
        flags.append("autocorrelated_units")
    if any(metric["censored"].values()):
        flags.append("censoring_ignored")
    analyst = [dict(f) for f in annotations.get("flags", []) if f["metric"] in ("*", metric["id"])]
    flags.extend(f["flag"] for f in analyst)
    descriptives = {g: describe(metric["values"][g]) for g in groups}
    if metric["kind"] == "rate":
        descriptives = {g: {**metric["rates"][g], "rate": metric["rates"][g]["events"] / metric["rates"][g]["exposure"]}
                        for g in groups}
    for g in groups:
        descriptives[g]["n_censored"] = metric["censored"][g]
    sizes = [descriptives[g]["n"] for g in groups]
    minimum_p = min_achievable_p(*sizes) if all(sizes) and metric["kind"] != "rate" else None
    if minimum_p is not None and minimum_p > settings["alpha"]:
        flags.append("cannot_reach_significance")
    result = {"kind": metric["kind"], "groups": descriptives,
              "min_achievable_p": minimum_p, "excluded_counts": metric["excluded"],
              "flags": sorted(set(flags)), "analyst_flags": analyst,
              "status": "insufficient_data", "direction": "no_change",
              "adjustment": "holm" if metric["primary"] else "bh"}
    if min(sizes) < settings["min_samples"]:
        return result
    tests, effects, primary_effect, p = infer(metric, groups, seed, settings)
    for effect in effects.values():
        effect["unbounded"] = [key for key in ("estimate", "lo", "hi")
                               if effect.get(key) is not None and not isfinite(effect[key])]
    result.update(tests=tests, effects=effects, primary_effect=primary_effect, p_raw=p)
    if primary_effect == "median_difference":
        result["flags"] = sorted(set(result["flags"] + ["relative_effect_undefined"]))
    return result


def _label(result, metric, alpha):
    if "p_raw" not in result:
        return
    if not result.get("primary_effect"):
        result["status"] = "significant" if result["p_adj"] < alpha else "inconclusive"
        return
    effect = result["effects"][result["primary_effect"]]
    lo, hi, estimate = effect["lo"], effect["hi"], effect["estimate"]
    null = effect["null"]
    bounded = lo is not None and hi is not None
    relative = result["primary_effect"] in ("median_ratio", "rate_ratio")
    # Binary equivalence uses relative difference against the baseline proportion.
    baseline = next(iter(result["groups"].values())).get("median")
    if result["kind"] == "binary":
        baseline = metric["values"]
        baseline = next(iter(baseline.values()))
        baseline = effect.get("baseline", sum(baseline) / len(baseline))
    margin = metric["mde"] if relative else metric["mde"] * (baseline or 0)
    equivalent = (relative or result["kind"] == "binary") and bounded and margin > 0 and lo >= null - margin and hi <= null + margin
    result["status"] = ("significant" if result["p_adj"] < alpha else
                        "practically_equivalent" if equivalent else "inconclusive")
    if bounded and (lo > null or hi < null) and estimate is not None and metric["direction"] != "none":
        lower_better = metric["direction"] in ("lower_is_better", "decrease")
        improved = (estimate < null) == lower_better
        result["direction"] = "improved" if improved else "regressed"


def analyze(snapshot, spec, annotations=None):
    """Return a canonical result body from explicit frozen JSON inputs."""
    annotations = {} if annotations is None else annotations
    experiment_id, groups, metrics, settings, warnings = normalize(snapshot, spec, annotations)
    inputs = {name + "_sha256": input_hash(value) for name, value in
              (("snapshot", snapshot), ("spec", spec), ("annotations", annotations))}
    results = {}
    for metric in metrics:
        seed = seed_from(experiment_id, metric["id"], "pooled", inputs["snapshot_sha256"])
        result = _metric(metric, groups, annotations, settings, seed)
        if "strata_rows" in metric:
            stratify(result, metric, groups, annotations, settings, seed, _metric)
        results[metric["id"]] = result
    for primary, method in ((True, "holm"), (False, "bh")):
        # Guarded hypotheses remain in the family as p=1, but have no test result.
        family = {m["id"]: results[m["id"]].get("p_raw", 1.0)
                  for m in metrics if m["primary"] == primary}
        adjusted = adjust(family, method)
        for key, value in adjusted.items():
            if "p_raw" in results[key]:
                results[key]["p_adj"] = value
    strata_family = {(m["id"], name): child.get("p_raw", 1.0)
                     for m in metrics for name, child in results[m["id"]].get("strata", {}).items()}
    for (metric_id, name), p in adjust(strata_family, "bh").items():
        child = results[metric_id]["strata"][name]
        if "p_raw" in child:
            child["p_adj"] = p
    for metric in metrics:
        result = results[metric["id"]]
        for name, child in result.get("strata", {}).items():
            # Binary equivalence needs this stratum's baseline, not the pooled one.
            rows = metric["strata_rows"][name]
            definition = submetric(metric, rows, groups)
            _label(child, definition, settings["alpha"])
            child = result["strata"][name] = rounded(child)
            child["summary_text"] = summarize(child, definition, groups)
        # Classify at full precision; serialize and summarize at the published precision.
        _label(result, metric, settings["alpha" if metric["primary"] else "fdr_q"])
        result = results[metric["id"]] = rounded(result)
        result["summary_text"] = summarize(result, metric, groups)
    primaries = {m["id"]: results[m["id"]]["status"] for m in metrics if m["primary"]}
    return rounded({"schema_version": "experiment-result/v1", "experiment_id": experiment_id,
                    "group_order": groups, "engine": {"name": "experiment-stats", "version": ENGINE_VERSION},
                    "inputs": inputs, "defaults": settings, "metrics": results,
                    "exclusions": annotations.get("exclusions", []), "warnings": warnings,
                    "overall": {"primary_statuses": primaries,
                                "note": "" if primaries else "no pre-registered primary",
                                "flags": sorted({flag for r in results.values() for flag in r["flags"]})}})
