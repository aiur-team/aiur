"""Declared-strata orchestration; the unstratified driver stays unchanged."""

from copy import deepcopy
import json

from .rng import seed_from
from .strata import composition, pooled, standardized


def declaration(spec):
    fields = spec.get("strata", spec.get("stratify_by", []))
    if isinstance(fields, list) and len(fields) == 1 and isinstance(fields[0], list):
        fields = fields[0]
    elif isinstance(fields, list) and len(fields) > 1:
        raise ValueError("crossed strata require an explicit tuple, e.g. a nested attribute-name array")
    if (not isinstance(fields, list) or any(not isinstance(f, str) or not f for f in fields)
            or len(set(fields)) != len(fields)):
        raise ValueError("strata must contain one attribute or one tuple of unique attribute names")
    return fields


def partition(rows, fields, excluded, groups):
    result, identities = {}, {}
    for row in sorted(rows, key=lambda r: r["unit_id"]):
        if row["unit_id"] in excluded:
            continue
        attrs = row.get("strata", {})
        if not isinstance(attrs, dict):
            raise ValueError("row strata must be an object")
        values = []
        for field in fields:
            value = attrs.get(field, row.get(field))
            if value is None:
                value = "unknown"
            if isinstance(value, list):
                if any(not isinstance(item, (str, int, float, bool)) for item in value):
                    raise ValueError("stratum list values must contain scalars")
                value = sorted(value, key=lambda item: json.dumps(item, sort_keys=True))
            elif not isinstance(value, (str, int, float, bool)):
                raise ValueError("stratum values must be scalar, tag lists or null")
            values.append(value)
        # Single-field labels are readable; JSON tuples keep crossed labels unambiguous.
        label = (json.dumps(values[0], separators=(",", ":")) if isinstance(values[0], list)
                 else str(values[0])) if len(values) == 1 else json.dumps(values, separators=(",", ":"))
        identity = json.dumps(values, separators=(",", ":"))
        if label in identities and identities[label] != identity:
            raise ValueError("stratum labels collide across attribute types")
        identities[label] = identity
        result.setdefault(label, {g: [] for g in groups})[row["group"]].append(row)
    return dict(sorted(result.items()))


def submetric(metric, rows, groups):
    return {**metric, "primary": False,
            "values": {g: [r["value"] for r in rows[g] if not r.get("censored", False)] for g in groups},
            "censored": {g: sum(r.get("censored", False) for r in rows[g]) for g in groups},
            "excluded": {g: 0 for g in groups}}


def stratify(result, metric, groups, annotations, settings, seed, evaluate, *, children=True):
    strata = metric["strata_rows"]
    result["unstratified"] = {key: deepcopy(result[key]) for key in
                              ("groups", "tests", "effects", "p_raw", "flags") if key in result}
    result["strata_fields"] = metric["strata_fields"]
    if children:
        children_results = {}
        for name, rows in strata.items():
            child = submetric(metric, rows, groups)
            child_seed = seed_from(str(seed), name)
            children_results[name] = evaluate(child, groups, annotations, settings, child_seed)
            # Censored strata need the same pooled score and total-unit guard.
            if any(child["censored"].values()):
                child["strata_rows"] = {name: rows}
                stratify(children_results[name], child, groups, annotations, settings,
                         child_seed, evaluate, children=False)
        result["strata"] = children_results
    result["composition"] = composition(strata, groups)
    flags = set(result["flags"])
    flags.discard("cannot_reach_significance")
    flags.discard("relative_effect_undefined")
    result["min_achievable_p"] = None
    p, tvd = result["composition"]["p_value"], result["composition"]["tvd"]
    if (p is not None and p < .05) or (tvd is not None and tvd > .2):
        flags.add("composition_shift")
    metadata = metric.get("strata_metadata", {})
    if any(metadata.get(field, {}).get("post_treatment") is True for field in metric["strata_fields"]):
        flags.add("stratum_may_be_affected_by_treatment")
    kept = {name: rows for name, rows in strata.items() if min(len(rows[g]) for g in groups) >= 2}
    result["strata_dropped"] = [name for name in strata if name not in kept]
    if result["strata_dropped"]:
        flags.add("small_stratum_dropped")
    censored = any(metric["censored"].values())
    if censored:
        flags.discard("censoring_ignored")
        flags.add("standardized_effect_unavailable")
        for g in groups:
            if metric["censored"][g]:
                # Completed-only quantiles cannot describe the total at-risk population.
                result["groups"][g] = {"n_censored": metric["censored"][g]}
            result["groups"][g]["n"] = sum(len(rows[g]) for rows in strata.values())
    # The guard applies to the population actually entering the pooled test.
    for key in ("tests", "effects", "primary_effect", "p_raw", "p_adj"):
        result.pop(key, None)
    result.update(status="insufficient_data", direction="no_change", flags=sorted(flags))
    if not kept or min(sum(len(rows[g]) for rows in kept.values()) for g in groups) < settings["min_samples"]:
        return
    test = pooled(kept, groups, metric["kind"])
    effects = {} if censored else standardized(
        kept, groups, seed, settings["bootstrap_primary" if metric["primary"] else "bootstrap_exploratory"], kind=metric["kind"])
    for effect in effects.values():
        effect["unbounded"] = []
    primary = next((name for name in ("proportion_difference", "median_ratio", "median_difference")
                    if name in effects), None)
    result.update(stratified=test, p_raw_source="stratified", p_raw=test["p_value"],
                  tests={test["method"]: test}, effects=effects, primary_effect=primary)
    if primary == "median_difference":
        result["flags"] = sorted(set(result["flags"] + ["relative_effect_undefined"]))
