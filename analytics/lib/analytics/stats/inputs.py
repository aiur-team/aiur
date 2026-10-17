"""Validate the frozen generic snapshot contract, including flat X2 rows."""

from datetime import datetime
import math

from .stratification import declaration, partition

KINDS = {"duration", "count", "binary", "rate", "bucketed"}
DIRECTIONS = {"lower_is_better", "higher_is_better", "decrease", "increase", "none"}


def number(value, name, minimum=0):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value < minimum):
        raise ValueError(f"{name} must be finite and >= {minimum}")
    return value


def positive_integer(value, name, minimum=1):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")
    return value


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("timezone required")
        return parsed
    except (AttributeError, TypeError, ValueError) as error:
        raise ValueError("timestamps must be ISO8601 with a timezone") from error


def normalize(snapshot, spec, annotations):
    if not all(isinstance(item, dict) for item in (snapshot, spec, annotations)):
        raise ValueError("snapshot, spec and annotations must be objects")
    experiment_id = snapshot.get("experiment_id", spec.get("id"))
    if not isinstance(experiment_id, str) or not experiment_id:
        raise ValueError("experiment_id is required")
    groups = snapshot.get("groups")
    if groups is None:
        design = spec.get("design", {})
        groups = ([c["id"] for c in design.get("cohorts", [])]
                  if design.get("kind") == "ab" else ["before", "after"])
        if design.get("control") in groups:
            control = design["control"]
            groups = [control] + [g for g in groups if g != control]
    if (not isinstance(groups, list) or len(groups) != 2 or groups[0] == groups[1]
            or any(not isinstance(g, str) or not g for g in groups)):
        raise ValueError("exactly two distinct group names are required")
    alpha = number(spec.get("alpha", .05), "alpha")
    if not 0 < alpha < 1:
        raise ValueError("alpha must be between zero and one")
    settings = {"alpha": alpha, "fdr_q": number(spec.get("fdr_q", alpha), "fdr_q"), "min_samples": positive_integer(spec.get("min_samples", 10), "min_samples"),
                "power_target": number(spec.get("power_target", .8), "power_target"),
                "bootstrap_primary": positive_integer(spec.get("bootstrap_primary", 10_000), "bootstrap_primary", 2),
                "bootstrap_exploratory": positive_integer(spec.get("bootstrap_exploratory", 2_000), "bootstrap_exploratory", 2),
                "permutation_resamples": positive_integer(spec.get("permutation_resamples", 20_000), "permutation_resamples")}
    if not 0 < settings["fdr_q"] < 1:
        raise ValueError("fdr_q must be between zero and one")
    if not 0 < settings["power_target"] < 1:
        raise ValueError("power_target must be between zero and one")
    strata_fields = declaration(spec)
    flags, exclusions = annotations.get("flags", []), annotations.get("exclusions", [])
    if not isinstance(flags, list) or not isinstance(exclusions, list):
        raise ValueError("annotation flags and exclusions must be arrays")
    for flag in flags:
        if (not isinstance(flag, dict) or any(not isinstance(flag.get(k), str)
                                            for k in ("metric", "flag", "reason", "author"))):
            raise ValueError("each analyst flag requires metric, flag, reason and author")
    for exclusion in exclusions:
        if (not isinstance(exclusion, dict) or any(not isinstance(exclusion.get(k), str)
                                                 for k in ("unit_id", "reason"))):
            raise ValueError("each exclusion requires unit_id and reason")
    excluded = {entry["unit_id"] for entry in exclusions}
    source_metrics = snapshot.get("metrics", {})
    if "rows" in snapshot:
        source_metrics = {}
        for row in snapshot["rows"]:
            source_metrics.setdefault(row["metric"], {"rows": []})["rows"].append(row)
    if not isinstance(source_metrics, dict) or not isinstance(spec.get("metrics"), list):
        raise ValueError("snapshot metrics must be an object; spec metrics must be an array")
    warnings, metrics, seen = [], [], set()
    frozen = spec.get("frozen_at", spec.get("registered_at"))
    if frozen is not None:
        frozen = timestamp(frozen)
    primaries = spec.get("primary_metrics", [m.get("id", m.get("ref")) for m in spec["metrics"] if m.get("primary")])
    if not isinstance(primaries, list) or any(not isinstance(p, str) for p in primaries):
        raise ValueError("primary_metrics must be an array of IDs")
    for definition in spec["metrics"]:
        metric_id = definition.get("id", definition.get("ref"))
        if not isinstance(metric_id, str) or not metric_id or metric_id in seen:
            raise ValueError("metric IDs must be nonempty and unique")
        seen.add(metric_id)
        evidence = source_metrics.get(metric_id, {})
        kind = definition.get("kind", evidence.get("kind"))
        if kind not in KINDS:
            raise ValueError(f"{metric_id}: explicit valid metric kind is required")
        direction = definition.get("direction", "lower_is_better")
        if direction not in DIRECTIONS:
            raise ValueError(f"{metric_id}: unknown direction")
        primary = metric_id in primaries
        if frozen and definition.get("added_at") and timestamp(definition["added_at"]) > frozen:
            primary = False
            warnings.append(f"{metric_id}: added after frozen_at; exploratory")
        metric = {**definition, "id": metric_id, "kind": kind, "direction": direction,
                  "mde": number(definition.get("mde", .2), "mde"), "primary": primary}
        metadata = snapshot.get("metric_metadata", {})
        if not isinstance(metadata, dict) or not isinstance(metadata.get(metric_id, {}), dict):
            raise ValueError("metric_metadata must map metric IDs to objects")
        strata_metadata = definition.get("strata_metadata", metadata.get(metric_id, {}).get("strata_metadata", {}))
        if (not isinstance(strata_metadata, dict)
                or any(not isinstance(value, dict) or not isinstance(value.get("post_treatment"), bool)
                       for value in strata_metadata.values())):
            raise ValueError("strata_metadata must map attributes to post_treatment booleans")
        metric["strata_metadata"] = strata_metadata
        grouped = {g: [] for g in groups}
        counts = {g: 0 for g in groups}
        censored = {g: 0 for g in groups}
        rows = evidence.get("rows", [])
        if not isinstance(rows, list):
            raise ValueError(f"{metric_id}: rows must be an array")
        units = set()
        for row in rows:
            group, unit = row.get("group"), row.get("unit_id")
            if group not in groups or not isinstance(unit, str) or not unit:
                raise ValueError(f"{metric_id}: invalid row group or unit_id")
            if unit in units:
                raise ValueError(f"{metric_id}: duplicate unit_id {unit}")
            units.add(unit)
            value = number(row.get("value"), f"{metric_id}.value")
            if kind == "binary" and value not in (0, 1):
                raise ValueError("binary observations must be zero or one")
            if not isinstance(row.get("censored", False), bool):
                raise ValueError("censored must be boolean")
            if unit in excluded:
                counts[group] += 1
            elif row.get("censored", False):
                if kind != "duration":
                    raise ValueError("only duration rows can be censored")
                censored[group] += 1
            else:
                grouped[group].append((unit, value))
        metric.update(values={g: [v for _, v in sorted(grouped[g])] for g in groups},
                      excluded=counts, censored=censored)
        if kind == "rate":
            if exclusions:
                raise ValueError("aggregate rate exclusions require per-unit exposure evidence")
            rate = evidence.get("groups", {})
            metric["rates"] = {}
            for group in groups:
                data = rate.get(group, {})
                events = positive_integer(data.get("events"), "events", 0)
                exposure = number(data.get("exposure"), "exposure")
                if exposure <= 0:
                    raise ValueError("exposure must be positive")
                n = positive_integer(data.get("n"), "rate independent-unit n", 0)
                metric["rates"][group] = {"events": events, "exposure": exposure, "n": n}
        if strata_fields and kind == "rate":
            metric["stratification_unavailable"] = True
            warnings.append(f"{metric_id}: aggregate rate evidence cannot be stratified")
        if strata_fields and kind != "rate":
            metric["strata_rows"] = partition(rows, strata_fields, excluded, groups)
            metric["strata_fields"] = strata_fields
        metrics.append(metric)
    if set(primaries) - seen:
        raise ValueError("primary_metrics IDs must exist in spec.metrics")
    for metric_id in sorted(set(source_metrics) - seen):
        warnings.append(f"{metric_id}: not in spec; skipped")
    return experiment_id, groups, metrics, settings, warnings
