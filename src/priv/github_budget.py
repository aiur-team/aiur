#!/usr/bin/env python3
"""Host-local GitHub request admission broker.

The broker deliberately persists only SHA-256 credential and consumer fingerprints.  A
single SQLite transaction covers every decision so independently started Aiur
nodes and their shell wrappers share the same leases, rate ceiling, stagger,
and cooldowns without a resident daemon or a network service.
"""

import argparse
import json
import os
import secrets
import sqlite3
import sys
import time


POLICY_TTL_MS = 120000


def now_ms():
    return int(time.time() * 1000)


def clamp(value, minimum, maximum):
    return max(minimum, min(int(value), maximum))


def connection(path):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    conn = sqlite3.connect(path, timeout=5, isolation_level=None)
    os.chmod(path, 0o600)
    conn.execute("PRAGMA busy_timeout = 5000")
    # The daemon and up to sixteen agents open this file at once, and the claim
    # check added for #2073 U6 puts every cacheable agent read through it. Under
    # the rollback journal a reader blocks a writer and a writer blocks every
    # reader, so admission latency grows with fleet size for no reason. Best
    # effort: a database on a filesystem that cannot do WAL keeps the default
    # journal and keeps working.
    try:
        conn.execute("PRAGMA journal_mode = WAL")
    except sqlite3.OperationalError:
        pass
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS budgets (
          token_key TEXT PRIMARY KEY,
          cooldown_until_ms INTEGER NOT NULL DEFAULT 0,
          next_admission_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS resource_holds (
          token_key TEXT NOT NULL,
          resource TEXT NOT NULL,
          until_ms INTEGER NOT NULL,
          PRIMARY KEY (token_key, resource)
        );
        CREATE TABLE IF NOT EXISTS leases (
          lease_id TEXT PRIMARY KEY,
          token_key TEXT NOT NULL,
          endpoint_family TEXT NOT NULL,
          expires_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS leases_token_family ON leases(token_key, endpoint_family);
        CREATE TABLE IF NOT EXISTS admissions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          token_key TEXT NOT NULL,
          endpoint_family TEXT NOT NULL,
          admitted_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS admissions_token_time ON admissions(token_key, admitted_at_ms);
        CREATE TABLE IF NOT EXISTS policies (
          token_key TEXT NOT NULL,
          consumer_key TEXT NOT NULL,
          max_inflight INTEGER NOT NULL,
          max_inflight_per_endpoint INTEGER NOT NULL,
          requests_per_minute INTEGER NOT NULL,
          stagger_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL,
          PRIMARY KEY (token_key, consumer_key)
        );
        CREATE INDEX IF NOT EXISTS policies_token_observed ON policies(token_key, observed_at_ms);
        CREATE TABLE IF NOT EXISTS cache_claims (
          token_key TEXT NOT NULL,
          cache_key TEXT NOT NULL,
          lease_id TEXT NOT NULL,
          expires_at_ms INTEGER NOT NULL,
          PRIMARY KEY (token_key, cache_key)
        );
        CREATE INDEX IF NOT EXISTS cache_claims_lease ON cache_claims(lease_id);
        """
    )
    return conn


def cleanup(conn, now):
    conn.execute("DELETE FROM leases WHERE expires_at_ms <= ?", (now,))
    conn.execute("DELETE FROM admissions WHERE admitted_at_ms < ?", (now - 120000,))
    conn.execute("DELETE FROM resource_holds WHERE until_ms <= ?", (now,))
    conn.execute("DELETE FROM policies WHERE observed_at_ms < ?", (now - POLICY_TTL_MS,))
    # A claim outlives its holder only until it expires. A leader killed between
    # taking the claim and publishing its answer must not wedge the followers, so
    # the claim is a lease with a deadline rather than a lock with an owner.
    conn.execute("DELETE FROM cache_claims WHERE expires_at_ms <= ?", (now,))


def acquire(args):
    now = now_ms()
    conn = connection(args.db)

    try:
        conn.execute("BEGIN IMMEDIATE")
        cleanup(conn, now)
        conn.execute(
            "INSERT OR IGNORE INTO budgets(token_key, cooldown_until_ms, next_admission_ms) VALUES (?, 0, 0)",
            (args.token_key,),
        )
        conn.execute(
            "INSERT INTO policies("
            "token_key, consumer_key, max_inflight, max_inflight_per_endpoint, requests_per_minute, stagger_ms, observed_at_ms"
            ") VALUES (?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(token_key, consumer_key) DO UPDATE SET "
            "max_inflight = excluded.max_inflight, "
            "max_inflight_per_endpoint = excluded.max_inflight_per_endpoint, "
            "requests_per_minute = excluded.requests_per_minute, "
            "stagger_ms = excluded.stagger_ms, "
            "observed_at_ms = excluded.observed_at_ms",
            (
                args.token_key,
                args.consumer_key,
                args.max_inflight,
                args.max_inflight_per_endpoint,
                args.requests_per_minute,
                args.stagger_ms,
                now,
            ),
        )
        cooldown, next_admission = conn.execute(
            "SELECT cooldown_until_ms, next_admission_ms FROM budgets WHERE token_key = ?", (args.token_key,)
        ).fetchone()
        if args.resource == "unknown":
            resource_hold = conn.execute(
                "SELECT MAX(until_ms) FROM resource_holds WHERE token_key = ?", (args.token_key,)
            ).fetchone()
        else:
            resource_hold = conn.execute(
                "SELECT until_ms FROM resource_holds WHERE token_key = ? AND resource = ?", (args.token_key, args.resource)
            ).fetchone()
        # SINGLE FLIGHT (#2073 U6). Thirteen agents asking for one pull request in
        # the same moment are thirteen separate processes with nothing between
        # them but this transaction, so this is where they are made into one
        # upstream call. The first to arrive claims the resource and fetches it;
        # the others are told to wait and, because the leader writes its answer to
        # the shared response store before releasing, they find that answer on
        # their next look and never reach GitHub at all.
        #
        # A follower is refused BEFORE any admission accounting: it takes no
        # lease, burns no request-per-minute slot and does not move the stagger.
        # Otherwise twelve followers would still consume the concurrency the
        # coalescing exists to give back.
        cache_key = getattr(args, "cache_key", None)
        cache_claim = None
        if cache_key and not args.cache_ignore_claim:
            cache_claim = conn.execute(
                "SELECT expires_at_ms FROM cache_claims WHERE token_key = ? AND cache_key = ?",
                (args.token_key, cache_key),
            ).fetchone()

        token_hold = 0 if args.ignore_token_cooldown else cooldown
        hold_until = max(token_hold, resource_hold[0] if resource_hold and resource_hold[0] else 0)

        max_inflight, max_inflight_per_endpoint, requests_per_minute, stagger_ms = conn.execute(
            "SELECT MIN(max_inflight), MIN(max_inflight_per_endpoint), "
            "MIN(requests_per_minute), MAX(stagger_ms) FROM policies WHERE token_key = ?",
            (args.token_key,),
        ).fetchone()

        if hold_until > now:
            conn.execute("COMMIT")
            print(f"wait {hold_until - now}")
            return

        # Checked AFTER the cooldown branch above, so a follower waiting behind
        # another agent's identical fetch is never given the claim's short wait in
        # place of the hold's long one. Answered the other way round, a fleet in a
        # rate-limit backoff would re-enter this transaction every ~100 ms per
        # follower — dozens of SQLite writes a second during exactly the incident
        # the backoff exists to quieten.
        if cache_claim and cache_claim[0] > now:
            # Short so the follower notices the leader's answer promptly, and
            # never longer than the claim itself can live.
            conn.execute("COMMIT")
            print(f"wait {jitter_wait(min(100, cache_claim[0] - now))}")
            return

        total = conn.execute("SELECT COUNT(*) FROM leases WHERE token_key = ?", (args.token_key,)).fetchone()[0]
        family = conn.execute(
            "SELECT COUNT(*) FROM leases WHERE token_key = ? AND endpoint_family = ?",
            (args.token_key, args.endpoint_family),
        ).fetchone()[0]
        minute = conn.execute(
            "SELECT COUNT(*) FROM admissions WHERE token_key = ? AND admitted_at_ms > ?",
            (args.token_key, now - 60000),
        ).fetchone()[0]

        if total >= max_inflight or family >= max_inflight_per_endpoint:
            if total >= max_inflight:
                earliest_expiry = conn.execute(
                    "SELECT MIN(expires_at_ms) FROM leases WHERE token_key = ?", (args.token_key,)
                ).fetchone()[0]
            else:
                earliest_expiry = conn.execute(
                    "SELECT MIN(expires_at_ms) FROM leases WHERE token_key = ? AND endpoint_family = ?",
                    (args.token_key, args.endpoint_family),
                ).fetchone()[0]

            base_wait = max(50, earliest_expiry - now if earliest_expiry else 50)
            wait = jitter_wait(min(250, base_wait))
            conn.execute("COMMIT")
            print(f"wait {wait}")
            return

        if minute >= requests_per_minute:
            earliest = conn.execute(
                "SELECT MIN(admitted_at_ms) FROM admissions WHERE token_key = ? AND admitted_at_ms > ?",
                (args.token_key, now - 60000),
            ).fetchone()[0]
            conn.execute("COMMIT")
            print(f"wait {jitter_wait(max(1, earliest + 60000 - now))}")
            return

        if next_admission > now:
            conn.execute("COMMIT")
            print(f"wait {jitter_wait(next_admission - now)}")
            return

        lease_id = secrets.token_hex(16)
        expires_at = now + args.lease_ttl_ms
        stagger = secrets.randbelow(stagger_ms) + 1 if stagger_ms > 0 else 0

        conn.execute(
            "INSERT INTO leases(lease_id, token_key, endpoint_family, expires_at_ms) VALUES (?, ?, ?, ?)",
            (lease_id, args.token_key, args.endpoint_family, expires_at),
        )
        conn.execute(
            "INSERT INTO admissions(token_key, endpoint_family, admitted_at_ms) VALUES (?, ?, ?)",
            (args.token_key, args.endpoint_family, now),
        )
        conn.execute(
            "UPDATE budgets SET next_admission_ms = ? WHERE token_key = ?", (now + stagger, args.token_key)
        )
        if cache_key:
            # `REPLACE` rather than `INSERT`: `--cache-ignore-claim` deliberately
            # overtakes a claim whose leader a follower has already waited out, and
            # that follower becomes the new leader for everybody behind it.
            conn.execute(
                "INSERT OR REPLACE INTO cache_claims(token_key, cache_key, lease_id, expires_at_ms) VALUES (?, ?, ?, ?)",
                (args.token_key, cache_key, lease_id, now + args.cache_claim_ttl_ms),
            )
        conn.execute("COMMIT")
        print(f"granted {lease_id}")
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def jitter_wait(delay_ms):
    return max(1, delay_ms) + secrets.randbelow(26)


def release(args):
    conn = connection(args.db)
    try:
        conn.execute("DELETE FROM leases WHERE lease_id = ?", (args.lease_id,))
        # The claim goes with the lease. The caller releases only after its answer
        # is in the shared response store, so a follower admitted by this release
        # finds the answer rather than paying for it again.
        conn.execute("DELETE FROM cache_claims WHERE lease_id = ?", (args.lease_id,))
    finally:
        conn.close()


def renew(args):
    conn = connection(args.db)
    try:
        conn.execute(
            "UPDATE leases SET expires_at_ms = ? WHERE lease_id = ? AND token_key = ?",
            (now_ms() + args.lease_ttl_ms, args.lease_id, args.token_key),
        )
    finally:
        conn.close()


def hold(args):
    until = now_ms() + args.delay_ms
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            "INSERT OR IGNORE INTO budgets(token_key, cooldown_until_ms, next_admission_ms) VALUES (?, 0, 0)",
            (args.token_key,),
        )

        if args.scope == "token":
            conn.execute(
                "UPDATE budgets SET cooldown_until_ms = MAX(cooldown_until_ms, ?) WHERE token_key = ?",
                (until, args.token_key),
            )
        else:
            conn.execute(
                "INSERT INTO resource_holds(token_key, resource, until_ms) VALUES (?, ?, ?) "
                "ON CONFLICT(token_key, resource) DO UPDATE SET until_ms = MAX(until_ms, excluded.until_ms)",
                (args.token_key, args.resource, until),
            )

        conn.execute("COMMIT")
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def snapshot(args):
    now = now_ms()
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        cleanup(conn, now)
        cooldown = conn.execute(
            "SELECT cooldown_until_ms FROM budgets WHERE token_key = ?", (args.token_key,)
        ).fetchone()
        leases = conn.execute(
            "SELECT endpoint_family, COUNT(*) FROM leases WHERE token_key = ? GROUP BY endpoint_family",
            (args.token_key,),
        ).fetchall()
        admissions = conn.execute(
            "SELECT endpoint_family, admitted_at_ms FROM admissions WHERE token_key = ? ORDER BY id", (args.token_key,)
        ).fetchall()
        conn.execute("COMMIT")
        print(
            json.dumps(
                {
                    "cooldown_until_ms": cooldown[0] if cooldown else 0,
                    "inflight": dict(leases),
                    "admissions": [
                        {"endpoint_family": endpoint_family, "admitted_at_ms": admitted_at_ms}
                        for endpoint_family, admitted_at_ms in admissions
                    ],
                }
            )
        )
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--db", required=True)
    common.add_argument("--token-key", required=True)

    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    acquire_parser = commands.add_parser("acquire", parents=[common])
    acquire_parser.add_argument("--resource", required=True)
    acquire_parser.add_argument("--consumer-key", required=True)
    acquire_parser.add_argument("--ignore-token-cooldown", action="store_true")
    acquire_parser.add_argument("--endpoint-family", required=True)
    acquire_parser.add_argument("--max-inflight", type=lambda value: clamp(value, 1, 100), required=True)
    acquire_parser.add_argument("--max-inflight-per-endpoint", type=lambda value: clamp(value, 1, 100), required=True)
    acquire_parser.add_argument("--requests-per-minute", type=lambda value: clamp(value, 1, 10000), required=True)
    acquire_parser.add_argument("--stagger-ms", type=lambda value: clamp(value, 0, 5000), required=True)
    acquire_parser.add_argument("--lease-ttl-ms", type=lambda value: clamp(value, 1000, 3600000), required=True)
    # Coalescing (#2073 U6). Absent, admission behaves exactly as it did before.
    acquire_parser.add_argument("--cache-key", default=None)
    acquire_parser.add_argument("--cache-claim-ttl-ms", type=lambda value: clamp(value, 1000, 600000), default=35000)
    acquire_parser.add_argument("--cache-ignore-claim", action="store_true")
    acquire_parser.set_defaults(fun=acquire)

    release_parser = commands.add_parser("release", parents=[common])
    release_parser.add_argument("--lease-id", required=True)
    release_parser.set_defaults(fun=release)

    renew_parser = commands.add_parser("renew", parents=[common])
    renew_parser.add_argument("--lease-id", required=True)
    renew_parser.add_argument("--lease-ttl-ms", type=lambda value: clamp(value, 1000, 3600000), required=True)
    renew_parser.set_defaults(fun=renew)

    hold_parser = commands.add_parser("hold", parents=[common])
    hold_parser.add_argument("--scope", choices=("token", "resource"), required=True)
    hold_parser.add_argument("--resource", default="core")
    hold_parser.add_argument("--delay-ms", type=lambda value: clamp(value, 1, 3600000), required=True)
    hold_parser.set_defaults(fun=hold)

    snapshot_parser = commands.add_parser("snapshot", parents=[common])
    snapshot_parser.set_defaults(fun=snapshot)
    return root


def main():
    args = parser().parse_args()

    for attempt in range(6):
        try:
            args.fun(args)
            return
        except sqlite3.OperationalError as error:
            if "locked" not in str(error).lower() or attempt == 5:
                raise
            time.sleep(0.01 * (attempt + 1))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"aiur github budget broker failed: {error}", file=sys.stderr)
        sys.exit(1)
