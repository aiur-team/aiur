"""Numeric summaries for fixed-vocabulary experiment labels."""


def fmt(value):
    return "undefined" if value is None else format(value, ".10g")


def measurement(value, metric):
    unit = metric.get("unit", "")
    if value is None:
        return "undefined"
    if metric["kind"] == "duration" and unit in ("h", "min", "s", "ms"):
        hours = value * {"h": 1, "min": 1 / 60, "s": 1 / 3600, "ms": 1 / 3_600_000}[unit]
        if abs(hours) < 1:
            return f"{fmt(hours * 60)} min"
        if abs(hours) > 48:
            return f"{fmt(hours / 24)} days"
        return f"{fmt(hours)} h"
    return f"{fmt(value)} {unit}".rstrip()


def summarize(result, metric, groups):
    a, b = (result["groups"][g] for g in groups)
    text = f'{metric.get("label", metric["id"])}: n {a["n"]} vs {b["n"]}'
    if metric["kind"] == "rate":
        text += f', rates {fmt(a["rate"])} to {fmt(b["rate"])}'
    else:
        text += f', median {measurement(a.get("median"), metric)} to {measurement(b.get("median"), metric)}'
    if result["status"] != "insufficient_data" and result.get("primary_effect"):
        effect = result["effects"][result["primary_effect"]]
        text += (f', {result["primary_effect"]} {fmt(effect["estimate"])}, '
                 f'95% CI [{fmt(effect["lo"])}, {fmt(effect["hi"])}], '
                 f'p {fmt(result["p_raw"])} ({result["adjustment"]} {fmt(result["p_adj"])})')
    if result["status"] != "insufficient_data" and not result.get("primary_effect"):
        text += f', effect unavailable, p {fmt(result["p_raw"])} ({result["adjustment"]} {fmt(result["p_adj"])})'
    if "composition_shift" in result["flags"]:
        text += ', stratum mix changed; ' + ('standardized effect shown' if result.get("primary_effect") else 'standardized effect unavailable')
    text += f'; {result["status"]}, {result["direction"]}'
    text += f'; {sum(result["excluded_counts"].values())} units excluded'
    text += '; flags: ' + (', '.join(result["flags"]) or 'none')
    for annotation in result["analyst_flags"]:
        if annotation["flag"] == "confounded":
            text += f' (analyst: confounded — {annotation["reason"]})'
    return text + '.'
