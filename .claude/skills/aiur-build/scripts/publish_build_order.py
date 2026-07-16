#!/usr/bin/env python3
"""Run an explicitly authorized Build Order publication adapter.

Dry-run is the default.  A planning pack supplies a versioned adapter at
``<pack>/scripts/publication_adapter.py``; this skill entry point owns mode
selection and never infers mutation authority from the presence of that file.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import stat
import sys
from pathlib import Path
from typing import Any, Protocol


ADAPTER_PROTOCOL_VERSION = 1
ADAPTER_RELATIVE_PATH = Path("scripts/publication_adapter.py")


class PublicationError(RuntimeError):
    """A publication adapter or CLI safety contract failed closed."""


class PublicationDriver(Protocol):
    def dry_run(self) -> dict[str, Any]: ...
    def apply(self) -> dict[str, Any]: ...
    def finalize(self, receipt_commit: str, receipt_url: str) -> dict[str, Any]: ...


def _regular_file(path: Path, label: str) -> Path:
    try:
        value = path.resolve(strict=True)
        mode = path.lstat().st_mode
    except OSError as exc:
        raise PublicationError(f"{label} is unavailable: {exc}") from None
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise PublicationError(f"{label} must be a regular non-symlink file")
    return value


def _load_extension(pack: Path) -> dict[str, Any]:
    candidate = pack / ADAPTER_RELATIVE_PATH
    if not candidate.exists():
        return {}
    adapter = _regular_file(candidate, "publication adapter")
    try:
        adapter.relative_to(pack)
    except ValueError:
        raise PublicationError("publication adapter escapes the planning pack") from None
    spec = importlib.util.spec_from_file_location(
        f"aiur_build_publication_adapter_{id(adapter)}", adapter,
    )
    if spec is None or spec.loader is None:
        raise PublicationError("publication adapter cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise PublicationError(
            f"publication adapter failed to load: {type(exc).__name__}: {exc}"
        ) from None
    if getattr(module, "AIUR_BUILD_PUBLICATION_ADAPTER_VERSION", None) != (
        ADAPTER_PROTOCOL_VERSION
    ):
        raise PublicationError(
            f"publication adapter protocol must equal {ADAPTER_PROTOCOL_VERSION}"
        )
    factory = getattr(module, "publication_extension", None)
    if not callable(factory):
        raise PublicationError("publication adapter must export publication_extension")
    value = factory()
    if not isinstance(value, dict):
        raise PublicationError("publication extension must be an object")
    return value


def load_driver(
    build_path: Path, publication_path: Path,
    approved_sha: str, green_authority_sha: str,
) -> PublicationDriver:
    build = _regular_file(build_path, "build-order manifest")
    publication = _regular_file(publication_path, "publication manifest")
    if build.name != "build-order.json" or publication.name != "publication.json":
        raise PublicationError(
            "canonical manifests must be named build-order.json and publication.json"
        )
    if build.parent != publication.parent:
        raise PublicationError("canonical manifests must share one planning-pack directory")
    extension = _load_extension(build.parent)
    publication_modules = Path(__file__).resolve().parent / "publication"
    if str(publication_modules) not in sys.path:
        sys.path.insert(0, str(publication_modules))
    try:
        from publication_operator import GhClient, Publisher, build_context
        driver = Publisher(
            GhClient(),
            build_context(
                build, publication, approved_sha, green_authority_sha,
                extension,
            ),
        )
    except Exception as exc:
        # Adapter errors may contain useful precondition text but never a
        # traceback or environment dump from this trusted boundary.
        raise PublicationError(str(exc)) from None
    for method in ("dry_run", "apply", "finalize"):
        if not callable(getattr(driver, method, None)):
            raise PublicationError(
                f"publication driver must implement {method}"
            )
    return driver


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--publication", type=Path)
    parser.add_argument("--approved-sha", required=True)
    parser.add_argument("--green-authority-sha", required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--dry-run", action="store_true", help="read-only rehearsal (default)")
    modes.add_argument("--apply", action="store_true", help="publish pending graph evidence")
    modes.add_argument(
        "--finalize", action="store_true",
        help="append and verify one successful receipt comment",
    )
    parser.add_argument("--receipt-commit")
    parser.add_argument("--receipt-url")
    args = parser.parse_args(argv[1:])
    publication = args.publication or args.build.parent / "publication.json"
    try:
        driver = load_driver(
            args.build, publication, args.approved_sha,
            args.green_authority_sha,
        )
        if args.finalize:
            if not args.receipt_commit or not args.receipt_url:
                raise PublicationError(
                    "--finalize requires --receipt-commit and --receipt-url"
                )
            result = driver.finalize(args.receipt_commit, args.receipt_url)
        elif args.apply:
            if args.receipt_commit or args.receipt_url:
                raise PublicationError(
                    "receipt arguments are accepted only with --finalize"
                )
            result = driver.apply()
        else:
            if args.receipt_commit or args.receipt_url:
                raise PublicationError(
                    "receipt arguments are accepted only with --finalize"
                )
            result = driver.dry_run()
        if not isinstance(result, dict):
            raise PublicationError("publication driver result must be an object")
    except PublicationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
