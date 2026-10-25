"""Attach prospective power and accrual projections to driver results."""

from datetime import timedelta

from .inputs import timestamp
from .power import estimate
from .rng import seed_from


def attach(result, metric, groups, settings, snapshot, spec, snapshot_hash):
    a, b = groups
    seed = seed_from(snapshot.get('experiment_id', spec.get('id')), metric['id'],
                     'pooled', snapshot_hash, 'power')
    baseline = [] if metric['kind'] in ('binary', 'rate') else metric['values'][a]
    power = estimate(baseline, metric['values'][b], metric['mde'], seed,
                     alpha=settings['alpha'], target=settings['power_target'],
                     higher=metric['direction'] in ('higher_is_better', 'increase'),
                     primary=metric['primary'])
    if metric['kind'] in ('binary', 'rate'):
        power['reason'] = 'empirical MWU power is unavailable for binary and aggregate rate tests'
    power['baseline_group'] = a
    result['power'] = power
    flags = result['flags']
    if not metric['primary'] or 'strata_rows' in metric:
        flags.append('power_estimate_approximate')
    if any(metric['censored'].values()):
        flags.append('power_ignores_censoring')
    current = power['power_at_current_n']
    if current is not None and current < settings['power_target']:
        flags.append('underpowered')
    _eta(power, len(metric['values'][b]), len(baseline), snapshot, spec, b)
    result['flags'] = sorted(set(flags))


def _eta(power, current, baseline_n, snapshot, spec, group):
    needed = power['samples_needed_per_group']
    taken = snapshot.get('taken_at')
    window = spec.get('windows', {}).get(group, spec.get('windows', {}).get('observation', {}))
    if not isinstance(needed, int) or not current or not taken or not window.get('start'):
        return
    taken = timestamp(taken)
    elapsed = (taken - timestamp(window['start'])).total_seconds() / 86400
    if elapsed < 1:
        return
    required = (needed * current + baseline_n - 1) // baseline_n
    days = max(0, required - current) / (current / elapsed)
    power.update(eta_date=(taken + timedelta(days=days)).date().isoformat(),
                 days_needed=days, accrual_per_day=current / elapsed)
