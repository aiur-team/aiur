"""Timing helpers for the resident GitHub budget broker."""

import json
import secrets
import sqlite3
import time


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


def successful_replies(replies, requests, sqlite_open_ms, lock_wait_ms, transaction_ms):
    for reply in replies:
        request = requests.get(reply["id"], {})
        reply.update({
            "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0),
            "python_queue_depth": request.get("_python_queue_depth", 0),
            "sqlite_open_ms": sqlite_open_ms,
            "sqlite_lock_wait_ms": lock_wait_ms,
            "sqlite_transaction_ms": transaction_ms,
        })
    return replies


def failed_replies(error, requests, local_timeout, sqlite_open_ms, transaction_ms):
    return [{
        "id": request["id"], "status": 2 if local_timeout else 1, "output": str(error),
        "python_queue_wait_ms": request.get("_python_queue_wait_ms", 0),
        "python_queue_depth": request.get("_python_queue_depth", 0),
        "sqlite_open_ms": sqlite_open_ms,
        "sqlite_lock_wait_ms": 0,
        "sqlite_transaction_ms": transaction_ms,
    } for request, _args in requests]
