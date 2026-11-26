"""Strict fixture peer: emit recorded input only after the expected output."""
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
ids = {}
for row in rows:
    msg = row["msg"]
    if row["dir"] == "out":
        actual = json.loads(sys.stdin.readline())
        with open(sys.argv[2], "a", encoding="utf-8") as frames:
            frames.write(json.dumps(actual) + "\n")
        if msg.get("id") in (4, 5):
            ids[msg["id"]] = actual.get("id")
        expected = dict(msg)
        if expected.get("id") in ids:
            expected["id"] = ids[expected["id"]]
        if actual != expected:
            raise AssertionError(f"Expected {expected!r}, got {actual!r}")
    else:
        msg = dict(msg)
        if msg.get("id") in ids:
            msg["id"] = ids[msg["id"]]
        print(json.dumps(msg), flush=True)
# Pipe ordering makes this an acknowledgement of every frame, including the last.
assert json.loads(sys.stdin.readline()) == {"replay": "done"}
print(json.dumps({"jsonrpc": "2.0", "id": 999999, "result": {"replayed": len(rows)}}), flush=True)
for _ in sys.stdin:
    raise AssertionError("Unexpected frame after end of fixture")
