#!/usr/bin/env python3
"""Host-local GitHub request admission broker.

The broker deliberately persists only SHA-256 credential and consumer fingerprints. A
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


# Per-actor hourly usage is read from `admissions`, so an admission must stay
# visible for the whole rolling-hour window it is counted in. The same window
# also keeps a consumer's policy row (label + hourly ceilings) alive for as
# long as its usage is reportable, so `usage` can name limits and reset times
# for an actor whose last request was minutes ago.
ADMISSIONS_RETENTION_MS = 3600000
HOURLY_WINDOW_MS = 3600000
# The concurrency/rate reconcile deliberately reads only recently-observed
# policy rows (the pre-#2181 2-minute window): a consumer that went idle must
# not keep its old max_inflight constraining the fleet for the whole hour that
# the usage report now retains it for.
POLICY_RECONCILE_WINDOW_MS = 120000
# A shared *resource* hold below this duration is reported as an in-guard
# `wait <ms>` (sleep-and-retry) rather than the typed `hold shared <resource>
# <until>` response that aborts the command and pauses the agent's whole turn.
# A token-wide secondary-rate-limit cooldown (default 60 seconds) always keeps
# sleeping inside the guard, exactly as it did before typed holds existed; only
# a real resource hold long enough to warrant a pause is surfaced to the agent.
SHARED_HOLD_MIN_MS = 10000


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
    # The daemon and up to sixteen agents open this file at once, and the claim
    # check added for #2073 U6 puts every cacheable agent read through it. Under
    # the rollback journal a reader blocks a writer and a writer blocks every
    # reader, so admission latency grows with fleet size for no reason.
    #
    # Attempted with NO busy timeout, and before the real one is installed.
    # Converting the journal takes a brief exclusive lock, so against a database
    # somebody else is holding this would otherwise wait the full timeout on
    # every single open — and the orchestrator, whose whole request deadline is
    # shorter than that, would be stranded by a lock it is not even contending
    # for. Failing instantly is the correct answer: the journal mode is a
    # throughput preference, and a database already open elsewhere either is
    # already in WAL or will be converted by whoever opens it uncontended.
    try:
        conn.execute("PRAGMA journal_mode = WAL")
    except sqlite3.DatabaseError:
        pass
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS budgets (
          token_key TEXT PRIMARY KEY,
          cooldown_until_ms INTEGER NOT NULL DEFAULT 0,
          next_admission_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS credential_bindings (
          identity_key TEXT PRIMARY KEY,
          token_key TEXT NOT NULL UNIQUE
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
          consumer_key TEXT NOT NULL DEFAULT '',
          lease_id TEXT,
          endpoint_family TEXT NOT NULL,
          admitted_at_ms INTEGER NOT NULL,
          billable INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS admissions_token_time ON admissions(token_key, admitted_at_ms);
        CREATE TABLE IF NOT EXISTS policies (
          token_key TEXT NOT NULL,
          consumer_key TEXT NOT NULL,
          consumer_label TEXT NOT NULL DEFAULT '',
          max_inflight INTEGER NOT NULL,
          max_inflight_per_endpoint INTEGER NOT NULL,
          requests_per_minute INTEGER NOT NULL,
          stagger_ms INTEGER NOT NULL,
          core_limit_per_hour INTEGER NOT NULL DEFAULT 0,
          graphql_limit_per_hour INTEGER NOT NULL DEFAULT 0,
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
    migrate(conn)
    return conn


# `CREATE TABLE IF NOT EXISTS` does not add columns to a table that predates
# them. Existing broker databases were created without the per-actor columns, so
# they must be migrated in place; a duplicate-column error is the normal "already
# migrated" outcome and is ignored.
def migrate(conn):
    admissions_columns = {row[1] for row in conn.execute("PRAGMA table_info(admissions)").fetchall()}
    if "consumer_key" not in admissions_columns:
        conn.execute("ALTER TABLE admissions ADD COLUMN consumer_key TEXT NOT NULL DEFAULT ''")
    if "lease_id" not in admissions_columns:
        conn.execute("ALTER TABLE admissions ADD COLUMN lease_id TEXT")
    if "billable" not in admissions_columns:
        conn.execute("ALTER TABLE admissions ADD COLUMN billable INTEGER NOT NULL DEFAULT 1")
    # The per-actor hourly query filters by (token, consumer, time), so the
    # column gets its own index. It cannot live in the CREATE TABLE script
    # above: on a pre-#2181 database the table predates the column and the index
    # would fail before migration ran. Creating it here covers both fresh and
    # migrated databases.
    conn.execute(
        "CREATE INDEX IF NOT EXISTS admissions_consumer_time ON admissions(token_key, consumer_key, admitted_at_ms)"
    )
    conn.execute("CREATE INDEX IF NOT EXISTS admissions_token_lease ON admissions(token_key, lease_id)")

    policies_columns = {row[1] for row in conn.execute("PRAGMA table_info(policies)").fetchall()}
    if "consumer_label" not in policies_columns:
        conn.execute("ALTER TABLE policies ADD COLUMN consumer_label TEXT NOT NULL DEFAULT ''")
    if "core_limit_per_hour" not in policies_columns:
        conn.execute("ALTER TABLE policies ADD COLUMN core_limit_per_hour INTEGER NOT NULL DEFAULT 0")
    if "graphql_limit_per_hour" not in policies_columns:
        conn.execute("ALTER TABLE policies ADD COLUMN graphql_limit_per_hour INTEGER NOT NULL DEFAULT 0")


def cleanup(conn, now):
    conn.execute("DELETE FROM leases WHERE expires_at_ms <= ?", (now,))
    # Admissions feed both the requests-per-minute throttle and per-actor hourly
    # usage. A two-minute retention was fine for the throttle; the hourly ceiling
    # needs the whole window, so the retention is now the window itself.
    conn.execute("DELETE FROM admissions WHERE admitted_at_ms < ?", (now - ADMISSIONS_RETENTION_MS,))
    conn.execute("DELETE FROM resource_holds WHERE until_ms <= ?", (now,))
    # Policy rows carry the consumer label and hourly ceilings the usage report
    # reads, so they are retained for the same window as the admissions they
    # describe. The concurrency reconcile takes MIN(max_inflight) and
    # MAX(stagger_ms), both conservative directions, so a policy row a few
    # minutes stale cannot loosen a ceiling.
    conn.execute("DELETE FROM policies WHERE observed_at_ms < ?", (now - ADMISSIONS_RETENTION_MS,))
    # A claim outlives its holder only until it expires. A leader killed between
    # taking the claim and publishing its answer must not wedge the followers, so
    # the claim is a lease with a deadline rather than a lock with an owner.
    conn.execute("DELETE FROM cache_claims WHERE expires_at_ms <= ?", (now,))


def resolve_credential_identity(conn, args):
    """Resolve a stable identity to compatibility storage under one transaction.

    The first stable identity to present a token adopts that token's existing
    ledger. A later rotation resolves back to the adopted key. If two configured
    credentials present the same token, only the first may adopt its hash; the
    second uses its distinct stable key and remains isolated.
    """
    identity_key = getattr(args, "identity_key", None)
    if not identity_key:
        return

    binding = conn.execute(
        "SELECT token_key FROM credential_bindings WHERE identity_key = ?", (identity_key,)
    ).fetchone()
    if binding:
        args.token_key = binding[0]
        return

    claimed = conn.execute(
        "SELECT identity_key FROM credential_bindings WHERE token_key = ?", (args.token_key,)
    ).fetchone()
    storage_key = identity_key if claimed else args.token_key
    conn.execute(
        "INSERT INTO credential_bindings(identity_key, token_key) VALUES (?, ?)",
        (identity_key, storage_key),
    )
    args.token_key = storage_key


# The rolling-hour billable responses of one actor and one resource, oldest
# first. Core is every REST family; GraphQL is the graphql family. A `resource`
# ceiling is a request-count ceiling: the broker sees admissions, never the
# GraphQL point price GitHub charged, so this is the coarsest thing that still
# stops one actor from exhausting the shared hourly budget. A reconciled 304 is
# not billable, so it stays in the admissions ledger for RPM accounting but is
# excluded here.
def actor_usage_rows(conn, token_key, consumer_key, resource, now):
    if resource == "graphql":
        family_clause = "endpoint_family = ?"
        family_value = "graphql"
    else:
        family_clause = "endpoint_family != ?"
        family_value = "graphql"
    return conn.execute(
        "SELECT admitted_at_ms FROM admissions "
        "WHERE token_key = ? AND consumer_key = ? AND billable = 1 AND admitted_at_ms > ? AND "
        + family_clause
        + " ORDER BY admitted_at_ms ASC",
        (token_key, consumer_key, now - HOURLY_WINDOW_MS, family_value),
    ).fetchall()


def actor_ceiling_hold(conn, args, now):
    limit = args.graphql_limit if args.resource == "graphql" else args.core_limit
    if not limit or limit <= 0:
        return 0

    rows = actor_usage_rows(conn, args.token_key, args.consumer_key, args.resource, now)
    used = len(rows)
    if used < limit:
        return 0
    # The newest `limit` admissions may stay; the (used - limit + 1)-th oldest
    # admission is the one that must age out before this actor may be admitted
    # again, and it does so exactly one hour after it was admitted.
    index = used - limit
    return max(rows[index][0] + HOURLY_WINDOW_MS - now, 1)


def acquire(args):
    now = now_ms()
    conn = connection(args.db)

    try:
        conn.execute("BEGIN IMMEDIATE")
        resolve_credential_identity(conn, args)
        cleanup(conn, now)
        conn.execute(
            "INSERT OR IGNORE INTO budgets(token_key, cooldown_until_ms, next_admission_ms) VALUES (?, 0, 0)",
            (args.token_key,),
        )
        conn.execute(
            "INSERT INTO policies("
            "token_key, consumer_key, consumer_label, max_inflight, max_inflight_per_endpoint, requests_per_minute, stagger_ms, "
            "core_limit_per_hour, graphql_limit_per_hour, observed_at_ms"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(token_key, consumer_key) DO UPDATE SET "
            "consumer_label = excluded.consumer_label, "
            "max_inflight = excluded.max_inflight, "
            "max_inflight_per_endpoint = excluded.max_inflight_per_endpoint, "
            "requests_per_minute = excluded.requests_per_minute, "
            "stagger_ms = excluded.stagger_ms, "
            "core_limit_per_hour = excluded.core_limit_per_hour, "
            "graphql_limit_per_hour = excluded.graphql_limit_per_hour, "
            "observed_at_ms = excluded.observed_at_ms",
            (
                args.token_key,
                args.consumer_key,
                args.consumer_label,
                args.max_inflight,
                args.max_inflight_per_endpoint,
                args.requests_per_minute,
                args.stagger_ms,
                args.core_limit,
                args.graphql_limit,
                now,
            ),
        )
        cooldown, next_admission = conn.execute(
            "SELECT cooldown_until_ms, next_admission_ms FROM budgets WHERE token_key = ?", (args.token_key,)
        ).fetchone()
        if args.resource == "unknown":
            resource_hold = conn.execute(
                "SELECT resource, until_ms FROM resource_holds WHERE token_key = ? ORDER BY until_ms DESC LIMIT 1",
                (args.token_key,),
            ).fetchone()
        else:
            resource_hold = conn.execute(
                "SELECT resource, until_ms FROM resource_holds WHERE token_key = ? AND resource = ?", (args.token_key, args.resource)
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
        hold_until = max(token_hold, resource_hold[1] if resource_hold and resource_hold[1] else 0)

        max_inflight, max_inflight_per_endpoint, requests_per_minute, stagger_ms = conn.execute(
            "SELECT MIN(max_inflight), MIN(max_inflight_per_endpoint), "
            "MIN(requests_per_minute), MAX(stagger_ms) FROM policies WHERE token_key = ? "
            "AND observed_at_ms > ?",
            (args.token_key, now - POLICY_RECONCILE_WINDOW_MS),
        ).fetchone()

        if hold_until > now:
            conn.execute("COMMIT")
            remaining = hold_until - now
            # Only a *resource* hold surfaces as the typed `hold shared
            # <resource> <until>` that aborts the command and pauses the agent's
            # whole turn. `hold_until` is the max of the token cooldown and the
            # resource hold, so the hold is resource-driven only when the
            # resource hold is the longer-lived one. A token-wide cooldown — the
            # routine secondary-rate-limit backoff the guard has always absorbed
            # by sleeping, default 60 seconds — keeps sleeping inside the guard
            # regardless of duration, exactly as it did before typed holds
            # existed.
            resource_driven = resource_hold is not None and resource_hold[1] == hold_until
            if resource_driven and remaining >= SHARED_HOLD_MIN_MS:
                hold_resource = resource_hold[0]
                if hold_resource == "unknown":
                    # Defensive fallback: the resource_holds table only ever
                    # stores concrete resource names, but never pause on a
                    # bucket we cannot name.
                    hold_resource = "core"
                print(f"hold shared {hold_resource} {hold_until}")
            else:
                # A token-wide cooldown, or a resource hold too short to
                # warrant a pause, is absorbed in the guard's sleep-and-retry
                # loop instead of aborting the command and pausing the turn.
                print(f"wait {remaining}")
            return

        # Per-actor hourly ceiling (#2181). An actor — the daemon, or one agent
        # workspace — that has consumed its configured Core or GraphQL ceiling for
        # this hour is held until its usage rolls back under the ceiling, and only
        # that actor is held: it shares the token's cooldown and resource holds but
        # has its own budget, so an exhausted agent cannot 429 the daemon or the
        # other agents. 0 disables the ceiling. Printed `wait actor <ms>` so the
        # Elixir side can name the reason (actor budget rather than the shared
        # budget) on the hold it returns.
        actor_hold = actor_ceiling_hold(conn, args, now)
        if actor_hold > 0:
            conn.execute("COMMIT")
            print(f"wait actor {actor_hold}")
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
            "INSERT INTO admissions(token_key, consumer_key, lease_id, endpoint_family, admitted_at_ms) VALUES (?, ?, ?, ?, ?)",
            (args.token_key, args.consumer_key, lease_id, args.endpoint_family, now),
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


# Reconciliation is keyed on the *adopted* storage key, not the raw token hash
# the caller presented. An admission was written under the adopted key, so a
# credential that rotated between admission and reconciliation would otherwise
# look for its own admission under a key that never held it and silently leave
# the `304` billable. Resolving inside the transaction is what makes this
# rotation-safe, and re-running it is a no-op because `billable = 1` is part of
# the predicate.
def reconcile(args):
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        resolve_credential_identity(conn, args)
        if args.status == 304:
            conn.execute(
                "UPDATE admissions SET billable = 0 WHERE token_key = ? AND lease_id = ? AND billable = 1",
                (args.token_key, args.lease_id),
            )
        conn.execute("COMMIT")
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def renew(args):
    conn = connection(args.db)
    try:
        conn.execute(
            "UPDATE leases SET expires_at_ms = ? WHERE lease_id = ?",
            (now_ms() + args.lease_ttl_ms, args.lease_id),
        )
    finally:
        conn.close()


def hold(args):
    until = now_ms() + args.delay_ms
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        resolve_credential_identity(conn, args)
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
        resolve_credential_identity(conn, args)
        cleanup(conn, now)
        cooldown = conn.execute(
            "SELECT cooldown_until_ms FROM budgets WHERE token_key = ?", (args.token_key,)
        ).fetchone()
        leases = conn.execute(
            "SELECT endpoint_family, COUNT(*) FROM leases WHERE token_key = ? GROUP BY endpoint_family",
            (args.token_key,),
        ).fetchall()
        admissions = conn.execute(
            "SELECT endpoint_family, admitted_at_ms, billable FROM admissions WHERE token_key = ? ORDER BY id", (args.token_key,)
        ).fetchall()
        conn.execute("COMMIT")
        print(
            json.dumps(
                {
                    "cooldown_until_ms": cooldown[0] if cooldown else 0,
                    "inflight": dict(leases),
                    "admissions": [
                        {"endpoint_family": endpoint_family, "admitted_at_ms": admitted_at_ms, "billable": bool(billable)}
                        for endpoint_family, admitted_at_ms, billable in admissions
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


def usage_figure(conn, token_key, consumer_key, resource, limit, now):
    rows = actor_usage_rows(conn, token_key, consumer_key, resource, now)
    used = len(rows)
    limit = limit or 0
    if used == 0:
        reset_at_ms = None
    elif limit and used > limit:
        # Over the ceiling: the moment the actor may be admitted again is the
        # same instant the broker would release its hold.
        reset_at_ms = rows[used - limit][0] + HOURLY_WINDOW_MS
    else:
        # Under the ceiling: the rolling hour begins to age out when its oldest
        # admission leaves the window.
        reset_at_ms = rows[0][0] + HOURLY_WINDOW_MS
    return {"used": used, "limit": limit, "reset_at_ms": reset_at_ms}


def usage(args):
    """Per-actor (daemon vs each agent workspace) Core/GraphQL usage and ceilings.

    Reads every policy row (the broker's actor inventory) and each actor's
    rolling-hour admissions, so one command answers "which actor is driving the
    shared hourly budget" across every credential the broker has seen.
    """
    now = now_ms()
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        cleanup(conn, now)
        policies = conn.execute(
            "SELECT COALESCE(bindings.identity_key, policies.token_key), policies.token_key, "
            "policies.consumer_key, policies.consumer_label, policies.core_limit_per_hour, policies.graphql_limit_per_hour "
            "FROM policies LEFT JOIN credential_bindings AS bindings ON bindings.token_key = policies.token_key "
            "ORDER BY COALESCE(bindings.identity_key, policies.token_key), policies.consumer_key"
        ).fetchall()
        actors = [
            {
                "token_key": reported_key,
                "consumer_key": consumer_key,
                "consumer_label": consumer_label,
                "core": usage_figure(conn, storage_key, consumer_key, "core", core_limit, now),
                "graphql": usage_figure(conn, storage_key, consumer_key, "graphql", graphql_limit, now),
            }
            for reported_key, storage_key, consumer_key, consumer_label, core_limit, graphql_limit in policies
        ]
        conn.execute("COMMIT")
        print(json.dumps({"schema_version": 1, "actors": actors}))
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def meter(args):
    """One actor/resource figure for hold diagnostics on the request path."""
    now = now_ms()
    conn = connection(args.db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        cleanup(conn, now)
        limits = conn.execute(
            "SELECT core_limit_per_hour, graphql_limit_per_hour FROM policies "
            "WHERE token_key = ? AND consumer_key = ?",
            (args.token_key, args.consumer_key),
        ).fetchone()
        limit = 0 if limits is None else limits[1 if args.resource == "graphql" else 0]
        figure = usage_figure(conn, args.token_key, args.consumer_key, args.resource, limit, now)
        conn.execute("COMMIT")
        print(json.dumps(figure))
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
    common.add_argument("--identity-key")

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
    # Per-actor hourly ceilings (#2181). 0 disables the ceiling for this
    # consumer; the broker stores them on the policy row so the usage report can
    # print each actor's limit without another round trip.
    acquire_parser.add_argument("--core-limit", type=lambda value: clamp(value, 0, 100000), default=0)
    acquire_parser.add_argument("--graphql-limit", type=lambda value: clamp(value, 0, 100000), default=0)
    # Display-only actor label (the raw consumer identity, e.g.
    # `daemon:node@host` or `workspace:/path/to/2181`). The consumer_key remains
    # the fingerprint; this is what `usage` prints so the report is readable.
    acquire_parser.add_argument("--consumer-label", default="")
    # Coalescing (#2073 U6). Absent, admission behaves exactly as it did before.
    acquire_parser.add_argument("--cache-key", default=None)
    acquire_parser.add_argument("--cache-claim-ttl-ms", type=lambda value: clamp(value, 1000, 600000), default=35000)
    acquire_parser.add_argument("--cache-ignore-claim", action="store_true")
    acquire_parser.set_defaults(fun=acquire)

    release_parser = commands.add_parser("release", parents=[common])
    release_parser.add_argument("--lease-id", required=True)
    release_parser.set_defaults(fun=release)

    reconcile_parser = commands.add_parser("reconcile", parents=[common])
    reconcile_parser.add_argument("--lease-id", required=True)
    reconcile_parser.add_argument("--status", type=lambda value: clamp(value, 100, 599), required=True)
    reconcile_parser.set_defaults(fun=reconcile)

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

    # Per-actor usage report. It spans every credential the broker has seen, so
    # it takes no `--token-key`: the report is the whole actor inventory, not one
    # consumer's slice of it.
    usage_parser = commands.add_parser("usage")
    usage_parser.add_argument("--db", required=True)
    usage_parser.set_defaults(fun=usage)

    meter_parser = commands.add_parser("meter", parents=[common])
    meter_parser.add_argument("--consumer-key", required=True)
    meter_parser.add_argument("--resource", choices=("core", "graphql"), required=True)
    meter_parser.set_defaults(fun=meter)
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
