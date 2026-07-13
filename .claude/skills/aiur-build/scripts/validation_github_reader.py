"""Bounded authenticated GitHub reads shared by both receipt snapshots."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from validation_github_api import GhApiClient, GitHubApiError


MAX_PAGES = 100
PAGE_SIZE = 100
MAX_ITEMS = 10_000
MAX_TOTAL_REQUESTS = 2_500
MAX_TOTAL_ITEMS = 50_000


class LiveGitHubError(RuntimeError):
    """A read-only GitHub query could not produce trustworthy JSON."""


class GitHubReader(Protocol):
    def repository_issues(self, repository: str) -> list[dict[str, Any]]: ...

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]: ...

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]: ...

    def parent(self, repository: str, number: int) -> dict[str, Any] | None: ...


@dataclass
class QueryBudget:
    requests_remaining: int = MAX_TOTAL_REQUESTS
    items_remaining: int = MAX_TOTAL_ITEMS

    def consume_request(self) -> None:
        if self.requests_remaining <= 0:
            raise LiveGitHubError("GitHub verification exceeds total request bound")
        self.requests_remaining -= 1

    def consume_items(self, count: int) -> None:
        if count > self.items_remaining:
            raise LiveGitHubError("GitHub verification exceeds total item bound")
        self.items_remaining -= count


class GhApiReader:
    """Read one publication graph through a shared finite query budget."""

    def __init__(
        self, cwd: Path, executable: str = "gh",
        budget: QueryBudget | None = None,
    ) -> None:
        self.api = GhApiClient(cwd, executable)
        self.budget = budget or QueryBudget()

    def repository_issues(self, repository: str) -> list[dict[str, Any]]:
        return self._paged(f"repos/{repository}/issues?state=all&per_page=100")

    def subissues(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._paged(
            f"repos/{repository}/issues/{number}/sub_issues?per_page=100"
        )

    def blockers(self, repository: str, number: int) -> list[dict[str, Any]]:
        return self._paged(
            f"repos/{repository}/issues/{number}/dependencies/blocked_by?per_page=100"
        )

    def parent(self, repository: str, number: int) -> dict[str, Any] | None:
        return self._one(
            f"repos/{repository}/issues/{number}/parent", allow_404=True,
        )

    def _paged(self, endpoint: str) -> list[dict[str, Any]]:
        separator = "&" if "?" in endpoint else "?"
        items: list[dict[str, Any]] = []
        for page_number in range(1, MAX_PAGES + 1):
            page = self._json(f"{endpoint}{separator}page={page_number}")
            if not isinstance(page, list):
                raise LiveGitHubError(
                    f"GitHub paginated query returned an invalid page for {endpoint}"
                )
            if len(page) > PAGE_SIZE or len(items) + len(page) > MAX_ITEMS:
                raise LiveGitHubError(
                    f"GitHub query exceeds item verification bound: {endpoint}"
                )
            if any(not isinstance(item, dict) for item in page):
                raise LiveGitHubError(
                    f"GitHub paginated query contains a malformed item for {endpoint}"
                )
            self.budget.consume_items(len(page))
            items.extend(page)
            if len(page) < PAGE_SIZE:
                return items
        raise LiveGitHubError(
            f"GitHub query reaches the {MAX_PAGES}-page verification ceiling: {endpoint}"
        )

    def _one(self, endpoint: str, *, allow_404: bool = False) -> dict[str, Any] | None:
        value = self._json(endpoint, allow_404=allow_404)
        if value is None:
            return None
        if not isinstance(value, dict):
            raise LiveGitHubError(f"GitHub query returned an invalid object for {endpoint}")
        self.budget.consume_items(1)
        return value

    def _json(self, endpoint: str, *, allow_404: bool = False) -> object | None:
        self.budget.consume_request()
        try:
            return self.api.get(endpoint, allow_404=allow_404)
        except GitHubApiError as exc:
            raise LiveGitHubError(str(exc)) from exc
