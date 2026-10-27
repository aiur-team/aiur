#!/usr/bin/env python3
"""Forward a guarded budget command to the local Aiur daemon."""

import json
import socket
import sys


def main():
    if len(sys.argv) < 3:
        return 2
    path, *args = sys.argv[1:]
    # The client deliberately strips local ledger credentials. The daemon owns
    # both the token file and database URL and derives the shared key itself.
    filtered = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ("--db", "--token-key", "--identity-key"):
            skip = True
            continue
        filtered.append(arg)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(120)
            client.connect(path)
            payload = json.dumps({"args": filtered}, separators=(",", ":")).encode() + b"\n"
            client.sendall(payload)
            chunks = []
            while not chunks or not chunks[-1].endswith(b"\n"):
                chunk = client.recv(65536)
                if not chunk:
                    raise OSError("daemon closed socket")
                chunks.append(chunk)
        response = json.loads(b"".join(chunks))
    except (OSError, TimeoutError):
        return 75
    if response.get("status") == 0:
        sys.stdout.write(response.get("output", ""))
        return 0
    sys.stderr.write("aiur daemon budget error: " + response.get("error", "unknown") + "\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
