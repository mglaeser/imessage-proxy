#!/usr/bin/env python3
"""Minimal HTTP bridge used only by the pinned Caddy facade integration test."""

from __future__ import annotations

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


EXPECTED_TOKEN = os.environ["FAKE_BRIDGE_TOKEN"]
EXPECTED_CALLER = os.environ["FAKE_BRIDGE_CALLER"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeBridge/1.0"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def respond(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("X-Content-Type-Options", "unsafe")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def facade_headers_valid(self) -> bool:
        return (
            self.headers.get("Authorization") == f"Bearer {EXPECTED_TOKEN}"
            and self.headers.get("X-API-Client") == EXPECTED_CALLER
        )

    def reject_bad_facade_headers(self) -> bool:
        if self.facade_headers_valid():
            return False
        self.respond(502, b'{"error":"invalid facade headers"}')
        return True

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.reject_bad_facade_headers():
            return
        if self.path == "/healthz":
            self.respond(200, b'{"status":"ok","version":"facade-test"}')
            return
        self.respond(404, b'{"error":"not found"}')

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.reject_bad_facade_headers():
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/v1/rpc":
            request = json.loads(body)
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {"ok": True},
            }
            self.respond(200, json.dumps(response, separators=(",", ":")).encode())
            return
        if self.path == "/v2/sessions/sms":
            self.respond(204)
            return
        self.respond(404, b'{"error":"not found"}')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
