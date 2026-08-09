"""GitHub issue-body size policy shared by planning and publication."""

from __future__ import annotations

from collections.abc import Mapping


MAX_ISSUE_BODY_CHARACTERS = 65_536


def oversized_bodies(
    bodies: Mapping[str, str],
) -> list[tuple[str, int, int]]:
    """Return logical IDs, lengths, and overages for bodies above GitHub's cap."""
    return sorted(
        (
            logical_id,
            len(body),
            len(body) - MAX_ISSUE_BODY_CHARACTERS,
        )
        for logical_id, body in bodies.items()
        if len(body) > MAX_ISSUE_BODY_CHARACTERS
    )


def format_body_limit_error(
    bodies: Mapping[str, str],
) -> str | None:
    """Format the actionable batch error, or return ``None`` when all fit."""
    offenders = oversized_bodies(bodies)
    if not offenders:
        return None
    lines = [
        f"{len(offenders)} members exceed GitHub's "
        f"{MAX_ISSUE_BODY_CHARACTERS:,}-character issue body limit"
    ]
    lines.extend(
        f"  {logical_id}  {length:,} (+{overage:,})"
        for logical_id, length, overage in offenders
    )
    return "\n".join(lines)
