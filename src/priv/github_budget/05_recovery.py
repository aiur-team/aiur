# SQLite connections pin the ledger until closed. A recovery first blocks new
# pins, then waits for active commands and idle resident sessions to release theirs.
class LedgerNeedsRecovery(Exception):
    pass


def close_sessions():
    for path in list(SESSION_CONNECTIONS):
        SESSION_CONNECTIONS.pop(path).stack.close()


def yield_ledger_for_recovery():
    for path in SESSION_CONNECTIONS:
        try:
            with broker_metrics.ledger_lock(path + ".recovery-lock", fcntl.LOCK_SH):
                pass
        except OSError:
            close_sessions()
            break


def corruption_error(error):
    if isinstance(error, LedgerNeedsRecovery):
        return True
    if not isinstance(error, sqlite3.DatabaseError):
        return False
    code = getattr(error, "sqlite_errorcode", None)
    if code is not None:
        return code & 0xff in (sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB)
    return str(error) in ("database disk image is malformed", "file is not a database")


def check_integrity(conn):
    try:
        result, = conn.execute("PRAGMA integrity_check(1)").fetchone()
    except sqlite3.DatabaseError as error:
        if not corruption_error(error):
            raise
        return str(error)
    return None if result == "ok" else result


def integrity_problem(path):
    with contextlib.closing(sqlite3.connect(path, timeout=0.05, isolation_level=None)) as conn:
        return check_integrity(conn)


def repair_indexes(path):
    try:
        with contextlib.closing(sqlite3.connect(path, timeout=0.05, isolation_level=None)) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("REINDEX")
            if check_integrity(conn) is None:
                return True
            conn.execute("ROLLBACK")
    except sqlite3.DatabaseError as error:
        # Duplicates in table data can prevent a unique index from being rebuilt.
        if not corruption_error(error) and not isinstance(error, sqlite3.IntegrityError):
            raise
    return False


def archive_ledger(path, pending):
    # Finish a partial move before any broker opens the live path again.
    os.makedirs(pending, mode=0o700, exist_ok=True)
    # The guard and daemon share writable budget storage. Keep archive writes
    # within the directory we opened even if its name is replaced concurrently.
    destination = os.open(pending, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for suffix in ("-wal", "-shm", "-journal", ""):
            source = path + suffix
            if os.path.exists(source):
                os.rename(source, os.path.basename(source), dst_dir_fd=destination)
    finally:
        os.close(destination)
    archive = tempfile.mkdtemp(prefix=os.path.basename(path) + ".corrupt-", dir=os.path.dirname(path))
    os.rename(pending, archive)
    return archive


def report_recovery(path, action, problem, archive=None):
    event = {"event": "sqlite_recovery", "path": path, "action": action, "problem": problem[:500], "archive": archive}
    if RESIDENT:
        print(json.dumps(event), flush=True)
    else:
        print(f"aiur github budget ledger recovery: {json.dumps(event)}", file=sys.stderr, flush=True)


def recover_ledger(path, cause):
    close_sessions()
    archive = None
    try:
        with broker_metrics.ledger_lock(path + ".recovery-lock", fcntl.LOCK_EX, wait_ms=5000):
            with broker_metrics.ledger_lock(path + ".connections", fcntl.LOCK_EX, wait_ms=5000):
                result = recover_locked_ledger(path)
                if result is None:
                    return
                problem, archive = result
                if archive is not None:
                    with contextlib.closing(open_ledger(path)):
                        pass
                report_recovery(path, "rebuilt" if archive else "reindexed", problem, archive)
    except (OSError, sqlite3.Error) as error:
        report_recovery(path, "archived" if archive else "failed", f"Recovery failed: {error}; original error: {cause}", archive)
        raise


def recover_locked_ledger(path):
    pending = path + ".recovery-pending"
    if os.path.isdir(pending):
        problem = "interrupted corrupt ledger archive"
    else:
        problem = integrity_problem(path) if os.path.exists(path) else None
        if problem is None:
            return None
        if repair_indexes(path):
            return problem, None
    return problem, archive_ledger(path, pending)
