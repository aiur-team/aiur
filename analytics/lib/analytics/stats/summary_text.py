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
    elif "survival" in result:
        km = [result["survival"]["groups"][g] for g in groups]
        text += f', Kaplan-Meier median {measurement(km[0]["median"], metric)} to {measurement(km[1]["median"], metric)}'
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
    if "median_not_reached" in result["flags"] and "survival" in result:
        open_rows = sum(g["n_censored"] for g in result["groups"].values())
        total = sum(g["n"] for g in result["survival"]["groups"].values())
        text += f'; median not yet reached ({fmt(open_rows / total * 100)}% still open)'
    text += f'; {result["status"]}, {result["direction"]}'
    text += f'; {sum(result["excluded_counts"].values())} units excluded'
    text += '; flags: ' + (', '.join(result["flags"]) or 'none')
    for annotation in result["analyst_flags"]:
        if annotation["flag"] == "confounded":
            text += f' (analyst: confounded — {annotation["reason"]})'
    power = result.get('power', {})
    needed = power.get('samples_needed_per_group')
    if result['status'] in ('insufficient_data', 'inconclusive') and needed is not None:
        text += f'; need about {needed} per group to detect {fmt(metric["mde"] * 100)}%'
        if power.get('days_needed') is not None:
            text += f' (about {fmt(power["days_needed"])} days at the current rate)'
    return text + '.'
