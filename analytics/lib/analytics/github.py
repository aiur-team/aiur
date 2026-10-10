"""GitHub PR anchor fields shared by offline record normalization."""


def anchor_fields(event: dict) -> tuple[str, str | None, str | None]:
    topic = event.get("topic", "")
    parts = topic.split(".", 2)
    ticket = parts[1] if len(parts) == 3 and parts[0] == "ticket" else None
    kind = parts[2] if ticket else topic
    timestamp = event.get("timestamp")
    pr = event.get("pr") or {}
    if kind == "pr.opened":
        timestamp = pr.get("created_at") or timestamp
    elif kind == "pr.merged":
        timestamp = pr.get("merged_at") or pr.get("closed_at") or timestamp
    return kind, timestamp, ticket
