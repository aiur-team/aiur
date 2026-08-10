#!/usr/bin/env python3
"""Loopback stand-in for a tunnel's public edge, for testing the ingress guard.

Modes model the postures `scripts/verify-webhook-ingress` has to tell apart:

  scoped     the intended posture: the webhook path reaches a receiver that
             rejects an unsigned delivery with 401; everything else is answered
             by the ingress catch-all with 404.
  wide-open  the failure this ticket exists to prevent: the tunnel forwards the
             origin root, so the dashboard and every /api/v1/* route answer 200.
  unsigned   the receiver is reachable but accepts a delivery with no signature.
  misrouted  the catch-all answers everything, including the webhook path: a
             tunnel that is scoped so tightly it delivers nothing. Every
             not-publicly-routable assertion passes here, so the reachability
             assertion is the only thing that can catch it.

Prints the bound port on stdout, then serves until killed.
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

WEBHOOK_PATH = "/api/v1/github/webhook"


def build_handler(mode):
    class Handler(BaseHTTPRequestHandler):
        # Silence the default one-line-per-request stderr log so a failing test
        # shows the guard's own output rather than a wall of request lines.
        def log_message(self, fmt, *args):
            pass

        def _reply(self, status):
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            if mode == "wide-open":
                self._reply(200)
            elif mode == "misrouted":
                self._reply(404)
            elif self.path.split("?")[0] == WEBHOOK_PATH:
                # GitHub only ever POSTs here; the guard does not GET it.
                self._reply(405)
            else:
                self._reply(404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)

            if mode == "misrouted":
                self._reply(404)
            elif self.path.split("?")[0] != WEBHOOK_PATH:
                self._reply(200 if mode == "wide-open" else 404)
            elif mode == "unsigned":
                self._reply(202)
            else:
                self._reply(401)

    return Handler


def main():
    modes = {"scoped", "wide-open", "unsigned", "misrouted"}

    if len(sys.argv) != 2 or sys.argv[1] not in modes:
        print("usage: fake_ingress.py <%s>" % "|".join(sorted(modes)), file=sys.stderr)
        return 2

    server = HTTPServer(("127.0.0.1", 0), build_handler(sys.argv[1]))
    print(server.server_address[1], flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
