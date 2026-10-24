"""Timing helpers and background WAL checkpoints for the resident broker."""

import json
import os
import queue
import secrets
import sqlite3
import sys
import threading
import time


CHECKPOINT_REQUESTS = None
CHECKPOINT_RESULTS = None
CHECKPOINT_LOCK = None
CHECKPOINT_THREAD = None
CHECKPOINT_ACTIVE = None
CHECKPOINT_STARTED_NS = None
LAST_SUCCESSFUL_CHECKPOINT_NS = None
LAST_OBSERVED_WAL_FRAMES = 0
LAST_FALLBACK_ATTEMPT_NS = None
FALLBACK_LOGGED = False
WAL_FRAME_LIMIT = 10_000
FALLBACK_RETRY_NS = 60_000_000_000


class SessionConnection:
    """Keep a request batch on one SQLite connection and transaction."""

    def __init__(self, conn):
        self.conn = conn
        self.prepared = False
        self.batching = False

    def __getattr__(self, name):
        return getattr(self.conn, name)

    def execute(self, sql, *args):
        if self.batching and sql in ("BEGIN IMMEDIATE", "COMMIT"):
            return None
        if self.batching and sql == "ROLLBACK":
            return self.conn.execute("ROLLBACK TO request")
        return self.conn.execute(sql, *args)

    def close(self):
        pass


def configure_connection(conn):
    # Keep automatic WAL checkpoints out of request COMMIT; checkpoint I/O is
    # handled by the passive background worker below. One-shot CLI commands do
    # not start that worker and keep SQLite's automatic checkpoint behavior.
    if CHECKPOINT_REQUESTS is not None:
        conn.execute("PRAGMA wal_autocheckpoint = 0")


def take_checkpoint_result(db):
    if CHECKPOINT_RESULTS is None:
        return None
    if CHECKPOINT_LOCK is None:
        return CHECKPOINT_RESULTS.pop(db, None)
    with CHECKPOINT_LOCK:
        return CHECKPOINT_RESULTS.pop(db, None)


def checkpoint_status(db):
    wal_path = db + "-wal"
    try:
        wal_size = os.path.getsize(wal_path)
    except OSError:
        wal_size = 0
    last = LAST_SUCCESSFUL_CHECKPOINT_NS or CHECKPOINT_STARTED_NS
    age_ms = None if last is None else max((time.monotonic_ns() - last) / 1_000_000, 0)
    return {
        "sqlite_wal_size_bytes": wal_size,
        "sqlite_checkpoint_age_ms": age_ms,
        "sqlite_checkpoint_stale": age_ms is not None and age_ms > 600_000,
    }


def schedule_checkpoint(db):
    if CHECKPOINT_REQUESTS is None:
        return
    try:
        CHECKPOINT_REQUESTS.put_nowait(db)
    except queue.Full:
        pass


def stale_checkpoint(status):
    age = status["sqlite_checkpoint_age_ms"]
    return age is not None and age > 600_000


def complete_batch(db, conn, checkpoint, requests):
    checkpoint = dict(checkpoint or {})
    checkpoint.update(recover_checkpoint_if_needed(db, conn))
    schedule_checkpoint(db)
    for request, _args in requests:
        request["_db_path"] = db
    return checkpoint


