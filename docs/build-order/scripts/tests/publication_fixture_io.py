"""Temporary planning-pack writer used by publication validator tests."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path


class FixtureBase:
    def __init__(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object],
    ) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.companion_path = self.base / "dashboard-companions.json"
        self.build_path = self.base / "build-order.json"
        self.publication_path = self.base / "publication.json"
        self._write(companion, build, publication_data)

    def _write(
        self, companion: dict[str, object], build: dict[str, object],
        publication_data: dict[str, object],
    ) -> None:
        (self.base / "tickets").mkdir(exist_ok=True)
        for ticket in companion.get("tickets", []):
            if not isinstance(ticket, dict) or not isinstance(ticket.get("id"), str):
                continue
            path = self.base / str(ticket.get("document"))
            path.write_text(_ticket_text(ticket), encoding="utf-8")
        self.companion_path.write_text(json.dumps(companion), encoding="utf-8")
        self.build_path.write_text(json.dumps(build), encoding="utf-8")
        self.publication_path.write_text(json.dumps(publication_data), encoding="utf-8")
        for name, logical_id in (
            ("root-issue.md", "example/repo:build-order-dashboard"),
            ("skill-delivery.md", "SKILL-DELIVERY-001"),
        ):
            (self.base / name).write_text(f"# Test\n\n{logical_id}\n", encoding="utf-8")

    def close(self) -> None:
        self.temp.cleanup()


def _ticket_text(ticket: dict[str, object]) -> str:
    dependencies = ticket.get("depends_on", []) + ticket.get("external_blockers", [])
    dependency_text = ", ".join(dependencies) if dependencies else "none"
    gates = ticket.get("external_gate_ids", [])
    gate_text = f"**External gates:** {', '.join(gates)}\n\n" if gates else ""
    return (
        f"# {ticket['id']} — Test\n\n"
        "**Kind:** executable\n\n"
        f"**Complexity:** {ticket.get('complexity_points')} — Test\n\n"
        f"**Depends on:** {dependency_text}\n\n"
        f"{gate_text}"
        f"**Requirements:** {ticket.get('requirement_ref')}\n\n"
        "**Build Order membership:** none — standalone dashboard companion\n"
    )
