#!/usr/bin/env bash
# Run after each executor-wait cycle. Emits new decisions and open blockers
# aged at least 15 minutes from the current command snapshot.
set -euo pipefail

: "${AIUR_CMD:?set AIUR_CMD to the aiur CLI path}"
: "${AIUR_DECISIONS_SEEN_FILE:?set AIUR_DECISIONS_SEEN_FILE to a persistent per-run file}"

"$AIUR_CMD" commands --filter open --json | python3 -c '
import datetime as dt
import json
import os
import sys

envelope = json.load(sys.stdin)
captured = dt.datetime.fromisoformat(envelope["snapshot"]["captured_at"].replace("Z", "+00:00"))
seen_path = os.environ["AIUR_DECISIONS_SEEN_FILE"]
try:
    with open(seen_path, encoding="utf-8") as stream:
        seen = set(json.load(stream))
except FileNotFoundError:
    seen = set()
current = set()
alerts = []
for row in envelope["data"]["page"]["decisions"]:
    created = dt.datetime.fromisoformat(row["created_at"].replace("Z", "+00:00"))
    age = max(0, int((captured - created).total_seconds()))
    decision_id = row.get("decision_id") or row.get("id")
    current.add(decision_id)
    is_new = decision_id not in seen
    if row.get("blocking") and (is_new or age >= 15 * 60):
        ticket = (row.get("ticket") or {}).get("identifier", "-")
        age_text = f"{age // 60}m" if age >= 60 else f"{age}s"
        label = "new" if is_new else "open blocker"
        alerts.append(f"decision={decision_id} ticket={ticket} age={age_text} blocking=true status={label}")
with open(seen_path, "w", encoding="utf-8") as stream:
    json.dump(sorted(current), stream)
for alert in alerts:
    print(alert)
'
