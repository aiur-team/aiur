

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
# first. Core is every REST booking; GraphQL is the graphql booking. The bucket
# is the booked `resource` column, NOT the descriptive `endpoint_family`:
# high-level GraphQL commands keep their family (pulls/issues/search) for the
# lease pool and the audit histogram while booking `resource=graphql`, so a
# family can no longer double as the bucket — bucketing on family again would
# count `pr view` against the core window. Anything not booked graphql (core,
# or an unclassified `unknown`) counts against the core window. A `resource`
# ceiling is a request-count ceiling: the broker sees admissions, never the
# GraphQL point price GitHub charged, so this is the coarsest thing that still
# stops one actor from exhausting the shared hourly budget. A reconciled 304 is
# not billable, so it stays in the admissions ledger for RPM accounting but is
# excluded here.
def actor_usage_rows(conn, token_key, consumer_key, resource, now):
    if resource == "graphql":
        resource_clause = "resource = 'graphql'"
    elif resource == "search":
        # GitHub meters `/search/*` against a third pool (`X-Ratelimit-Resource:
        # search`, ~30 req/min rather than 5,000/hr), so `search` is a
        # first-class resource of its own — booking it to core or graphql
        # mis-states the spend and paces nothing against the pool that throttles
        # first.
        resource_clause = "resource = 'search'"
    else:
        # Parentheses are load-bearing: without them `AND resource IS NULL OR
        # resource != ?` binds as `(AND resource IS NULL) OR (resource != ?)`,
        # and the OR branch then matches every non-graphql row on any token or
        # consumer regardless of billable.
        resource_clause = "(resource IS NULL OR resource NOT IN ('graphql', 'search'))"
    # A `304` is reconciled to `billable = 0`. A lease-less row stays billable:
    # its status is unknown, and unknown defaults to billed. Keeping it in the
    # ledger is what GitHub actually charged, and the meter must agree with the
    # ledger.
    return conn.execute(
        "SELECT admitted_at_ms FROM admissions "
        "WHERE token_key = ? AND consumer_key = ? AND billable = 1 AND admitted_at_ms > ? AND "
        + resource_clause
        + " ORDER BY admitted_at_ms ASC",
        (token_key, consumer_key, now - HOURLY_WINDOW_MS),
    ).fetchall()


def actor_ceiling_hold(conn, args, now):
    if args.resource == "graphql":
        limit = args.graphql_limit
    elif args.resource == "search":
        limit = args.search_limit
    else:
        limit = args.core_limit
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
    _ensure_writable(conn)
    _prepare_writable(conn)

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
            "core_limit_per_hour, graphql_limit_per_hour, search_limit_per_hour, observed_at_ms"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(token_key, consumer_key) DO UPDATE SET "
            "consumer_label = excluded.consumer_label, "
            "max_inflight = excluded.max_inflight, "
            "max_inflight_per_endpoint = excluded.max_inflight_per_endpoint, "
            "requests_per_minute = excluded.requests_per_minute, "
            "stagger_ms = excluded.stagger_ms, "
            "core_limit_per_hour = excluded.core_limit_per_hour, "
            "graphql_limit_per_hour = excluded.graphql_limit_per_hour, "
            "search_limit_per_hour = excluded.search_limit_per_hour, "
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
                args.search_limit,
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
            "SELECT MIN(max_inflight) + ?, MIN(max_inflight_per_endpoint) + ?, MIN(requests_per_minute), MAX(stagger_ms) "
            "FROM policies WHERE token_key = ? AND observed_at_ms > ?",
            (int(args.priority), int(args.priority), args.token_key, now - POLICY_RECONCILE_WINDOW_MS),
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
            "INSERT INTO admissions(token_key, consumer_key, lease_id, endpoint_family, resource, admitted_at_ms, billable) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (args.token_key, args.consumer_key, lease_id, args.endpoint_family, args.resource, now, args.billable),
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
    _ensure_writable(conn)
    _prepare_writable(conn)
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
    _ensure_writable(conn)
    _prepare_writable(conn)
    try:
        conn.execute("BEGIN IMMEDIATE")
        resolve_credential_identity(conn, args)
        if args.status == 304:
            conn.execute(
                "UPDATE admissions SET billable = 0, billable_reason = '304' WHERE token_key = ? AND lease_id = ? AND billable = 1",
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
    _ensure_writable(conn)
    _prepare_writable(conn)
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
    _ensure_writable(conn)
    _prepare_writable(conn)
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
