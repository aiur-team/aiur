#!/usr/bin/env python3
"""Rerun tests with every hardcoded fixture date moved into the past.

A test whose fixture uses a fixed date breaks on its own once the real clock
passes a window the code checks against `DateTime.utc_now()` (#4691). Moving
every `YYYY-MM-DD` literal under src/test back by --days is the same as moving
"now" forward for those comparisons, while fixture-to-fixture and
fixture-to-injected-now comparisons stay unchanged. The process clock is never
touched. The default 35 days keeps weekdays and crosses 24 h, 7 d and 30 d
windows.

Usage: check-test-time-bombs.py [--days N] [TEST_FILE ...]
Runs the given test files (paths relative to src/) that contain a date
literal; with no files, every such *_test.exs. The tree under src/test must be
clean; it is restored with git afterwards.
"""
import argparse
import datetime
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATE = re.compile(r'(?<![0-9])(20[2-3][0-9])-([01][0-9])-([0-3][0-9])(?![0-9])')
# Keeps each `mix test` command line, and the build-gate owner record it becomes, small.
BATCH = 40

# These fail under the shift for reasons unrelated to the real clock: they compare
# fixture dates with data the shift cannot reach (epoch integers, price tables and
# golden files outside src/test, YYYY-MM month keys, API and protocol version
# strings) or with calendar facts that move with the date (DST, weekend pricing
# rules). Each was read and confirmed clock-free in #4691; a new time bomb in one
# of them is missed.
FIXED_DATE_FILES = {
    'test/aiur/agent_tools/mcp_test.exs',
    'test/aiur/analytics_cli_test.exs',
    'test/aiur/build_order/github_graph/provider_failure_test.exs',
    'test/aiur/build_order/index_pages_test.exs',
    'test/aiur/capabilities_wire_test.exs',
    'test/aiur/claude/rate_limit_adapter_test.exs',
    'test/aiur/claude/reset_time_test.exs',
    'test/aiur/claude/telemetry_ingest_test.exs',
    'test/aiur/codex/rate_limit_adapter_test.exs',
    'test/aiur/codex/reset_time_test.exs',
    'test/aiur/codex/usage_limit_test.exs',
    'test/aiur/config/priority_routes_test.exs',
    'test/aiur/events/github_keys_test.exs',
    'test/aiur/experiments/auto/creator_test.exs',
    'test/aiur/experiments/capture_test.exs',
    'test/aiur/experiments/snapshot_test.exs',
    'test/aiur/experiments/sources/common_test.exs',
    'test/aiur/experiments/sources/evaluator_test.exs',
    'test/aiur/github/client_events_test.exs',
    'test/aiur/github/dependencies_api_test.exs',
    'test/aiur/github/issues/blocked_by_test.exs',
    'test/aiur/github/issues/datetime_test.exs',
    'test/aiur/github/transport_test.exs',
    'test/aiur/github_client/auth_and_errors_test.exs',
    'test/aiur/landing_watch/pr_rerun_test.exs',
    'test/aiur/model_discovery_test.exs',
    'test/aiur/muse/meter_probe_test.exs',
    'test/aiur/run_telemetry/dataset_pr_timing_test.exs',
    'test/aiur/run_telemetry/summaries_test.exs',
    'test/aiur/usage/grouped_scopes/grouped_scopes_test.exs',
    'test/aiur/usage/price_table/window_test.exs',
    'test/aiur/usage/price_table_deepseek_test.exs',
    'test/aiur/usage/price_table_test.exs',
    'test/aiur/usage/pricing_test.exs',
    'test/aiur_engine_pre_pr_test.exs',
    'test/aiur_web/build/freshness_test.exs',
    'test/aiur_web/build/now_rows_test.exs',
    'test/aiur_web/build/planned_rows_test.exs',
    'test/aiur_web/live/analytics_live_test.exs',
    'test/aiur_web/operator_control_center/analytics/retained_projection_test.exs',
    'test/mix/tasks/aiur.pricing_window_test.exs',
}


def shift_text(text, days):
    def sub(match):
        try:
            date = datetime.date(int(match[1]), int(match[2]), int(match[3]))
        except ValueError:
            return match[0]
        return (date - datetime.timedelta(days=days)).isoformat()

    return DATE.sub(sub, text)


def tracked_test_files():
    out = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '--', 'src/test'])
    return [ROOT / name for name in out.decode().split('\0') if name]


def shift_tree(days):
    dated = []
    for path in tracked_test_files():
        try:
            text = path.read_text(encoding='utf-8')
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        shifted = shift_text(text, days)
        if shifted != text:
            path.write_text(shifted, encoding='utf-8')
            dated.append(path)
    return dated


def select(requested, dated):
    dated_tests = {str(p.relative_to(ROOT / 'src')) for p in dated if p.name.endswith('_test.exs')}
    # ponytail: a requested file without its own date literal is skipped even if it reads dated support fixtures.
    candidates = requested if requested else sorted(dated_tests)
    return [f for f in candidates if f in dated_tests and f not in FIXED_DATE_FILES]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--days', type=int, default=35)
    parser.add_argument('files', nargs='*')
    args = parser.parse_args()

    dirty = subprocess.run(['git', '-C', str(ROOT), 'status', '--porcelain', '--', 'src/test'],
                           capture_output=True, text=True, check=True).stdout
    if dirty:
        sys.exit('check-test-time-bombs: src/test has uncommitted changes; commit or stash them first')

    try:
        files = select(args.files, shift_tree(args.days))
        if not files:
            print('check-test-time-bombs: no dated test files to run')
            return 0
        print(f'check-test-time-bombs: fixture dates moved {args.days} days back; running {len(files)} files',
              flush=True)
        status = 0
        for start in range(0, len(files), BATCH):
            batch = files[start:start + BATCH]
            status = subprocess.run(['mix', 'test', '--max-cases', '4', *batch], cwd=ROOT / 'src').returncode or status
        if status:
            print(f'::error::tests fail with fixture dates {args.days} days older; a fixed date is compared '
                  'with the real clock. Inject the clock or date the fixture relative to now (#4691).',
                  flush=True)
        return status
    finally:
        subprocess.run(['git', '-C', str(ROOT), 'checkout', '--', 'src/test'], check=True)


if __name__ == '__main__':
    sys.exit(main())
