"""Input discovery and state-node path resolution for the analytics tools.

The analytics tools read durable run-telemetry NDJSON streams and build-order
packs, and write materialized summaries into the per-repo state node (the same
non-git machine-local root ``RepoBase.repo_path/1`` uses, at
``~/.aiur/repo/<owner>/<name>``). This module owns every filesystem guess so the
reducer and renderers stay pure.
"""

from __future__ import annotations

import os
from pathlib import Path

# Telemetry schema versions the reducer understands (mirrors the Elixir
# RunTelemetry.schema_version/0 range; version 2 adds dispatch complexity).
SUPPORTED_TELEMETRY_SCHEMA_VERSIONS = (1, 2)

TELEMETRY_FILENAME = "telemetry.ndjson"

# Canonical build-order pack filenames, in discovery order. Packs load from the
# in-repo location (``.aiur/build_orders`` / ``src/priv/build_orders``) or from
# the state node's ``builds/<slug>/build-order.json`` (Executor-placed).
BUILD_ORDER_RELATIVE_PATHS = (
    ".aiur/build_orders",
    "src/priv/build_orders",
    "build_orders",
)

DEFAULT_LOGS_ROOT = "~/.aiur/logs"
DEFAULT_REPO_NODE_ROOT = "~/.aiur/repo"


def expand(path: str | os.PathLike) -> Path:
    """Expand ~ and resolve to an absolute path."""
    return Path(os.path.expanduser(str(path))).expanduser().resolve()


def discover_telemetry_files(inputs: list[str]) -> list[Path]:
    """Expand CLI inputs into a sorted, de-duplicated list of telemetry files.

    A directory input is searched recursively for ``telemetry.ndjson`` files; a
    file input is used directly. With no inputs, ``~/.aiur/logs`` is searched.
    Returns [] when nothing is found.
    """
    if not inputs:
        inputs = [str(expand(DEFAULT_LOGS_ROOT))]

    found: list[Path] = []
    for raw in inputs:
        path = expand(raw)
        if path.is_file():
            found.append(path)
        elif path.is_dir():
            found.extend(path.rglob(TELEMETRY_FILENAME))
        # Missing inputs are ignored (discovery is best-effort).

    # De-duplicate while preserving a stable, deterministic order.
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in sorted(found):
        if path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def state_node_root(repo: str | None, base: str | os.PathLike | None = None) -> Path:
    """Resolve the per-repo state node root.

    Precedence: an explicit ``--state-node`` (``base``) wins; otherwise the
    ``--repo``-derived ``~/.aiur/repo/<owner>/<name>``; otherwise a single repo
    node discovered under ``~/.aiur/repo``; otherwise ``~/.aiur/repo`` itself.
    """
    if base:
        return expand(base)

    if repo:
        owner, name = _repo_segments(repo)
        return expand(DEFAULT_REPO_NODE_ROOT).joinpath(owner, name)

    root = expand(DEFAULT_REPO_NODE_ROOT)
    if root.is_dir():
        nodes = [p for p in root.iterdir() if p.is_dir() and any(c.is_dir() for c in p.iterdir())]
        if len(nodes) == 1:
            return nodes[0]
    return root


def analytics_root(state_node: Path) -> Path:
    """The analytics output root inside the state node."""
    return state_node / "analytics"


def runs_dir(state_node: Path) -> Path:
    """``<state-node>/analytics/runs`` — one run-summary per boot."""
    return analytics_root(state_node) / "runs"


def builds_dir(state_node: Path) -> Path:
    """``<state-node>/builds`` — the real writer target for RepoBase.builds_path/1.

    Mirrors ``RepoBase.builds_path(repo_url)``. Each build order writes
    ``<slug>/build-summary.json`` here.
    """
    return state_node / "builds"


def run_summary_path(state_node: Path, boot_id: str) -> Path:
    return runs_dir(state_node) / _safe_segment(boot_id) / "run-summary.json"


def build_summary_path(state_node: Path, slug: str) -> Path:
    return builds_dir(state_node) / _safe_segment(slug) / "build-summary.json"


def discover_build_orders(state_node: Path, repo_root: Path | None = None) -> list[tuple[str, Path]]:
    """Discover ``(slug, build-order-json-path)`` pairs.

    Slugs are the build-order JSON filenames' stems (e.g. ``analytics-optimizations``).
    Discovery order: state node ``builds/<slug>/build-order.json``, then the repo
    checkout's canonical pack directories.
    """
    state_node_packs: list[Path] = []
    repo_packs: list[Path] = []

    # Executor-placed build orders in the state node builds root: the slug is
    # the parent directory name (`builds/<slug>/build-order.json`).
    builds = builds_dir(state_node)
    if builds.is_dir():
        state_node_packs.extend(sorted(builds.rglob("build-order.json")))

    # Canonical in-repo packs (`src/priv/build_orders/<slug>.json`): the slug is
    # the filename stem.
    for relative in BUILD_ORDER_RELATIVE_PATHS:
        for base in (_repo_checkout(repo_root, state_node),):
            if base is None:
                continue
            dir_path = base / relative
            if dir_path.is_dir():
                repo_packs.extend(sorted(dir_path.glob("*.json")))

    result: list[tuple[str, Path]] = []
    seen: set[Path] = set()
    for path in state_node_packs:
        if path in seen:
            continue
        seen.add(path)
        result.append((path.parent.name, path))
    for path in repo_packs:
        if path in seen:
            continue
        seen.add(path)
        result.append((path.stem, path))
    return result


def find_build_order(state_node: Path, slug: str, repo_root: Path | None = None) -> Path | None:
    """Locate one build order pack by slug."""
    for candidate_slug, path in discover_build_orders(state_node, repo_root):
        if candidate_slug == slug:
            return path
    return None


def repo_root() -> Path | None:
    """The repository checkout root when the tools run from a clone.

    Used to locate in-repo build-order packs and the analytics README contract
    when no state node exists yet.
    """
    here = Path(__file__).resolve()
    # analytics/lib/analytics/sources.py -> lib -> analytics -> repo root
    repo = here.parents[3]
    if (repo / ".git").exists() or (repo / "README.md").exists():
        return repo
    return None


def _repo_checkout(repo_root_arg: Path | None, state_node: Path) -> Path | None:
    if repo_root_arg is not None:
        return repo_root_arg
    # The warm base clone inside the state node carries the analytics code.
    latest = state_node / "latest"
    if (latest / ".git").exists():
        return latest
    return repo_root()


def _repo_segments(repo: str) -> tuple[str, str]:
    cleaned = repo.strip().rstrip("/")
    if cleaned.endswith(".git"):
        cleaned = cleaned[:-4]
    parts = [p for p in cleaned.split("/") if p and p not in ("https:", "http:", "ssh:", "git@", "github.com")]
    if len(parts) >= 2:
        return parts[-2], parts[-1]
    if len(parts) == 1:
        return "local", parts[0]
    return "local", "repo"


def _safe_segment(value: str) -> str:
    """Sanitize a boot id or slug for use as a filesystem segment."""
    safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in value)
    return safe or "unknown"
