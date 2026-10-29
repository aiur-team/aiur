"""Escaped, evidence-preserving metric presentations for the v2 template."""
from html import escape
import math

from assets import icon

UNAVAILABLE = "unavailable"
CLASSES = (("feature", "Feature", "accent"), ("test_ci", "Test & CI", "attn"),
           ("tooling", "Tooling", "super"), ("other", "Other", "muted"))


def value(node):
    return node.get("value", UNAVAILABLE) if isinstance(node, dict) else node


def numeric(node):
    node = value(node)
    return node if isinstance(node, (int, float)) and not isinstance(node, bool) and math.isfinite(node) else None


def text(node):
    node = value(node)
    return escape(str(UNAVAILABLE if node is None else node))


def shown(node):
    return '<span class="unav">unavailable</span>' if node is None or value(node) == UNAVAILABLE else text(node)


def trend(node):
    number = numeric(node)
    if number is None:
        return shown(UNAVAILABLE)
    tone = "good" if number >= 0 else "attn"
    return f'<span class="chip {tone}">{number:+.0f} pts vs yesterday</span>'


def bar(parts, total, goal=False):
    total = numeric(total)
    if total is None or any(numeric(n) is None for n, _ in parts):
        return shown(UNAVAILABLE)
    spans = ''.join(f'<span class="seg {tone}" style="width:{max(0, min(100, n / total * 100)) if total else 0:.2f}%"></span>'
                    for n, tone in parts)
    return '<div class="pbar">' + spans + ('<i class="goal" title="95% goal"></i>' if goal else '') + '</div>'


def gauge(node):
    number = numeric(node)
    arc = '' if number is None else (f'<path d="M20 120 A100 100 0 0 1 220 120" pathLength="100" '
                                    f'fill="none" stroke-width="22" stroke="var(--accent)" stroke-dasharray="{max(0, min(100, number))} 100"/>')
    label = '<span class="unav big">unavailable</span>' if number is None else f'{number:.0f}<small>%</small>'
    return ('<div class="gauge"><svg viewBox="0 0 240 140" aria-label="Feature share of merges, goal 95%">'
            '<path d="M20 120 A100 100 0 0 1 220 120" fill="none" stroke-width="22" stroke="var(--surface-3)"/>'
            + arc + '<line x1="201" y1="107" x2="236.5" y2="101.5" stroke="var(--fg)" stroke-width="3"/>'
            '<text x="232" y="139" text-anchor="end" class="gt">goal 95%</text></svg>'
            f'<div class="gnum">{label}</div></div>')


def progress_row(label, row, total=False):
    done, size, today = (numeric(row.get(k)) for k in ("done", "total", "done_in_window"))
    parts = [(max(0, done - today), "accent"), (today, "today")] if done is not None and today is not None else []
    progress = bar(parts, size) if parts else shown(UNAVAILABLE)
    chip = ('<span class="chip paused-pill">paused</span>' if value(row.get("paused")) is True else
            f'<span class="chip good">+{today:g} today</span>' if today is not None and today > 0 else
            '<span class="delta-zero">0 today</span>' if today == 0 else shown(UNAVAILABLE))
    return (f'<div class="frow{" total" if total else ""}{" paused" if value(row.get("paused")) is True else ""}{" long-name" if len(label) > 24 else ""}"><span class="fname">{text(label)}</span>{progress}'
            f'<span class="fnum">{shown(done)}<i>/{shown(size)}</i></span>{chip}</div>')


def metric_row(label, node, total):
    n = numeric(node)
    return (f'<div class="srow">{icon("git-branch")}<span>{text(label)}</span>'
            + (bar([(n, "good")], total) if n is not None else '') + f'<b>{shown(node)}</b></div>')


def observed(node):
    if numeric(node) is not None:
        return True
    return isinstance(node, dict) and any(observed(v) for k, v in node.items() if k != 'sources')


def focus(allocation):
    context = allocation.get("instant_context", {})
    daily = [windows.get("window_24h", {}).get("feature_turn_hours_percent")
             for windows in allocation.get("headline", {}).values()]
    known = any(observed(context.get(k)) for k in ("running_agents", "held_slots", "agent_hours"))
    if not known and not any(observed(metric) for metric in daily):
        return ('<div class="focus unavailable-focus"><span class="kick">Running agents · 95% goal</span>'
                '<div class="pbar"><i class="goal" title="95% goal"></i></div>'
                '<p class="allocation-unavailable">' + shown(None) + '</p></div>')
    counts = context.get("running_by_class", {})
    counts = counts if isinstance(counts, dict) else {}
    classes = [(numeric(counts.get(k)), tone) for k, _, tone in CLASSES]
    result = '<div class="focus"><span class="kick">Running agents · 95% goal</span>'
    result += bar(classes, context.get("running_agents"), goal=True)
    result += ' '.join(f'<span class="lg">{label} {shown(counts.get(k))}</span>' for k, label, _ in CLASSES)
    result += '<p>Held: '
    held = context.get("held_slots")
    result += ('; '.join(text(life) + ' ' + ', '.join(label + ' ' + shown(rows.get(k)) for k, label, _ in CLASSES)
                        for life, rows in held.items()) if isinstance(held, dict) else shown(UNAVAILABLE))
    result += '</p><p>Allocation trend ' + trend(context.get("trend_pp")) + '</p>'
    hours = context.get("agent_hours")
    result += '<p>Agent-hours: ' + (', '.join(text(k) + ' ' + shown(v) for k, v in hours.items())
                                  if isinstance(hours, dict) and "value" not in hours else shown(hours)) + '</p>'
    for machine, windows in allocation.get("headline", {}).items():
        daily = windows.get("window_24h", {})
        result += '<span class="lg">' + text(machine.upper()) + ' 24h turn hour share ' + shown(daily.get("feature_turn_hours_percent")) + '</span>'
    return result + '</div>'


def state_bar(program):
    states = program.get("states")
    if not isinstance(states, dict):
        return shown(None)
    tones = ("accent", "today", "muted", "attn", "super", "block")
    numbers = [numeric(v) for v in states.values()]
    total = sum(numbers) if all(n is not None for n in numbers) else None
    return '<div class="focus">' + bar(list(zip(numbers, tones)), total) + ' '.join(
        f'<span class="lg">{text(k)} {shown(v)}</span>' for k, v in states.items()) + '</div>'


def funnel(outcomes):
    return '<div class="pipeline">' + ''.join(
        '<div class="pipeline-stage"><span class="kick">' + label + '</span><span class="snum">'
        + shown(outcomes.get(key)) + '</span></div>' for label, key in
        (("Merged", "merged"), ("Live", "live"), ("Verified", "finished_verified"))) + '</div>'
