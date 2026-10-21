"""Timing helpers and background WAL checkpoints for the resident broker."""

import json
import queue
import secrets
import sqlite3
import threading
import time


CHECKPOINT_REQUESTS = None
CHECKPOINT_RESULTS = None
CHECKPOINT_LOCK = None


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


def schedule_checkpoint(db):
    if CHECKPOINT_REQUESTS is None:
        return
    try:
        CHECKPOINT_REQUESTS.put_nowait(db)
    except queue.Full:
        pass


def start_checkpoint_worker():
    global CHECKPOINT_REQUESTS, CHECKPOINT_RESULTS, CHECKPOINT_LOCK
    CHECKPOINT_REQUESTS = queue.Queue(maxsize=1)
    CHECKPOINT_RESULTS = {}
    CHECKPOINT_LOCK = threading.Lock()

    def run():
        while True:
            db = CHECKPOINT_REQUESTS.get()
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
            except sqlite3.Error:
                result = {"sqlite_checkpoint_ms": (time.monotonic_ns() - started_ns) / 1_000_000}
            with CHECKPOINT_LOCK:
                CHECKPOINT_RESULTS[db] = result

    threading.Thread(target=run, daemon=True).start()


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
    while True:
        active = [(request, args) for request, args in requests if request["deadline_ms"] - commit_margin_ms > now_ms()]
        for request, _args in requests:
            if request["deadline_ms"] - commit_margin_ms <= now_ms():
                replies.append({"id": request["id"], "status": 2, "output": "broker deadline expired waiting for SQLite", "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0), "python_queue_depth": request.get("_python_queue_depth", 0)})
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
