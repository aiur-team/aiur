#!/usr/bin/env python3
"""Deterministic source-citation delta for the frozen feature inventory."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
from pathlib import Path

FROZEN = "3339b887196d5e9aefb273117a14bf33391ee41f"
CANDIDATE = "0299daca28383a336682374e19e90d6434aa4e1a"
RESEARCH = Path(__file__).resolve().parents[1]
INVENTORY = RESEARCH / "features/features.json"
OUTPUT = RESEARCH / "synthesis/feature-release-candidate-v3-delta.jsonl"
PATH_TOKEN = re.compile(r"(?<![A-Za-z0-9_./-])(?:[A-Za-z0-9_.{},*+-]+/)+[A-Za-z0-9_.{},*+-]+")

# New Muse files did not exist in the frozen inventory, so exact cited-path
# matching cannot discover their adjacency. Keep this small, explicit and
# separately labeled; it is a review queue, not proof that a decision changed.
MUSE_ADJACENT = {
    "cli-23", "config-16", "config-17", "config-18", "config-19", "config-37",
    "integrations-05", "integrations-06",
    "integrations-07", "integrations-08", "integrations-10", "integrations-13",
    "integrations-12", "integrations-14", "integrations-15", "integrations-47", "subsystems-04",
    "subsystems-12", "subsystems-38", "ui-20", "ui-23",
}


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True)


def paths_at(repo: Path, revision: str) -> set[str]:
    return set(git(repo, "ls-tree", "-r", "--name-only", revision).splitlines())


def changed_at(repo: Path) -> dict[str, str]:
    rows = git(repo, "diff", "--no-renames", "--name-status", FROZEN, CANDIDATE).splitlines()
    return {path: status for status, path in (row.split("\t", 1) for row in rows)}


def expand_braces(token: str) -> list[str]:
    match = re.search(r"\{([^{}]+)\}", token)
    if not match:
        return [token]
    return [part for choice in match.group(1).split(",")
            for part in expand_braces(token[:match.start()] + choice + token[match.end():])]


def cited_paths(citations: list[str], known: set[str]) -> tuple[list[str], list[str]]:
    found: set[str] = set()
    unresolved: set[str] = set()
    for citation in citations:
        # ui-12 abbreviates a README plus "three demo pack JSON files" with
        # spaces inside braces. At the frozen revision this directory has
        # exactly those four tracked files; resolve the explicit shorthand.
        build_order_shorthand = "src/priv/build_orders/{README.md, three demo pack JSON files}"
        if build_order_shorthand in citation:
            found.update(path for path in known if path.startswith("src/priv/build_orders/"))
            citation = citation.replace(build_order_shorthand, "")
        for raw_token in PATH_TOKEN.findall(citation):
            token = raw_token.rstrip(",")
            # Elixir arity such as `analytics/1` is a function, not a path.
            if re.search(r"/\d+$", token):
                continue
            matches: set[str] = set()
            for expanded in expand_braces(token):
                # The subsystems partition uses paths relative to src/.
                variants = [expanded]
                if expanded.startswith(("lib/", "test/", "priv/")):
                    variants.append("src/" + expanded)
                for variant in variants:
                    if "*" in variant:
                        matches.update(path for path in known if fnmatch.fnmatchcase(path, variant))
                    elif variant in known:
                        matches.add(variant)
                    else:
                        # Skill inventories cite a directory as one feature.
                        matches.update(path for path in known if path.startswith(variant + "/"))
            if matches:
                found.update(matches)
            elif token.startswith(("src/", "lib/", "test/", "priv/", ".claude/", ".aiur/", "docs/", "website/", "packaging/", "scripts/", "packages/", "analytics/")):
                unresolved.add(token)
    return sorted(found), sorted(unresolved)


def build(repo: Path) -> list[dict]:
    inventory = json.loads(INVENTORY.read_text())
    assert inventory["source_revision"] == FROZEN
    assert len(inventory["features"]) == 216
    assert git(repo, "rev-parse", CANDIDATE).strip() == CANDIDATE
    known = paths_at(repo, FROZEN) | paths_at(repo, CANDIDATE)
    changes = changed_at(repo)
    rows = []
    for feature in inventory["features"]:
        source_paths, unresolved_source = cited_paths(feature["modules"], known)
        docs_paths, unresolved_docs = cited_paths([feature.get("docs") or ""], known)
        source_delta = {p: changes[p] for p in source_paths if p in changes}
        docs_delta = {p: changes[p] for p in docs_paths if p in changes}
        override = feature.get("release_override")
        reasons = []
        if source_delta:
            reasons.append("cited_source_changed")
        if docs_delta:
            reasons.append("cited_docs_changed")
        if override:
            reasons.append("inventory_release_override")
        if feature["id"] in MUSE_ADJACENT:
            reasons.append("new_muse_surface_adjacency")
        resolution = "tracked_citation" if source_paths else "unresolved"
        if feature["id"] == "cli-39":
            # The frozen entry expressly cites Mix's generated release boot
            # script, not a tracked Aiur path. Related configuration/caller
            # anchors are documented in the manual reconciliation note.
            resolution = "generated_release_script"
            reasons.append("generated_release_rpc_contract")
        elif feature["id"] == "ui-33":
            # The frozen entry expressly says this recorder is absent.
            resolution = "documented_without_implementation"
            reasons.append("documented_absent_surface")
        rows.append({
            "id": feature["id"],
            "surface": feature["surface"],
            "name": feature["name"],
            "working_decision": feature["working_decision"],
            "release_override_decision": override["decision"] if override else None,
            "cited_source_paths": source_paths,
            "cited_source_delta": source_delta,
            "cited_docs_delta": docs_delta,
            "unresolved_source_citations": unresolved_source,
            "unresolved_docs_citations": unresolved_docs,
            "source_resolution": resolution,
            "merged_main_revalidation_reasons": reasons,
        })
    assert len({row["id"] for row in rows}) == 216
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True, help="checkout containing both source revisions")
    parser.add_argument("--check", action="store_true", help="compare committed artifact without writing")
    args = parser.parse_args()
    body = "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in build(args.repo))
    if args.check:
        assert OUTPUT.read_text() == body, "feature release delta is stale"
    else:
        OUTPUT.write_text(body)


if __name__ == "__main__":
    main()
