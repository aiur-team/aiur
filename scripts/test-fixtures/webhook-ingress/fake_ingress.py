#!/usr/bin/env python3
"""Loopback stand-in for a tunnel's public edge, for testing the ingress guard.

Modes model the postures `scripts/verify-webhook-ingress` has to tell apart:

  scoped     the intended posture: the webhook path reaches a receiver that
             rejects an unsigned delivery with 401; everything else is answered
             by the ingress catch-all with 404.
  scoped-403 the same posture with a 403 default-deny catch-all.
  generic-401 a false positive candidate: an unrelated edge authentication
             policy answers the webhook with 401 while denying everything else.
  wide-open  the failure this ticket exists to prevent: the tunnel forwards the
             origin root, so the dashboard and every /api/v1/* route answer 200.
  unsigned   the receiver is reachable but accepts a delivery with no signature.
  misrouted  the catch-all answers everything, including the webhook path: a
             tunnel that is scoped so tightly it delivers nothing. Every
             not-publicly-routable assertion passes here, so the reachability
             assertion is the only thing that can catch it.
  post-leak  the webhook and one POST-only API route are published while every
             GET outside the webhook still receives the edge 404. This catches
             a verifier that mistakes a GET-only sample for route scoping.

The five modes above collapse the edge and the daemon into one process, which
is all the guard's scoping assertions need. AC 5 -- "restarting the daemon does
not change the webhook URL" -- is about the seam *between* those two tiers, so
it needs them apart:

  origin     the daemon alone: 401 on the webhook path, 404 elsewhere. Takes
             `--port` to model a pinned `server.port`; without it the OS assigns
             a fresh port on every start, which is what an unpinned daemon does.
  edge       the tunnel alone: forwards the webhook path to `--origin-port` and
             answers every other path from its own catch-all, so a route added
             to the daemon later is not silently published. Answers 502 when the
             origin does not accept the connection -- what Cloudflare returns
             once a restarted daemon comes back on a different port.

Restarting an `origin` behind a long-lived `edge` is the restart invariant: the
edge's port never moves, so whether the public URL survives depends entirely on
whether the origin's did.

Prints the bound port on stdout, then serves until killed.
"""

import argparse
import http.client
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

WEBHOOK_PATH = "/api/v1/github/webhook"
INVALID_SIGNATURE_BODY = b'{"error":"invalid signature","code":"invalid_signature"}'


def build_handler(mode):
    class Handler(BaseHTTPRequestHandler):
        # Silence the default one-line-per-request stderr log so a failing test
        # shows the guard's own output rather than a wall of request lines.
        def log_message(self, fmt, *args):
            pass

        def _reply(self, status, body=b""):
            self.send_response(status)
            if body:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            if mode == "wide-open":
                self._reply(200)
            elif mode == "misrouted":
                self._reply(404)
            elif self.path.split("?")[0] == WEBHOOK_PATH:
                # GitHub only ever POSTs here; the guard does not GET it.
                self._reply(405)
            else:
                self._reply(403 if mode == "scoped-403" else 404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)

            if mode == "misrouted":
                self._reply(404)
            elif mode == "post-leak" and self.path.split("?")[0] == "/api/v1/streamdeck/token":
                self._reply(401)
            elif self.path.split("?")[0] != WEBHOOK_PATH:
                self._reply(200 if mode == "wide-open" else (403 if mode == "scoped-403" else 404))
            elif mode == "unsigned":
                self._reply(202)
            elif mode == "generic-401":
                self._reply(401)
            else:
                self._reply(401, INVALID_SIGNATURE_BODY)

    return Handler


def build_origin_handler():
    """The daemon alone, with no tunnel in front of it."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _reply(self, status, body=b""):
            self.send_response(status)
            if body:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self):
            self._reply(405 if self.path.split("?")[0] == WEBHOOK_PATH else 404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)

            if self.path.split("?")[0] == WEBHOOK_PATH:
                self._reply(401, INVALID_SIGNATURE_BODY)
            else:
                self._reply(404)

    return Handler


def build_edge_handler(origin_port):
    """The tunnel alone: one published route, everything else default-denied."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _reply(self, status, body=b"", content_type=None):
            self.send_response(status)
            if content_type:
                self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _forward(self, method, body):
            # A real edge holds no state about the origin beyond its address, so
            # a moved origin surfaces here as a refused connection and nothing
            # else. Answering 502 is what Cloudflare does in that case, and it
            # is the status the guard has to interpret correctly.
            try:
                conn = http.client.HTTPConnection("127.0.0.1", origin_port, timeout=5)
                conn.request(method, self.path, body=body)
                response = conn.getresponse()
                self._reply(response.status, response.read(), response.getheader("Content-Type"))
                conn.close()
            except OSError:
                self._reply(502)

        def do_GET(self):
            if self.path.split("?")[0] == WEBHOOK_PATH:
                self._forward("GET", None)
            else:
                self._reply(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None

            if self.path.split("?")[0] == WEBHOOK_PATH:
                self._forward("POST", body)
            else:
                self._reply(404)

    return Handler


def main():
    modes = (
        "scoped",
        "scoped-403",
        "generic-401",
        "wide-open",
        "unsigned",
        "misrouted",
        "post-leak",
        "origin",
        "edge",
    )

    parser = argparse.ArgumentParser(prog="fake_ingress.py")
    parser.add_argument("mode", choices=modes)
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="port to bind; models a pinned server.port. Default 0 (OS-assigned).",
    )
    parser.add_argument(
        "--origin-port",
        type=int,
        help="required by `edge`: the origin port the published route forwards to.",
    )
    args = parser.parse_args()

    if args.mode == "edge":
        if args.origin_port is None:
            parser.error("edge requires --origin-port")
        handler = build_edge_handler(args.origin_port)
    elif args.mode == "origin":
        handler = build_origin_handler()
    else:
        handler = build_handler(args.mode)

    server = HTTPServer(("127.0.0.1", args.port), handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
