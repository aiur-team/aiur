#!/usr/bin/env python3
"""Host-local GitHub request admission broker.

The broker deliberately persists only SHA-256 credential and consumer fingerprints. A
single SQLite transaction covers every decision so independently started Aiur
nodes and their shell wrappers share the same leases, rate ceiling, stagger,
and cooldowns. Daemons use a resident line protocol; shell wrappers retain
the one-shot CLI against the same database.
"""

import argparse
import contextlib
import io
import json
import os
import queue
import threading
import itertools
import secrets
import sqlite3
import sys
import time
sys.path.insert(0, os.path.dirname(__file__))
import github_budget_metrics as broker_metrics


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
# The version of this broker's ledger interpretation, stamped into `broker_meta`
# by the newest broker to write. A broker that *carries this check* and is older
# than the stamp refuses to write, loudly, rather than silently writing rows the
# newer broker cannot read. This is forward-looking: pre-#2307 brokers have no
# such check, so the currently-deployed stale population is stopped by the
# `admissions_require_lease` trigger instead. The stamp is what protects the
# *next* schema change, when the brokers being refused will be #2307-era ones
# that do carry this check. Bump it whenever the on-disk shape or meaning of any
# table changes in a way an older broker would get wrong (#2307).
BROKER_VERSION = 1


class LedgerTooNewError(Exception):
    """Raised when this broker is older than the ledger's version stamp."""


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


SESSION_CONNECTIONS = None


def connection(path):
    if SESSION_CONNECTIONS is not None and path in SESSION_CONNECTIONS:
        return SESSION_CONNECTIONS[path]
    if SESSION_CONNECTIONS is not None:
        for cached in SESSION_CONNECTIONS.values():
            cached.conn.close()
        SESSION_CONNECTIONS.clear()
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
    broker_metrics.configure_connection(conn)
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
          resource TEXT,
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
          search_limit_per_hour INTEGER NOT NULL DEFAULT 0,
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
        CREATE TABLE IF NOT EXISTS broker_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """
    )
    migrate(conn)
    if SESSION_CONNECTIONS is not None:
        wrapped = broker_metrics.SessionConnection(conn)
        SESSION_CONNECTIONS[path] = wrapped
        return wrapped
    return conn


# SQLite has no `ALTER TABLE ADD COLUMN IF NOT EXISTS`, so adding one is a read
# of `PRAGMA table_info` followed by a write — and the daemon plus up to sixteen
# agents run this on the same file, in separate processes, with nothing between
# them. On a cold start they all read the same column set before any of them
# writes, so they all decide the column is missing and all try to add it. One
# wins; every other one is handed `duplicate column name` for a column that is
# now, by the only definition that matters, present.
#
# That is the outcome this comment has always claimed was "ignored" — it was
# not, and the exception aborted the broker with exit 1. The guard collapsed
# that into `GitHub budget broker unavailable` and refused the call, which is
# how a fresh ledger could refuse most of a simultaneous fleet's first reads
# (#2499). Losing this race is success: the column exists and the loser's own
# check would now agree.
def _add_column(conn, table, column, definition):
    try:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
    except sqlite3.OperationalError as error:
        if "duplicate column name" not in str(error).lower():
            raise


# `CREATE TABLE IF NOT EXISTS` does not add columns to a table that predates
# them. Existing broker databases were created without the per-actor columns, so
# they must be migrated in place.
def migrate(conn):
    admissions_columns = {row[1] for row in conn.execute("PRAGMA table_info(admissions)").fetchall()}
    if "consumer_key" not in admissions_columns:
        _add_column(conn, "admissions", "consumer_key", "TEXT NOT NULL DEFAULT ''")
    if "lease_id" not in admissions_columns:
        _add_column(conn, "admissions", "lease_id", "TEXT")
    if "billable" not in admissions_columns:
        _add_column(conn, "admissions", "billable", "INTEGER NOT NULL DEFAULT 1")
    # The resource the guard booked this admission to (core / graphql / unknown).
    # The broker's accounting buckets on `endpoint_family`, so this column does
    # not change how a row is counted; it records what the caller *said* it was
    # spending, which makes a guard that books a GraphQL call to core detectable
    # from the ledger instead of only inferable from the family-to-bucket map.
    if "resource" not in admissions_columns:
        _add_column(conn, "admissions", "resource", "TEXT")
    # A lease-less admission is of unknown status, not free: no lease means
    # nothing can ever prove it was a `304`, and the safe default for unknown is
    # billable. Stale pre-#2284 writers that could not take a lease are stopped
    # at the schema (version stamp + lease trigger, #2307) rather than by
    # redefining what counts as spend.
    if "billable_reason" not in admissions_columns:
        _add_column(conn, "admissions", "billable_reason", "TEXT")
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
        _add_column(conn, "policies", "consumer_label", "TEXT NOT NULL DEFAULT ''")
    if "core_limit_per_hour" not in policies_columns:
        _add_column(conn, "policies", "core_limit_per_hour", "INTEGER NOT NULL DEFAULT 0")
    if "graphql_limit_per_hour" not in policies_columns:
        _add_column(conn, "policies", "graphql_limit_per_hour", "INTEGER NOT NULL DEFAULT 0")
    if "search_limit_per_hour" not in policies_columns:
        _add_column(conn, "policies", "search_limit_per_hour", "INTEGER NOT NULL DEFAULT 0")


def _ledger_version(conn):
    row = conn.execute("SELECT value FROM broker_meta WHERE key = 'broker_version'").fetchone()
    if row is None:
        return None
    try:
        return int(row[0])
    except (TypeError, ValueError):
        return None


# The newest broker to open a ledger stamps its version. A broker older than the
# stamp refuses every write below (`_ensure_writable`); it never downgrades the
# stamp, so a freshly-written ledger cannot be silently regressed by an older
# writer. A broker at or above the stamp (or opening a ledger with no stamp yet,
# e.g. one created by a pre-#2307 broker) advances the stamp to its own version,
# which is the designed upgrade path.
def _stamp_ledger(conn):
    version = _ledger_version(conn)
    if version is None or version <= BROKER_VERSION:
        conn.execute(
            "INSERT INTO broker_meta(key, value) VALUES ('broker_version', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (str(BROKER_VERSION),),
        )


def _ensure_writable(conn):
    version = _ledger_version(conn)
    if version is not None and version > BROKER_VERSION:
        raise LedgerTooNewError(
            f"refusing to write: ledger is stamped version {version}, this broker is version {BROKER_VERSION}; "
            "install the current broker (a dispatch re-installs the daemon's broker into the workspace)"
        )


# Write commands run this after `_ensure_writable` and before touching data. It
# installs the schema trigger that refuses a pre-#2284 broker's lease-less
# admission INSERT and advances the ledger's version stamp. Both are writes, so
# read-only commands (snapshot/usage/meter) must not run them against the shared
# ledger just to report on it; the first current-broker write after a deploy
# installs them, which is the earliest a stale broker can be stopped (#2307).
def _prepare_writable(conn):
    if isinstance(conn, broker_metrics.SessionConnection) and conn.prepared:
        return
    conn.execute(
        """
        CREATE TRIGGER IF NOT EXISTS admissions_require_lease
        BEFORE INSERT ON admissions
        WHEN NEW.lease_id IS NULL OR NEW.lease_id = ''
        BEGIN
          SELECT RAISE(ABORT, 'refusing admission without a lease_id: this broker predates the ledger schema');
        END;
        """
    )
    _stamp_ledger(conn)
    if isinstance(conn, broker_metrics.SessionConnection):
        conn.prepared = True


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
