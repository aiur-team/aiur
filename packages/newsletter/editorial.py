"""Optional executor input is text, never template code or replacement metrics."""
import json

from assets import icon
from presentation import shown, text

LIST_FIELDS = {"blockers": ("label", "action"), "shipped": ("icon", "label"),
               "bottlenecks": ("problem", "action", "result", "tone")}


def read_notes(path):
    if path is None:
        return {}
    raw = path.read_text()
    if path.suffix.lower() != ".json":
        return {"notes": [part.strip() for part in raw.split("\n\n") if part.strip()]}
    notes = json.loads(raw)
    if not isinstance(notes, dict) or notes.keys() - (LIST_FIELDS.keys() | {"notes"}):
        raise ValueError("notes JSON accepts only blockers, shipped, bottlenecks and notes")
    for key, fields in LIST_FIELDS.items():
        if key in notes and (not isinstance(notes[key], list) or any(
                not isinstance(row, dict) or row.keys() - set(fields) or not all(isinstance(v, str) for v in row.values())
                for row in notes[key])):
            raise ValueError(f"{key} must be a list of text objects with fields {', '.join(fields)}")
    if "notes" in notes and (not isinstance(notes["notes"], list) or not all(isinstance(s, str) for s in notes["notes"])):
        raise ValueError("notes must be a list of paragraphs")
    return notes


def removable(content, kind, priority):
    return f'<div data-trim="{priority}" data-kind="{kind}">{content}</div>'


def blockers(rows):
    if rows is None:
        return '<li>' + shown(None) + '</li>'
    content = ''.join(f'<li data-trim="100" data-kind="blockers"><b>{text(r.get("label"))}</b><span class="arw"></span>'
                      f'<span>{text(r.get("action"))}</span></li>' for r in rows)
    return content + (f'<li class="more editorial-more" data-more="true">+{len(rows) - 5} more</li>' if len(rows) > 5 else '') or '<li>Nothing blocked on you today</li>'


def shipped(rows):
    if rows is None:
        return '<li>' + shown(None) + '</li>'
    return ''.join(f'<li data-trim="70" data-kind="shipped">{icon(r.get("icon"))}<span>{text(r.get("label"))}</span></li>'
                   for r in rows[:6]) or '<li>None reported</li>'


def bottlenecks(rows):
    if rows is None:
        return '<div class="bottleneck-status"><span class="kick">Bottlenecks</span>' + shown(None) + '</div>'
    if not rows:
        return '<div class="bottleneck-status"><span class="kick">Bottlenecks</span><span>None reported</span></div>'
    result = []
    for r in rows[:3]:
        tone = r.get("tone") if r.get("tone") in ("attn", "block", "super", "good") else "attn"
        result.append(f'<div class="bn {tone}" data-trim="80" data-kind="bottlenecks"><h4>{text(r.get("problem"))}</h4>'
                      f'<div class="bl"><span>Action</span><b>{text(r.get("action"))}</b></div>'
                      f'<div class="bl"><span>Result</span><span>{text(r.get("result"))}</span></div></div>')
    return ''.join(result)


def automated_bottlenecks(report):
    if report.get("meta_patterns", {}).get("status") == "unavailable":
        return None
    rows = report.get("bottlenecks")
    if not isinstance(rows, list):
        return None
    result = []
    for row in rows:
        actions = row.get("actions")
        linked = actions if isinstance(actions, list) else []
        action = '; '.join(str(r["action"].get("summary", r["action"].get("action", r["action"].get("reason", "unavailable")))) for r in linked)
        outcomes = '; '.join('; '.join(str(m.get("result", "unavailable")) for m in r["result"])
                             if isinstance(r["result"], list) else str(r["result"]) for r in linked)
        result.append({"problem": row.get("bottleneck"), "action": action or actions,
                       "result": outcomes or "impact not measured"})
    return result
