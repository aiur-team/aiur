#!/usr/bin/env python3
"""Summarize independent AST references using the survey's candidate taxonomy.

This does not execute the original graph extractor. Edges include type, struct,
import, behaviour and module-value references, not just calls. Runtime dispatch
and macro-generated references are absent; counts are not proven lower bounds.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

LEVEL = {"K": 0, "CFG": 1, "TRK": 2, "CA": 2,
         **dict.fromkeys("GHC GHB LIN USG PM BUS WS".split(), 3),
         "GHR": 4, "GHD": 4, **dict.fromkeys("ING CDX CLD OAI OC".split(), 5),
         "RUN": 6, **dict.fromkeys("ORC DSP CTL PRL MSG".split(), 7),
         **dict.fromkeys("DEC EXE PRJ TEL BO".split(), 8),
         **dict.fromkeys("WEB TUI SD VOX CLI INI DEV".split(), 9)}

FAMILY = {
    **dict.fromkeys("K CFG TRK".split(), "Foundation"),
    **dict.fromkeys("GHC GHB GHR GHD ING".split(), "GitHub"),
    "LIN": "Linear", "BUS": "Bus",
    **dict.fromkeys("ORC DSP CTL PRL MSG".split(), "Orchestration"),
    "RUN": "Runtime", "WS": "Runtime",
    **dict.fromkeys("CA CDX CLD OAI OC".split(), "Agents"),
    "PM": "Accounting", "USG": "Accounting", "EXE": "Executor", "DEC": "Executor",
    "PRJ": "ReadModels", "TEL": "ReadModels", "BO": "BuildOrder",
    **dict.fromkeys("WEB TUI SD VOX CLI INI DEV".split(), "Surfaces"),
}


def components(nodes, edges):
    reach = {n: {n} | {b for a, b in edges if a == n} for n in nodes}
    for via in sorted(nodes):
        for node in nodes:
            if via in reach[node]:
                reach[node].update(reach[via])
    groups = {tuple(sorted(m for m in nodes if m in reach[n] and n in reach[m])) for n in nodes}
    return sorted([list(c) for c in groups], key=lambda c: (-len(c), c))


def simulate(edges, assignments, rules):
    """Apply the original proposed relocations/inversions to independent edges.

    This deliberately reproduces a design hypothesis, not a measured saving.
    The simulation drops dependencies instead of implementing their replacement.
    """
    moved = {}
    for pattern, destination in rules:
        moved.update({module: destination for module in assignments if re.search(pattern, module)})
    after = {**assignments, **moved}
    levels = {**LEVEL, "SBX": 2, "SIG": 1, "TERM": 1}
    removed, remaining = Counter(), set()
    for a, b in edges:
        ba, bb = after[a], after[b]
        if ba == bb:
            continue
        reason = None
        if b == "Aiur.Orchestrator" and levels[ba] < 7:
            reason = "orchestrator-callback->event"
        elif b == "Aiur.AlertFeed" and ba in ("ORC", "DSP", "PRL", "ING", "CTL"):
            reason = "alert-latch->signal-state"
        elif ba == "CFG" and bb not in ("K", "SIG", "CFG"):
            reason = "config->schema-registration"
        elif a == "Aiur.Tracker" and bb in ("GHD", "LIN"):
            reason = "tracker-adapter-registry"
        elif a.startswith(("Aiur.CodingAgent", "Aiur.AppServer")) and bb in ("CDX", "CLD", "OAI", "PM", "USG"):
            reason = "backend-registry"
        elif b.startswith("Aiur.Claude.RemoteControl") and ba not in ("CLD", "CA"):
            reason = "remote-session-capability"
        if reason:
            removed[reason] += 1
        elif levels[ba] < levels[bb]:
            remaining.add((a, b))
    return {"relocated_modules": len(moved), "inversions": dict(sorted(removed.items())),
            "inverted_edges": sum(removed.values()), "remaining_upward_edges": len(remaining),
            "limitation": "Synthetic reassignment and deletion of edges. Replacement contracts, their costs and runtime behavior are not modeled."}


def summarize(tsv, mapping, relocation_rules=None):
    rules = [(b, re.compile(pattern)) for b, pattern in mapping["rules"]]
    boundary = lambda module: next((b for b, pat in rules if pat.search(module)), "??")
    modules, file_modules, references = {}, defaultdict(list), []
    for line in tsv.read_text().splitlines():
        row = line.split("\t")
        if row[0] == "M":
            _, path, module = row
            modules[module] = path
            file_modules[path].append(module)
        elif row[0] == "R":
            references.append(row[1:])
        else:
            raise ValueError("Unexpected record")
    primary = {module: (file_modules[path][0] if file_modules[path][0] != "Aiur" else "Aiur.Application")
               for module, path in modules.items()}
    edges = set()
    unresolved = Counter()
    for path, source, target, kind, line in references:
        candidate = target
        if candidate not in modules:
            if target.startswith(("Aiur.", "AiurWeb.")):
                unresolved[target] += 1
            continue
        source, target = primary[source], primary[candidate]
        if source != target:
            edges.add((source, target))
    assignments = {m: boundary(m) for m in set(primary.values())}
    unknown = [m for m, b in assignments.items() if b == "??"]
    if unknown:
        raise ValueError(f"Unmapped modules: {unknown}")
    bedges = {(assignments[a], assignments[b]) for a, b in edges if assignments[a] != assignments[b]}
    nodes = set(assignments.values())
    cross = {(a, b) for a, b in edges if assignments[a] != assignments[b]}
    upward = {(a, b) for a, b in cross if LEVEL[assignments[a]] < LEVEL[assignments[b]]}
    inbound_alerts = {a for a, b in edges if b == "Aiur.Alerts"}
    return {
        "method": "module_references.exs AST traversal; docs and alias declarations excluded; primary-file collapse; original candidate boundary map",
        "defined_modules": len(modules), "primary_files": len(file_modules), "module_edges": len(edges),
        "boundaries": len(nodes), "boundary_edges": len(bedges),
        "strongly_connected_components": components(nodes, bedges),
        "family_components": components(set(FAMILY.values()), {(FAMILY[a], FAMILY[b]) for a, b in bedges}),
        "mutually_dependent_boundary_pairs": len({tuple(sorted((a, b))) for a, b in bedges if (b, a) in bedges}),
        "cross_boundary_module_edges": len(cross), "upward_module_edges": len(upward),
        "alerts_inbound_modules": len(inbound_alerts),
        "alerts_inbound_boundaries": len({assignments[a] for a in inbound_alerts}),
        "unresolved_aiur_module_references": dict(sorted(unresolved.items())),
        "cache_boundary_dependencies": sorted({b for a, b in bedges if a == "GHR"}),
        "github_references_outside_github_boundaries": {
            "source_modules": len({a for a, b in edges if b.startswith("Aiur.GitHub.") and assignments[a] not in {"GHC", "GHB", "GHR", "GHD", "ING"}}),
            "boundaries": len({assignments[a] for a, b in edges if b.startswith("Aiur.GitHub.") and assignments[a] not in {"GHC", "GHB", "GHR", "GHD", "ING"}}),
        },
        "relocation_simulation": simulate(edges, assignments, relocation_rules) if relocation_rules else None,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("references", type=Path)
    parser.add_argument("boundary_map", type=Path)
    parser.add_argument("--relocations", type=Path)
    args = parser.parse_args()
    rules = json.loads(args.relocations.read_text())["rules"] if args.relocations else None
    print(json.dumps(summarize(args.references, json.loads(args.boundary_map.read_text()), rules), indent=2))
