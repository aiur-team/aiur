

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
            "SELECT endpoint_family, resource, admitted_at_ms, billable, billable_reason FROM admissions WHERE token_key = ? ORDER BY id", (args.token_key,)
        ).fetchall()
        conn.execute("COMMIT")
        print(
            json.dumps(
                {
                    "cooldown_until_ms": cooldown[0] if cooldown else 0,
                    "inflight": dict(leases),
                    "admissions": [
                        {"endpoint_family": endpoint_family, "resource": resource, "admitted_at_ms": admitted_at_ms, "billable": bool(billable), "billable_reason": billable_reason}
                        for endpoint_family, resource, admitted_at_ms, billable, billable_reason in admissions
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
            "policies.consumer_key, policies.consumer_label, policies.core_limit_per_hour, "
            "policies.graphql_limit_per_hour, policies.search_limit_per_hour "
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
                "search": usage_figure(conn, storage_key, consumer_key, "search", search_limit, now),
            }
            for reported_key, storage_key, consumer_key, consumer_label, core_limit, graphql_limit, search_limit in policies
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
            "SELECT core_limit_per_hour, graphql_limit_per_hour, search_limit_per_hour FROM policies "
            "WHERE token_key = ? AND consumer_key = ?",
            (args.token_key, args.consumer_key),
        ).fetchone()
        if limits is None:
            limit = 0
        elif args.resource == "graphql":
            limit = limits[1]
        elif args.resource == "search":
            limit = limits[2]
        else:
            limit = limits[0]
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
    acquire_parser.add_argument("--priority", action="store_true", help="main-watch: one lease above each in-flight cap; pacing still applies")
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
    acquire_parser.add_argument("--search-limit", type=lambda value: clamp(value, 0, 100000), default=0)
    # Display-only actor label (the raw consumer identity, e.g.
    # `daemon:node@host` or `workspace:/path/to/2181`). The consumer_key remains
    # the fingerprint; this is what `usage` prints so the report is readable.
    acquire_parser.add_argument("--consumer-label", default="")
    # Free endpoints (`/rate_limit`, anything the shared EndpointPolicy table
    # marks non-billable) are still admitted and leased for ordering, but their
    # admission row is recorded non-billable so the ledger never reports them
    # as spend (#2353). Absent, `1` preserves the original behavior.
    acquire_parser.add_argument("--billable", type=lambda value: 0 if int(value) == 0 else 1, default=1)
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
    meter_parser.add_argument("--resource", choices=("core", "graphql", "search"), required=True)
    meter_parser.set_defaults(fun=meter)
    return root


def execute(args):
    for attempt in range(6):
        try:
            args.fun(args)
            return
        except sqlite3.OperationalError as error:
            if "locked" not in str(error).lower() or attempt == 5:
                raise
            time.sleep(0.01 * (attempt + 1))


def read_requests(inbox):
    broker_metrics.receive_requests(sys.stdin, inbox)


def run_batch(requests, command_parser, queue_depth=0):
    parsed = []
    for request in requests:
        broker_metrics.prepare_request(request, queue_depth)
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                args = command_parser.parse_args(request["args"])
            parsed.append((request, args))
            request["_command_type"] = args.command
        except (Exception, SystemExit) as error:
            yield {"id": request["id"], "status": 1, "output": str(error), "python_queue_wait_ms": request["_python_queue_wait_ms"], "python_queue_depth": queue_depth}
    for db, group in itertools.groupby(parsed, key=lambda item: item[1].db):
        active = []
        for request, args in group:
            if request["deadline_ms"] <= now_ms():
                yield {"id": request["id"], "status": 2, "output": "broker deadline expired before admission", "python_queue_wait_ms": request["_python_queue_wait_ms"], "python_queue_depth": queue_depth, "command_type": request.get("_command_type", "unknown")}
            else:
                active.append((request, args))
        if active:
            yield from run_transaction(db, active)


COMMIT_MARGIN_MS = 50


def begin_batch(conn, requests, replies):
    return broker_metrics.begin_batch(conn, requests, replies, now_ms, COMMIT_MARGIN_MS)


def run_transaction(db, requests):
    requests = list(requests)
    replies = []
    conn = None
    sqlite_open_ms = 0
    transaction_started_ns = None
    try:
        checkpoint = broker_metrics.take_checkpoint_result(db)
        conn, sqlite_open_ms = broker_metrics.open_connection(connection, db)
        acquired, lock_wait_ms = begin_batch(conn, requests, replies)
        if not acquired:
            return broker_metrics.add_open_time(replies, sqlite_open_ms)
        transaction_started_ns = time.monotonic_ns()
        conn.batching = True
        if any(args.command in ("acquire", "release", "reconcile", "renew", "hold") for _request, args in requests):
            _ensure_writable(conn)
            _prepare_writable(conn)
        for request, args in requests:
            conn.conn.execute("SAVEPOINT request")
            output = io.StringIO()
            status = 0
            try:
                if request["deadline_ms"] - COMMIT_MARGIN_MS <= now_ms():
                    raise TimeoutError("broker deadline expired before admission")
                with contextlib.redirect_stdout(output):
                    args.fun(args)
            except Exception as error:
                conn.conn.execute("ROLLBACK TO request")
                status = 2 if isinstance(error, TimeoutError) else 1
                output.write(str(error))
            conn.conn.execute("RELEASE request")
            replies.append({"id": request["id"], "status": status, "output": output.getvalue()})
        expired = {request["id"] for request, _args in requests if request["deadline_ms"] - COMMIT_MARGIN_MS <= now_ms()}
        if expired:
            # Savepoints cannot remove earlier requests after later commands run; roll back and replay live requests.
            conn.conn.execute("ROLLBACK")
            conn.prepared = False
            conn.batching = False
            timed_out = [{"id": request["id"], "status": 2, "output": "broker deadline expired before commit"}
                         for request, _args in requests if request["id"] in expired]
            waiting_replies = [reply for reply in replies if reply["id"] not in {request["id"] for request, _args in requests}]
            remaining = [(request, args) for request, args in requests if request["id"] not in expired]
            return waiting_replies + timed_out + (run_transaction(db, remaining) if remaining else [])
        commit_started_ns = time.monotonic_ns()
        conn.conn.execute("COMMIT")
        commit_ms = (time.monotonic_ns() - commit_started_ns) / 1_000_000
        transaction_ms = (time.monotonic_ns() - transaction_started_ns) / 1_000_000
        for request, _args in requests:
            request["_sqlite_command_ms"] = transaction_ms - commit_ms
            request["_sqlite_commit_ms"] = commit_ms
        return broker_metrics.successful_replies(
            replies,
            {request["id"]: request for request, _args in requests},
            sqlite_open_ms,
            lock_wait_ms,
            transaction_ms,
            broker_metrics.complete_batch(db, conn.conn, checkpoint, requests),
        )
    except Exception as error:
        if conn is not None and conn.in_transaction:
            conn.conn.execute("ROLLBACK")
            conn.prepared = False
        local_timeout = isinstance(error, TimeoutError) or (isinstance(error, sqlite3.OperationalError) and "locked" in str(error).lower())
        active_ids = {request["id"] for request, _args in requests}
        completed = [reply for reply in replies if reply["id"] not in active_ids]
        transaction_ms = 0 if transaction_started_ns is None else (time.monotonic_ns() - transaction_started_ns) / 1_000_000
        failed = broker_metrics.failed_replies(error, requests, local_timeout, sqlite_open_ms, transaction_ms)
        return completed + failed
    finally:
        if conn is not None:
            conn.batching = False


def serve():
    global SESSION_CONNECTIONS
    SESSION_CONNECTIONS = {}
    broker_metrics.start_checkpoint_worker()
    command_parser = parser()
    inbox = queue.Queue(maxsize=64)
    threading.Thread(target=read_requests, args=(inbox,), daemon=True).start()
    finished = False
    try:
        while not finished:
            request = inbox.get()
            if request is None:
                break
            batch = [request]
            while len(batch) < 32:
                try:
                    request = inbox.get_nowait()
                except queue.Empty:
                    break
                if request is None:
                    finished = True
                    break
                batch.append(request)
            # Replies are published only after the batch commits: a granted
            # lease must be durable before a caller may contact GitHub.
            for reply in run_batch(batch, command_parser, inbox.qsize()):
                print(json.dumps(reply), flush=True)
    finally:
        for conn in SESSION_CONNECTIONS.values():
            conn.conn.close()


def main():
    if sys.argv[1:] == ["serve"]:
        serve()
    else:
        execute(parser().parse_args())


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"aiur github budget broker failed: {error}", file=sys.stderr)
        sys.exit(1)
