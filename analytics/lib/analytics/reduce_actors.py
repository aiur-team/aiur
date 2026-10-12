"""Resource-sample actors: per-actor profiles, gaps and availability."""

from __future__ import annotations

import math


RESOURCE_METRICS = (
    "cpu_percent",
    "rss_bytes",
    "fd_count",
    "read_bytes",
    "write_bytes",
    "read_bytes_per_second",
    "write_bytes_per_second",
    "system_fd_used",
    "system_fd_limit",
    "system_fd_available",
    "system_fd_headroom_ratio",
    "fleet_agents_occupied",
    "fleet_agents_configured",
    "fleet_agents_max",
    "fleet_agents_effective",
    "fleet_load",
    "fleet_load_threshold",
    "fleet_schedulers",
    "build_gate_capacity",
    "build_gate_active",
    "build_gate_queued",
    "build_queue_oldest_wait_seconds",
)

RESOURCE_EVIDENCE = (
    "fleet_capacity_status",
    "fleet_capacity_age_ms",
    "fleet_capacity_observed_at_ms",
    "fleet_admission_signal",
    "build_gate_enabled",
    "build_gate_status",
    "build_gate_observed_at_ms",
)

DEFAULT_SAMPLE_INTERVAL_MS = 5_000
DEFAULT_GAP_THRESHOLD_MULTIPLIER = 1.5


def _reduce_actors(records: list[dict], opts: dict) -> dict:
    samples_by_actor: dict[str, list[dict]] = {}
    warnings: list[dict] = []
    for record in records:
        if record["kind"] != "resource":
            continue
        actor = record["attributes"].get("actor")
        if isinstance(actor, str) and actor:
            samples_by_actor.setdefault(actor, []).append(_resource_sample(record))
        else:
            warnings.append({"type": "resource_actor_missing", "record_id": record["record_id"]})

    actors: dict[str, dict] = {}
    for actor, samples in samples_by_actor.items():
        samples = _sort_samples(samples)
        first = samples[0]
        actors[actor] = {
            "actor": actor,
            "actor_type": first.get("actor_type"),
            "samples": samples,
            "profile": _resource_profile(samples),
            "gaps": _resource_gaps(samples, opts),
            "availability": _availability_counts(samples),
        }
    return actors


def _resource_sample(record: dict) -> dict:
    attributes = record["attributes"]
    sample = {metric: attributes.get(metric) for metric in RESOURCE_METRICS}
    sample.update({field: attributes.get(field) for field in RESOURCE_EVIDENCE})
    sample.update(
        {
            "actor": attributes.get("actor"),
            "actor_type": attributes.get("actor_type"),
            "ticket": attributes.get("ticket"),
            "availability": attributes.get("availability") or "unavailable",
            "unavailable_reason": attributes.get("unavailable_reason"),
            "process_count": attributes.get("process_count"),
            "partial_fields": attributes.get("partial_fields") or [],
            "timestamp": record["timestamp_iso"],
            "timestamp_ms": record["timestamp_ms"],
            "boot_id": record["boot_id"],
            "record_id": record["record_id"],
        }
    )
    return sample


def _resource_profile(samples: list[dict]) -> dict:
    profile: dict[str, dict] = {}
    for metric in RESOURCE_METRICS:
        values = [sample[metric] for sample in samples if isinstance(sample.get(metric), (int, float))]
        if values:
            profile[metric] = _statistics(values)
    return profile


def _statistics(values: list[float]) -> dict:
    sorted_values = sorted(values)
    count = len(sorted_values)
    midpoint = count // 2
    if count % 2 == 1:
        median = sorted_values[midpoint]
    else:
        median = (sorted_values[midpoint - 1] + sorted_values[midpoint]) / 2
    p95_index = max(math.ceil(0.95 * count) - 1, 0)
    return {
        "count": count,
        "min": sorted_values[0],
        "mean": sum(sorted_values) / count,
        "median": median,
        "p95": sorted_values[p95_index],
        "max": sorted_values[-1],
    }


def _resource_gaps(samples: list[dict], opts: dict) -> list[dict]:
    interval_ms = opts.get("sample_interval_ms", DEFAULT_SAMPLE_INTERVAL_MS)
    threshold_ms = opts.get(
        "sample_gap_threshold_ms", int(interval_ms * DEFAULT_GAP_THRESHOLD_MULTIPLIER)
    )
    gaps: list[dict] = []
    by_boot: dict[str, list[dict]] = {}
    for sample in samples:
        by_boot.setdefault(sample["boot_id"], []).append(sample)

    for boot_id, boot_samples in by_boot.items():
        ordered = sorted(boot_samples, key=lambda sample: sample["timestamp_ms"])
        for previous, current in zip(ordered, ordered[1:]):
            duration_ms = current["timestamp_ms"] - previous["timestamp_ms"]
            if duration_ms > threshold_ms:
                gaps.append(
                    {
                        "boot_id": boot_id,
                        "start_at": previous["timestamp"],
                        "end_at": current["timestamp"],
                        "duration_ms": duration_ms,
                        "expected_interval_ms": interval_ms,
                    }
                )
    gaps.sort(key=lambda gap: (gap.get("start_at", ""), gap.get("boot_id", "")))
    return gaps


def _availability_counts(samples: list[dict]) -> dict:
    measured = sum(1 for sample in samples if sample["availability"] == "measured")
    return {"measured": measured, "unavailable": len(samples) - measured}


def _sort_samples(samples: list[dict]) -> list[dict]:
    return sorted(
        samples,
        key=lambda sample: (
            sample["timestamp_ms"],
            sample["boot_id"],
            sample["record_id"],
        ),
    )


def _rescope_actors(actors: dict, boot_id: str) -> dict:
    scoped: dict[str, dict] = {}
    for key, actor in actors.items():
        samples = [sample for sample in actor["samples"] if sample["boot_id"] == boot_id]
        if not samples:
            continue
        scoped[key] = {
            "actor": actor["actor"],
            "actor_type": actor["actor_type"],
            "samples": samples,
            "profile": _resource_profile(samples),
            "gaps": _resource_gaps(samples, {}),
            "availability": _availability_counts(samples),
        }
    return scoped
