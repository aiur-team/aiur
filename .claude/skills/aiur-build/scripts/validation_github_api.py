"""Pinned, bounded GitHub API reads for publication authority."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


GITHUB_API_VERSION = "2026-03-10"
GITHUB_TIMEOUT_SECONDS = 60


class GitHubApiError(RuntimeError):
    """A read-only GitHub API request could not produce trustworthy JSON."""


class GhApiClient:
    """Issue explicit authenticated GET requests to the public GitHub host."""

    def __init__(self, cwd: Path, executable: str = "gh") -> None:
        self.cwd = cwd
        self.executable = executable

    def get(self, endpoint: str, *, allow_404: bool = False) -> object | None:
        try:
            result = subprocess.run(
                [
                    self.executable,
                    "api",
                    "--hostname", "github.com",
                    "-H", "Accept: application/vnd.github+json",
                    "-H", f"X-GitHub-Api-Version: {GITHUB_API_VERSION}",
                    "--method", "GET",
                    endpoint,
                ],
                cwd=self.cwd,
                check=False,
                capture_output=True,
                text=True,
                timeout=GITHUB_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise GitHubApiError(
                f"GitHub query failed for {endpoint}: {exc}"
            ) from exc
        if result.returncode:
            if allow_404 and "HTTP 404" in result.stderr:
                return None
            detail = result.stderr.strip() or f"exit {result.returncode}"
            raise GitHubApiError(f"GitHub query failed for {endpoint}: {detail}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise GitHubApiError(
                f"GitHub query returned invalid JSON for {endpoint}: {exc}"
            ) from exc
