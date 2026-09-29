#!/usr/bin/env python3
"""Reconcile the frozen feature inventory without treating estimates as savings."""

import json
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FEATURES = ROOT / "features"
SURFACES = ("cli", "config", "integrations", "subsystems", "ui")
DECISIONS = {"keep", "simplify", "merge", "cut", "externalize"}

# Free-text skeptical verdicts need explicit interpretation. The exact text and
# reasoning remain on each record; this class is only an index.
FREEFORM = {
    "integrations-10": "keep",
    "integrations-16": "cut",
    "integrations-20": "keep",
    "integrations-49": "merge",
    "integrations-50": "keep",
    "integrations-51": "keep",
    "integrations-52": "cut",
    "subsystems-34": "keep",
    "subsystems-36": "keep",
    "subsystems-42": "externalize",
    "ui-15": "keep",
    "ui-16": "keep",
    "ui-06": "keep",
    "ui-07": "keep",
    "ui-08": "keep",
    "ui-09": "simplify",
    "ui-13": "keep",
    "ui-14": "keep",
    "ui-17": "keep",
    "ui-18": "keep",
    "ui-19": "cut",
    "ui-24": "keep",
    "ui-26": "cut",
    "ui-29": "cut",
    "ui-31": "keep",
}

# Later user release direction supersedes the frozen research recommendation.
# Keep it distinct until PRs are merged and the released artifact is checked.
PENDING_RELEASE_REMOVALS = {
    "cli-38": {"pr": 2840, "feature": "local PR deletion guard"},
    "integrations-20": {"pr": 2841, "feature": "GitHub cache dashboard"},
    "ui-13": {"pr": 2841, "feature": "GitHub cache dashboard"},
}


def load_challenges():
    result = {}
    for path in sorted((FEATURES / "challenges").glob("*.json")):
        data = json.loads(path.read_text())
        for row in data if isinstance(data, list) else data["verdicts"]:
            key = row["id"]
            if key in result:
                raise ValueError(f"duplicate challenge {key}")
            result[key] = {**row, "source_file": str(path.relative_to(ROOT))}
    return result


def classify(row, challenge):
    if challenge is None:
        return row["recommendation"], "unchallenged"
    verdict = challenge["recommendation"].strip().lower()
    if verdict in DECISIONS:
        return verdict, "challenged"
    if row["id"] in FREEFORM:
        return FREEFORM[row["id"]], "challenged-qualified"
    raise ValueError(f"unclassified challenge {row['id']}: {verdict}")


def escape(value):
    return str(value or "—").replace("|", "\\|").replace("\n", " ")


def main():
    challenges = load_challenges()
    rows = []
    for surface in SURFACES:
        path = FEATURES / "raw" / f"{surface}.json"
        for raw in json.loads(path.read_text())["features"]:
            key = raw["id"]
            if any(existing["id"] == key for existing in rows):
                raise ValueError(f"duplicate raw ID {key}")
            challenge = challenges.get(key)
            decision, state = classify(raw, challenge)
            rows.append({
                "id": key, "surface": surface, "name": raw["name"],
                "description": raw["description"], "entry_points": raw["entry_points"],
                "modules": raw["modules"], "docs": raw["docs"],
                "observed_use": raw["usage"], "usage_evidence": raw["usage_evidence"],
                "raw_recommendation": raw["recommendation"],
                "raw_rationale": raw.get("rationale"), "raw_rewrite_notes": raw.get("rewrite_notes"),
                "raw_lib_loc": raw.get("lib_loc"), "raw_test_loc": raw.get("test_loc"),
                "raw_loc_saving_estimate": raw.get("loc_saving_estimate"),
                "working_decision": decision, "decision_status": state,
                "release_override": ({**PENDING_RELEASE_REMOVALS[key], "status": "pending merge and publication", "decision": "cut"}
                                     if key in PENDING_RELEASE_REMOVALS else None),
                "challenge": challenge,
                "source_file": str(path.relative_to(ROOT)),
            })
    ids = {row["id"] for row in rows}
    if len(rows) != 216 or len(challenges) != 91 or set(challenges) - ids:
        raise ValueError("unexpected inventory or challenge population")
    for row in rows:
        if row["raw_recommendation"] in {"cut", "merge", "externalize"} and row["challenge"] is None:
            raise ValueError(f"candidate lacks challenge: {row['id']}")
    payload = {
        "source_revision": "3339b887196d5e9aefb273117a14bf33391ee41f",
        "scope": "five frozen feature inventories; other repository paths are covered by the complete file census, not asserted to be product features",
        "measurement_warning": "Raw feature LOC and predicted savings overlap and are not additive. No implementation savings have been measured.",
        "pending_release_removals": PENDING_RELEASE_REMOVALS,
        "counts": {
            "features": len(rows), "challenges": len(challenges),
            "by_surface": dict(Counter(row["surface"] for row in rows)),
            "by_observed_use": dict(Counter(row["observed_use"] for row in rows)),
            "by_raw_recommendation": dict(Counter(row["raw_recommendation"] for row in rows)),
            "by_working_decision": dict(Counter(row["working_decision"] for row in rows)),
            "challenge_holds": dict(Counter(str(row["challenge"]["holds"]).lower() for row in rows if row["challenge"])),
        },
        "features": rows,
    }
    (FEATURES / "features.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    pages = []
    for surface in SURFACES:
        subset = [row for row in rows if row["surface"] == surface]
        page = [f"# {surface.title()} feature use", "",
                "Frozen-source use observations and working decisions. `none-found` means no use in the sampled evidence, not no users. Follow the feature ID in [features.json](../features.json) for the full evidence, caveats, exact challenge text and module list.", "",
                "| ID | Feature | Observed use | Raw → working decision | Skeptical status |",
                "| --- | --- | --- | --- | --- |"]
        for row in subset:
            challenge = row["challenge"]
            status = "not challenged" if challenge is None else ("holds" if challenge["holds"] else "overturned / narrowed")
            if row["release_override"]:
                status += f"; 0.0.6 cut pending PR #{row['release_override']['pr']}"
            page.append(f"| {row['id']} | {escape(row['name'])} | {row['observed_use']} | {row['raw_recommendation']} → {row['working_decision']} | {status} |")
        (FEATURES / "matrix" / f"{surface}.md").write_text("\n".join(page) + "\n")
        pages.append((surface, len(subset)))
    summary = ["# Feature usage matrix", "",
               "The five frozen inventories contain 216 entries. All 91 raw cut, merge and externalize recommendations have a skeptical challenge. The matrix shows working decisions, not permission to delete. Usage labels come from bounded transcript/config/log samples; `none-found` is not proof of no users. Full evidence, challenge text and unresolved qualifications are retained in [features.json](features.json).", "",
               "| Surface | Entries | Matrix |", "| --- | ---: | --- |"]
    summary.extend(f"| {surface} | {count} | [{surface}](matrix/{surface}.md) |" for surface, count in pages)
    summary += ["", "Raw `lib_loc`, `test_loc` and saving estimates overlap across features. See [LOC reduction](loc-reduction.md) for deduplicated, conditional file scenarios and the hard file-size acceptance contract.", ""]
    (FEATURES / "usage-matrix.md").write_text("\n".join(summary))
    print(json.dumps(payload["counts"], indent=2))


if __name__ == "__main__":
    main()
