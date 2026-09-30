#!/usr/bin/env python3
"""Render a navigable feature-use matrix from raw inventory and challenges."""

import argparse
import json
from pathlib import Path


def escape(value: object) -> str:
    return str(value or "—").replace("|", "\\|").replace("\n", " ")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("features", type=Path)
    args = parser.parse_args()
    root = args.features
    challenges = {}
    for path in sorted((root / "challenges").glob("*.json")):
        data = json.loads(path.read_text())
        for row in data if isinstance(data, list) else data["verdicts"]:
            if row["id"] in challenges:
                raise SystemExit(f"duplicate challenge: {row['id']}")
            challenges[row["id"]] = row

    pages = []
    for path in sorted((root / "raw").glob("*.json")):
        data = json.loads(path.read_text())
        rows = sorted(data["features"], key=lambda row: row["id"])
        output = [
            f"# {path.stem.title()} feature use",
            "",
            "Usage and raw recommendations are frozen research observations; challenged recommendations are continuing-researcher decisions and remain provisional until final synthesis. See the matching `raw/` feature and `challenges/` record for evidence and limits.",
            "",
            "| ID | Feature | Observed use | Raw recommendation | Challenge |",
            "| --- | --- | --- | --- | --- |",
        ]
        for row in rows:
            challenge = challenges.get(row["id"])
            verdict = "pending" if challenge is None else ("holds" if challenge["holds"] else f"overturned → {challenge['recommendation']}")
            output.append(
                f"| {row['id']} | {escape(row['name'])} | {escape(row.get('usage'))} | "
                f"{escape(row['recommendation'])} | {escape(verdict)} |"
            )
        destination = root / "matrix" / f"{path.stem}.md"
        destination.parent.mkdir(exist_ok=True)
        destination.write_text("\n".join(output) + "\n")
        pages.append((path.stem, len(rows)))

    if set(challenges) - {row["id"] for path in (root / "raw").glob("*.json") for row in json.loads(path.read_text())["features"]}:
        raise SystemExit("challenge refers to an unknown feature")
    summary = [
        "# Feature usage matrix",
        "",
        "The five linked tables cover all 216 frozen feature entries. Their observed-use labels come from bounded transcript, config and log samples; `none-found` is not proof of no users. Raw `lib_loc` and `test_loc` footprints overlap across features and must not be summed into a deletion estimate. The challenge column tracks whether a cut/merge/externalize candidate has received a skeptical pass; an unchallenged recommendation is not a decision.",
        "",
        "| Surface | Features | Usage table |",
        "| --- | ---: | --- |",
    ]
    for surface, count in pages:
        summary.append(f"| {surface} | {count} | [{surface}](matrix/{surface}.md) |")
    summary += ["", "The current matrix is an index. Final keep/simplify/merge/cut/externalize decisions and physical line savings belong in `feature-inventory.md` and `loc-reduction.md` after all challenges are resolved.", ""]
    (root / "usage-matrix.md").write_text("\n".join(summary))
    if sum(count for _, count in pages) != 216:
        raise SystemExit("feature population changed; revise the source census before publishing")
    print(f"rendered {len(pages)} surfaces and {sum(count for _, count in pages)} features")


if __name__ == "__main__":
    main()