def recover_checkpoint_if_needed(db, conn):
    global FALLBACK_LOGGED, LAST_FALLBACK_ATTEMPT_NS, LAST_OBSERVED_WAL_FRAMES, LAST_SUCCESSFUL_CHECKPOINT_NS
    if CHECKPOINT_REQUESTS is None:
        return checkpoint_status(db)
    status = checkpoint_status(db)
    dead_worker = CHECKPOINT_THREAD is None or not CHECKPOINT_THREAD.is_alive()
    frames = LAST_OBSERVED_WAL_FRAMES
    if not dead_worker and frames <= WAL_FRAME_LIMIT and not stale_checkpoint(status):
        return status
    now_ns = time.monotonic_ns()
    if LAST_FALLBACK_ATTEMPT_NS is not None and now_ns - LAST_FALLBACK_ATTEMPT_NS < FALLBACK_RETRY_NS:
        return status
    if dead_worker:
        while True:
            try:
                CHECKPOINT_REQUESTS.get_nowait()
            except queue.Empty:
                break
    elif not CHECKPOINT_REQUESTS.empty() or (CHECKPOINT_ACTIVE is not None and CHECKPOINT_ACTIVE.is_set()):
        return status
    try:
        LAST_FALLBACK_ATTEMPT_NS = now_ns
        conn.execute("PRAGMA busy_timeout = 50")
        busy, total, checkpointed = conn.execute("PRAGMA wal_checkpoint(RESTART)").fetchone()
        if busy == 0 and checkpointed >= total:
            LAST_SUCCESSFUL_CHECKPOINT_NS = time.monotonic_ns()
            LAST_OBSERVED_WAL_FRAMES = 0
            LAST_FALLBACK_ATTEMPT_NS = None
            if dead_worker:
                start_checkpoint_worker()
        if not FALLBACK_LOGGED:
            print("budget broker checkpoint worker fallback checkpoint ran", file=sys.stderr)
            FALLBACK_LOGGED = True
    except sqlite3.Error:
        pass
    return checkpoint_status(db)


def start_checkpoint_worker():
    global CHECKPOINT_REQUESTS, CHECKPOINT_RESULTS, CHECKPOINT_LOCK, CHECKPOINT_THREAD, CHECKPOINT_ACTIVE, CHECKPOINT_STARTED_NS
    CHECKPOINT_STARTED_NS = time.monotonic_ns()
    CHECKPOINT_REQUESTS = queue.Queue(maxsize=1)
    CHECKPOINT_RESULTS = {}
    CHECKPOINT_LOCK = threading.Lock()
    CHECKPOINT_ACTIVE = threading.Event()

    def run():
        global LAST_OBSERVED_WAL_FRAMES, LAST_SUCCESSFUL_CHECKPOINT_NS
        while True:
            db = CHECKPOINT_REQUESTS.get()
            CHECKPOINT_ACTIVE.set()
            started_ns = time.monotonic_ns()
            try:
                conn = sqlite3.connect(db, timeout=0.05, isolation_level=None)
                try:
                    busy, frames, checkpointed = conn.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()
                finally:
                    conn.close()
                result = {
                    "sqlite_checkpoint_ms": (time.monotonic_ns() - started_ns) / 1_000_000,
                    "sqlite_checkpoint_busy": busy,
                    "sqlite_wal_frames": frames,
                    "sqlite_checkpointed_frames": checkpointed,
                }
                LAST_OBSERVED_WAL_FRAMES = frames
                if busy == 0 and checkpointed >= frames:
                    LAST_SUCCESSFUL_CHECKPOINT_NS = time.monotonic_ns()
            except sqlite3.Error:
                result = {"sqlite_checkpoint_ms": (time.monotonic_ns() - started_ns) / 1_000_000}
            with CHECKPOINT_LOCK:
                CHECKPOINT_RESULTS[db] = result
            CHECKPOINT_ACTIVE.clear()

    CHECKPOINT_THREAD = threading.Thread(target=run, daemon=True)
    CHECKPOINT_THREAD.start()


def receive_requests(lines, inbox):
    try:
        for line in lines:
            inbox.put(received(json.loads(line)))
    finally:
        inbox.put(None)


def received(request):
    request["_received_ns"] = time.monotonic_ns()
    return request


def prepare_request(request, queue_depth):
    request["_python_queue_wait_ms"] = max((time.monotonic_ns() - request.get("_received_ns", time.monotonic_ns())) / 1_000_000, 0)
    request["_python_queue_depth"] = queue_depth


