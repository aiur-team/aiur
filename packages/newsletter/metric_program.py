"""Program scope and lane transitions, deduplicated by repository ticket number."""
from metric_values import UNAVAILABLE, available, difference, metric, percent, unique, window

FIELDS = ("program.tickets[].number", "program.tickets[].state", "program.tickets[].state_reason")


def tickets(snapshot):
    if snapshot is None or not available(snapshot, "github_tickets"):
        return None
    return unique(snapshot.get("program", {}).get("tickets"))


def completed(row):
    return row["state"].lower() == "closed" and (row.get("state_reason") or "").lower() == "completed"


def not_planned(row):
    return row["state"].lower() == "closed" and (row.get("state_reason") or "").lower() == "not_planned"


def opened(row):
    return row["state"].lower() == "open"


def shelved(row):
    return (not completed(row) and not not_planned(row)
            and row.get("mobile", False) and row.get("paused", False))


def counts(rows):
    if rows is None:
        return {key: UNAVAILABLE for key in ("total", "done")}
    rows = {n: r for n, r in rows.items() if not not_planned(r)}
    return {"total": len(rows), "done": sum(completed(r) for r in rows.values())}


def transitions(now, before):
    if now is None or before is None:
        return {k: UNAVAILABLE for k in ("completions", "added", "removed", "reopened", "paused", "shelved")}
    shared = now.keys() & before.keys()
    return {
        "completions": sum(opened(before[n]) and completed(now[n]) for n in shared),
        "added": len(now.keys() - before.keys()),
        "removed": len(before.keys() - now.keys()) + sum(
            not_planned(row) and (n not in before or not not_planned(before[n]))
            for n, row in now.items()),
        "reopened": sum(not opened(before[n]) and opened(now[n]) for n in shared),
        "paused": sum(not before[n].get("paused", False) and now[n].get("paused", False) for n in shared),
        "shelved": sum(shelved(row) and (n not in before or not shelved(before[n]))
                       for n, row in now.items())}


def program(snapshot, yesterday):
    now, before = tickets(snapshot), tickets(yesterday)
    current, previous = counts(now), counts(before)
    report = {key: metric(value, *FIELDS) for key, value in current.items()}
    report["yesterday"] = {key: metric(value, *("yesterday." + f for f in FIELDS))
                           for key, value in previous.items()}
    report["delta"] = {key: metric(difference(value, previous[key]), *FIELDS,
                                  *("yesterday." + f for f in FIELDS)) for key, value in current.items()}
    report["scope"] = {key: metric(value, *FIELDS, "program.tickets[].paused", "program.tickets[].mobile",
                                  "yesterday.program.tickets") for key, value in transitions(now, before).items()}
    report["done_in_window"] = metric(sum(completed(r) and r.get("closed_at") is not None and window(snapshot, r["closed_at"])
                                         for r in now.values()) if now is not None else UNAVAILABLE, *FIELDS,
                                     "program.tickets[].closed_at", "window_start", "window_end")
    report["states"] = state_counts(now)
    report["lanes"] = lanes(snapshot, now, before)
    return report


def lanes(snapshot, now, before):
    if now is None:
        return UNAVAILABLE
    names = sorted({r["lane"] for r in now.values() if r.get("lane")})
    result = {}
    for name in names:
        rows = {n: r for n, r in now.items() if r.get("lane") == name}
        old = None if before is None else {n: r for n, r in before.items() if r.get("lane") == name}
        current, previous = counts(rows), counts(old)
        fields = (*FIELDS, "program.tickets[].lane", "program.tickets[].closed_at", "window_start", "window_end")
        done = sum(completed(r) and r.get("closed_at") is not None and window(snapshot, r["closed_at"])
                   for r in rows.values())
        reached = UNAVAILABLE if old is None else bool(
            current["done"] == current["total"] and previous["done"] < previous["total"])
        result[name] = {**{k: metric(v, *fields) for k, v in current.items()},
                        "done_in_window": metric(done, *fields),
                        "percent": metric(percent(current["done"], current["total"]), *fields),
                        "finished": metric(reached, *fields, "yesterday.program.tickets"),
                        "paused": metric(bool(rows) and all(r.get("paused", False) for r in rows.values()),
                                         *fields, "program.tickets[].paused")}
    return result


def state_counts(rows):
    if rows is None:
        return UNAVAILABLE
    result = dict.fromkeys(("done", "active", "todo", "paused", "shelved", "removed"), 0)
    for row in rows.values():
        if not_planned(row):
            state = "removed"
        elif completed(row):
            state = "done"
        elif row.get("paused"):
            state = "shelved" if row.get("mobile") else "paused"
        elif row.get("lifecycle") in ("running", "allocated", "waiting", "retrying") or any(
                label.split(':')[-1] in ("in-progress", "ci-wait", "human-review", "rework", "merging")
                for label in row.get("labels", [])):
            state = "active"
        else:
            state = "todo"
        result[state] += 1
    return {key: metric(value, *FIELDS, "program.tickets[].labels", "program.tickets[].lifecycle",
                        "program.tickets[].paused", "program.tickets[].mobile") for key, value in result.items()}
