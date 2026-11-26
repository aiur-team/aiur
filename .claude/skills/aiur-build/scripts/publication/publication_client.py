"""GitHub client, request budget and REST helpers for the Build Order publisher."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from typing import Any, Protocol

from publication_live_graph import API_VERSION


TIMEOUT_SECONDS = 30


PAGE_SIZE = 100


MAX_PAGES = 100


MAX_REQUESTS = 2_500


MAX_ITEMS = 50_000


AUTHORITY_CHECKPOINT_MUTATIONS = 16


MATERIALIZATION_TRANSACTION = ".aiur-publication-transaction.json"


class PublicationError(RuntimeError):
    """A fail-closed publication precondition or GitHub operation failed."""


class Client(Protocol):
    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None,
        *, allow_404: bool = False,
    ) -> Any: ...


@dataclass
class Budget:
    requests: int = 0
    items: int = 0

    def request(self) -> None:
        self.requests += 1
        if self.requests > MAX_REQUESTS:
            raise PublicationError("GitHub operation exceeds total request bound")

    def add_items(self, count: int) -> None:
        self.items += count
        if self.items > MAX_ITEMS:
            raise PublicationError("GitHub operation exceeds total item bound")


class GhClient:
    """A github.com-only, version-pinned, timeout-bounded ``gh api`` client."""

    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None,
        *, allow_404: bool = False,
    ) -> Any:
        if not path.startswith("repos/") or "://" in path or path.startswith("/"):
            raise PublicationError("refusing non-repository or non-relative API path")
        command = [
            "gh", "api", "--hostname", "github.com", "--method", method,
            "-H", "Accept: application/vnd.github+json",
            "-H", f"X-GitHub-Api-Version: {API_VERSION}", path,
        ]
        input_text = None
        if payload is not None:
            command.extend(["--input", "-"])
            input_text = json.dumps(payload, separators=(",", ":"))
        try:
            result = subprocess.run(
                command, input=input_text, capture_output=True, text=True,
                check=False, timeout=TIMEOUT_SECONDS,
                env=os.environ.copy(),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PublicationError(
                f"GitHub {method} request failed safely ({type(exc).__name__})"
            ) from None
        if result.returncode:
            if allow_404 and "HTTP 404" in result.stderr:
                return None
            # Never echo stderr: auth helpers and proxies can include secrets.
            raise PublicationError(
                f"GitHub {method} request failed safely (gh exit {result.returncode})"
            )
        if not result.stdout.strip():
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            raise PublicationError("GitHub returned invalid JSON") from None


def pages(publisher, path: str) -> list[Any]:
    output: list[Any] = []
    separator = "&" if "?" in path else "?"
    for page in range(1, MAX_PAGES + 1):
        raw = publisher._get(f"{path}{separator}page={page}")
        if not isinstance(raw, list):
            raise PublicationError("paginated GitHub response must be an array")
        publisher.budget.add_items(len(raw)); output.extend(raw)
        if len(raw) < PAGE_SIZE:
            return output
    raise PublicationError("GitHub pagination exceeds page bound")


def get(publisher, path: str, *, allow_404: bool = False) -> Any:
    publisher.budget.request()
    return publisher.client.request("GET", path, allow_404=allow_404)


def mutate(publisher, method: str, path: str, payload: dict[str, Any]) -> Any:
    if (
        publisher._guard_apply_mutations
        and publisher._apply_mutation_count % AUTHORITY_CHECKPOINT_MUTATIONS == 0
    ):
        publisher._check_authority()
    publisher.budget.request()
    result = publisher.client.request(method, path, payload)
    if publisher._guard_apply_mutations:
        publisher._apply_mutation_count += 1
    return result


def mapping(publisher, raw: dict[str, Any]) -> dict[str, Any]:
    number, node, url = raw.get("number"), raw.get("node_id"), raw.get("html_url")
    expected_url = f"https://github.com/{publisher.context.repository}/issues/{number}"
    if type(number) is not int or not isinstance(node, str) or url != expected_url:
        raise PublicationError("GitHub issue returned invalid canonical mapping")
    return {
        "repository": publisher.context.repository, "number": number,
        "node_id": node, "url": url,
        "_database_id": raw.get("id"),
    }


def receipt_mapping(mapping: dict[str, Any]) -> dict[str, Any]:
    return {
        key: mapping[key]
        for key in ("repository", "number", "node_id", "url")
    }


def database_id(mapping: dict[str, Any]) -> int:
    value = mapping.get("_database_id")
    if type(value) is not int or value < 1:
        raise PublicationError("mapped issue lacks numeric relationship identity")
    return value


def labels(raw: dict[str, Any]) -> list[str]:
    values = raw.get("labels")
    if not isinstance(values, list):
        raise PublicationError("issue labels must be an array")
    labels = [item.get("name") if isinstance(item, dict) else None for item in values]
    if not all(isinstance(item, str) and item for item in labels) or len(labels) != len(set(labels)):
        raise PublicationError("issue labels contain invalid or duplicate names")
    return sorted(labels)
