#!/usr/bin/env python3
"""Read public-repository wake metadata and historical Executor evidence.

No raw message, command, result payload or private repository is emitted.
Counts prove cursor-relative backlog and observed errors, not task completion.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

PUBLIC_REPOS = ('architecture-docs', 'archon', 'aiur')
CUTOFF = '2026-09-26T15:40:00Z'


def blocks(record):
    message = record.get('message', {})
    content = message.get('content', []) if isinstance(message, dict) else []
    return [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []


def audit(state_root, public_project_sessions):
    summary = []
    for repo in PUBLIC_REPOS:
        base = state_root / 'aiur-team' / repo / 'executor'
        journal = base / f'{repo}.executor.wakes.ndjson'
        cursor_file = base / f'{repo}.executor.wakes.cursor.json'
        cursor = json.loads(cursor_file.read_text())['last_seen_wake_id']
        records = [json.loads(line) for line in journal.read_text().splitlines()]
        records = [r for r in records if r['first_seen_at'] <= CUTOFF]
        pending = [r for r in records if r['wake_id'] > cursor]
        summary.append({
            'repo': repo, 'cursor': cursor, 'retained_records_before_cutoff': len(records),
            'above_cursor': len(pending),
            'above_cursor_topics': dict(sorted(Counter(r['topic_class'] for r in pending).items())),
            'journal_sha256': hashlib.sha256(journal.read_bytes()).hexdigest(),
            'cursor_sha256': hashlib.sha256(cursor_file.read_bytes()).hexdigest(),
        })
    limits, notifications, resets, read_results = [], 0, [], []
    for session in sorted(public_project_sessions.glob('*.jsonl')):
        calls = {}
        for line in session.open():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            timestamp = row.get('timestamp', '')
            content = blocks(row)
            if '2026-09-03T19:00' <= timestamp < '2026-09-04T00:00':
                message = row.get('message', {})
                raw = message.get('content', '') if isinstance(message, dict) else ''
                text = raw if isinstance(raw, str) else '\n'.join(b.get('text', '') for b in content)
                if row.get('type') == 'assistant' and "You've hit your session limit" in text:
                    limits.append(timestamp)
                if row.get('type') == 'user' and ('task-notification' in text or 'Background' in text):
                    notifications += 1
                if row.get('type') == 'user' and 'has reset now' in text:
                    resets.append(timestamp)
            for block in content:
                if block.get('type') == 'tool_use' and '2026-09-03T22:49' < timestamp < '2026-09-04T00:10':
                    command = block.get('input', {}).get('command', '')
                    if '.executor.wakes.ndjson' in command:
                        calls[block['id']] = timestamp
                if block.get('type') == 'tool_result' and block.get('tool_use_id') in calls:
                    value = block.get('content', '')
                    text = value if isinstance(value, str) else json.dumps(value)
                    ids = [int(n) for n in re.findall(r'"wake_id"\s*:\s*(\d+)', text)]
                    read_results.append({
                        'call_at': calls[block['tool_use_id']],
                        'successful_tool_result': not block.get('is_error', False),
                        'returned_wake_ids': ids,
                    })
    return {
        'scope': 'Three public repositories only; journal counts clipped by first_seen_at to the historical report cutoff. Cursor files are observed at audit time, not reconstructed historical snapshots.',
        'cutoff': CUTOFF,
        'backlogs': summary,
        'architecture_docs_limit_episode': {
            'assistant_limit_records': len(limits),
            'first_limit_record': min(limits), 'last_limit_record': max(limits),
            'notification_like_user_records': notifications,
            'reset_message_times': resets,
            'limits': 'Record counts do not prove every notification caused a wake or that repeated errors continued until the reset message.',
        },
        'later_wake_read_evidence': read_results,
        'interpretation': 'Above-cursor means not acknowledged through that shared cursor. Returned wake metadata can be observed without advancing it, and neither viewing nor cursor advancement proves the required work was completed.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('local_repo_state_root', type=Path)
    parser.add_argument('public_project_sessions_dir', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.local_repo_state_root, args.public_project_sessions_dir), indent=2))