def open_connection(connection, db):
    started_ns = time.monotonic_ns()
    conn = connection(db)
    return conn, (time.monotonic_ns() - started_ns) / 1_000_000


def begin_batch(conn, requests, replies, now_ms, commit_margin_ms):
    started_ns = time.monotonic_ns()
    reported_wait_ns = 0
    while True:
        active = [(request, args) for request, args in requests if request["deadline_ms"] - commit_margin_ms > now_ms()]
        for request, _args in requests:
            if request["deadline_ms"] - commit_margin_ms <= now_ms():
                replies.append({"id": request["id"], "status": 2, "output": "broker deadline expired waiting for SQLite", "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0), "python_queue_depth": request.get("_python_queue_depth", 0), "command_type": request.get("_command_type", "unknown")})
        requests[:] = active
        if not requests:
            lock_wait_ms = (time.monotonic_ns() - started_ns) / 1_000_000
            add_lock_wait(replies, lock_wait_ms)
            return False, lock_wait_ms
        remaining = min(request["deadline_ms"] for request, _args in requests) - commit_margin_ms - now_ms()
        if remaining > 0:
            conn.conn.execute(f"PRAGMA busy_timeout = {min(remaining, 20)}")
            try:
                conn.conn.execute("BEGIN IMMEDIATE")
                return True, (time.monotonic_ns() - started_ns) / 1_000_000
            except sqlite3.OperationalError as error:
                if "locked" not in str(error).lower():
                    raise
                elapsed_ns = time.monotonic_ns() - started_ns
                if elapsed_ns - reported_wait_ns >= 100_000_000:
                    print(json.dumps({
                        "event": "sqlite_lock_wait",
                        "ids": [request["id"] for request, _args in requests],
                        "sqlite_lock_wait_ms": elapsed_ns / 1_000_000,
                    }), flush=True)
                    reported_wait_ns = elapsed_ns
                time.sleep(min(remaining, 2 + secrets.randbelow(9)) / 1000)


def add_lock_wait(replies, lock_wait_ms):
    for reply in replies:
        reply["sqlite_lock_wait_ms"] = lock_wait_ms
        reply["sqlite_transaction_ms"] = 0


def add_open_time(replies, sqlite_open_ms):
    for reply in replies:
        reply["sqlite_open_ms"] = sqlite_open_ms
    return replies


def successful_replies(replies, requests, sqlite_open_ms, lock_wait_ms, transaction_ms, checkpoint=None):
    for reply in replies:
        request = requests.get(reply["id"], {})
        reply.update({
            "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0),
            "python_queue_depth": request.get("_python_queue_depth", 0),
            "sqlite_open_ms": sqlite_open_ms,
            "sqlite_lock_wait_ms": lock_wait_ms,
            "sqlite_transaction_ms": transaction_ms,
            "sqlite_command_ms": request.get("_sqlite_command_ms", transaction_ms),
            "sqlite_commit_ms": request.get("_sqlite_commit_ms", 0),
            "command_type": request.get("_command_type", "unknown"),
        })
        if checkpoint:
            reply.update(checkpoint)
        reply.update(checkpoint_status(request.get("_db_path", "")) if request.get("_db_path") else {})
    return replies


def failed_replies(error, requests, local_timeout, sqlite_open_ms, transaction_ms):
    return [{
        "id": request["id"], "status": 2 if local_timeout else 1, "output": str(error),
        "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0),
        "python_queue_depth": request.get("_python_queue_depth", 0),
        "sqlite_open_ms": sqlite_open_ms,
        "sqlite_lock_wait_ms": 0,
        "sqlite_transaction_ms": transaction_ms,
        "sqlite_command_ms": request.get("_sqlite_command_ms", transaction_ms),
        "sqlite_commit_ms": request.get("_sqlite_commit_ms", 0),
        "command_type": request.get("_command_type", "unknown"),
    } for request, _args in requests]
