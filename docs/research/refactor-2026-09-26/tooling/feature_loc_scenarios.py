#!/usr/bin/env python3
"""Count conditional whole-file removal scenarios in the frozen source tree."""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
# These are narrow file sets, not all modules touched by a feature. Shared
# modules and partial edits are deliberately excluded from removal arithmetic.
SCENARIOS = {
    "linear": ("config-10", "integrations-03", [
        "src/lib/aiur/linear/*.ex", "src/lib/aiur/codex/dynamic_tool/linear_graphql.ex"]),
    "rtk": ("config-24", "integrations-52", "subsystems-41", [
        "src/lib/aiur/rtk.ex"]),
    "pr-watch": ("config-32", "integrations-31", [
        "src/lib/aiur/config/schema/pr_watch.ex", "src/lib/aiur/orchestrator/command_scan.ex",
        "src/lib/aiur/orchestrator/pr_anchored.ex", "src/lib/aiur/events/pr_command_scanner.ex"]),
    "otlp-intake": ("integrations-16", ["src/lib/aiur/claude/telemetry/*.ex"]),
    "usage-compaction": ("subsystems-07", ["src/lib/aiur/usage_compaction/*.ex"]),
    "operator-wait-log": ("subsystems-14", ["src/lib/aiur/operator_wait_log.ex"]),
    "saturation-sentinel": ("subsystems-20", ["src/lib/aiur/saturation_sentinel.ex"]),
    "agent-process-log": ("subsystems-26", ["src/lib/aiur/agent_process_log.ex"]),
    "planning-source": ("ui-12", ["src/lib/aiur_web/build_order/planning_source.ex"]),
    "offline-telemetry-report": ("ui-26", [
        "src/lib/aiur/run_telemetry/dashboard.ex", "src/lib/aiur/run_telemetry/github_enricher.ex",
        "src/lib/mix/tasks/aiur.telemetry.dashboard.ex", "scripts/aiur-telemetry-dashboard"]),
    "unreachable-dashboard-components": ("ui-29", [
        "src/lib/aiur_web/components/operator_control_center/fleet_table.ex",
        "src/lib/aiur_web/components/operator_control_center/fleet_filters.ex",
        "src/lib/aiur_web/components/operator_control_center/capacity_control.ex",
        "src/lib/aiur_web/components/operator_control_center/recent_outcomes.ex",
        "src/lib/aiur_web/components/operator_control_center/decision_latency.ex",
        "src/lib/aiur_web/components/operator_control_center/lifecycle_components.ex",
        "src/lib/aiur_web/components/operator_control_center/build_order_icon.ex"]),
    "dom-svg-layout": ("ui-30", [
        "src/priv/static/aiur-dom-svg-layout*.js", "src/priv/static/aiur-dom-svg-layout/*.js",
        "src/browser/layout/*.js", "src/priv/static/vendor/elk/0.11.1/*"]),
}


def line_count(path):
    data = path.read_bytes()
    if b"\0" in data:
        raise ValueError(f"binary candidate {path}")
    data.decode("utf-8")
    return data.count(b"\n") + int(bool(data) and not data.endswith(b"\n"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path, help="complete frozen 3339b887 extraction")
    args = parser.parse_args()
    snapshot = args.snapshot.resolve()
    if not snapshot.is_dir():
        parser.error("snapshot directory is missing")
    result = []
    all_files = {}
    for name, parts in SCENARIOS.items():
        *feature_ids, patterns = parts
        files = {}
        for pattern in patterns:
            matches = sorted(snapshot.glob(pattern))
            if not matches:
                raise ValueError(f"no frozen matches: {name} {pattern}")
            for path in matches:
                if path.is_file() and not path.is_symlink():
                    rel = path.relative_to(snapshot).as_posix()
                    files[rel] = {"path": rel, "physical_lines": line_count(path),
                                  "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if not files:
            raise ValueError(f"empty scenario: {name}")
        for path, entry in files.items():
            if path in all_files:
                raise ValueError(f"candidate file belongs to two scenarios: {path}")
            all_files[path] = entry
        result.append({"scenario": name, "feature_ids": feature_ids,
                       "files": [entry for _, entry in sorted(files.items())],
                       "file_count": len(files), "gross_file_lines": sum(f["physical_lines"] for f in files.values()),
                       "oversized_files": sum(f["physical_lines"] > 500 for f in files.values()),
                       "measurement_status": "conditional gross whole-file deletion footprint, not net LOC saved"})
    data = {"revision": "3339b887196d5e9aefb273117a14bf33391ee41f",
            "scope": "explicit candidate-owned whole files only; shared/partial edits and tests/docs excluded",
            "scenarios": result, "unique_file_count": len(all_files),
            "unique_gross_file_lines": sum(f["physical_lines"] for f in all_files.values()),
            "unique_oversized_files": sum(f["physical_lines"] > 500 for f in all_files.values()),
            "warning": "Conditional upper footprint of removed files before replacements and dependency migrations. No implemented or measured saving."}
    (ROOT / "features" / "loc-scenarios.json").write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps({k: data[k] for k in ("unique_file_count", "unique_gross_file_lines", "unique_oversized_files")}, indent=2))


if __name__ == "__main__":
    main()
